#!/usr/bin/env python3
"""Write data/map-detail.bin: the Map's 1:10m detail, for zooming in, from Natural Earth
(public domain, naturalearthdata.com/about/terms-of-use, read 2026-10-10; GeoJSON from
github.com/nvkelso/natural-earth-vector commit ca96624, geojson/).

    python3 tools/gen_map_detail.py FOLDER

FOLDER holds ne_10m_land, ne_10m_lakes, ne_10m_rivers_lake_centerlines,
ne_10m_admin_0_boundary_lines_land, ne_10m_admin_1_states_provinces_lines,
ne_10m_urban_areas and ne_10m_populated_places_simple (.geojson).

Shapes are simplified (Douglas-Peucker) to a few hundred metres, which is what 1:10m holds.
The file, little-endian, read by src/core/adif_detail.cpp:

    "ADIFMAP1"
    u32 layers; each:
        u8 kind (0 land, 1 lakes, 2 rivers, 3 borders, 4 states, 5 urban areas)
        u32 shapes; each:
            i16 west, south, east, north   (hundredths of a degree, rounded outward)
            u8 rank                        (rivers: scalerank; states: min_zoom x 10; else 0)
            u32 points; then i32 lon, lat of the first (1e-4 degree), and for the rest
            i16 dlon, dlat steps, or i16 -32768, -32768 then i32 lon, lat for a long step
    u32 cities, most populous first; each:
        i32 lon, lat (1e-4 degree), u32 population, u8 min_zoom x 10, u8 name bytes, name (UTF-8)
"""
import json
import math
import pathlib
import struct
import sys

folder = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(__file__).resolve().parent.parent / "data" / "map-detail.bin"

LAYERS = [  # kind, file, tolerance in degrees, rank
    (0, "ne_10m_land", 0.002, lambda p: 0),
    (1, "ne_10m_lakes", 0.002, lambda p: 0),
    (2, "ne_10m_rivers_lake_centerlines", 0.003, lambda p: int(p.get("scalerank") or 0)),
    (3, "ne_10m_admin_0_boundary_lines_land", 0.002, lambda p: 0),
    (4, "ne_10m_admin_1_states_provinces_lines", 0.003, lambda p: min(255, int(round((p.get("MIN_ZOOM") or 0) * 10)))),
    (5, "ne_10m_urban_areas", 0.003, lambda p: 0),
]


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
        length = math.hypot(dx, dy)
        best, at = 0.0, -1
        for k in range(i + 1, j):
            x, y = pts[k]
            d = abs(dy * (x - x0) - dx * (y - y0)) / length if length else math.hypot(x - x0, y - y0)
            if d > best:
                best, at = d, k
        if at >= 0 and best > tolerance:
            keep[at] = True
            stack += [(i, at), (at, j)]
    return [p for p, k in zip(pts, keep) if k]


def parts(geometry):
    if not geometry:
        return []
    kind, c = geometry["type"], geometry["coordinates"]
    if kind == "Polygon":
        return c
    if kind == "MultiPolygon":
        return [ring for poly in c for ring in poly]
    if kind == "LineString":
        return [c]
    if kind == "MultiLineString":
        return c
    return []


def fixed(v):
    return int(round(v * 10000))


out = bytearray(b"ADIFMAP1")
out += struct.pack("<I", len(LAYERS))
for kind, name, tolerance, rank_of in LAYERS:
    data = json.loads((folder / (name + ".geojson")).read_text(encoding="utf-8"))
    shapes = []
    for feature in data["features"]:
        rank = rank_of(feature.get("properties") or {})
        for part in parts(feature.get("geometry")):
            pts = simplify([tuple(c[:2]) for c in part], tolerance)
            q = []
            for lon, lat in pts:
                p = (fixed(lon), fixed(lat))
                if not q or q[-1] != p:
                    q.append(p)
            if len(q) >= 2:
                shapes.append((q, rank))
    out += struct.pack("<BI", kind, len(shapes))
    points = 0
    for q, rank in shapes:
        xs, ys = [p[0] for p in q], [p[1] for p in q]
        box = (math.floor(min(xs) / 100), math.floor(min(ys) / 100), math.ceil(max(xs) / 100), math.ceil(max(ys) / 100))
        out += struct.pack("<hhhhBI", *box, rank, len(q))
        out += struct.pack("<ii", *q[0])
        for (x0, y0), (x1, y1) in zip(q, q[1:]):
            dx, dy = x1 - x0, y1 - y0
            if -32767 <= dx <= 32767 and -32767 <= dy <= 32767:
                out += struct.pack("<hh", dx, dy)
            else:
                out += struct.pack("<hhii", -32768, -32768, x1, y1)
        points += len(q)
    print(f"{name}: {len(shapes)} shapes, {points} points")

places = json.loads((folder / "ne_10m_populated_places_simple.geojson").read_text(encoding="utf-8"))["features"]
cities = []
for feature in places:
    p = feature["properties"]
    name = (p.get("name") or p.get("nameascii") or "").strip().encode("utf-8")[:255]
    if not name or p.get("latitude") is None:
        continue
    cities.append((max(0, int(p.get("pop_max") or 0)), fixed(p["longitude"]), fixed(p["latitude"]), min(255, int(round((p.get("min_zoom") or 0) * 10))), name))
cities.sort(key=lambda c: -c[0])
out += struct.pack("<I", len(cities))
for pop, lon, lat, zoom, name in cities:
    out += struct.pack("<iiIBB", lon, lat, pop, zoom, len(name)) + name
print(f"cities: {len(cities)}")
out_path.write_bytes(bytes(out))
print(f"{out_path}: {len(out)} bytes")
