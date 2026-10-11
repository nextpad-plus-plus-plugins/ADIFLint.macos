// The Map's colours as sRGB values (0xRRGGBB), here rather than in the AppKit code so the
// tests can check them: band colours (PSKReporter's, or a colour-blind safe set), the four
// palettes, and the colour science the colour-blind check uses (CIEDE2000, and simulated
// colour-vision deficiency).
#pragma once

#include <cstddef>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace adif {

constexpr unsigned kUnknownBandColour = 0x808080;  // PSKReporter's "unknown"

// A band's place in frequency order (ADIF's band names, 2190m first); -1 when not a band.
int bandOrder(std::string_view band);
// The colour PSKReporter's map gives a band; kUnknownBandColour when it has none.
unsigned pskReporterBandColour(std::string_view band);

struct MapPalette {
    const char *name;
    unsigned background, ocean, land, river, border;
    bool dark;  // light ink (labels, grid lines) on a dark map
    unsigned confirmed, worked, dxccConfirmed, dxccWorked, park, me;
    std::vector<unsigned> qualitative;  // modes, then other programs
    double rampFrom;                    // where counts and years start along viridis
    bool safeBands;                     // bands from colourBlindBandSet() instead of PSKReporter's
};
size_t mapPaletteCount();
const MapPalette &mapPalette(int i);  // clamped: 0 standard, 1 colour-blind safe, 2 high contrast, 3 light

// Viridis (matplotlib's perceptually uniform map) at t in 0..1, for counts and years.
unsigned viridisColour(double t);

// The colour-blind safe palette's band colours, in the order they are given out.
const std::vector<unsigned> &colourBlindBandSet();
// Band colours on the colour-blind safe palette: the set given to the log's most used bands
// (as many as it has colours), in frequency order so the legend reads in order; any other
// band is kUnknownBandColour. Counted over the whole log, so filters don't shuffle colours.
std::map<std::string, unsigned> colourBlindBandColours(const std::map<std::string, size_t> &qsosPerBand);

// CIEDE2000 colour difference between two sRGB colours (D65, CIELAB).
double deltaE2000(unsigned a, unsigned b);
// The same between two CIELAB colours, for testing against published data.
double deltaE2000Lab(double L1, double a1, double b1, double L2, double a2, double b2);
// How an sRGB colour looks with a colour-vision deficiency (full strength).
enum class Vision { Normal, Protan, Deutan, Tritan };
unsigned simulateVision(unsigned rgb, Vision v);

}  // namespace adif
