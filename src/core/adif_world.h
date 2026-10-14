// What the Map draws: the world (Natural Earth 1:110m and 1:50m, public domain;
// naturalearthdata.com terms read 2026-10-10; land, lakes, rivers, country borders
// and state/province lines from github.com/nvkelso/natural-earth-vector ca96624,
// converted by tools/gen_world_outline.py) and a log's grids, parks and your locations.
#pragma once

#include "adif_lint.h"
#include "adif_tools.h"

#include <array>
#include <cstddef>
#include <map>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

// The layers, as shapes of (longitude, latitude) in degrees. Polygons (land, lakes) come
// ring by ring, holes as rings of their own (fill them even-odd); the rest are lines.
enum class MapLayer { Land110, Land50, Lakes110, Lakes50, Rivers50, Borders50, States50 };
size_t layerShapeCount(MapLayer l);
std::vector<std::pair<double, double>> layerShape(MapLayer l, size_t i);
int layerShapeRank(MapLayer l, size_t i);  // rivers: Natural Earth's scalerank, 1 (major) to 6; else 0

// Overlays: US states, CQ zones, ITU zones, countries and US counties, each an area with a
// name (a postal code, a zone number, a country's short name, "WI,Dane" as CNTY writes a
// county) and a place to write it; and the map subunits DXCC entities are drawn on
// ("NAME|SU_A3|ADMIN": England, Alaska, Sardinia...). adif_overlays_data.cpp, by
// tools/gen_map_overlays.py.
enum class Overlay { UsStates, CqZones, ItuZones, Countries, UsCounties, Subunits };
struct OverlayArea {
    std::string name;
    double labelLon = 0, labelLat = 0;
    std::vector<std::vector<std::pair<double, double>>> rings;  // (lon, lat), not closed
};
size_t overlayCount(Overlay o);
OverlayArea overlayArea(Overlay o, size_t i);

// The land that pictures each DXCC entity, as rings of the map subunits (England apart from
// Scotland, Alaska from the lower 48), worked out from the country file's name and place for
// each entity (several places for one entity where the file lists its parts, as Sicily under
// Italy):
//   - an entity has the ring its place is in; a place just offshore counts as in the
//     country it names (the file puts Cuba in the sea south of Cuba);
//   - of several entities in one ring, the land is the one's the country is named for, else
//     the one nearest where the country's name goes. The others are spots inside a larger
//     country (the Vatican, Mount Athos, Guantanamo Bay) and have no land at this scale.
//     Parts of one land placed in one ring share it (England, Scotland and Wales; European
//     and Asiatic Russia), though the subunits mostly keep them apart;
//   - a country's other rings, over all its subunits, go with the nearest of those, nearest
//     first (Sicily with Italy's mainland), or with an island entity placed nearer to them
//     than that (Maui with Hawaii, the Aleutians with Alaska, the Canaries with the Canary
//     Islands, not with Spain).
// An entity with no land here (small islands, the spots above) has none: the Map draws it
// as a dot.
struct EntityPlace {
    int dxcc = 0;
    double lat = 0, lon = 0;
    std::string name;  // the country file's ("United States", "Cuba")
};
struct RingRef {
    size_t area = 0, ring = 0;  // overlayArea(Overlay::Subunits, area).rings[ring]
};
std::map<int, std::vector<RingRef>> dxccRings(const std::vector<EntityPlace> &places);

// A QSO confirmed by card, LoTW or eQSL: QSL_RCVD, LOTW_QSL_RCVD or EQSL_QSL_RCVD Y or V.
bool isConfirmed(const Record &r);

struct MapQso {
    int group = -1, record = 0;  // DocModel group, 1-based record number
    std::string call, date, time, band, mode, grid;
    std::string date8;   // QSO_DATE as written (YYYYMMDD)
    std::string myGrid;  // MY_GRIDSQUARE
    int modeGroup = 2;   // 0 CW, 1 phone, 2 data (from MODE, as modeGroup() in adif_enrich.h)
    bool confirmed = false;
    // Where the other station was, when the record says closely: LAT and LON, else a
    // GRIDSQUARE of 6 or 8 characters (a 4-character square is 100 km or more across).
    // LAT and LON are left out when they are a placeholder (isPlaceholderPlace) or, with a
    // GRIDSQUARE, more than half a square outside it: a callbook fills them in from the
    // station's address, which is not where it was when it worked portable, and the two
    // can't tell which is right.
    bool located = false;
    double lat = 0, lon = 0;
    std::string locatedBy;  // "LAT/LON", or the grid
    std::string iota;       // IOTA, as iotaRef() writes it ("EU-005"); "" when none or not a reference
};
struct MapSquare {
    std::string grid;  // 4 characters, upper case ("FN31")
    size_t qsos = 0;
    bool confirmed = false;
    std::vector<std::string> calls;  // the first few
    std::vector<size_t> qsoIndex;    // into MapData::qsos
};
struct MapPark {
    std::string reference, grid;  // their reference and the QSO's grid
    std::string program;          // POTA, WWFF, SOTA, IOTA, or the SIG of another program
    size_t qso = 0;               // into MapData::qsos
    bool park() const { return program == "POTA" || program == "WWFF"; }  // the Map's Parks layer; the rest are other programs'
};
struct MapData {
    std::vector<MapSquare> squares;   // from GRIDSQUARE and VUCC_GRIDS
    std::vector<MapPark> parks;       // the other station's references (POTA, WWFF, SOTA, IOTA, SIG_INFO), where GRIDSQUARE says where
    std::vector<std::string> mine;    // MY_GRIDSQUARE values (4 or more characters), each once
    std::vector<std::pair<std::string, bool>> calls;  // every CALL with whether that QSO is confirmed (entities)
    std::vector<MapQso> qsos;                         // the records shown, in log order (calls[i] is qsos[i]'s)
    size_t records = 0, withoutGrid = 0;
    size_t unusedLatLon = 0;  // records whose LAT and LON were left out (MapQso::located)
};
// Which records the map shows: empty strings mean any.
struct MapFilter {
    std::string band, mode;      // mode matches MODE or SUBMODE
    std::string from, to;        // QSO_DATE range, YYYYMMDD, both included
    int confirmed = 0;           // 0 all, 1 confirmed only, 2 not confirmed
};
MapData mapData(std::string_view text, const DocModel &m, const MapFilter &filter);
// The log's records on `band` and `mode` (empty: all; mode matches MODE or SUBMODE).
MapData mapData(std::string_view text, const DocModel &m, std::string_view band, std::string_view mode);

// What programs write for "unknown", seen in a QRZ.com Logbook export (2026-10-09): the
// grids AA00 and JJ00 (their first square, alone or with subsquare aa), and LAT/LON at
// 0, 0 or at the centre of AA00aa or JJ00aa. The map draws no square, park or contact there.
bool isPlaceholderGrid(std::string_view grid);
bool isPlaceholderPlace(double lat, double lon);

// An IOTA island group, from IOTA's groups.json. The list is © RSGB and IOTA Ltd, who allow
// downloading it for personal non-commercial use (iota-world.org, read 2026-10-13): the user
// downloads it from Settings and nothing of it ships with the plugin. Its fields, read from
// the file 2026-10-13, are all strings: refno, name, dxcc_num, latitude_min, latitude_max,
// longitude_min, longitude_max (and grp_region, whitelist, pc_credited, comment, unused).
struct IotaGroup {
    std::string ref, name;  // "EU-005", the group's name
    int dxcc = 0;
    // Its box, in degrees. east passes 180 when the box crosses the 180th meridian (AS-027:
    // 178.25 to 184.75, which is 175.25 W); -180 to 180 when it goes all the way round.
    double west = 0, south = 0, east = 0, north = 0;
};
// One group from the file's strings; false when the reference isn't one or a coordinate isn't
// a number in range. The file's "min" and "max" are not always in that order (AF-001's
// latitude_max is the smaller), so each pair is sorted; a box then wider than 180 degrees of
// longitude crosses the 180th meridian (no group is that wide), unless it is all but the whole
// way round (AN-016, -180 to 180).
bool iotaGroup(std::string_view ref, std::string_view name, std::string_view dxcc, std::string_view latMin, std::string_view latMax,
               std::string_view lonMin, std::string_view lonMax, IotaGroup *out);
// An IOTA reference in the list's form, from how a log writes it: "eu-5", "EU005" and
// "EU-005" are "EU-005"; "" when it isn't one (a continent's two letters, then 1 to 3 digits).
std::string iotaRef(std::string_view s);
// A group's box as one or two boxes within -180..180 (two when it crosses the 180th meridian):
// west, south, east, north each.
std::vector<std::array<double, 4>> iotaBoxes(const IotaGroup &g);

// A 4-character square's corners: west, south, east, north (degrees); false when not a grid.
bool squareBounds(std::string_view grid, double *west, double *south, double *east, double *north);
// The 4-character square at a point ("FN31"); "" off the map.
std::string squareAt(double lon, double lat);

}  // namespace adif
