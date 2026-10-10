// What the Map draws: the world's land and land borders (Natural Earth 1:110m
// and 1:50m, public domain; naturalearthdata.com terms read 2026-10-10;
// ne_110m_land, ne_50m_land and ne_50m_admin_0_boundary_lines_land from
// github.com/nvkelso/natural-earth-vector ca96624, converted by
// tools/gen_world_outline.py) and a log's grids, parks and your locations.
#pragma once

#include "adif_lint.h"
#include "adif_tools.h"

#include <cstddef>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

enum class MapDetail { Coarse, Fine };  // 1:110m for the whole world, 1:50m zoomed in
size_t landRingCount(MapDetail d = MapDetail::Coarse);
std::vector<std::pair<double, double>> landRing(size_t i, MapDetail d = MapDetail::Coarse);  // (longitude, latitude) in degrees
size_t borderLineCount();                                   // country borders on land, 1:50m
std::vector<std::pair<double, double>> borderLine(size_t i);

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
    std::string reference, grid;  // their park and the QSO's grid
    size_t qso = 0;               // into MapData::qsos
};
struct MapData {
    std::vector<MapSquare> squares;   // from GRIDSQUARE and VUCC_GRIDS
    std::vector<MapPark> parks;       // the other station's POTA, WWFF, SOTA or ZLOTA reference, where GRIDSQUARE says where
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
