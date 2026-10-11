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
        case Projection::Globe: {
            if (!visible(lon, lat)) return false;
            double phi = lat * kRad, phi1 = lat0_ * kRad, dl = (lon - lon0_) * kRad;
            *x = std::cos(phi) * std::sin(dl) * kDeg;
            *y = (std::cos(phi1) * std::sin(phi) - std::sin(phi1) * std::cos(phi) * std::cos(dl)) * kDeg;
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
        case Projection::Globe: {  // Snyder (1987) eqs. 20-14 and 20-15
            double X = x / kDeg, Y = y / kDeg, rho = std::hypot(X, Y), phi1 = lat0_ * kRad;
            if (rho > 1 + 1e-12) return false;
            if (rho < 1e-12) {
                *lon = lon0_, *lat = lat0_;
                return true;
            }
            double c = std::asin(std::min(1.0, rho)), sc = std::sin(c), cc = std::cos(c);
            *lat = std::asin(std::clamp(cc * std::sin(phi1) + Y * sc * std::cos(phi1) / rho, -1.0, 1.0)) * kDeg;
            *lon = normLon(lon0_ + std::atan2(X * sc, rho * std::cos(phi1) * cc - Y * std::sin(phi1) * sc) * kDeg);
            return true;
        }
    }
    return false;
}

bool Projector::visible(double lon, double lat) const {
    if (kind_ != Projection::Globe) return true;
    double phi = lat * kRad, phi1 = lat0_ * kRad, dl = (lon - lon0_) * kRad;
    return std::sin(phi1) * std::sin(phi) + std::cos(phi1) * std::cos(phi) * std::cos(dl) >= 0;
}

void Projector::bounds(double *minX, double *minY, double *maxX, double *maxY) const {
    switch (kind_) {
        case Projection::Equirectangular: *minX = -180, *maxX = 180, *minY = -90, *maxY = 90; return;
        case Projection::Mercator: *minX = -180, *maxX = 180, *minY = -180, *maxY = 180; return;
        case Projection::Globe: *minX = -kDeg, *maxX = kDeg, *minY = -kDeg, *maxY = kDeg; return;
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
        case Projection::Globe:
            for (int a = 0; a < 360; ++a) out.emplace_back(kDeg * std::cos(a * kRad), kDeg * std::sin(a * kRad));
            break;
    }
    return out;
}

namespace {

struct Vec {
    double x, y, z;
};
Vec unit(double lon, double lat) {
    double p = lat * kRad, l = lon * kRad;
    return {std::cos(p) * std::cos(l), std::cos(p) * std::sin(l), std::sin(p)};
}
double dot(const Vec &a, const Vec &b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

// Where the great-circle step from a to b crosses the globe's horizon (exactly one end in
// front): on the arc P(t) = slerp(a, b, t), P(t)·C = 0 at t·d = atan2(sin d · a·C, cos d · a·C - b·C).
std::pair<double, double> horizonCrossing(const Projector &pr, std::pair<double, double> a, std::pair<double, double> b) {
    Vec c = unit(pr.centerLon(), pr.centerLat()), va = unit(a.first, a.second), vb = unit(b.first, b.second);
    double d = std::acos(std::clamp(dot(va, vb), -1.0, 1.0));
    if (d < 1e-12) return a;
    double da = dot(va, c), db = dot(vb, c);
    double td = std::atan2(std::sin(d) * da, std::cos(d) * da - db);
    double f = std::clamp(td / d, 0.0, 1.0), wa = std::sin((1 - f) * d) / std::sin(d), wb = std::sin(f * d) / std::sin(d);
    Vec p{wa * va.x + wb * vb.x, wa * va.y + wb * vb.y, wa * va.z + wb * vb.z};
    return {std::atan2(p.y, p.x) * kDeg, std::atan2(p.z, std::hypot(p.x, p.y)) * kDeg};
}

// The rim point in the direction of (lon, lat) from the centre (any side), as an angle on the plane.
bool rimAngle(const Projector &pr, double lon, double lat, double *angle) {
    double phi = lat * kRad, phi1 = pr.centerLat() * kRad, dl = (lon - pr.centerLon()) * kRad;
    double x = std::cos(phi) * std::sin(dl), y = std::cos(phi1) * std::sin(phi) - std::sin(phi1) * std::cos(phi) * std::cos(dl);
    if (std::hypot(x, y) < 1e-12) return false;  // the centre's antipode: no direction
    *angle = std::atan2(y, x);
    return true;
}

}  // namespace

std::vector<ShapePiece> projectShape(const Projector &pr, const std::vector<std::pair<double, double>> &pts, bool polygon, bool wraps) {
    std::vector<ShapePiece> out;
    if (pts.empty()) return out;
    if (pr.kind() != Projection::Globe) {
        ShapePiece cur;
        for (size_t i = 0; i < pts.size(); ++i) {
            double x, y;
            if (!pr.forward(pts[i].first, pts[i].second, &x, &y)) continue;
            if (wraps && !cur.pts.empty() && std::fabs(pts[i].first - pts[i - 1].first) > 180) {
                if (cur.pts.size() > 1) out.push_back(cur);
                cur = ShapePiece();
            }
            cur.pts.emplace_back(x, y);
        }
        cur.closed = polygon && out.empty();
        if (!cur.pts.empty()) out.push_back(cur);
        return out;
    }
    auto onPlane = [&](std::pair<double, double> p) {
        double x = 0, y = 0;
        pr.forward(p.first, p.second, &x, &y);
        return std::pair<double, double>{x, y};
    };
    // A horizon crossing, on the rim (rounding can put it a hair behind).
    auto onRim = [&](std::pair<double, double> p) {
        double angle = 0;
        rimAngle(pr, p.first, p.second, &angle);
        return std::pair<double, double>{kDeg * std::cos(angle), kDeg * std::sin(angle)};
    };
    if (polygon) {
        ShapePiece piece;
        piece.closed = true;
        bool front = false, behind = false, lastOnRim = false;
        double lastAngle = 0;
        // A rim point, with the arc from the last one when the shape keeps to the rim.
        auto rim = [&](double angle) {
            if (lastOnRim) {
                double delta = std::remainder(angle - lastAngle, 2 * kPi);
                int steps = (int)std::ceil(std::fabs(delta) / (3 * kRad));
                for (int k = 1; k < steps; ++k) {
                    double a = lastAngle + delta * k / steps;
                    piece.pts.emplace_back(kDeg * std::cos(a), kDeg * std::sin(a));
                }
            }
            piece.pts.emplace_back(kDeg * std::cos(angle), kDeg * std::sin(angle));
            lastOnRim = true, lastAngle = angle;
        };
        size_t n = pts.size();
        for (size_t i = 0; i < n; ++i) {
            const auto &a = pts[i], &b = pts[(i + 1) % n];
            bool va = pr.visible(a.first, a.second), vb = pr.visible(b.first, b.second);
            double angle, next;
            if (va) {
                piece.pts.push_back(onPlane(a));
                front = true, lastOnRim = false;
            } else if (rimAngle(pr, a.first, a.second, &angle)) {
                behind = true;
                rim(angle);
                // An edge passing near the antipode turns fast round the rim: follow its middle
                // so the arc goes the way the edge does, not the short way.
                if (!vb && rimAngle(pr, b.first, b.second, &next) && std::fabs(std::remainder(next - angle, 2 * kPi)) > kPi / 3) {
                    std::vector<std::pair<double, double>> mid = greatCirclePath(a.second, a.first, b.second, b.first, 0.5);
                    for (size_t k = 1; k + 1 < mid.size(); ++k)
                        if (rimAngle(pr, mid[k].first, mid[k].second, &angle)) rim(angle);
                }
            }
            if (va != vb) {
                std::pair<double, double> x = horizonCrossing(pr, va ? a : b, va ? b : a);
                if (rimAngle(pr, x.first, x.second, &angle)) rim(angle);
                if (vb) lastOnRim = false;
            }
        }
        if (!front) return out;
        out.push_back(piece);
        // A shape round the centre's antipode that shows in front (a continent seen from the
        // far side of the world) winds round the whole disc, so its front part is the disc
        // outside the piece: add the rim the other way round, so either fill rule leaves the
        // piece's inside empty. Natural Earth's shapes are cut at the 180th meridian, so
        // "round the antipode" is the plain (lon, lat) point-in-polygon test.
        double alon = normLon(pr.centerLon() + 180), alat = -pr.centerLat();
        bool inside = false;
        for (size_t i = 0, j = n - 1; i < n; j = i++) {
            const auto &pi = pts[i], &pj = pts[j];
            if ((pi.second > alat) != (pj.second > alat) && alon < (pj.first - pi.first) * (alat - pi.second) / (pj.second - pi.second) + pi.first)
                inside = !inside;
        }
        if (behind && inside) {
            double area = 0;
            for (size_t i = 0, j = piece.pts.size() - 1; i < piece.pts.size(); j = i++)
                area += piece.pts[j].first * piece.pts[i].second - piece.pts[i].first * piece.pts[j].second;
            ShapePiece disc;
            disc.closed = true;
            for (int k = 0; k < 120; ++k) {
                double a = (area > 0 ? -k : k) * 3 * kRad;
                disc.pts.emplace_back(kDeg * std::cos(a), kDeg * std::sin(a));
            }
            out.push_back(disc);
        }
        return out;
    }
    ShapePiece cur;
    for (size_t i = 0; i < pts.size(); ++i) {
        bool v = pr.visible(pts[i].first, pts[i].second), prev = i > 0 && pr.visible(pts[i - 1].first, pts[i - 1].second);
        if (v) {
            if (i > 0 && !prev) cur.pts.push_back(onRim(horizonCrossing(pr, pts[i], pts[i - 1])));  // coming round the rim
            cur.pts.push_back(onPlane(pts[i]));
        } else if (prev) {  // going behind
            cur.pts.push_back(onRim(horizonCrossing(pr, pts[i - 1], pts[i])));
            if (cur.pts.size() > 1) out.push_back(cur);
            cur = ShapePiece();
        }
    }
    if (cur.pts.size() > 1) out.push_back(cur);
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
