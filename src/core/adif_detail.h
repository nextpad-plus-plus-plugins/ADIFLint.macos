// The Map's 1:10m detail for zooming in: land, lakes, rivers, borders, state and province
// lines, urban areas and 7,300 cities, from Natural Earth (public domain), in
// data/map-detail.bin beside the plugin (written by tools/gen_map_detail.py, which
// describes the format). Read once; each shape keeps its box so a zoomed-in map draws only
// the shapes in view.
#pragma once

#include <array>
#include <cstddef>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

enum class DetailLayer { Land, Lakes, Rivers, Borders, States, Urban };
constexpr size_t kDetailLayers = 6;

struct DetailShape {
    float west = 0, south = 0, east = 0, north = 0;  // degrees, rounded outward
    int rank = 0;                                    // rivers: scalerank (1 major..); states: min zoom x 10
    size_t first = 0, count = 0;                     // its points in the layer
};

struct DetailCity {
    std::string name;
    double lat = 0, lon = 0;
    long population = 0;
    double minZoom = 0;  // Natural Earth's: the web-map zoom from which it is worth showing
};

class MapDetail {
public:
    // Read the file's bytes; false (with the reason) when they are not a whole detail file.
    bool load(std::string_view bytes, std::string *error = nullptr);
    bool empty() const { return cities_.empty(); }
    const std::vector<DetailShape> &shapes(DetailLayer l) const { return shapes_[(size_t)l]; }
    // A shape's points (lon, lat).
    std::vector<std::pair<double, double>> points(DetailLayer l, const DetailShape &s) const;
    // The shapes whose box meets this box of longitude and latitude.
    std::vector<size_t> within(DetailLayer l, double west, double south, double east, double north) const;
    // Most populous first.
    const std::vector<DetailCity> &cities() const { return cities_; }

private:
    std::array<std::vector<DetailShape>, kDetailLayers> shapes_;
    std::array<std::vector<float>, kDetailLayers> pts_;  // lon, lat, lon, lat...
    std::vector<DetailCity> cities_;
};

}  // namespace adif
