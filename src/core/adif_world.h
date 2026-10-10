// What the Map draws: the world's land (Natural Earth 1:110m, public domain;
// naturalearthdata.com terms read 2026-10-10; ne_110m_land.geojson from
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

size_t landRingCount();
std::vector<std::pair<double, double>> landRing(size_t i);  // (longitude, latitude) in degrees

// A QSO confirmed by card, LoTW or eQSL: QSL_RCVD, LOTW_QSL_RCVD or EQSL_QSL_RCVD Y or V.
bool isConfirmed(const Record &r);

struct MapSquare {
    std::string grid;  // 4 characters, upper case ("FN31")
    size_t qsos = 0;
    bool confirmed = false;
    std::vector<std::string> calls;  // the first few
};
struct MapPark {
    std::string reference, grid;  // their park and the QSO's grid
};
struct MapData {
    std::vector<MapSquare> squares;   // from GRIDSQUARE and VUCC_GRIDS
    std::vector<MapPark> parks;       // the other station's POTA, WWFF, SOTA or ZLOTA reference, where GRIDSQUARE says where
    std::vector<std::string> mine;    // MY_GRIDSQUARE values (4 or more characters), each once
    std::vector<std::pair<std::string, bool>> calls;  // every CALL with whether that QSO is confirmed (entities)
    size_t records = 0, withoutGrid = 0;
};
// The log's records on `band` and `mode` (empty: all; mode matches MODE or SUBMODE).
MapData mapData(std::string_view text, const DocModel &m, std::string_view band, std::string_view mode);

// A 4-character square's corners: west, south, east, north (degrees); false when not a grid.
bool squareBounds(std::string_view grid, double *west, double *south, double *east, double *north);
// The 4-character square at a point ("FN31"); "" off the map.
std::string squareAt(double lon, double lat);

}  // namespace adif
