#include "adif_palette.h"

#include "adif_spec.h"

#include <algorithm>
#include <cmath>

namespace adif {
namespace {

// The bands in frequency order (ADIF's names), each with the colour PSKReporter's map gives
// it by default (https://pskreporter.info/mc_ol.js, its colormapper, read 2026-10-10).
// PSKReporter's "2200m", "600m", "2.4Ghz", "5.8Ghz", "10Ghz", "24Ghz", "47Ghz" and "76Ghz"
// are ADIF's 2190m, 630m, 13cm, 6cm, 3cm, 1.25cm, 6mm and 4mm.
struct BandColour {
    const char *band;
    unsigned rgb;
};
const BandColour kBands[] = {
    {"2190m", 0xFF4500},   {"630m", 0x1E90FF},    {"560m", kUnknownBandColour}, {"160m", 0x7CFC00},  {"80m", 0xE550E5},
    {"60m", 0x00008B},     {"40m", 0x5959FF},     {"30m", 0x62D962},            {"20m", 0xF2C40C},   {"17m", 0xF2F261},
    {"15m", 0xCCA166},     {"12m", 0xB22222},     {"10m", 0xFF69B4},            {"8m", 0x7F00F1},    {"6m", 0xFF0000},
    {"5m", 0xE0E0E0},      {"4m", 0xCC0044},      {"2m", 0xFF1493},             {"1.25m", 0xCCFF00}, {"70cm", 0x999900},
    {"33cm", kUnknownBandColour}, {"23cm", 0x5AB8C7}, {"13cm", 0xFF7F50},       {"9cm", kUnknownBandColour}, {"6cm", 0xCC0099},
    {"3cm", 0x696969},     {"1.25cm", 0xF3EDC6},  {"6mm", 0xFFE786},            {"4mm", 0xBAF9D8},   {"2.5mm", kUnknownBandColour},
    {"2mm", kUnknownBandColour}, {"1mm", kUnknownBandColour}, {"submm", kUnknownBandColour}};
constexpr size_t kBandCount = sizeof(kBands) / sizeof(kBands[0]);

double channel(unsigned rgb, int shift) { return ((rgb >> shift) & 0xFF) / 255.0; }
double toLinear(double c) { return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4); }
double toEncoded(double c) {
    c = std::clamp(c, 0.0, 1.0);
    return c <= 0.0031308 ? 12.92 * c : 1.055 * std::pow(c, 1 / 2.4) - 0.055;
}

// sRGB (IEC 61966-2-1, D65) to CIELAB.
void toLab(unsigned rgb, double *L, double *a, double *b) {
    double r = toLinear(channel(rgb, 16)), g = toLinear(channel(rgb, 8)), bl = toLinear(channel(rgb, 0));
    double x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * bl;
    double y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * bl;
    double z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * bl;
    auto f = [](double t) {
        const double d = 6.0 / 29;
        return t > d * d * d ? std::cbrt(t) : t / (3 * d * d) + 4.0 / 29;
    };
    double fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883);
    *L = 116 * fy - 16, *a = 500 * (fx - fy), *b = 200 * (fy - fz);
}

}  // namespace

int bandOrder(std::string_view band) {
    for (size_t i = 0; i < kBandCount; ++i)
        if (equalsNoCase(band, kBands[i].band)) return (int)i;
    return -1;
}

unsigned pskReporterBandColour(std::string_view band) {
    int i = bandOrder(band);
    return i < 0 ? kUnknownBandColour : kBands[i].rgb;
}

unsigned viridisColour(double t) {
    static const unsigned stops[] = {0x440154, 0x46327E, 0x365C8D, 0x277F8E, 0x1FA187, 0x4AC16D, 0xA0DA39, 0xFDE725};
    t = std::clamp(t, 0.0, 1.0) * 7;
    int i = std::min(6, (int)t);
    double f = t - i;
    unsigned out = 0;
    for (int shift : {16, 8, 0}) {
        double c = ((stops[i] >> shift) & 0xFF) * (1 - f) + ((stops[i + 1] >> shift) & 0xFF) * f;
        out |= (unsigned)std::lround(c) << shift;
    }
    return out;
}

// The colour-blind safe palette's band colours: chosen from published colour-blind safe sets
// (Paul Tol's light, medium-contrast and bright schemes, sronpersonalpages.nl/~pault, read
// 2026-10-10; Okabe and Ito's; Petroff 2024, arXiv:2107.02270) plus white, as the seven
// that differ most from each other and from the "other bands" grey under normal vision and
// simulated protan, deutan and tritan vision (Machado et al. 2009), while standing out from
// the dark map's ocean and land; ordered so the first few, which a log with few bands uses,
// differ most. Smallest difference: CIEDE2000 14.9 between any two, 22 from the map
// (checked in adif_tests; viridis, used before, came to 5.3 and 6.3).
const std::vector<unsigned> &colourBlindBandSet() {
    static const std::vector<unsigned> set = {0x99DDFF, 0xF0E442, 0x997700, 0x6699CC, 0xFFFFFF, 0xBBBBBB, 0xEE8866};
    return set;
}

size_t mapPaletteCount() { return 4; }

const MapPalette &mapPalette(int i) {
    // Tableau 10 (plus two), a common qualitative set.
    static const std::vector<unsigned> tableau = {0x4E79A7, 0xF28E2B, 0xE15759, 0x76B7B2, 0x59A14F, 0xEDC948,
                                                  0xB07AA1, 0xFF9DA7, 0x9C755F, 0xBAB0AC, 0x86BCB6, 0xD37295};
    static const std::vector<unsigned> bright = {0x00E5FF, 0xFFD400, 0xFF2D95, 0x00FF66, 0xFF7A00, 0xB388FF,
                                                 0xFFFFFF, 0x76FF03, 0xFF5252, 0x40C4FF};
    static const std::vector<MapPalette> all = {
        // Close to macOS's own green, orange, teal, blue, purple and red in the dark appearance.
        {"Standard", 0x17202B, 0x21334A, 0x546154, 0x5C85B3, 0xCCD1C2, true, 0x30D158, 0xFF9F0A, 0x40C8E0, 0x0A84FF, 0xBF5AF2, 0xFF453A,
         tableau, 0.2, false},
        // Okabe and Ito's colours for confirmed and worked, DXCC worked, parks and your station;
        // white for DXCC confirmed (their bluish green barely stood out from the ocean); modes
        // and programs take the band set; counts and years start further along viridis.
        {"Colour-blind safe", 0x17202B, 0x21334A, 0x546154, 0x5C85B3, 0xCCD1C2, true, 0x56B4E9, 0xE69F00, 0xFFFFFF, 0xD55E00, 0xCC79A7,
         0xF0E442, colourBlindBandSet(), 0.3, true},
        {"High contrast", 0x000000, 0x0A1A2F, 0x3C3C3C, 0x4FA3FF, 0xFFFFFF, true, 0x00FF66, 0xFF2D95, 0x00E5FF, 0xFFD400, 0xB388FF, 0xFF3B30,
         bright, 0.3, false},
        {"Light", 0xFFFFFF, 0xDCE9F5, 0xF2EFE6, 0x7FA7D0, 0x8A8A8A, false, 0x1A9850, 0xF46D43, 0x2C7BB6, 0x8C510A, 0x762A83, 0xD7191C,
         tableau, 0.0, false},
    };
    return all[(size_t)std::clamp(i, 0, (int)all.size() - 1)];
}

std::map<std::string, unsigned> colourBlindBandColours(const std::map<std::string, size_t> &qsosPerBand) {
    std::vector<std::pair<std::string, size_t>> bands(qsosPerBand.begin(), qsosPerBand.end());
    // The most used first (ties: frequency order), as many as the set has colours...
    std::sort(bands.begin(), bands.end(), [](const auto &x, const auto &y) {
        return x.second != y.second ? x.second > y.second : bandOrder(x.first) < bandOrder(y.first);
    });
    const std::vector<unsigned> &set = colourBlindBandSet();
    if (bands.size() > set.size()) bands.resize(set.size());
    // ...then given out in frequency order.
    std::sort(bands.begin(), bands.end(), [](const auto &x, const auto &y) {
        int a = bandOrder(x.first), b = bandOrder(y.first);
        return (a < 0 ? 1000 : a) < (b < 0 ? 1000 : b);
    });
    std::map<std::string, unsigned> out;
    for (size_t i = 0; i < bands.size(); ++i) out[bands[i].first] = set[i];
    return out;
}

double deltaE2000Lab(double L1, double a1, double b1, double L2, double a2, double b2) {
    // Sharma, Wu and Dalal (2005), "The CIEDE2000 color-difference formula: implementation
    // notes, supplementary test data, and mathematical observations", eqs. 2-22.
    const double kPi = 3.14159265358979323846, deg = 180 / kPi;
    double C1 = std::hypot(a1, b1), C2 = std::hypot(a2, b2), Cbar = (C1 + C2) / 2;
    double C7 = std::pow(Cbar, 7), G = 0.5 * (1 - std::sqrt(C7 / (C7 + std::pow(25.0, 7))));
    double a1p = (1 + G) * a1, a2p = (1 + G) * a2;
    double C1p = std::hypot(a1p, b1), C2p = std::hypot(a2p, b2);
    auto hue = [&](double b, double ap) {
        if (b == 0 && ap == 0) return 0.0;
        double h = std::atan2(b, ap) * deg;
        return h < 0 ? h + 360 : h;
    };
    double h1p = hue(b1, a1p), h2p = hue(b2, a2p);
    double dLp = L2 - L1, dCp = C2p - C1p, dhp = 0;
    if (C1p * C2p != 0) {
        dhp = h2p - h1p;
        if (dhp > 180) dhp -= 360;
        else if (dhp < -180) dhp += 360;
    }
    double dHp = 2 * std::sqrt(C1p * C2p) * std::sin(dhp / deg / 2);
    double Lbp = (L1 + L2) / 2, Cbp = (C1p + C2p) / 2, hbp;
    if (C1p * C2p == 0) hbp = h1p + h2p;
    else if (std::fabs(h1p - h2p) <= 180) hbp = (h1p + h2p) / 2;
    else hbp = h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2;
    double T = 1 - 0.17 * std::cos((hbp - 30) / deg) + 0.24 * std::cos(2 * hbp / deg) + 0.32 * std::cos((3 * hbp + 6) / deg) -
               0.20 * std::cos((4 * hbp - 63) / deg);
    double dTheta = 30 * std::exp(-std::pow((hbp - 275) / 25, 2));
    double Cb7 = std::pow(Cbp, 7), Rc = 2 * std::sqrt(Cb7 / (Cb7 + std::pow(25.0, 7)));
    double Sl = 1 + 0.015 * std::pow(Lbp - 50, 2) / std::sqrt(20 + std::pow(Lbp - 50, 2));
    double Sc = 1 + 0.045 * Cbp, Sh = 1 + 0.015 * Cbp * T, Rt = -std::sin(2 * dTheta / deg) * Rc;
    return std::sqrt(std::pow(dLp / Sl, 2) + std::pow(dCp / Sc, 2) + std::pow(dHp / Sh, 2) + Rt * (dCp / Sc) * (dHp / Sh));
}

unsigned simulateVision(unsigned rgb, Vision v) {
    // Machado, Oliveira and Fernandes (2009), "A Physiologically-based Model for Simulation of
    // Color Vision Deficiency", IEEE TVCG 15(6); severity 1.0 matrices from the authors' page
    // (inf.ufrgs.br/~oliveira, read 2026-10-10; the same in colorspacious), applied to linear
    // sRGB as colorspacious and DaltonLens do. Tritan is the model's weakest case.
    static const double kMatrices[3][3][3] = {
        {{0.152286, 1.052583, -0.204868}, {0.114503, 0.786281, 0.099216}, {-0.003882, -0.048116, 1.051998}},  // protan
        {{0.367322, 0.860646, -0.227968}, {0.280085, 0.672501, 0.047413}, {-0.011820, 0.042940, 0.968881}},   // deutan
        {{1.255528, -0.076749, -0.178779}, {-0.078411, 0.930809, 0.147602}, {0.004733, 0.691367, 0.303900}},  // tritan
    };
    if (v == Vision::Normal) return rgb;
    const double(&m)[3][3] = kMatrices[(int)v - 1];
    double in[3] = {toLinear(channel(rgb, 16)), toLinear(channel(rgb, 8)), toLinear(channel(rgb, 0))};
    unsigned out = 0;
    for (int i = 0; i < 3; ++i) {
        double c = m[i][0] * in[0] + m[i][1] * in[1] + m[i][2] * in[2];
        out |= (unsigned)std::lround(toEncoded(c) * 255) << (16 - 8 * i);
    }
    return out;
}

double deltaE2000(unsigned a, unsigned b) {
    double L1, a1, b1, L2, a2, b2;
    toLab(a, &L1, &a1, &b1);
    toLab(b, &L2, &a2, &b2);
    return deltaE2000Lab(L1, a1, b1, L2, a2, b2);
}

}  // namespace adif
