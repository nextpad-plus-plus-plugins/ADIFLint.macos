// What the Map draws: the world (Natural Earth 1:110m and 1:50m, public domain;
// naturalearthdata.com terms read 2026-10-10; land, lakes, rivers, country borders
// and state/province lines from github.com/nvkelso/natural-earth-vector ca96624,
// converted by tools/gen_world_outline.py) and a log's grids, parks and your locations.
#pragma once

#include "adif_lint.h"
#include "adif_tools.h"

#include <cstddef>
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

// A QSO confirmed by card, LoTW or eQSL: QSL_RCVD, LOTW_QSL_RCVD or EQSL_QSL_RCVD Y or V.
bool isConfirmed(const Record &r);

struct MapQso {
    int group = -1, record = 0;  // DocModel group, 1-based record number
    std::string call, date, time, band, mode, grid;
    bool confirmed = false;
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
};
// The log's records on `band` and `mode` (empty: all; mode matches MODE or SUBMODE).
MapData mapData(std::string_view text, const DocModel &m, std::string_view band, std::string_view mode);

// A 4-character square's corners: west, south, east, north (degrees); false when not a grid.
bool squareBounds(std::string_view grid, double *west, double *south, double *east, double *north);
// The 4-character square at a point ("FN31"); "" off the map.
std::string squareAt(double lon, double lat);

}  // namespace adif
