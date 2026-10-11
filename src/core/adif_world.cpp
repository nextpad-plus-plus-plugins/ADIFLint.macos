#include "adif_world.h"

#include "adif_enrich.h"
#include "adif_geo.h"
#include "adif_programs.h"
#include "adif_spec.h"

#include <algorithm>
#include <cmath>
#include <map>

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

}  // namespace adif
