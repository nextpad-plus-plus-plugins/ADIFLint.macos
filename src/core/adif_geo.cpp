#include "adif_geo.h"

#include "adif_lint.h"

#include <cmath>
#include <cstdio>

namespace adif {
namespace {

const double kPi = 3.14159265358979323846;
double rad(double d) { return d * kPi / 180.0; }
double deg(double r) { return r * 180.0 / kPi; }
char up(char c) { return (c >= 'a' && c <= 'z') ? (char)(c - 32) : c; }

}  // namespace

bool gridToLatLon(std::string_view g, double *lat, double *lon) {
    if (!isAdifGridSquare(g)) return false;
    // Field (A-R): 20 x 10 degrees; square (0-9): 2 x 1; subsquare (A-X): 5' x 2.5'; extended square (0-9): 30" x 15".
    double lo = (up(g[0]) - 'A') * 20.0 - 180.0, la = (up(g[1]) - 'A') * 10.0 - 90.0;
    double w = 20.0, h = 10.0;
    if (g.size() >= 4) {
        w = 2.0, h = 1.0;
        lo += (g[2] - '0') * w;
        la += (g[3] - '0') * h;
    }
    if (g.size() >= 6) {
        w /= 24.0, h /= 24.0;
        lo += (up(g[4]) - 'A') * w;
        la += (up(g[5]) - 'A') * h;
    }
    if (g.size() >= 8) {
        w /= 10.0, h /= 10.0;
        lo += (g[6] - '0') * w;
        la += (g[7] - '0') * h;
    }
    if (lat) *lat = la + h / 2;
    if (lon) *lon = lo + w / 2;
    return true;
}

bool locationToDegrees(std::string_view v, bool latitude, double *degrees) {
    auto digit = [&](size_t i) { return v[i] >= '0' && v[i] <= '9'; };
    if (v.size() != 11 || v[4] != ' ' || v[7] != '.' || !digit(1) || !digit(2) || !digit(3) || !digit(5) || !digit(6) || !digit(8) ||
        !digit(9) || !digit(10))
        return false;
    char x = up(v[0]);
    if (latitude ? (x != 'N' && x != 'S') : (x != 'E' && x != 'W')) return false;
    int d = (v[1] - '0') * 100 + (v[2] - '0') * 10 + (v[3] - '0');
    double minutes = (v[5] - '0') * 10 + (v[6] - '0') + ((v[8] - '0') * 100 + (v[9] - '0') * 10 + (v[10] - '0')) / 1000.0;
    double value = d + minutes / 60.0;
    if (minutes >= 60 || value > (latitude ? 90 : 180)) return false;
    if (degrees) *degrees = x == 'S' || x == 'W' ? -value : value;
    return true;
}

double greatCircleKm(double lat1, double lon1, double lat2, double lon2) {
    double p1 = rad(lat1), p2 = rad(lat2), dp = rad(lat2 - lat1), dl = rad(lon2 - lon1);
    double a = std::sin(dp / 2) * std::sin(dp / 2) + std::cos(p1) * std::cos(p2) * std::sin(dl / 2) * std::sin(dl / 2);
    return 6371.0 * 2 * std::atan2(std::sqrt(a), std::sqrt(1 - a));
}

double initialBearing(double lat1, double lon1, double lat2, double lon2) {
    double p1 = rad(lat1), p2 = rad(lat2), dl = rad(lon2 - lon1);
    double y = std::sin(dl) * std::cos(p2), x = std::cos(p1) * std::sin(p2) - std::sin(p1) * std::cos(p2) * std::cos(dl);
    double b = std::fmod(deg(std::atan2(y, x)) + 360.0, 360.0);
    return b;
}

std::string gridDistanceKm(std::string_view myGrid, std::string_view grid) {
    double a, b, c, d;
    if (!gridToLatLon(myGrid, &a, &b) || !gridToLatLon(grid, &c, &d)) return "";
    return std::to_string((long)std::lround(greatCircleKm(a, b, c, d)));
}

std::string gridDistanceText(std::string_view myGrid, std::string_view grid) {
    double a, b, c, d;
    if (!gridToLatLon(myGrid, &a, &b) || !gridToLatLon(grid, &c, &d)) return "";
    long km = std::lround(greatCircleKm(a, b, c, d));
    std::string n = std::to_string(km);
    for (int i = (int)n.size() - 3; i > 0; i -= 3) n.insert((size_t)i, ",");
    char buf[64];
    std::snprintf(buf, sizeof buf, " km at %ld\xC2\xB0", std::lround(initialBearing(a, b, c, d)) % 360);
    return n + buf;
}

}  // namespace adif
