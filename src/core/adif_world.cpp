#include "adif_world.h"

#include "adif_enrich.h"
#include "adif_geo.h"
#include "adif_parks.h"
#include "adif_programs.h"
#include "adif_spec.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <set>

namespace adif {
namespace {

std::string trimmed(std::string_view s) {
    size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
    return b == std::string_view::npos ? std::string() : std::string(s.substr(b, e - b + 1));
}

std::string upper(std::string_view s) {
    std::string o(s);
    for (char &c : o)
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
    return o;
}

bool yes(const std::string &v) {
    std::string t = upper(trimmed(v));
    return t == "Y" || t == "V";
}

// "FN31pr" -> "FN31"; "" when it isn't a grid of 4 or more characters.
std::string square4(std::string_view g) {
    std::string s = upper(trimmed(g));
    if (s.size() < 4 || s[0] < 'A' || s[0] > 'R' || s[1] < 'A' || s[1] > 'R' || s[2] < '0' || s[2] > '9' || s[3] < '0' || s[3] > '9')
        return "";
    return s.substr(0, 4);
}

// A grid's square to draw: none for a placeholder.
std::string usableSquare(std::string_view g) { return isPlaceholderGrid(g) ? "" : square4(g); }

}  // namespace

bool isPlaceholderGrid(std::string_view grid) {
    std::string g = upper(trimmed(grid));
    if (g.size() < 4 || (g.compare(0, 4, "AA00") != 0 && g.compare(0, 4, "JJ00") != 0)) return false;
    return g.size() == 4 || g.substr(4) == "AA" || g.substr(4) == "AA00";
}

bool isPlaceholderPlace(double lat, double lon) {
    if (lat == 0 && lon == 0) return true;
    for (const char *g : {"AA00aa", "JJ00aa"}) {
        double clat = 0, clon = 0;
        gridToLatLon(g, &clat, &clon);
        if (std::fabs(lat - clat) < 1e-6 && std::fabs(lon - clon) < 1e-6) return true;
    }
    return false;
}

bool isConfirmed(const Record &r) { return yes(r.get("QSL_RCVD")) || yes(r.get("LOTW_QSL_RCVD")) || yes(r.get("EQSL_QSL_RCVD")); }

bool squareBounds(std::string_view grid, double *west, double *south, double *east, double *north) {
    std::string s = square4(grid);
    if (s.empty()) return false;
    *west = (s[0] - 'A') * 20.0 - 180.0 + (s[2] - '0') * 2.0;
    *south = (s[1] - 'A') * 10.0 - 90.0 + (s[3] - '0') * 1.0;
    *east = *west + 2.0;
    *north = *south + 1.0;
    return true;
}

std::string squareAt(double lon, double lat) {
    if (!(lon >= -180 && lon < 180 && lat >= -90 && lat < 90)) return "";
    double x = lon + 180, y = lat + 90;
    int fx = (int)(x / 20), fy = (int)(y / 10);
    int sx = (int)((x - fx * 20) / 2), sy = (int)(y - fy * 10);
    return std::string{(char)('A' + fx), (char)('A' + fy), (char)('0' + sx), (char)('0' + sy)};
}

MapData mapData(std::string_view text, const DocModel &m, std::string_view band, std::string_view mode) {
    MapFilter f;
    f.band = std::string(band), f.mode = std::string(mode);
    return mapData(text, m, f);
}

MapData mapData(std::string_view text, const DocModel &m, const MapFilter &filter) {
    MapData out;
    std::map<std::string, size_t> squareIndex;
    std::vector<std::string> mine;
    const std::string &band = filter.band, &mode = filter.mode;
    for (const Record &r : records(text, m)) {
        if (r.fields.empty()) continue;
        if (!band.empty() && !equalsNoCase(effectiveBand(r), band)) continue;
        if (!mode.empty() && !equalsNoCase(trimmed(r.get("MODE")), mode) && !equalsNoCase(trimmed(r.get("SUBMODE")), mode)) continue;
        std::string date8 = trimmed(r.get("QSO_DATE"));
        if (!filter.from.empty() && date8 < filter.from) continue;
        if (!filter.to.empty() && (date8.empty() || date8 > filter.to)) continue;
        bool confirmed = isConfirmed(r);
        if ((filter.confirmed == 1 && !confirmed) || (filter.confirmed == 2 && confirmed)) continue;
        ++out.records;
        std::string call = upper(trimmed(r.get("CALL")));
        size_t index = out.qsos.size();
        {
            MapQso q;
            q.group = r.group;
            q.record = r.number;
            q.call = call;
            q.date = displayDate(trimmed(r.get("QSO_DATE")));
            q.time = displayTime(trimmed(r.get("TIME_ON")));
            q.band = effectiveBand(r);
            std::string sub = trimmed(r.get("SUBMODE"));
            q.mode = sub.empty() ? trimmed(r.get("MODE")) : sub;
            q.grid = trimmed(r.get("GRIDSQUARE"));
            q.date8 = date8;
            q.myGrid = upper(trimmed(r.get("MY_GRIDSQUARE")));
            q.modeGroup = modeGroup(trimmed(r.get("MODE")));
            q.confirmed = confirmed;
            q.iota = iotaRef(r.get("IOTA"));
            for (const std::string &park : theirParks(r))
                if (std::string ref = potaListRef(park); !ref.empty()) q.potaHunted.push_back(ref);
            for (const std::string &park : myParks(r))
                if (std::string ref = potaListRef(park); !ref.empty()) q.potaActivated.push_back(ref);
            bool grid = !usableSquare(q.grid).empty() && gridToLatLon(q.grid, nullptr, nullptr);
            double lat = 0, lon = 0, w, s, e, n;
            if (locationToDegrees(trimmed(r.get("LAT")), true, &lat) && locationToDegrees(trimmed(r.get("LON")), false, &lon)) {
                bool nearGrid = !grid || (squareBounds(q.grid, &w, &s, &e, &n) && lon >= w - 1 && lon <= e + 1 && lat >= s - 0.5 && lat <= n + 0.5);
                if (!isPlaceholderPlace(lat, lon) && nearGrid) q.located = true, q.lat = lat, q.lon = lon, q.locatedBy = "LAT/LON";
                else ++out.unusedLatLon;
            }
            if (!q.located && grid && q.grid.size() >= 6 && gridToLatLon(q.grid, &q.lat, &q.lon)) q.located = true, q.locatedBy = q.grid;
            out.qsos.push_back(std::move(q));
            out.calls.emplace_back(call, confirmed);
        }
        std::vector<std::string> grids;
        if (std::string g = usableSquare(r.get("GRIDSQUARE")); !g.empty()) grids.push_back(g);
        std::string vucc = r.get("VUCC_GRIDS");  // a QSO on a grid line or corner: two or four squares
        for (size_t b = 0; b < vucc.size();) {
            size_t e = vucc.find(',', b);
            if (e == std::string::npos) e = vucc.size();
            if (std::string g = usableSquare(vucc.substr(b, e - b)); !g.empty() && std::find(grids.begin(), grids.end(), g) == grids.end())
                grids.push_back(g);
            b = e + 1;
        }
        if (grids.empty()) ++out.withoutGrid;
        for (const std::string &g : grids) {
            auto it = squareIndex.find(g);
            if (it == squareIndex.end()) {
                it = squareIndex.emplace(g, out.squares.size()).first;
                MapSquare added;
                added.grid = g;
                out.squares.push_back(std::move(added));
            }
            MapSquare &sq = out.squares[it->second];
            ++sq.qsos;
            sq.confirmed |= confirmed;
            sq.qsoIndex.push_back(index);
            if (sq.calls.size() < 6 && std::find(sq.calls.begin(), sq.calls.end(), call) == sq.calls.end()) sq.calls.push_back(call);
        }
        std::string theirGrid = trimmed(r.get("GRIDSQUARE"));
        if (!usableSquare(theirGrid).empty()) {
            std::vector<std::pair<std::string, std::string>> refs;  // (program, reference)
            for (Program p : {Program::POTA, Program::WWFF, Program::SOTA})
                for (const std::string &ref : programRefs(r, p, false)) refs.emplace_back(programName(p), ref);
            std::string sig = upper(trimmed(r.get("SIG")));
            if (!sig.empty() && sig != "POTA" && sig != "WWFF" && sig != "SOTA") {  // other programs: SIG_INFO's list
                std::string info = r.get("SIG_INFO");
                for (size_t b = 0; b < info.size();) {
                    size_t e = info.find(',', b);
                    if (e == std::string::npos) e = info.size();
                    if (std::string ref = upper(trimmed(info.substr(b, e - b))); !ref.empty()) refs.emplace_back(sig, ref);
                    b = e + 1;
                }
            }
            // IOTA: an island group, often filled in by a callbook for every island station, so not a park.
            if (std::string iota = upper(trimmed(r.get("IOTA"))); !iota.empty()) refs.emplace_back("IOTA", iota);
            for (const auto &[program, ref] : refs) {
                MapPark p;
                p.reference = ref, p.grid = theirGrid, p.program = program, p.qso = index;
                out.parks.push_back(std::move(p));
            }
        }
        std::string my = upper(trimmed(r.get("MY_GRIDSQUARE")));
        if (!usableSquare(my).empty() && std::find(out.mine.begin(), out.mine.end(), my) == out.mine.end()) out.mine.push_back(my);
    }
    std::sort(out.squares.begin(), out.squares.end(), [](const MapSquare &a, const MapSquare &b) { return a.grid < b.grid; });
    return out;
}

std::map<int, std::vector<RingRef>> dxccRings(const std::vector<EntityPlace> &places) {
    using Ring = std::vector<std::pair<double, double>>;
    struct Area {
        std::string name, country;  // the subunit's name, and the country it is part of
        double labelLon = 0, labelLat = 0;       // where the country's name goes
        std::vector<Ring> rings;
        std::vector<std::array<double, 4>> box;  // west, south, east, north of each ring
        std::vector<std::set<int>> owners;       // the entities each ring pictures
    };
    std::vector<Area> areas(overlayCount(Overlay::Subunits));
    for (size_t a = 0; a < areas.size(); ++a) {
        OverlayArea area = overlayArea(Overlay::Subunits, a);
        areas[a].name = area.name.substr(0, area.name.find('|')), areas[a].country = area.name.substr(area.name.rfind('|') + 1);
        areas[a].labelLon = area.labelLon, areas[a].labelLat = area.labelLat;
        areas[a].rings = std::move(area.rings);
        for (const Ring &r : areas[a].rings) {
            std::array<double, 4> b{999, 999, -999, -999};
            for (const auto &p : r) b = {std::min(b[0], p.first), std::min(b[1], p.second), std::max(b[2], p.first), std::max(b[3], p.second)};
            areas[a].box.push_back(b);
        }
        areas[a].owners.resize(areas[a].rings.size());
    }
    auto inside = [](const Ring &r, double lon, double lat) {
        bool in = false;
        for (size_t i = 0, j = r.size() - 1; i < r.size(); j = i++)
            if ((r[i].second > lat) != (r[j].second > lat) && lon < (r[j].first - r[i].first) * (lat - r[i].second) / (r[j].second - r[i].second) + r[i].first)
                in = !in;
        return in;
    };
    // Degrees between two places, near enough for telling islands apart.
    auto apart = [](double lon1, double lat1, double lon2, double lat2) {
        double dlon = std::fabs(lon1 - lon2);
        if (dlon > 180) dlon = 360 - dlon;
        return std::hypot(dlon * std::cos((lat1 + lat2) / 2 * 3.14159265358979323846 / 180), lat1 - lat2);
    };
    // The nearest a ring comes to a place, where its box says it could be within `limit`.
    auto nearest = [&](const Area &a, size_t r, double lon, double lat, double limit) {
        const auto &b = a.box[r];
        if (lat < b[1] - limit || lat > b[3] + limit) return 1e9;
        double best = 1e9;
        for (const auto &p : a.rings[r]) best = std::min(best, apart(lon, lat, p.first, p.second));
        return best;
    };
    // The country is named for the entity: "United States" and "United States of America".
    auto named = [](const Area &a, const EntityPlace &e) {
        std::string x = upper(a.name), y = upper(e.name);
        return !y.empty() && (x.find(y) != std::string::npos || y.find(x) != std::string::npos);
    };
    // Parts of one land, which share its ring (ADIF's DXCC numbers).
    auto together = [](int a, int b) {
        static const std::set<int> britain = {223, 279, 294}, russia = {54, 15};
        return (britain.count(a) && britain.count(b)) || (russia.count(a) && russia.count(b));
    };

    std::map<std::pair<size_t, size_t>, std::vector<const EntityPlace *>> placed;  // (area, ring) -> the entities in it
    std::vector<const EntityPlace *> islands;                                      // placed at sea
    for (const EntityPlace &e : places) {
        if (e.dxcc <= 0) continue;
        // The country it is in (inside an odd number of its rings: a hole is another
        // country), and of that country's rings round it, the smallest.
        bool found = false;
        for (size_t a = 0; a < areas.size() && !found; ++a) {
            int holding = -1, count = 0;
            for (size_t r = 0; r < areas[a].rings.size(); ++r) {
                const auto &b = areas[a].box[r];
                if (e.lon < b[0] || e.lon > b[2] || e.lat < b[1] || e.lat > b[3] || !inside(areas[a].rings[r], e.lon, e.lat)) continue;
                ++count;
                auto size = [&](size_t i) { return (areas[a].box[i][2] - areas[a].box[i][0]) * (areas[a].box[i][3] - areas[a].box[i][1]); };
                if (holding < 0 || size(r) < size((size_t)holding)) holding = (int)r;
            }
            if (count % 2 == 1) placed[{a, (size_t)holding}].push_back(&e), found = true;
        }
        if (found) continue;
        // Just offshore of the country it names: in that country's nearest ring.
        double best = 0.5;
        std::pair<size_t, size_t> at{0, 0};
        for (size_t a = 0; a < areas.size(); ++a) {
            if (!named(areas[a], e)) continue;
            for (size_t r = 0; r < areas[a].rings.size(); ++r)
                if (double d = nearest(areas[a], r, e.lon, e.lat, 0.5); d < best) best = d, at = {a, r}, found = true;
        }
        if (found) placed[at].push_back(&e);
        else islands.push_back(&e);
    }
    for (const auto &kv : placed) {
        Area &a = areas[kv.first.first];
        const EntityPlace *main = nullptr;
        for (const EntityPlace *e : kv.second) {
            if (!main) {
                main = e;
                continue;
            }
            bool mine = named(a, *e), theirs = named(a, *main);
            if (mine != theirs ? mine : apart(e->lon, e->lat, a.labelLon, a.labelLat) < apart(main->lon, main->lat, a.labelLon, a.labelLat)) main = e;
        }
        for (const EntityPlace *e : kv.second)
            if (e->dxcc == main->dxcc || together(e->dxcc, main->dxcc)) a.owners[kv.first.second].insert(e->dxcc);
    }
    // Land that touches the land of the entity a country is named for is that entity's too:
    // an entity placed there is a spot on it (UN HQ on Long Island) or a small island beside
    // it (St. Paul, placed on Cape Breton). Alaska, Sardinia and Corsica are well clear.
    for (size_t ai = 0; ai < areas.size(); ++ai) {
        Area &a = areas[ai];
        std::vector<size_t> home;  // rings whose owner the country is named for
        for (const auto &kv : placed)
            if (kv.first.first == ai)
                for (const EntityPlace *e : kv.second)
                    if (a.owners[kv.first.second].count(e->dxcc) && named(a, *e)) home.push_back(kv.first.second);
        if (home.empty()) continue;
        for (auto it = placed.begin(); it != placed.end();) {
            size_t r = it->first.second;
            bool spot = it->first.first == ai && std::find(home.begin(), home.end(), r) == home.end();
            if (spot) {
                double gap = 1e9;
                for (size_t h : home) {
                    const auto &hb = a.box[h], &rb = a.box[r];
                    if (rb[1] > hb[3] + 0.3 || rb[3] < hb[1] - 0.3) continue;
                    for (const auto &p : a.rings[r])
                        for (const auto &q : a.rings[h]) gap = std::min(gap, apart(p.first, p.second, q.first, q.second));
                }
                spot = gap < 0.3;
            }
            if (spot) a.owners[r].clear(), it = placed.erase(it);
            else ++it;
        }
    }
    // An island entity (placed at sea) starts from the nearest land within half a degree,
    // unless that land touches land an entity is placed in: then it is that mainland's
    // (Long Island beside the UN's place, Cape Breton beside St. Paul's).
    auto gap = [&](const Area &a, size_t r1, size_t r2, size_t every) {  // the nearest two rings come, sampling the first
        const auto &b1 = a.box[r1], &b2 = a.box[r2];
        double least = 1e9, apartLat = std::max({0.0, b2[1] - b1[3], b1[1] - b2[3]});
        if (apartLat > 60) return apartLat;
        for (size_t i = 0; i < a.rings[r1].size(); i += every)
            for (const auto &q : a.rings[r2]) least = std::min(least, apart(a.rings[r1][i].first, a.rings[r1][i].second, q.first, q.second));
        return least;
    };
    for (const EntityPlace *e : islands) {
        double best = 0.5;
        Area *where = nullptr;
        size_t which = 0;
        for (Area &a : areas)
            for (size_t r = 0; r < a.rings.size(); ++r)
                if (a.owners[r].empty())
                    if (double d = nearest(a, r, e->lon, e->lat, best); d < best) best = d, where = &a, which = r;
        if (!where) continue;
        bool mainland = false;
        for (size_t r = 0; r < where->rings.size() && !mainland; ++r)
            mainland = placed.count({(size_t)(where - areas.data()), r}) && gap(*where, which, r, 1) < 0.3;
        if (!mainland) where->owners[which].insert(e->dxcc);
    }
    // A country's other rings (over all its subunits) join the nearest land that has an
    // entity, nearest first, so an archipelago grows outward from its own start: Maui joins
    // Oahu's Hawaii, Hokkaido joins Honshu's Japan, the Magdalen Islands join Canada.
    std::map<std::string, std::vector<RingRef>> countries;
    for (size_t a = 0; a < areas.size(); ++a)
        for (size_t r = 0; r < areas[a].rings.size(); ++r) countries[areas[a].country].push_back({a, r});
    auto ringGap = [&](RingRef x, RingRef y) {  // the nearest two rings come, sampling the first
        const Area &ax = areas[x.area], &ay = areas[y.area];
        const auto &bx = ax.box[x.ring], &by = ay.box[y.ring];
        double apartLat = std::max({0.0, by[1] - bx[3], bx[1] - by[3]});
        if (apartLat > 60) return apartLat;
        const Ring &rx = ax.rings[x.ring], &ry = ay.rings[y.ring];
        size_t every = std::max<size_t>(1, rx.size() / 16);
        double least = 1e9;
        for (size_t i = 0; i < rx.size(); i += every)
            for (const auto &q : ry) least = std::min(least, apart(rx[i].first, rx[i].second, q.first, q.second));
        return least;
    };
    for (auto &kv : countries) {
        std::vector<RingRef> owned, open;
        for (RingRef ref : kv.second) (areas[ref.area].owners[ref.ring].empty() ? open : owned).push_back(ref);
        if (owned.empty() || open.empty()) continue;
        std::vector<std::pair<double, RingRef>> near(open.size(), {1e9, RingRef{}});
        for (size_t i = 0; i < open.size(); ++i)
            for (RingRef o : owned)
                if (double d = ringGap(open[i], o); d < near[i].first) near[i] = {d, o};
        while (!open.empty()) {
            size_t pick = 0;
            for (size_t i = 1; i < open.size(); ++i)
                if (near[i].first < near[pick].first) pick = i;
            RingRef r = open[pick], with = near[pick].second;
            open.erase(open.begin() + (long)pick), near.erase(near.begin() + (long)pick);
            areas[r.area].owners[r.ring] = areas[with.area].owners[with.ring];
            for (size_t i = 0; i < open.size(); ++i)
                if (double d = ringGap(open[i], r); d < near[i].first) near[i] = {d, r};
        }
    }
    std::map<int, std::vector<RingRef>> out;
    for (size_t a = 0; a < areas.size(); ++a)
        for (size_t r = 0; r < areas[a].rings.size(); ++r)
            for (int dxcc : areas[a].owners[r]) out[dxcc].push_back({a, r});
    return out;
}

std::string iotaRef(std::string_view s) {
    std::string v = upper(trimmed(s));
    static const char *const kContinents[] = {"AF", "AN", "AS", "EU", "NA", "OC", "SA"};
    if (v.size() < 3 || std::none_of(std::begin(kContinents), std::end(kContinents), [&](const char *c) { return v.compare(0, 2, c) == 0; }))
        return "";
    std::string digits = v.substr(v[2] == '-' ? 3 : 2);
    if (digits.empty() || digits.size() > 3 || !std::all_of(digits.begin(), digits.end(), [](char c) { return c >= '0' && c <= '9'; })) return "";
    return v.substr(0, 2) + "-" + std::string(3 - digits.size(), '0') + digits;
}

bool iotaGroup(std::string_view ref, std::string_view name, std::string_view dxcc, std::string_view latMin, std::string_view latMax,
               std::string_view lonMin, std::string_view lonMax, IotaGroup *out) {
    IotaGroup g;
    g.ref = iotaRef(ref);
    if (g.ref.empty() || g.ref != upper(trimmed(ref))) return false;  // the list's own references are written in full
    double a, b, c, d;
    if (!parseAdifNumber(trimmed(latMin), &a) || !parseAdifNumber(trimmed(latMax), &b) || !parseAdifNumber(trimmed(lonMin), &c) ||
        !parseAdifNumber(trimmed(lonMax), &d))
        return false;
    if (std::fabs(a) > 90 || std::fabs(b) > 90 || std::fabs(c) > 180 || std::fabs(d) > 180) return false;
    g.south = std::min(a, b), g.north = std::max(a, b);
    g.west = std::min(c, d), g.east = std::max(c, d);
    if (g.east - g.west >= 359) g.west = -180, g.east = 180;  // all the way round (Antarctica)
    else if (g.east - g.west > 180) std::swap(g.west, g.east), g.east += 360;
    g.name = trimmed(name);
    double n = 0;
    if (parseAdifNumber(trimmed(dxcc), &n) && n >= 0 && n < 10000) g.dxcc = (int)n;
    if (out) *out = std::move(g);
    return true;
}

std::vector<std::array<double, 4>> iotaBoxes(const IotaGroup &g) {
    if (g.east <= 180) return {{g.west, g.south, g.east, g.north}};
    return {{g.west, g.south, 180, g.north}, {-180, g.south, g.east - 360, g.north}};
}

}  // namespace adif
