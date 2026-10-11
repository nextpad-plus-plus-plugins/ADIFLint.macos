#!/usr/bin/env python3
"""Write src/core/adif_overlays_data.cpp: the Map's overlays, each an area with a name and a
place to write it.

    python3 tools/gen_map_overlays.py STATES CQZONES ITUZONES

STATES is Natural Earth's ne_50m_admin_1_states_provinces.geojson (public domain,
naturalearthdata.com/about/terms-of-use, read 2026-10-10; from
github.com/nvkelso/natural-earth-vector, geojson/): the features whose adm0_a3 is USA, named
by their postal code, written at Natural Earth's label point.

CQZONES and ITUZONES are cqzones.geojson and ituzones.geojson from
github.com/HB9HIL/hamradio-zones-geojson, commit 19599364fe316b36182f02dbe99deffab5801111
(2024-10-31; MIT licence, copyright 2024 HB9HIL, in data/zones-license.txt; the data Wavelog
uses; where its lines came from is not stated). Each zone is named by its number
(cq_zone_number, itu_zone_number) and written at its *_name_loc ([lat, lon]). The zones are
drawn in unwrapped longitudes (-205 to 192): each ring is followed in steps of a degree, cut
into the -180..180 world and the parts beyond moved round. Their lines along 85 degrees are
the edge of the web map they were drawn for, not zone lines; the Map leaves them out.

Rings are simplified (Douglas-Peucker, 0.02 degrees for zones, 0.01 for states) and kept in
hundredths of a degree, as adif_world_data.cpp keeps them.
"""
import json
import pathlib
import sys

def rings_of(geometry):
    if not geometry or not geometry.get("coordinates"):
        return []
    if geometry["type"] == "Polygon":
        return geometry["coordinates"]
    if geometry["type"] == "MultiPolygon":
        return [ring for poly in geometry["coordinates"] for ring in poly]
    return []


def densify(ring, step=1.0):
    """The ring (closed) with a point at least every `step` degrees, in its own longitudes."""
    pts = [tuple(c[:2]) for c in ring]
    if pts[0] != pts[-1]:
        pts.append(pts[0])
    out = [pts[0]]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        n = max(1, int(max(abs(x1 - x0), abs(y1 - y0)) / step + 0.999))
        out += [(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n) for k in range(1, n + 1)]
    return out


def clip(ring, x, keep_left):
    """Sutherland-Hodgman: the part of a closed ring left (or right) of the meridian x."""
    inside = (lambda p: p[0] <= x) if keep_left else (lambda p: p[0] >= x)
    out = []
    for a, b in zip(ring, ring[1:] + ring[:1]):
        if inside(b):
            if not inside(a):
                out.append((x, a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0])))
            out.append(b)
        elif inside(a):
            out.append((x, a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0])))
    return out


def into_world(ring):
    """A ring in unwrapped longitudes as rings in -180..180: each 360-degree sheet it reaches, moved round."""
    lo, hi = min(p[0] for p in ring), max(p[0] for p in ring)
    if lo >= -180 and hi <= 180:
        return [ring]
    out = []
    for k in range(-1, 2):
        west, east = -180 + 360 * k, 180 + 360 * k
        if hi <= west or lo >= east:
            continue
        part = clip(clip(ring, west, False), east, True)
        if len(part) >= 3:
            out.append([(x - 360 * k, y) for x, y in part])
    return out


def simplify(pts, tolerance):
    """Douglas-Peucker on an open run of points."""
    if len(pts) < 3:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        (x0, y0), (x1, y1) = pts[i], pts[j]
        dx, dy = x1 - x0, y1 - y0
        length = (dx * dx + dy * dy) ** 0.5
        best, at = 0.0, -1
        for k in range(i + 1, j):
            x, y = pts[k]
            d = abs(dy * (x - x0) - dx * (y - y0)) / length if length else ((x - x0) ** 2 + (y - y0) ** 2) ** 0.5
            if d > best:
                best, at = d, k
        if at >= 0 and best > tolerance:
            keep[at] = True
            stack += [(i, at), (at, j)]
    return [p for p, k in zip(pts, keep) if k]


def quantise(ring):
    pts = []
    for lon, lat in ring:
        p = (round(lon * 100), round(lat * 100))
        if not pts or pts[-1] != p:
            pts.append(p)
    if len(pts) > 1 and pts[0] == pts[-1]:
        pts.pop()
    return pts if len(pts) >= 3 else None


def area_and_middle(pts):
    """The planar (lon, lat) area and centroid of a ring, in hundredths."""
    a = cx = cy = 0.0
    for (x0, y0), (x1, y1) in zip(pts, pts[1:] + pts[:1]):
        cross = x0 * y1 - x1 * y0
        a += cross
        cx += (x0 + x1) * cross
        cy += (y0 + y1) * cross
    if abs(a) < 1e-9:
        return 0.0, pts[0]
    return abs(a) / 2, (round(cx / (3 * a)), round(cy / (3 * a)))


def areas(path, keep, name_of, label_of, tolerance):
    data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    out = {}
    for feature in data["features"]:
        props = feature.get("properties") or {}
        if not keep(props):
            continue
        name = name_of(props)
        rings = []
        for ring in rings_of(feature["geometry"]):
            for part in into_world(densify(ring)[:-1]):
                q = quantise(simplify(part + part[:1], tolerance)[:-1])
                if q:
                    rings.append(q)
        if not name or not rings:
            continue
        entry = out.setdefault(name, {"rings": [], "label": None})
        entry["rings"] += rings
        if entry["label"] is None:
            entry["label"] = label_of(props)
    for entry in out.values():
        if entry["label"] is None:  # the middle of the largest ring
            entry["label"] = max((area_and_middle(r) for r in entry["rings"]), key=lambda t: t[0])[1]
    return out


def number_key(name):
    return (0, int(name)) if name.isdigit() else (1, name)


def state_label(props):
    for x, y in (("label_x", "label_y"), ("longitude", "latitude")):
        if props.get(x) is not None and props.get(y) is not None:
            return (round(props[x] * 100), round(props[y] * 100))
    return None


def zone_label(key):
    def label(props):
        lat, lon = props[key]  # [lat, lon]
        lon = (lon + 180) % 360 - 180
        return (round(lon * 100), round(lat * 100))
    return label


states_path, cq_path, itu_path = sys.argv[1:4]
overlays = [
    ("UsStates", areas(states_path, lambda p: p.get("adm0_a3") == "USA", lambda p: (p.get("postal") or "").strip(), state_label, 0.01)),
    ("CqZones", areas(cq_path, lambda p: True, lambda p: str(p["cq_zone_number"]), zone_label("cq_zone_name_loc"), 0.02)),
    ("ItuZones", areas(itu_path, lambda p: True, lambda p: str(p["itu_zone_number"]), zone_label("itu_zone_name_loc"), 0.02)),
]

out = ["// Generated by tools/gen_map_overlays.py: US states from Natural Earth (public domain,",
       "// naturalearthdata.com); CQ and ITU zones from HB9HIL's hamradio-zones-geojson (MIT,",
       "// copyright 2024 HB9HIL; data/zones-license.txt).",
       "// Do not edit by hand.",
       '#include "adif_world.h"', "", "namespace adif {", "namespace {", "",
       "// Longitude and latitude in hundredths of a degree. Area i's rings are kXArea[i] to",
       "// kXArea[i + 1] in kXRing, ring j's points kXRing[j] to kXRing[j + 1]."]
for name, items in overlays:
    names = sorted(items, key=number_key)
    points, ring_starts, area_starts, labels = [], [0], [0], []
    for n in names:
        for ring in items[n]["rings"]:
            points += ring
            ring_starts.append(len(points))
        area_starts.append(len(ring_starts) - 1)
        labels.append(items[n]["label"])
    out.append(f"const short k{name}Points[] = {{")
    for i in range(0, len(points), 12):
        out.append("    " + ",".join(f"{x},{y}" for x, y in points[i:i + 12]) + ",")
    out.append("};")
    out.append(f"const unsigned k{name}Ring[] = {{")
    for i in range(0, len(ring_starts), 16):
        out.append("    " + ",".join(str(s) for s in ring_starts[i:i + 16]) + ",")
    out.append("};")
    out.append(f"const unsigned k{name}Area[] = {{")
    for i in range(0, len(area_starts), 16):
        out.append("    " + ",".join(str(s) for s in area_starts[i:i + 16]) + ",")
    out.append("};")
    out.append(f"const char *const k{name}Name[] = {{" + ",".join(f'"{n}"' for n in names) + "};")
    out.append(f"const short k{name}Label[] = {{" + ",".join(f"{x},{y}" for x, y in labels) + "};")
    print(f"{name}: {len(names)} areas, {len(ring_starts) - 1} rings, {len(points)} points")

out += ["", "struct Data {", "    const short *points;", "    const unsigned *ring, *area;", "    const char *const *name;",
        "    const short *label;", "    size_t count;", "};", "", "Data data(Overlay o) {", "    switch (o) {"]
for name, _ in overlays:
    out.append(f"        case Overlay::{name}: return {{k{name}Points, k{name}Ring, k{name}Area, k{name}Name, k{name}Label, "
               f"sizeof k{name}Name / sizeof k{name}Name[0]}};")
out += ["    }", "    return {nullptr, nullptr, nullptr, nullptr, nullptr, 0};", "}", "", "}  // namespace", "",
        "size_t overlayCount(Overlay o) { return data(o).count; }", "",
        "OverlayArea overlayArea(Overlay o, size_t i) {",
        "    Data d = data(o);",
        "    OverlayArea a;",
        "    if (i >= d.count) return a;",
        "    a.name = d.name[i];",
        "    a.labelLon = d.label[2 * i] / 100.0, a.labelLat = d.label[2 * i + 1] / 100.0;",
        "    for (unsigned r = d.area[i]; r < d.area[i + 1]; ++r) {",
        "        a.rings.emplace_back();",
        "        for (unsigned k = d.ring[r]; k < d.ring[r + 1]; ++k) a.rings.back().emplace_back(d.points[2 * k] / 100.0, d.points[2 * k + 1] / 100.0);",
        "    }",
        "    return a;", "}", "", "}  // namespace adif"]
pathlib.Path("src/core/adif_overlays_data.cpp").write_text("\n".join(out) + "\n")
