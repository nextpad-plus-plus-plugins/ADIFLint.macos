// Map projections for the Map window, and great-circle helpers. Plane units are
// degree-sized (a unit is a degree of longitude at the equator, or of arc from the
// centre for the azimuthal projection), so zoom and labels behave alike in all of them.
//
//   Equirectangular (plate carrée): x = longitude, y = latitude.
//   Mercator: y = ln(tan(pi/4 + lat/2)), cut at 85.05 degrees (where the map is square).
//   Equal Earth: Šavrič, Patterson and Jenny (2018), "The Equal Earth map projection",
//     International Journal of Geographical Information Science 33(3); constants and the
//     Newton inverse as in d3-geo src/projection/equalEarth.js (commit 44b6d89, read
//     2026-10-10). Equal-area, the continents in their true sizes.
//   Globe: the orthographic projection, the Earth as seen from far away, centred on a
//     point (the oblique aspect, Snyder 1987, USGS Professional Paper 1395; as d3-geo's
//     orthographic.js with clipAngle 90, read 2026-10-10). Only the near hemisphere shows,
//     in a disc of radius 57.3 (a unit is a degree of arc at the centre); bearings from
//     the centre are true. Checked in the tests against initialBearing (adif_geo.h).
#pragma once

#include <utility>
#include <vector>

namespace adif {

enum class Projection { Equirectangular, Mercator, EqualEarth, Globe };

class Projector {
public:
    explicit Projector(Projection p = Projection::Equirectangular, double centerLat = 0, double centerLon = 0);
    Projection kind() const { return kind_; }
    double centerLat() const { return lat0_; }
    double centerLon() const { return lon0_; }
    // (lon, lat) in degrees to the plane; false for a point with no place (the far side
    // of the globe). Mercator clamps latitude to its limit instead.
    bool forward(double lon, double lat, double *x, double *y) const;
    // The globe: whether the point is on the near side.
    bool visible(double lon, double lat) const;
    // The plane to (lon, lat); false outside the world.
    bool inverse(double x, double y, double *lon, double *lat) const;
    // The world's extent on the plane.
    void bounds(double *minX, double *minY, double *maxX, double *maxY) const;
    // The world's edge as plane points (closed), for the ocean and for clipping.
    std::vector<std::pair<double, double>> outline() const;

private:
    Projection kind_;
    double lat0_, lon0_;
};

// A shape's points (lon, lat) as pieces on the plane. On the globe, a polygon that passes
// behind follows the rim there (from where it crosses the horizon to where it comes back),
// one wholly behind is dropped, and a line is cut into the pieces in front, each ending on
// the rim. On the flat maps a polygon is one closed piece, and a line that `wraps` (a path
// or ring that may cross the 180th meridian) is cut where it does.
struct ShapePiece {
    std::vector<std::pair<double, double>> pts;
    bool closed = false;
};
std::vector<ShapePiece> projectShape(const Projector &pr, const std::vector<std::pair<double, double>> &pts, bool polygon, bool wraps);

// Points (lon, lat) along the short great circle from point 1 to point 2, about every
// `stepDeg` degrees of arc, both ends included.
std::vector<std::pair<double, double>> greatCirclePath(double lat1, double lon1, double lat2, double lon2, double stepDeg = 2);
// The point `km` from (lat, lon) on the initial bearing `bearingDeg` (sphere of 6371 km).
void destinationPoint(double lat, double lon, double bearingDeg, double km, double *lat2, double *lon2);

}  // namespace adif
