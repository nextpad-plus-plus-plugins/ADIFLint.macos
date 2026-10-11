#include "adif_projection.h"

#include <algorithm>
#include <cmath>

namespace adif {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kDeg = 180.0 / kPi, kRad = kPi / 180.0;
constexpr double kEarthKm = 6371.0;  // as adif_geo's greatCircleKm

// Mercator: the latitude where y = pi, so the world is a square (2 atan(e^pi) - pi/2).
const double kMercatorLimit = (2 * std::atan(std::exp(kPi)) - kPi / 2) * kDeg;

// Equal Earth (Šavrič, Patterson and Jenny 2018; d3-geo equalEarth.js).
constexpr double A1 = 1.340264, A2 = -0.081106, A3 = 0.000893, A4 = 0.003796;
const double M = std::sqrt(3.0) / 2;

double normLon(double lon) {
    lon = std::fmod(lon + 180.0, 360.0);
    if (lon < 0) lon += 360.0;
    return lon - 180.0;
}

}  // namespace

Projector::Projector(Projection p, double centerLat, double centerLon)
    : kind_(p), lat0_(std::clamp(centerLat, -90.0, 90.0)), lon0_(normLon(centerLon)) {}

bool Projector::forward(double lon, double lat, double *x, double *y) const {
    switch (kind_) {
        case Projection::Equirectangular:
            *x = lon, *y = lat;
            return true;
        case Projection::Mercator: {
            double phi = std::clamp(lat, -kMercatorLimit, kMercatorLimit) * kRad;
            *x = lon, *y = std::log(std::tan(kPi / 4 + phi / 2)) * kDeg;
            return true;
        }
        case Projection::EqualEarth: {
            double l = std::asin(M * std::sin(lat * kRad)), l2 = l * l, l6 = l2 * l2 * l2;
            *x = lon * kRad * std::cos(l) / (M * (A1 + 3 * A2 * l2 + l6 * (7 * A3 + 9 * A4 * l2))) * kDeg;
            *y = l * (A1 + A2 * l2 + l6 * (A3 + A4 * l2)) * kDeg;
            return true;
        }
        case Projection::Azimuthal: {
            double phi = lat * kRad, phi1 = lat0_ * kRad, dl = (lon - lon0_) * kRad;
            double cosc = std::clamp(std::sin(phi1) * std::sin(phi) + std::cos(phi1) * std::cos(phi) * std::cos(dl), -1.0, 1.0);
            double c = std::acos(cosc);
            if (c < 1e-12) {
                *x = *y = 0;
                return true;
            }
            if (kPi - c < 1e-9) return false;  // the antipode: every direction at once
            double k = c / std::sin(c);
            *x = k * std::cos(phi) * std::sin(dl) * kDeg;
            *y = k * (std::cos(phi1) * std::sin(phi) - std::sin(phi1) * std::cos(phi) * std::cos(dl)) * kDeg;
            return true;
        }
    }
    return false;
}

bool Projector::inverse(double x, double y, double *lon, double *lat) const {
    switch (kind_) {
        case Projection::Equirectangular:
            if (std::fabs(x) > 180 || std::fabs(y) > 90) return false;
            *lon = x, *lat = y;
            return true;
        case Projection::Mercator:
            if (std::fabs(x) > 180 || std::fabs(y) > 180) return false;
            *lon = x, *lat = (2 * std::atan(std::exp(y * kRad)) - kPi / 2) * kDeg;
            return true;
        case Projection::EqualEarth: {
            double maxX, maxY, minX, minY;
            bounds(&minX, &minY, &maxX, &maxY);
            if (std::fabs(y) > maxY + 1e-9) return false;
            double X = x * kRad, Y = y * kRad, l = Y, l2 = l * l, l6 = l2 * l2 * l2;
            for (int i = 0; i < 12; ++i) {
                double fy = l * (A1 + A2 * l2 + l6 * (A3 + A4 * l2)) - Y;
                double fpy = A1 + 3 * A2 * l2 + l6 * (7 * A3 + 9 * A4 * l2);
                double delta = fy / fpy;
                l -= delta, l2 = l * l, l6 = l2 * l2 * l2;
                if (std::fabs(delta) < 1e-12) break;
            }
            double lambda = M * X * (A1 + 3 * A2 * l2 + l6 * (7 * A3 + 9 * A4 * l2)) / std::cos(l);
            if (std::fabs(lambda) > kPi + 1e-9) return false;
            *lon = lambda * kDeg;
            *lat = std::asin(std::clamp(std::sin(l) / M, -1.0, 1.0)) * kDeg;
            return true;
        }
        case Projection::Azimuthal: {
            double X = x * kRad, Y = y * kRad, c = std::hypot(X, Y), phi1 = lat0_ * kRad;
            if (c > kPi + 1e-9) return false;
            if (c < 1e-12) {
                *lon = lon0_, *lat = lat0_;
                return true;
            }
            double sc = std::sin(c), cc = std::cos(c);
            *lat = std::asin(std::clamp(cc * std::sin(phi1) + Y * sc * std::cos(phi1) / c, -1.0, 1.0)) * kDeg;
            *lon = normLon(lon0_ + std::atan2(X * sc, c * std::cos(phi1) * cc - Y * std::sin(phi1) * sc) * kDeg);
            return true;
        }
    }
    return false;
}

void Projector::bounds(double *minX, double *minY, double *maxX, double *maxY) const {
    switch (kind_) {
        case Projection::Equirectangular: *minX = -180, *maxX = 180, *minY = -90, *maxY = 90; return;
        case Projection::Mercator:
        case Projection::Azimuthal: *minX = -180, *maxX = 180, *minY = -180, *maxY = 180; return;
        case Projection::EqualEarth: {
            double xe = 0, ye = 0, xn = 0, yn = 0;
            forward(180, 0, &xe, &ye);
            forward(0, 90, &xn, &yn);
            *minX = -xe, *maxX = xe, *minY = -yn, *maxY = yn;
            return;
        }
    }
}

std::vector<std::pair<double, double>> Projector::outline() const {
    std::vector<std::pair<double, double>> out;
    double x = 0, y = 0;
    switch (kind_) {
        case Projection::Equirectangular:
        case Projection::Mercator: {
            double minX, minY, maxX, maxY;
            bounds(&minX, &minY, &maxX, &maxY);
            out = {{minX, minY}, {maxX, minY}, {maxX, maxY}, {minX, maxY}};
            break;
        }
        case Projection::EqualEarth:  // the 180th meridian on each side; the poles are straight lines
            for (double lat = -90; lat <= 90; lat += 1)
                if (forward(180, lat, &x, &y)) out.emplace_back(x, y);
            for (double lat = 90; lat >= -90; lat -= 1)
                if (forward(-180, lat, &x, &y)) out.emplace_back(x, y);
            break;
        case Projection::Azimuthal:
            for (int a = 0; a < 360; ++a) out.emplace_back(180 * std::cos(a * kRad), 180 * std::sin(a * kRad));
            break;
    }
    return out;
}

std::vector<std::pair<double, double>> greatCirclePath(double lat1, double lon1, double lat2, double lon2, double stepDeg) {
    double p1 = lat1 * kRad, l1 = lon1 * kRad, p2 = lat2 * kRad, l2 = lon2 * kRad;
    double ax = std::cos(p1) * std::cos(l1), ay = std::cos(p1) * std::sin(l1), az = std::sin(p1);
    double bx = std::cos(p2) * std::cos(l2), by = std::cos(p2) * std::sin(l2), bz = std::sin(p2);
    double d = std::acos(std::clamp(ax * bx + ay * by + az * bz, -1.0, 1.0));
    std::vector<std::pair<double, double>> out;
    if (d < 1e-9 || kPi - d < 1e-9) {  // the same point, or antipodes (no single short path)
        out = {{lon1, lat1}, {lon2, lat2}};
        return out;
    }
    int n = std::max(1, (int)std::ceil(d * kDeg / std::max(0.1, stepDeg)));
    for (int i = 0; i <= n; ++i) {
        double f = (double)i / n, a = std::sin((1 - f) * d) / std::sin(d), b = std::sin(f * d) / std::sin(d);
        double x = a * ax + b * bx, y = a * ay + b * by, z = a * az + b * bz;
        out.emplace_back(std::atan2(y, x) * kDeg, std::atan2(z, std::hypot(x, y)) * kDeg);
    }
    return out;
}

void destinationPoint(double lat, double lon, double bearingDeg, double km, double *lat2, double *lon2) {
    double p1 = lat * kRad, l1 = lon * kRad, t = bearingDeg * kRad, d = km / kEarthKm;
    double p2 = std::asin(std::clamp(std::sin(p1) * std::cos(d) + std::cos(p1) * std::sin(d) * std::cos(t), -1.0, 1.0));
    double l2 = l1 + std::atan2(std::sin(t) * std::sin(d) * std::cos(p1), std::cos(d) - std::sin(p1) * std::sin(p2));
    *lat2 = p2 * kDeg;
    *lon2 = normLon(l2 * kDeg);
}

}  // namespace adif
