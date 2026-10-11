#import "Map.h"

#import "Country.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "adif_geo.h"
#include "adif_palette.h"
#include "adif_projection.h"
#include "adif_spec.h"
#include "adif_world.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <tuple>

using namespace adifhost;

struct ADIFMapEntity {
    int dxcc = 0;
    double lat = 0, lon = 0;
    std::vector<size_t> qsos;  // into MapData::qsos
    bool confirmed = false;
    std::string name;
};

// What the pointer is over, or what was clicked.
struct ADIFMapHit {
    enum Kind { None, Square, Dxcc, Park, Contact, Empty } kind = None;
    std::string square;  // the 4-character square under the point (always set on the map)
    size_t index = 0;    // into squares, entities, parks or contacts
};

// How the map looks: the Options menu, the colour popup and the overlay checkboxes.
struct ADIFMapStyle {
    int colorBy = 0;    // 0 confirmation, 1 band, 2 mode, 3 QSO count, 4 year first worked
    int palette = 0;    // 0 standard, 1 colour-blind safe, 2 high contrast, 3 light (print)
    int shape = 0;      // markers: 0 by layer (DXCC dots, park triangles, program diamonds), 1 circles, 2 squares
    int fill = 0;       // worked squares: 0 solid, 1 translucent, 2 outline
    int contact = 0;    // contacts: 0 pins, 1 dots, 2 crosshairs
    int lineStyle = 0;  // lines to contacts: 0 solid, 1 dashed, 2 dotted
    int lineWidth = 1;  // 0 thin, 1 medium, 2 thick
    double marker = 1;  // marker size factor
    bool grid = true, labels = true, legend = true, rings = false, paths = false, mine = true;
    bool cqZones = false, ituZones = false, states = false, countries = false;  // overlays
};

// QSOs at one exact place (MapQso::located), for the Contacts layer.
struct ADIFMapContact {
    double lat = 0, lon = 0;
    std::vector<size_t> qsos;  // into MapData::qsos
};

// What colours a square or a DXCC dot, over its QSOs.
struct ADIFMapAgg {
    std::string band;  // the band with the most QSOs
    int mode = 2;      // the mode group with the most QSOs: 0 CW, 1 phone, 2 data
    size_t count = 0;
    int year = 0;      // the first QSO's year
    bool confirmed = false;
};

namespace {

constexpr double kMaxZoom = 64;
constexpr double kPin = 4;  // a contact pin's head radius (times Style's marker size); the head is 2.2 of these above the point

// ── Colours ──

NSColor *rgb(unsigned hex, CGFloat a = 1) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:a];
}

// The palettes and band colours live in adif_palette (the tests check them).
using adif::MapPalette;
const MapPalette &paletteAt(int i) { return adif::mapPalette(i); }

void setFill(CGContextRef ctx, unsigned hex, CGFloat a = 1) {
    CGContextSetRGBFillColor(ctx, ((hex >> 16) & 0xFF) / 255.0, ((hex >> 8) & 0xFF) / 255.0, (hex & 0xFF) / 255.0, a);
}
void setStroke(CGContextRef ctx, unsigned hex, CGFloat a = 1) {
    CGContextSetRGBStrokeColor(ctx, ((hex >> 16) & 0xFF) / 255.0, ((hex >> 8) & 0xFF) / 255.0, (hex & 0xFF) / 255.0, a);
}

int bandIndex(const std::string &band) { return adif::bandOrder(band); }

// Whether a marker in this colour needs a light edge to show on a dark map (60m's navy).
bool darkColour(NSColor *c) {
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return s && 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent < 0.22;
}

NSColor *ramp(double t, const MapPalette &p) {
    return rgb(adif::viridisColour(p.rampFrom + std::clamp(t, 0.0, 1.0) * (1 - p.rampFrom) * (p.dark ? 1 : 0.9)));
}

// QSO counts in five steps: 1, 2-4, 5-9, 10-24, 25 and more.
int countBucket(size_t n) { return n <= 1 ? 0 : n <= 4 ? 1 : n <= 9 ? 2 : n <= 24 ? 3 : 4; }
const char *const kCountLabels[] = {"1 QSO", "2-4", "5-9", "10-24", "25+"};
const char *const kModeLabels[] = {"CW", "Phone", "Data"};

// ── Programs ──

// Other programs the map lists, with what their references are; any other SIG in the log follows.
struct ProgramInfo {
    const char *key, *label;
};
const ProgramInfo kPrograms[] = {{"SOTA", "SOTA (summits)"},       {"IOTA", "IOTA (islands)"},        {"GMA", "GMA (mountains)"},
                                 {"WWBOTA", "WWBOTA (bunkers)"},   {"HEMA", "HEMA (hills)"},          {"SIOTA", "SiOTA (silos)"},
                                 {"WCA", "WCA (castles)"},         {"ILLW", "ILLW (lighthouses)"},    {"ARLHS", "ARLHS (lighthouses)"},
                                 {"MOTA", "MOTA (mills)"},         {"ZLOTA", "ZLOTA (New Zealand)"}, {"WOTA", "WOTA (Lake District)"}};
constexpr size_t kProgramCount = sizeof(kPrograms) / sizeof(kPrograms[0]);

// The overlays' areas, read once, with each area's extent for deciding when its name fits.
struct OverlayCache {
    std::vector<adif::OverlayArea> areas;
    std::vector<std::pair<double, double>> span;  // longitude and latitude extent
};
const OverlayCache &overlay(adif::Overlay o) {
    static std::map<int, OverlayCache> all;
    OverlayCache &c = all[(int)o];
    if (c.areas.empty())
        for (size_t i = 0; i < adif::overlayCount(o); ++i) {
            c.areas.push_back(adif::overlayArea(o, i));
            double w = 999, e = -999, so = 999, n = -999;
            for (const auto &ring : c.areas.back().rings)
                for (const auto &p : ring) w = std::min(w, p.first), e = std::max(e, p.first), so = std::min(so, p.second), n = std::max(n, p.second);
            c.span.emplace_back(e - w, n - so);
        }
    return c;
}

// A layer projected onto the plane, kept for the projection in use (and the globe's turn).
// On the globe, shapes are cut where they go behind (adif::projectShape).
CGPathRef projectedLayer(const adif::Projector &pr, adif::MapLayer l, int maxRank = 99) {
    static std::map<std::tuple<int, int>, CGPathRef> cache;
    static std::tuple<int, long, long> cachedFor{-1, 0, 0};
    std::tuple<int, long, long> key{(int)pr.kind(), std::lround(pr.centerLat() * 1e6), std::lround(pr.centerLon() * 1e6)};
    if (key != cachedFor) {
        for (auto &kv : cache) CGPathRelease(kv.second);
        cache.clear();
        cachedFor = key;
    }
    CGPathRef &p = cache[{(int)l, maxRank}];
    if (p) return p;
    bool polygons = l == adif::MapLayer::Land110 || l == adif::MapLayer::Land50 || l == adif::MapLayer::Lakes110 || l == adif::MapLayer::Lakes50;
    CGMutablePathRef m = CGPathCreateMutable();
    for (size_t i = 0; i < adif::layerShapeCount(l); ++i) {
        if (adif::layerShapeRank(l, i) > maxRank) continue;
        for (const adif::ShapePiece &piece : adif::projectShape(pr, adif::layerShape(l, i), polygons, false)) {
            for (size_t k = 0; k < piece.pts.size(); ++k)
                if (k == 0) CGPathMoveToPoint(m, nullptr, piece.pts[k].first, piece.pts[k].second);
                else CGPathAddLineToPoint(m, nullptr, piece.pts[k].first, piece.pts[k].second);
            if (piece.closed) CGPathCloseSubpath(m);
        }
    }
    p = m;
    return p;
}

}  // namespace

// The map, in one of four projections. Scroll or pinch to zoom (a trackpad's two-finger
// scroll pans), drag to pan, double-click to zoom in, + and - keys, 0 for the whole world.
// On the globe, dragging, a two-finger scroll and the arrow keys turn it instead.
@interface ADIFMapView : NSView
@property(nonatomic) BOOL showSquares, showEntities, showParks, showContacts;
@property(nonatomic) std::set<std::string> hiddenPrograms;
@property(nonatomic) std::map<std::string, size_t> qsosPerBand;  // over the whole log, for the colour-blind safe band colours
@property(nonatomic) ADIFMapStyle style;
@property(nonatomic, readonly) double zoom;
@property(nonatomic, copy) void (^onHover)(const ADIFMapHit &hit);
@property(nonatomic, copy) void (^onSelect)(const ADIFMapHit &hit);
@property(nonatomic, copy) void (^onViewChanged)(void);
- (void)setData:(const adif::MapData &)data entities:(const std::vector<ADIFMapEntity> &)entities;
- (void)setProjector:(const adif::Projector &)projector home:(NSString *)homeGrid lat:(double)lat lon:(double)lon;
- (void)zoomBy:(double)factor;  // about the middle
- (void)showWorld;
- (void)fitLog;                 // zoom to what the log shows
- (void)showWest:(double)w south:(double)s east:(double)e north:(double)n;  // a region
- (NSPoint)viewPointForLon:(double)lon lat:(double)lat;
- (const std::vector<ADIFMapContact> &)contacts;
@end

@implementation ADIFMapView {
    adif::MapData _data;
    std::vector<ADIFMapEntity> _entities;
    std::vector<ADIFMapContact> _contacts;
    std::vector<ADIFMapAgg> _squareAgg, _entityAgg, _contactAgg;
    std::vector<std::string> _bands;  // in the data, frequency order
    int _minYear, _maxYear;
    adif::Projector _pr;    // in use: the globe turned to wherever you dragged it
    adif::Projector _base;  // as chosen: the globe centred on home
    bool _hasHome;
    double _homeLat, _homeLon;
    NSString *_homeGrid;
    double _cx, _cy, _zoom;  // the view's centre on the plane, and its zoom
    ADIFMapHit _hover, _selected;
    NSPoint _down;
    BOOL _dragged;
    NSTrackingArea *_tracking;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _showSquares = _showEntities = _showParks = YES;
        _zoom = 1;
        _minYear = _maxYear = 0;
        _hasHome = false;
        _homeLat = _homeLon = 0;
    }
    return self;
}

- (BOOL)isFlipped {
    return NO;
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES;
}
- (double)zoom {
    return _zoom;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                                     NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (ADIFMapAgg)aggregate:(const std::vector<size_t> &)qsos {
    ADIFMapAgg a;
    std::map<std::string, size_t> bands;
    size_t modes[3] = {0, 0, 0};
    std::string first;
    for (size_t i : qsos) {
        if (i >= _data.qsos.size()) continue;
        const adif::MapQso &q = _data.qsos[i];
        ++a.count;
        a.confirmed |= q.confirmed;
        if (!q.band.empty()) ++bands[q.band];
        ++modes[std::clamp(q.modeGroup, 0, 2)];
        if (q.date8.size() == 8 && (first.empty() || q.date8 < first)) first = q.date8;
    }
    size_t most = 0;
    for (const auto &kv : bands)  // ties: the lower band
        if (kv.second > most || (kv.second == most && bandIndex(kv.first) < bandIndex(a.band))) most = kv.second, a.band = kv.first;
    a.mode = modes[0] >= modes[1] && modes[0] >= modes[2] ? 0 : modes[1] >= modes[2] ? 1 : 2;
    a.year = first.empty() ? 0 : std::atoi(first.substr(0, 4).c_str());
    return a;
}

- (void)setData:(const adif::MapData &)data entities:(const std::vector<ADIFMapEntity> &)entities {
    _data = data;
    _entities = entities;
    _squareAgg.clear();
    _entityAgg.clear();
    _contactAgg.clear();
    _contacts.clear();
    for (const adif::MapSquare &sq : _data.squares) _squareAgg.push_back([self aggregate:sq.qsoIndex]);
    for (const ADIFMapEntity &e : _entities) _entityAgg.push_back([self aggregate:e.qsos]);
    std::map<std::pair<long, long>, size_t> at;  // QSOs at the same place (to about 10 m) share a marker
    for (size_t i = 0; i < _data.qsos.size(); ++i) {
        const adif::MapQso &q = _data.qsos[i];
        if (!q.located) continue;
        auto [it, added] = at.emplace(std::make_pair(std::lround(q.lat * 1e4), std::lround(q.lon * 1e4)), _contacts.size());
        if (added) _contacts.push_back({q.lat, q.lon, {}});
        _contacts[it->second].qsos.push_back(i);
    }
    for (const ADIFMapContact &c : _contacts) _contactAgg.push_back([self aggregate:c.qsos]);
    std::set<std::string> bands;
    _minYear = _maxYear = 0;
    for (const adif::MapQso &q : _data.qsos) {
        if (!q.band.empty()) bands.insert(q.band);
        int y = q.date8.size() == 8 ? std::atoi(q.date8.substr(0, 4).c_str()) : 0;
        if (y > 0) _minYear = _minYear ? std::min(_minYear, y) : y, _maxYear = std::max(_maxYear, y);
    }
    _bands.assign(bands.begin(), bands.end());
    std::sort(_bands.begin(), _bands.end(), [](const std::string &a, const std::string &b) {
        int x = bandIndex(a), y = bandIndex(b);
        if (x < 0) x = 1000;
        if (y < 0) y = 1000;
        return x != y ? x < y : a < b;
    });
    _hover = ADIFMapHit();
    _selected = ADIFMapHit();
    self.needsDisplay = YES;
}

- (void)setProjector:(const adif::Projector &)projector home:(NSString *)homeGrid lat:(double)lat lon:(double)lon {
    bool same = projector.kind() == _base.kind() && projector.centerLat() == _base.centerLat() && projector.centerLon() == _base.centerLon();
    _base = projector;
    if (!same) _pr = projector;
    _homeGrid = homeGrid;
    _hasHome = homeGrid.length > 0;
    _homeLat = lat, _homeLon = lon;
    if (!same) [self showWorld];
    else self.needsDisplay = YES;
}

- (const std::vector<ADIFMapContact> &)contacts {
    return _contacts;
}

- (void)setShowContacts:(BOOL)on {
    _showContacts = on;
    self.needsDisplay = YES;
}

- (void)setStyle:(ADIFMapStyle)style {
    _style = style;
    self.needsDisplay = YES;
}

- (void)setHiddenPrograms:(std::set<std::string>)hidden {
    _hiddenPrograms = hidden;
    self.needsDisplay = YES;
}

// ── The plane and the view ──

- (double)ppu {  // pixels per plane unit
    double minX, minY, maxX, maxY;
    _pr.bounds(&minX, &minY, &maxX, &maxY);
    NSRect b = self.bounds;
    return std::min(b.size.width / (maxX - minX), b.size.height / (maxY - minY)) * _zoom;
}

- (BOOL)globe {
    return _pr.kind() == adif::Projection::Globe;
}

// The globe turns rather than pans: the place at plane point (x, y) becomes the centre.
- (void)turnTo:(double)x y:(double)y {
    double lon, lat;
    if (!_pr.inverse(x, y, &lon, &lat)) return;
    _pr = adif::Projector(adif::Projection::Globe, lat, lon);
    [self viewChanged];
}

// Turn the globe so its surface moves (dx, dy) plane units: exactly with the pointer at the
// centre, where a unit is a degree of arc. North stays up, so it stops with a pole in the
// middle; near a pole, sideways moves spin the globe about it.
- (void)rotateBy:(double)dx y:(double)dy {
    double lat = std::clamp(_pr.centerLat() - dy, -90.0, 90.0);
    double lon = _pr.centerLon() - dx / std::max(std::cos(_pr.centerLat() * M_PI / 180), 0.2);
    _pr = adif::Projector(adif::Projection::Globe, lat, lon);
    [self viewChanged];
}

- (BOOL)atHome {
    return std::fabs(_pr.centerLat() - _base.centerLat()) < 1e-9 && std::fabs(_pr.centerLon() - _base.centerLon()) < 1e-9;
}

- (void)clampCenter {
    if ([self globe]) {  // always centred on the globe's centre
        _cx = _cy = 0;
        return;
    }
    double ppu = [self ppu];
    if (ppu <= 0) return;
    double minX, minY, maxX, maxY;
    _pr.bounds(&minX, &minY, &maxX, &maxY);
    double halfW = self.bounds.size.width / 2 / ppu, halfH = self.bounds.size.height / 2 / ppu;
    _cx = halfW >= (maxX - minX) / 2 ? (minX + maxX) / 2 : std::clamp(_cx, minX + halfW, maxX - halfW);
    _cy = halfH >= (maxY - minY) / 2 ? (minY + maxY) / 2 : std::clamp(_cy, minY + halfH, maxY - halfH);
}

- (NSPoint)planeToView:(double)x y:(double)y {
    double ppu = [self ppu];
    return NSMakePoint(NSMidX(self.bounds) + (x - _cx) * ppu, NSMidY(self.bounds) + (y - _cy) * ppu);
}

- (void)viewToPlane:(NSPoint)p x:(double *)x y:(double *)y {
    double ppu = [self ppu];
    *x = _cx + (p.x - NSMidX(self.bounds)) / ppu;
    *y = _cy + (p.y - NSMidY(self.bounds)) / ppu;
}

// A point on the map in view coordinates; far outside the view when it has no place.
- (NSPoint)viewPointForLon:(double)lon lat:(double)lat {
    double x, y;
    if (!_pr.forward(lon, lat, &x, &y)) return NSMakePoint(-1e6, -1e6);
    return [self planeToView:x y:y];
}

- (BOOL)lonLatAt:(NSPoint)p lon:(double *)lon lat:(double *)lat {
    double x, y;
    [self viewToPlane:p x:&x y:&y];
    return _pr.inverse(x, y, lon, lat);
}

// A run of (lon, lat) points as a path in view coordinates: on the globe, cut where it goes
// behind (a closed shape follows the rim there); on a flat map, cut where it crosses the
// 180th meridian when it `wraps` (paths and rings do, the grid doesn't).
- (NSBezierPath *)viewPath:(const std::vector<std::pair<double, double>> &)pts close:(BOOL)close wraps:(BOOL)wraps {
    NSBezierPath *path = [NSBezierPath bezierPath];
    for (const adif::ShapePiece &piece : adif::projectShape(_pr, pts, close, wraps)) {
        for (size_t k = 0; k < piece.pts.size(); ++k) {
            NSPoint v = [self planeToView:piece.pts[k].first y:piece.pts[k].second];
            if (k == 0) [path moveToPoint:v];
            else [path lineToPoint:v];
        }
        if (piece.closed) [path closePath];
    }
    return path;
}

// A 4-character square's outline, its edges curved as the projection bends them.
- (NSBezierPath *)squarePath:(const std::string &)grid {
    double w, s, e, n;
    if (!adif::squareBounds(grid, &w, &s, &e, &n)) return nil;
    int steps = _pr.kind() == adif::Projection::Equirectangular ? 1 : 4;
    std::vector<std::pair<double, double>> pts;
    for (int i = 0; i < steps; ++i) pts.emplace_back(w + (e - w) * i / steps, s);
    for (int i = 0; i < steps; ++i) pts.emplace_back(e, s + (n - s) * i / steps);
    for (int i = 0; i < steps; ++i) pts.emplace_back(e - (e - w) * i / steps, n);
    for (int i = 0; i < steps; ++i) pts.emplace_back(w, n - (n - s) * i / steps);
    return [self viewPath:pts close:YES wraps:NO];
}

// The longitudes and latitudes in view (sampled; the whole world when it all shows).
- (void)visibleWest:(double *)west south:(double *)south east:(double *)east north:(double *)north {
    *west = 180, *east = -180, *south = 90, *north = -90;
    NSRect b = self.bounds;
    int hits = 0;
    for (int i = 0; i <= 8; ++i)
        for (int j = 0; j <= 8; ++j) {
            double lon, lat;
            if (![self lonLatAt:NSMakePoint(NSMinX(b) + b.size.width * i / 8, NSMinY(b) + b.size.height * j / 8) lon:&lon lat:&lat]) continue;
            ++hits;
            *west = std::min(*west, lon), *east = std::max(*east, lon), *south = std::min(*south, lat), *north = std::max(*north, lat);
        }
    for (double pole : {90.0, -90.0}) {  // a pole in view: every longitude, up to the pole
        NSPoint at = [self viewPointForLon:0 lat:pole];
        if (!NSPointInRect(at, b)) continue;
        *west = -180, *east = 180;
        if (pole > 0) *north = 90;
        else *south = -90;
    }
    if (hits < 81 || [self globe] || *east - *west > 300) {  // edges show, or the view wraps
        if (_zoom < 2 || hits < 81) *west = -180, *east = 180, *south = -90, *north = 90;
    }
    *west = std::max(-180.0, *west - 2), *east = std::min(180.0, *east + 2);
    *south = std::max(-90.0, *south - 1), *north = std::min(90.0, *north + 1);
}

// Pixels across a span of longitude at a place, for sizing labels and the square grid.
- (double)pixelsForLon:(double)lon lat:(double)lat span:(double)span {
    NSPoint a = [self viewPointForLon:lon - span / 2 lat:lat], b = [self viewPointForLon:lon + span / 2 lat:lat];
    if (a.x < -1e5 || b.x < -1e5) return 0;
    return std::hypot(b.x - a.x, b.y - a.y);
}

- (void)viewChanged {
    [self clampCenter];
    self.needsDisplay = YES;
    if (self.onViewChanged) self.onViewChanged();
}

- (void)zoomBy:(double)factor at:(NSPoint)p {
    double x, y;
    [self viewToPlane:p x:&x y:&y];
    double z = std::clamp(_zoom * factor, 1.0, kMaxZoom);
    if (z == _zoom) return;
    if ([self globe]) {  // turn toward the pointer so the place under it stays about there
        double f = z / _zoom;
        _zoom = z;
        [self turnTo:x * (1 - 1 / f) y:y * (1 - 1 / f)];
        return;
    }
    _zoom = z;
    double ppu = [self ppu];  // keep the point under the pointer where it was
    _cx = x - (p.x - NSMidX(self.bounds)) / ppu;
    _cy = y - (p.y - NSMidY(self.bounds)) / ppu;
    [self viewChanged];
}

- (void)zoomBy:(double)factor {
    [self zoomBy:factor at:NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds))];
}

- (void)showWorld {
    _pr = _base;  // the globe back on home
    double minX, minY, maxX, maxY;
    _pr.bounds(&minX, &minY, &maxX, &maxY);
    _zoom = 1, _cx = (minX + maxX) / 2, _cy = (minY + maxY) / 2;
    [self viewChanged];
}

// Zoom to a box of longitudes and latitudes (a continent): the flat maps fit it, the globe
// turns to face its middle (a pole, for a box that reaches one) and fits it.
- (void)showWest:(double)w south:(double)s east:(double)e north:(double)n {
    if ([self globe]) {
        double clat = s <= -89.9 ? -90 : n >= 89.9 ? 90 : (s + n) / 2;
        _pr = adif::Projector(adif::Projection::Globe, clat, (w + e) / 2);
    } else {
        _pr = _base;
    }
    double west = 1e9, east = -1e9, south = 1e9, north = -1e9;
    for (int i = 0; i <= 24; ++i)
        for (int j = 0; j <= 12; ++j) {
            double x, y;
            if (!_pr.forward(w + (e - w) * i / 24, s + (n - s) * j / 12, &x, &y)) continue;
            west = std::min(west, x), east = std::max(east, x), south = std::min(south, y), north = std::max(north, y);
        }
    if (west > east) return [self showWorld];
    [self fitPlaneWest:west south:south east:east north:north];
}

- (void)fitLog {
    _pr = _base;
    double west = 1e9, east = -1e9, south = 1e9, north = -1e9;
    auto add = [&](double lon, double lat) {
        double x, y;
        if (!_pr.forward(lon, lat, &x, &y)) return;
        west = std::min(west, x), east = std::max(east, x), south = std::min(south, y), north = std::max(north, y);
    };
    if (_showSquares)
        for (const adif::MapSquare &sq : _data.squares) {
            double w, s, e, n;
            if (adif::squareBounds(sq.grid, &w, &s, &e, &n)) add(w, s), add(e, n), add(w, n), add(e, s);
        }
    if (_showEntities)
        for (const ADIFMapEntity &e : _entities) add(e.lon, e.lat);
    if (_showContacts)
        for (const ADIFMapContact &c : _contacts) add(c.lon, c.lat);
    for (const std::string &g : _data.mine) {
        double lat, lon;
        if (adif::gridToLatLon(g, &lat, &lon)) add(lon, lat);
    }
    if (west > east) return [self showWorld];
    [self fitPlaneWest:west south:south east:east north:north];
}

// Fit the view to a part of the plane; on the globe, centred where it is turned to.
- (void)fitPlaneWest:(double)west south:(double)south east:(double)east north:(double)north {
    if ([self globe]) {  // the span is twice the farthest point in front
        double r = std::max({std::fabs(west), std::fabs(east), std::fabs(south), std::fabs(north)});
        west = -r, east = r, south = -r, north = r;
    }
    double spanX = std::max(8.0, (east - west) * 1.15), spanY = std::max(4.0, (north - south) * 1.15);
    double minX, minY, maxX, maxY;
    _pr.bounds(&minX, &minY, &maxX, &maxY);
    NSRect b = self.bounds;
    double base = std::min(b.size.width / (maxX - minX), b.size.height / (maxY - minY));
    _zoom = std::clamp(std::min(b.size.width / spanX, b.size.height / spanY) / base, 1.0, kMaxZoom);
    _cx = (west + east) / 2, _cy = (south + north) / 2;
    [self viewChanged];
}

// ── Colours of things ──

// By band: PSKReporter's colours, or on the colour-blind safe palette its own set, given to
// the log's most used bands.
- (NSColor *)bandColor:(const std::string &)band {
    const MapPalette &p = paletteAt(_style.palette);
    if (!p.safeBands) return rgb(adif::pskReporterBandColour(band));
    static std::map<std::string, size_t> countedFor;
    static std::map<std::string, unsigned> colours;
    if (countedFor != _qsosPerBand) countedFor = _qsosPerBand, colours = adif::colourBlindBandColours(_qsosPerBand);
    for (const auto &kv : colours)
        if (adif::equalsNoCase(kv.first, band)) return rgb(kv.second);
    return rgb(adif::kUnknownBandColour);
}

- (void)setQsosPerBand:(std::map<std::string, size_t>)counts {
    _qsosPerBand = counts;
    self.needsDisplay = YES;
}

- (NSColor *)colorFor:(const ADIFMapAgg &)a entity:(BOOL)entity {
    const MapPalette &p = paletteAt(_style.palette);
    switch (_style.colorBy) {
        case 1: return [self bandColor:a.band];
        case 2: return rgb(p.qualitative[(size_t)std::clamp(a.mode, 0, 2) % p.qualitative.size()]);
        case 3: return ramp(countBucket(a.count) / 4.0, p);
        case 4: return ramp(_maxYear > _minYear && a.year ? (double)(a.year - _minYear) / (_maxYear - _minYear) : 1.0, p);
        default: return rgb(entity ? (a.confirmed ? p.dxccConfirmed : p.dxccWorked) : (a.confirmed ? p.confirmed : p.worked));
    }
}

- (NSColor *)programColor:(const std::string &)program {
    const MapPalette &p = paletteAt(_style.palette);
    size_t i = kProgramCount;
    for (size_t k = 0; k < kProgramCount; ++k)
        if (program == kPrograms[k].key) i = k;
    if (i == kProgramCount) {  // a program the map doesn't list: a stable colour from its name
        size_t h = 0;
        for (char c : program) h = h * 31 + (unsigned char)c;
        i = h;
    }
    return rgb(p.qualitative[i % p.qualitative.size()]);
}

// A marker centred on p: kind 0 dot, 1 triangle, 2 diamond, 3 star, 4 pin (its point at p),
// 5 crosshair; Style's shape overrides 0-2.
- (NSBezierPath *)marker:(int)kind at:(NSPoint)p size:(double)r {
    if (kind < 3 && _style.shape == 1) kind = 0;
    if (kind < 3 && _style.shape == 2) return [NSBezierPath bezierPathWithRect:NSMakeRect(p.x - r * 0.85, p.y - r * 0.85, r * 1.7, r * 1.7)];
    NSBezierPath *m = [NSBezierPath bezierPath];
    switch (kind) {
        case 4: {  // a head of radius r, 2.2 r above the point, the sides tangent to it
            NSPoint head = NSMakePoint(p.x, p.y + 2.2 * r);
            double t = std::acos(1 / 2.2) * 180 / M_PI;  // the tangent points, from straight down
            [m moveToPoint:p];
            [m appendBezierPathWithArcWithCenter:head radius:r startAngle:-90 + t endAngle:270 - t clockwise:NO];
            [m closePath];
            [m appendBezierPathWithOvalInRect:NSMakeRect(head.x - r * 0.38, head.y - r * 0.38, r * 0.76, r * 0.76)];
            m.windingRule = NSWindingRuleEvenOdd;  // the head's hole
            return m;
        }
        case 5:
            [m appendBezierPathWithOvalInRect:NSMakeRect(p.x - r, p.y - r, 2 * r, 2 * r)];
            [m moveToPoint:NSMakePoint(p.x - r * 1.6, p.y)];
            [m lineToPoint:NSMakePoint(p.x + r * 1.6, p.y)];
            [m moveToPoint:NSMakePoint(p.x, p.y - r * 1.6)];
            [m lineToPoint:NSMakePoint(p.x, p.y + r * 1.6)];
            return m;
        case 1:
            [m moveToPoint:NSMakePoint(p.x, p.y + r * 1.15)];
            [m lineToPoint:NSMakePoint(p.x - r, p.y - r * 0.75)];
            [m lineToPoint:NSMakePoint(p.x + r, p.y - r * 0.75)];
            break;
        case 2:
            [m moveToPoint:NSMakePoint(p.x, p.y + r)];
            [m lineToPoint:NSMakePoint(p.x - r * 0.9, p.y)];
            [m lineToPoint:NSMakePoint(p.x, p.y - r)];
            [m lineToPoint:NSMakePoint(p.x + r * 0.9, p.y)];
            break;
        case 3:
            for (int k = 0; k < 10; ++k) {
                double a = M_PI / 2 + k * M_PI / 5, rad = k % 2 ? r * 0.4 : r;
                NSPoint q = NSMakePoint(p.x + rad * std::cos(a), p.y + rad * std::sin(a));
                if (k == 0) [m moveToPoint:q];
                else [m lineToPoint:q];
            }
            break;
        default: return [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - r, p.y - r, 2 * r, 2 * r)];
    }
    [m closePath];
    return m;
}

- (double)dotRadius:(size_t)qsos {
    return std::min(8.0, 3.0 + std::log2((double)qsos + 1)) * _style.marker;
}

// An overlay area's outline as lines: each ring closed, its edges followed in steps of a
// degree or so (zone lines run along parallels and meridians), but not along the 180th
// meridian, where a shape is cut that goes on beyond, nor along 85 degrees north or south,
// the edge of the web map the zone files were drawn for (no zone line runs there).
- (NSBezierPath *)outlineOf:(const adif::OverlayArea &)a {
    NSBezierPath *path = [NSBezierPath bezierPath];
    for (const auto &ring : a.rings) {
        std::vector<std::pair<double, double>> run;
        auto flush = [&]() {
            if (run.size() > 1) [path appendBezierPath:[self viewPath:run close:NO wraps:YES]];
            run.clear();
        };
        size_t n = ring.size();
        for (size_t k = 0; k <= n; ++k) {
            std::pair<double, double> p = ring[k % n];
            if (!run.empty()) {
                std::pair<double, double> q = run.back();
                bool cut = (std::fabs(q.first) > 179.99 && std::fabs(p.first) > 179.99 && q.first * p.first > 0) ||
                           (std::fabs(q.second) > 84.99 && std::fabs(p.second) > 84.99 && q.second * p.second > 0);
                if (cut) {
                    flush();
                } else if (std::fabs(p.first - q.first) <= 180) {
                    int steps = (int)std::ceil(std::max(std::fabs(p.first - q.first), std::fabs(p.second - q.second)));
                    for (int j = 1; j < steps; ++j)
                        run.emplace_back(q.first + (p.first - q.first) * j / steps, q.second + (p.second - q.second) * j / steps);
                }
            }
            run.push_back(p);
        }
        flush();
    }
    return path;
}

// A line to a contact as Options sets it: solid, dashed or dotted; thin, medium or thick.
- (void)styleLine:(NSBezierPath *)path {
    static const double kWidths[] = {0.6, 1.0, 1.8};
    double w = kWidths[std::clamp(_style.lineWidth, 0, 2)];
    path.lineWidth = w;
    if (_style.lineStyle == 1) {
        CGFloat dash[] = {(CGFloat)(5 + 2 * w), (CGFloat)(3 + w)};
        [path setLineDash:dash count:2 phase:0];
    } else if (_style.lineStyle == 2) {
        CGFloat dot[] = {0, (CGFloat)(2 + 1.5 * w)};
        [path setLineDash:dot count:2 phase:0];
        path.lineCapStyle = NSLineCapStyleRound;
    }
}

// The contact marker's shape and size, by Options.
- (NSBezierPath *)contactMarkerAt:(NSPoint)p {
    switch (_style.contact) {
        case 1: return [self marker:0 at:p size:3 * _style.marker];
        case 2: return [self marker:5 at:p size:3.6 * _style.marker];
        default: return [self marker:4 at:p size:kPin * _style.marker];
    }
}

- (BOOL)programShown:(const adif::MapPark &)pk {
    return pk.park() ? _showParks : !_hiddenPrograms.count(pk.program);
}

// ── Drawing ──

- (void)drawLabel:(NSString *)text at:(NSPoint)p size:(CGFloat)size alpha:(CGFloat)alpha {
    const MapPalette &pal = paletteAt(_style.palette);
    NSDictionary *attrs = @{NSFontAttributeName : [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:alpha]};
    NSSize s = [text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint(p.x - s.width / 2, p.y - s.height / 2) withAttributes:attrs];
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    const MapPalette &pal = paletteAt(_style.palette);
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    // Views don't clip their drawing to their bounds since macOS 14: zoomed in, the
    // world would paint over the controls above and the list below.
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, NSRectToCGRect(b));
    setFill(ctx, pal.background);
    CGContextFillRect(ctx, NSRectToCGRect(b));
    double ppu = [self ppu];
    CGFloat ink = pal.dark ? 1 : 0;

    // The world: ocean, clipped to its outline; then land, lakes, rivers and borders on the plane.
    NSBezierPath *world = [NSBezierPath bezierPath];
    std::vector<std::pair<double, double>> outline = _pr.outline();
    for (size_t i = 0; i < outline.size(); ++i) {
        NSPoint v = [self planeToView:outline[i].first y:outline[i].second];
        if (i == 0) [world moveToPoint:v];
        else [world lineToPoint:v];
    }
    [world closePath];
    CGContextSaveGState(ctx);
    bool globe = [self globe];
    NSPoint middle = [self planeToView:0 y:0];
    double radius = 180 / M_PI * ppu;  // the globe's, in points
    if (globe) {  // a thin glow of air round it
        NSGradient *air = [[NSGradient alloc] initWithColors:@[ rgb(pal.river, pal.dark ? 0.45 : 0.35), rgb(pal.river, 0) ]];
        [air drawFromCenter:middle radius:radius toCenter:middle radius:radius * 1.07 options:0];
    }
    [rgb(pal.ocean) setFill];
    [world fill];
    [world addClip];
    if (globe) {  // lit from the upper left
        NSColor *sea = rgb(pal.ocean);
        NSGradient *light = [[NSGradient alloc] initWithColors:@[ [sea blendedColorWithFraction:0.22 ofColor:NSColor.whiteColor], sea,
                                                                  [sea blendedColorWithFraction:0.3 ofColor:NSColor.blackColor] ]];
        [light drawFromCenter:NSMakePoint(middle.x - radius * 0.35, middle.y + radius * 0.35) radius:0 toCenter:middle radius:radius options:0];
    }
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, NSMidX(b) - _cx * ppu, NSMidY(b) - _cy * ppu);
    CGContextScaleCTM(ctx, ppu, ppu);
    bool fine = _zoom >= 3;
    setFill(ctx, pal.land);
    CGContextAddPath(ctx, projectedLayer(_pr, fine ? adif::MapLayer::Land50 : adif::MapLayer::Land110));
    CGContextEOFillPath(ctx);
    setFill(ctx, pal.ocean);  // lakes: the ocean's colour; their islands stay land
    CGContextAddPath(ctx, projectedLayer(_pr, fine ? adif::MapLayer::Lakes50 : adif::MapLayer::Lakes110));
    CGContextEOFillPath(ctx);
    setStroke(ctx, pal.river, 0.85);
    CGContextSetLineWidth(ctx, (_zoom >= 8 ? 1.0 : 0.7) / ppu);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextAddPath(ctx, projectedLayer(_pr, adif::MapLayer::Rivers50, _zoom < 2 ? 2 : _zoom < 4 ? 4 : 6));
    CGContextStrokePath(ctx);
    if (_zoom >= 2.5) {  // states and provinces: US, Canada, Australia, Russia...
        CGFloat dash[] = {(CGFloat)(3 / ppu), (CGFloat)(2 / ppu)};
        CGContextSetLineDash(ctx, 0, dash, 2);
        setStroke(ctx, pal.border, 0.4);
        CGContextSetLineWidth(ctx, 0.5 / ppu);
        CGContextAddPath(ctx, projectedLayer(_pr, adif::MapLayer::States50));
        CGContextStrokePath(ctx);
        CGContextSetLineDash(ctx, 0, nullptr, 0);
    }
    setStroke(ctx, pal.border, _zoom >= 2 ? 0.6 : 0.35);
    CGContextSetLineWidth(ctx, (_zoom >= 4 ? 0.9 : 0.6) / ppu);
    CGContextAddPath(ctx, projectedLayer(_pr, adif::MapLayer::Borders50));
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
    if (globe) {  // the edge turns away into shadow, so the globe looks round
        NSGradient *edge = [[NSGradient alloc] initWithColors:@[ [NSColor colorWithCalibratedWhite:0 alpha:0], [NSColor colorWithCalibratedWhite:0 alpha:pal.dark ? 0.38 : 0.18] ]];
        [edge drawFromCenter:middle radius:radius * 0.72 toCenter:middle radius:radius options:0];
    }

    double west, south, east, north;
    [self visibleWest:&west south:&south east:&east north:&north];
    double clon = 0, clat = 0;
    [self lonLatAt:NSMakePoint(NSMidX(b), NSMidY(b)) lon:&clon lat:&clat];
    double squareW = [self pixelsForLon:clon lat:clat span:2], fieldW = squareW * 10;
    bool curved = _pr.kind() != adif::Projection::Equirectangular;

    // Maidenhead fields (20 x 10 degrees), and squares (2 x 1) when they are big enough to see.
    if (_style.grid) {
        NSBezierPath *grid = [NSBezierPath bezierPath];
        double step = curved ? 2 : 180;
        for (int lon = -180; lon <= 180; lon += 20) {
            std::vector<std::pair<double, double>> line;
            for (double lat = -90; lat <= 90 + 1e-9; lat += step) line.emplace_back(lon, lat);
            [grid appendBezierPath:[self viewPath:line close:NO wraps:NO]];
        }
        for (int lat = -90; lat <= 90; lat += 10) {
            std::vector<std::pair<double, double>> line;
            for (double lon = -180; lon <= 180 + 1e-9; lon += curved ? 2 : 360) line.emplace_back(lon, lat);
            [grid appendBezierPath:[self viewPath:line close:NO wraps:NO]];
        }
        grid.lineWidth = 0.6;
        [[NSColor colorWithCalibratedWhite:ink alpha:0.18] setStroke];
        [grid stroke];
        if (squareW >= 12) {
            NSBezierPath *fineGrid = [NSBezierPath bezierPath];
            for (double lon = std::floor(west / 2) * 2; lon <= east; lon += 2) {
                std::vector<std::pair<double, double>> line;
                for (double lat = south; lat <= north + 1e-9; lat += curved ? 0.5 : north - south) line.emplace_back(lon, lat);
                [fineGrid appendBezierPath:[self viewPath:line close:NO wraps:NO]];
            }
            for (double lat = std::floor(south); lat <= north; lat += 1) {
                std::vector<std::pair<double, double>> line;
                for (double lon = west; lon <= east + 1e-9; lon += curved ? 1 : east - west) line.emplace_back(lon, lat);
                [fineGrid appendBezierPath:[self viewPath:line close:NO wraps:NO]];
            }
            fineGrid.lineWidth = 0.4;
            [[NSColor colorWithCalibratedWhite:ink alpha:0.08] setStroke];
            [fineGrid stroke];
        }
    }

    // Overlays: countries, US states, ITU zones and CQ zones, outlined, each named where its
    // name fits inside it on screen.
    struct OverlayStyle {
        bool on;
        adif::Overlay which;
        NSColor *color;
        CGFloat width, labelSize, minPixels;
    };
    const OverlayStyle overlayStyles[] = {
        {_style.countries, adif::Overlay::Countries, [NSColor colorWithCalibratedWhite:ink alpha:0.6], 0.8, 10, 24},
        {_style.states, adif::Overlay::UsStates, [NSColor colorWithCalibratedWhite:ink alpha:0.5], 0.7, 10, 26},
        {_style.ituZones, adif::Overlay::ItuZones, pal.dark ? rgb(0x4FC3F7, 0.75) : rgb(0x0277BD, 0.8), 1.0, 12, 30},
        {_style.cqZones, adif::Overlay::CqZones, pal.dark ? rgb(0xFFB74D, 0.8) : rgb(0xE65100, 0.8), 1.4, 14, 30},
    };
    for (const OverlayStyle &os : overlayStyles) {
        if (!os.on) continue;
        const OverlayCache &oc = overlay(os.which);
        NSBezierPath *lines = [NSBezierPath bezierPath];
        for (const adif::OverlayArea &a : oc.areas) [lines appendBezierPath:[self outlineOf:a]];
        lines.lineWidth = os.width;
        lines.lineJoinStyle = NSLineJoinStyleRound;
        [os.color setStroke];
        [lines stroke];
        NSDictionary *attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:os.labelSize weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName : [os.color colorWithAlphaComponent:0.95]};
        for (size_t i = 0; i < oc.areas.size(); ++i) {
            const adif::OverlayArea &a = oc.areas[i];
            NSPoint p = [self viewPointForLon:a.labelLon lat:a.labelLat];
            if (!NSPointInRect(p, NSInsetRect(b, -20, -10))) continue;
            double wide = [self pixelsForLon:a.labelLon lat:a.labelLat span:std::min(oc.span[i].first, 60.0)];
            NSString *name = ADIFString(a.name);
            NSSize sz = [name sizeWithAttributes:attrs];
            if (wide < std::max((double)os.minPixels, sz.width + 6)) continue;  // too small on screen for its name
            [name drawAtPoint:NSMakePoint(p.x - sz.width / 2, p.y - sz.height / 2) withAttributes:attrs];
        }
    }

    // Lines to contacts: from your station (the QSO's MY_GRIDSQUARE, else home) to the contact
    // (its LAT and LON, else its GRIDSQUARE, else its DXCC entity's centre), along great
    // circles; each pair once, coloured as the map colours.
    if (_style.paths) {
        std::map<size_t, size_t> entityOf, squareOf;  // QSO -> entity, QSO -> square
        for (size_t e = 0; e < _entities.size(); ++e)
            for (size_t qi : _entities[e].qsos) entityOf[qi] = e;
        for (size_t s = 0; s < _data.squares.size(); ++s)
            for (size_t qi : _data.squares[s].qsoIndex) squareOf.emplace(qi, s);
        std::set<std::tuple<long, long, long, long>> drawn;
        for (size_t qi = 0; qi < _data.qsos.size(); ++qi) {
            const adif::MapQso &q = _data.qsos[qi];
            double flat = _homeLat, flon = _homeLon, tlat = 0, tlon = 0;
            if (q.myGrid.size() >= 4 && !adif::isPlaceholderGrid(q.myGrid)) {
                if (!adif::gridToLatLon(q.myGrid, &flat, &flon)) continue;
            } else if (!_hasHome) {
                continue;
            }
            if (q.located) {
                tlat = q.lat, tlon = q.lon;
            } else if (adif::isPlaceholderGrid(q.grid) || !adif::gridToLatLon(q.grid, &tlat, &tlon)) {
                auto e = entityOf.find(qi);
                if (e == entityOf.end()) continue;
                tlat = _entities[e->second].lat, tlon = _entities[e->second].lon;
            }
            if (!drawn.insert({std::lround(flat * 100), std::lround(flon * 100), std::lround(tlat * 100), std::lround(tlon * 100)}).second) continue;
            ADIFMapAgg a;
            a.band = q.band, a.mode = q.modeGroup, a.confirmed = q.confirmed;
            a.year = q.date8.size() == 8 ? std::atoi(q.date8.substr(0, 4).c_str()) : 0;
            auto sq = squareOf.find(qi);
            a.count = sq != squareOf.end() ? _squareAgg[sq->second].count : 1;
            NSBezierPath *path = [self viewPath:adif::greatCirclePath(flat, flon, tlat, tlon, 3) close:NO wraps:YES];
            [self styleLine:path];
            [[[self colorFor:a entity:NO] colorWithAlphaComponent:0.5] setStroke];
            [path stroke];
        }
    }

    // Worked squares.
    if (_showSquares) {
        CGFloat alpha = _style.fill == 1 ? 0.45 : 0.85;
        for (size_t i = 0; i < _data.squares.size(); ++i) {
            NSBezierPath *cell = [self squarePath:_data.squares[i].grid];
            if (!cell || cell.isEmpty) continue;
            NSRect r = cell.bounds;
            if (!NSIntersectsRect(NSInsetRect(r, -2, -2), b)) continue;
            NSColor *c = [self colorFor:_squareAgg[i] entity:NO];
            if (r.size.width < 2) {  // the whole world: at least a dot
                [[c colorWithAlphaComponent:alpha] setFill];
                NSRectFill(NSMakeRect(NSMidX(r) - 1, NSMidY(r) - 1, 2, 2));
            } else if (_style.fill == 2) {
                cell.lineWidth = 1.5;
                [c setStroke];
                [cell stroke];
            } else {
                [[c colorWithAlphaComponent:alpha] setFill];
                [cell fill];
                if (pal.dark && darkColour(c)) {  // a dark square (60m's navy) needs an edge on a dark map
                    cell.lineWidth = 1;
                    [[NSColor colorWithCalibratedWhite:1 alpha:0.5] setStroke];
                    [cell stroke];
                }
            }
        }
    }

    // Field and square names, once there is room for them.
    if (_style.labels) {
        if (fieldW >= 44 && squareW < 36)
            for (int fx = 0; fx < 18; ++fx)
                for (int fy = 0; fy < 18; ++fy) {
                    double lon = -180 + fx * 20 + 10, lat = -90 + fy * 10 + 5;
                    if (lon + 10 < west || lon - 10 > east || lat + 5 < south || lat - 5 > north) continue;
                    NSPoint p = [self viewPointForLon:lon lat:lat];
                    double w = curved ? [self pixelsForLon:lon lat:lat span:20] : fieldW;
                    NSPoint top = [self viewPointForLon:lon lat:lat + 5], bottom = [self viewPointForLon:lon lat:lat - 5];
                    double tall = std::hypot(top.x - bottom.x, top.y - bottom.y);  // fields near Equal Earth's poles get thin
                    if (!NSPointInRect(p, NSInsetRect(b, -40, -20)) || w < 30 || tall < 16) continue;
                    [self drawLabel:[NSString stringWithFormat:@"%c%c", 'A' + fx, 'A' + fy] at:p size:std::min(16.0, w / 6) alpha:0.35];
                }
        if (squareW >= 36)
            for (double lon = std::floor(west / 2) * 2; lon < east; lon += 2)
                for (double lat = std::floor(south); lat < north; lat += 1) {
                    std::string sq = adif::squareAt(lon + 1, lat + 0.5);
                    NSPoint p = [self viewPointForLon:lon + 1 lat:lat + 0.5];
                    if (sq.empty() || !NSPointInRect(p, NSInsetRect(b, -30, -15))) continue;
                    [self drawLabel:@(sq.c_str()) at:p size:std::min(13.0, squareW / 6) alpha:0.32];
                }
    }

    // Distance rings around home (and bearings on the globe, when it is centred there).
    if (_style.rings && _hasHome) {
        double step = _zoom < 3 ? 2500 : _zoom < 8 ? 1000 : 500;
        NSBezierPath *rings = [NSBezierPath bezierPath];
        for (double km = step; km < 20000; km += step) {
            std::vector<std::pair<double, double>> ring;
            for (int a = 0; a <= 360; a += 2) {
                double la, lo;
                adif::destinationPoint(_homeLat, _homeLon, a, km, &la, &lo);
                ring.emplace_back(lo, la);
            }
            [rings appendBezierPath:[self viewPath:ring close:NO wraps:YES]];
            // The distance where the ring crosses north of home, beside the N spoke rather than on it.
            double la, lo, x, y;
            adif::destinationPoint(_homeLat, _homeLon, 0, km, &la, &lo);
            if (!_pr.forward(lo, la, &x, &y) || (globe && std::hypot(x, y) > 180 / M_PI - 30 / ppu)) continue;  // behind, or cut by the rim
            NSPoint p = [self planeToView:x y:y];
            if (NSPointInRect(p, b))
                [self drawLabel:[NSString stringWithFormat:@"%.0f km", km] at:NSMakePoint(p.x + 30, p.y + 7) size:10 alpha:0.55];
        }
        CGFloat dash[] = {4, 3};
        [rings setLineDash:dash count:2 phase:0];
        rings.lineWidth = 0.8;
        [[NSColor colorWithCalibratedWhite:ink alpha:0.35] setStroke];
        [rings stroke];
        if (globe && [self atHome]) {  // great circles through the centre are straight lines on the globe
            NSBezierPath *spokes = [NSBezierPath bezierPath];
            double rim = 180 / M_PI;
            for (int a = 0; a < 360; a += 30) {
                double s = std::sin(a * M_PI / 180), c = std::cos(a * M_PI / 180);
                [spokes moveToPoint:[self planeToView:0 y:0]];
                [spokes lineToPoint:[self planeToView:rim * s y:rim * c]];
                NSString *name = a == 0 ? @"N" : a == 90 ? @"E" : a == 180 ? @"S" : a == 270 ? @"W" : [NSString stringWithFormat:@"%d°", a];
                NSPoint p = [self planeToView:rim * 0.93 * s y:rim * 0.93 * c];
                if (NSPointInRect(p, b)) [self drawLabel:name at:p size:11 alpha:0.6];
            }
            spokes.lineWidth = 0.5;
            [[NSColor colorWithCalibratedWhite:ink alpha:0.22] setStroke];
            [spokes stroke];
        }
    }

    // DXCC dots.
    if (_showEntities)
        for (size_t i = 0; i < _entities.size(); ++i) {
            const ADIFMapEntity &e = _entities[i];
            NSPoint p = [self viewPointForLon:e.lon lat:e.lat];
            if (!NSPointInRect(p, NSInsetRect(b, -10, -10))) continue;
            NSBezierPath *dot = [self marker:0 at:p size:[self dotRadius:e.qsos.size()]];
            [[self colorFor:_entityAgg[i] entity:YES] setFill];
            [dot fill];
            bool lit = (_hover.kind == ADIFMapHit::Dxcc && _hover.index == i) || (_selected.kind == ADIFMapHit::Dxcc && _selected.index == i);
            [[NSColor colorWithCalibratedWhite:ink alpha:lit ? 1 : 0.6] setStroke];
            dot.lineWidth = lit ? 2 : 1;
            [dot stroke];
        }

    // Contacts: a marker at each QSO's own place (LAT and LON, else a 6 or 8 character grid).
    if (_showContacts)
        for (size_t i = 0; i < _contacts.size(); ++i) {
            NSPoint p = [self viewPointForLon:_contacts[i].lon lat:_contacts[i].lat];
            if (!NSPointInRect(p, NSInsetRect(b, -12, -12))) continue;
            // In the map's colours, outlined dark so a marker shows on a square of its own colour.
            NSBezierPath *m = [self contactMarkerAt:p];
            NSColor *c = [self colorFor:_contactAgg[i] entity:NO];
            bool lit = (_hover.kind == ADIFMapHit::Contact && _hover.index == i) || (_selected.kind == ADIFMapHit::Contact && _selected.index == i);
            NSColor *edge = lit ? [NSColor colorWithCalibratedWhite:ink alpha:1]
                                : [NSColor colorWithCalibratedWhite:pal.dark && darkColour(c) ? 1 : 0 alpha:0.85];
            if (_style.contact == 2) {  // crosshairs: a dark halo under the coloured lines
                m.lineWidth = 3.2;
                [edge setStroke];
                [m stroke];
                m.lineWidth = lit ? 1.8 : 1.4;
                [c setStroke];
                [m stroke];
                continue;
            }
            [c setFill];
            [m fill];
            [edge setStroke];
            m.lineWidth = lit ? 1.6 : 1;
            [m stroke];
        }

    // Parks (triangles) and other programs' references (diamonds, a colour each).
    for (size_t i = 0; i < _data.parks.size(); ++i) {
        const adif::MapPark &pk = _data.parks[i];
        if (![self programShown:pk]) continue;
        double lat = 0, lon = 0;
        if (!adif::gridToLatLon(pk.grid, &lat, &lon)) continue;
        NSPoint p = [self viewPointForLon:lon lat:lat];
        if (!NSPointInRect(p, NSInsetRect(b, -10, -10))) continue;
        NSBezierPath *m = [self marker:pk.park() ? 1 : 2 at:p size:(pk.park() ? 5.5 : 5) * _style.marker];
        [(pk.park() ? rgb(pal.park) : [self programColor:pk.program]) setFill];
        [m fill];
        bool lit = (_hover.kind == ADIFMapHit::Park && _hover.index == i) || (_selected.kind == ADIFMapHit::Park && _selected.index == i);
        [[NSColor colorWithCalibratedWhite:ink alpha:lit ? 1 : 0.35] setStroke];
        m.lineWidth = lit ? 1.5 : 0.6;
        [m stroke];
    }

    // Your station: a star at each MY_GRIDSQUARE.
    if (_style.mine)
        for (const std::string &g : _data.mine) {
            double lat = 0, lon = 0;
            if (!adif::gridToLatLon(g, &lat, &lon)) continue;
            NSBezierPath *star = [self marker:3 at:[self viewPointForLon:lon lat:lat] size:7.5 * _style.marker];
            [rgb(pal.me) setFill];
            [star fill];
            [[NSColor colorWithCalibratedWhite:ink alpha:1] setStroke];
            [star stroke];
        }

    // The square under the pointer and the one chosen, outlined.
    for (const ADIFMapHit *h : {&_hover, &_selected}) {
        if (h->square.empty() || (h->kind != ADIFMapHit::Square && h->kind != ADIFMapHit::Empty)) continue;
        NSBezierPath *box = [self squarePath:h->square];
        if (!box || box.isEmpty || box.bounds.size.width < 3) continue;  // behind the globe, or too small to see
        box.lineWidth = h == &_selected ? 2 : 1;
        [[NSColor colorWithCalibratedWhite:ink alpha:h == &_selected ? 0.95 : 0.6] setStroke];
        [box stroke];
    }
    CGContextRestoreGState(ctx);
    if (_style.legend) [self drawLegend];
    CGContextRestoreGState(ctx);
}

// The key to the colours and markers, bottom left (in the PNG too).
- (void)drawLegend {
    const MapPalette &pal = paletteAt(_style.palette);
    struct Entry {
        int kind;  // 0 swatch, 1 dot, 2 triangle, 3 diamond, 4 star, 5 line, 6 contact marker, 7 heading, 8 plain text
        NSColor *color;
        std::string text;
    };
    std::vector<Entry> rows;
    if ([self globe]) {
        std::string centre = adif::squareAt(_pr.centerLon() >= 180 ? _pr.centerLon() - 360 : _pr.centerLon(), std::clamp(_pr.centerLat(), -89.999, 89.999));
        rows.push_back({8, nil, [self atHome] && _hasHome ? "Centre: " + centre + " (home)" : "Centre: " + centre + (_hasHome ? "; World goes home" : "")});
    }
    static const char *const kBy[] = {"Colour: confirmed or not", "Colour: band (the most QSOs)", "Colour: mode (the most QSOs)",
                                      "Colour: QSO count", "Colour: year first worked"};
    bool contacts = _showContacts && !_contacts.empty();
    if (_showSquares || _showEntities || contacts) {
        rows.push_back({7, nil, kBy[std::clamp(_style.colorBy, 0, 4)]});
        switch (_style.colorBy) {
            case 1:
                for (size_t i = 0; i < _bands.size() && i < 14; ++i) rows.push_back({0, [self bandColor:_bands[i]], _bands[i]});
                break;
            case 2:
                for (int m = 0; m < 3; ++m) rows.push_back({0, rgb(pal.qualitative[(size_t)m % pal.qualitative.size()]), kModeLabels[m]});
                break;
            case 3:
                for (int k = 0; k < 5; ++k) rows.push_back({0, ramp(k / 4.0, pal), kCountLabels[k]});
                break;
            case 4:
                if (_maxYear && _maxYear - _minYear <= 7)
                    for (int y = _minYear; y <= _maxYear; ++y)
                        rows.push_back({0, ramp(_maxYear > _minYear ? (double)(y - _minYear) / (_maxYear - _minYear) : 1, pal), std::to_string(y)});
                else if (_maxYear)
                    for (int k = 0; k < 5; ++k) {
                        int y = _minYear + (int)std::lround((_maxYear - _minYear) * k / 4.0);
                        rows.push_back({0, ramp(k / 4.0, pal), std::to_string(y)});
                    }
                break;
            default:
                if (_showSquares || contacts) rows.push_back({0, rgb(pal.confirmed), "confirmed"}), rows.push_back({0, rgb(pal.worked), "worked"});
                if (_showEntities) rows.push_back({1, rgb(pal.dxccConfirmed), "DXCC confirmed"}), rows.push_back({1, rgb(pal.dxccWorked), "DXCC worked"});
                break;
        }
    }
    std::set<std::string> programs;
    bool parks = false;
    for (const adif::MapPark &pk : _data.parks)
        if ([self programShown:pk]) pk.park() ? (void)(parks = true) : (void)programs.insert(pk.program);
    if (contacts || parks || !programs.empty()) rows.push_back({7, nil, "Markers"});
    if (contacts) rows.push_back({6, [NSColor colorWithCalibratedWhite:pal.dark ? 0.85 : 0.35 alpha:1], "contacts (exact place)"});
    if (parks) rows.push_back({2, rgb(pal.park), "parks (POTA, WWFF)"});
    for (const std::string &p : programs) rows.push_back({3, [self programColor:p], p});
    if (_style.mine && !_data.mine.empty()) rows.push_back({4, rgb(pal.me), "my station"});
    if (_style.paths) rows.push_back({5, [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:0.6], "lines to contacts"});
    if (rows.empty()) return;

    NSDictionary *text = @{NSFontAttributeName : [NSFont systemFontOfSize:11],
                           NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:0.9]};
    NSDictionary *head = @{NSFontAttributeName : [NSFont boldSystemFontOfSize:11],
                           NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:pal.dark ? 1 : 0 alpha:0.9]};
    CGFloat width = 0, lineH = 16;
    for (const Entry &e : rows) width = std::max(width, [ADIFString(e.text) sizeWithAttributes:e.kind == 7 ? head : text].width + (e.kind >= 7 ? 0 : 20));
    NSRect box = NSMakeRect(NSMinX(self.bounds) + 8, NSMinY(self.bounds) + 8, width + 16, rows.size() * lineH + 10);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:box xRadius:6 yRadius:6];
    [[NSColor colorWithCalibratedWhite:pal.dark ? 0 : 1 alpha:0.62] setFill];
    [bg fill];
    CGFloat y = NSMaxY(box) - 5 - lineH;
    for (const Entry &e : rows) {
        NSPoint at = NSMakePoint(NSMinX(box) + 8, y);
        if (e.kind >= 7) {
            [ADIFString(e.text) drawAtPoint:NSMakePoint(at.x, y + 1) withAttributes:e.kind == 7 ? head : text];
        } else {
            NSPoint c = NSMakePoint(at.x + 6, y + lineH / 2);
            NSBezierPath *m = nil;
            switch (e.kind) {
                case 0: m = [NSBezierPath bezierPathWithRect:NSMakeRect(c.x - 5, c.y - 5, 10, 10)]; break;
                case 1: m = [self marker:0 at:c size:4.5]; break;
                case 2: m = [self marker:1 at:c size:5]; break;
                case 3: m = [self marker:2 at:c size:5]; break;
                case 4: m = [self marker:3 at:c size:6]; break;
                case 6: m = [self contactMarkerAt:NSMakePoint(c.x, _style.contact == 0 ? c.y - 5 : c.y)]; break;
                case 5:
                    m = [NSBezierPath bezierPath];
                    [m moveToPoint:NSMakePoint(c.x - 6, c.y)];
                    [m lineToPoint:NSMakePoint(c.x + 6, c.y)];
                    [self styleLine:m];
                    break;
                default:
                    m = [NSBezierPath bezierPath];
                    [m moveToPoint:NSMakePoint(c.x - 6, c.y)];
                    [m lineToPoint:NSMakePoint(c.x + 6, c.y)];
                    break;
            }
            if (e.kind == 5 || (e.kind == 6 && _style.contact == 2)) {
                if (e.kind == 6) m.lineWidth = 1.5;
                [e.color setStroke];
                [m stroke];
            } else {
                [e.color setFill];
                [m fill];
            }
            [ADIFString(e.text) drawAtPoint:NSMakePoint(at.x + 18, y + 1) withAttributes:text];
        }
        y -= lineH;
    }
}

// ── Pointer and keys ──

- (ADIFMapHit)hitAt:(NSPoint)p {
    ADIFMapHit h;
    double lon, lat;
    if (![self lonLatAt:p lon:&lon lat:&lat]) return h;
    h.square = adif::squareAt(lon, lat);
    if (h.square.empty()) return h;
    for (size_t i = 0; i < _data.parks.size(); ++i) {
        if (![self programShown:_data.parks[i]]) continue;
        double plat, plon;
        if (!adif::gridToLatLon(_data.parks[i].grid, &plat, &plon)) continue;
        NSPoint q = [self viewPointForLon:plon lat:plat];
        if (std::hypot(q.x - p.x, q.y - p.y) <= 7 * _style.marker) return h.kind = ADIFMapHit::Park, h.index = i, h;
    }
    if (_showContacts)  // the pin's head, or the dot or crosshair
        for (size_t i = 0; i < _contacts.size(); ++i) {
            NSPoint q = [self viewPointForLon:_contacts[i].lon lat:_contacts[i].lat];
            if (_style.contact == 0) q.y += 2.2 * kPin * _style.marker;
            if (std::hypot(q.x - p.x, q.y - p.y) <= 5 * _style.marker + 1) return h.kind = ADIFMapHit::Contact, h.index = i, h;
        }
    if (_showEntities)
        for (size_t i = 0; i < _entities.size(); ++i) {
            NSPoint q = [self viewPointForLon:_entities[i].lon lat:_entities[i].lat];
            if (std::hypot(q.x - p.x, q.y - p.y) <= [self dotRadius:_entities[i].qsos.size()] + 2)
                return h.kind = ADIFMapHit::Dxcc, h.index = i, h;
        }
    if (_showSquares)
        for (size_t i = 0; i < _data.squares.size(); ++i)
            if (_data.squares[i].grid == h.square) return h.kind = ADIFMapHit::Square, h.index = i, h;
    h.kind = ADIFMapHit::Empty;
    return h;
}

- (void)mouseMoved:(NSEvent *)event {
    ADIFMapHit h = [self hitAt:[self convertPoint:event.locationInWindow fromView:nil]];
    bool changed = h.kind != _hover.kind || h.index != _hover.index || h.square != _hover.square;
    _hover = h;
    if (!changed) return;
    self.needsDisplay = YES;
    if (self.onHover) self.onHover(h);
}

- (void)mouseExited:(NSEvent *)event {
    _hover = ADIFMapHit();
    self.needsDisplay = YES;
    if (self.onHover) self.onHover(_hover);
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    _down = [self convertPoint:event.locationInWindow fromView:nil];
    _dragged = NO;
    if (event.clickCount == 2) [self zoomBy:2 at:_down];
}

- (void)mouseDragged:(NSEvent *)event {
    double ppu = [self ppu];
    _dragged = YES;
    [[NSCursor closedHandCursor] set];
    if ([self globe]) return [self rotateBy:event.deltaX / ppu y:-event.deltaY / ppu];  // the surface moves with the pointer
    _cx -= event.deltaX / ppu;
    _cy += event.deltaY / ppu;
    [self viewChanged];
}

- (void)mouseUp:(NSEvent *)event {
    [[NSCursor arrowCursor] set];
    if (_dragged || event.clickCount > 1) return;
    ADIFMapHit h = [self hitAt:[self convertPoint:event.locationInWindow fromView:nil]];
    _selected = h;
    self.needsDisplay = YES;
    if (self.onSelect) self.onSelect(h);
}

- (void)scrollWheel:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (event.hasPreciseScrollingDeltas && !(event.modifierFlags & NSEventModifierFlagOption)) {  // a trackpad: pan
        double ppu = [self ppu];
        if ([self globe]) return [self rotateBy:event.scrollingDeltaX / ppu y:-event.scrollingDeltaY / ppu];
        _cx -= event.scrollingDeltaX / ppu;
        _cy += event.scrollingDeltaY / ppu;
        [self viewChanged];
        return;
    }
    double dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 20 : event.scrollingDeltaY;
    if (dy != 0) [self zoomBy:std::pow(1.2, dy) at:p];
}

- (void)magnifyWithEvent:(NSEvent *)event {
    [self zoomBy:1 + event.magnification at:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)keyDown:(NSEvent *)event {
    NSString *c = event.charactersIgnoringModifiers;
    unichar k = c.length ? [c characterAtIndex:0] : 0;
    double step = 60 / [self ppu];
    if ([self globe] && (k == NSLeftArrowFunctionKey || k == NSRightArrowFunctionKey || k == NSUpArrowFunctionKey || k == NSDownArrowFunctionKey)) {
        // Look west, east, north or south: the surface moves the other way.
        [self rotateBy:k == NSLeftArrowFunctionKey ? step : k == NSRightArrowFunctionKey ? -step : 0
                     y:k == NSDownArrowFunctionKey ? step : k == NSUpArrowFunctionKey ? -step : 0];
        return;
    }
    if (k == '+' || k == '=') [self zoomBy:1.5];
    else if (k == '-') [self zoomBy:1 / 1.5];
    else if (k == '0') [self showWorld];
    else if (k == NSLeftArrowFunctionKey) _cx -= step, [self viewChanged];
    else if (k == NSRightArrowFunctionKey) _cx += step, [self viewChanged];
    else if (k == NSUpArrowFunctionKey) _cy += step, [self viewChanged];
    else if (k == NSDownArrowFunctionKey) _cy -= step, [self viewChanged];
    else [super keyDown:event];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self clampCenter];
}

@end

// The QSOs of what was clicked: a small table; double-click goes to the record.
@interface ADIFMapList : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, copy) void (^onActivate)(NSInteger row);
@property(nonatomic) std::vector<std::vector<std::string>> rows;
@end

@implementation ADIFMapList
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    return (NSInteger)_rows.size();
}
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSTextField *f = [t makeViewWithIdentifier:@"map.cell" owner:self];
    if (!f) {
        f = [NSTextField labelWithString:@""];
        f.identifier = @"map.cell";
        f.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        f.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    size_t c = (size_t)col.identifier.integerValue;
    f.stringValue = row >= 0 && (size_t)row < _rows.size() && c < _rows[(size_t)row].size() ? ADIFString(_rows[(size_t)row][c]) : @"";
    return f;
}
- (void)activated:(id)sender {
    NSTableView *t = sender;
    if (self.onActivate && t.clickedRow >= 0) self.onActivate(t.clickedRow);
}
@end

namespace worldmap {
namespace {

struct {
    NSPanel *window = nil;
    ADIFMapView *view = nil;
    ADIFMapList *list = nil;
    NSTableView *table = nil;
    NSButton *squares = nil, *grid = nil, *labels = nil, *entities = nil, *contacts = nil, *parks = nil, *mine = nil;
    NSButton *cqZones = nil, *ituZones = nil, *states = nil, *countries = nil;
    NSPopUpButton *programs = nil, *style = nil, *projection = nil, *colorBy = nil, *region = nil;
    NSPopUpButton *band = nil, *mode = nil, *dates = nil, *confirmed = nil;
    NSTextField *target = nil, *status = nil, *zoomLabel = nil;
    adif::MapData data;
    std::vector<ADIFMapEntity> dxcc;
    std::vector<size_t> listed;   // the table's rows: indexes into data.qsos
    std::string summary, chosen;  // what the status line says when nothing is under the pointer
    std::string home;             // the grid the globe, rings and paths start from
    intptr_t buffer = 0;
} mw;

// Saved choices, in ADIFLint.ini.
bool flag(const char *key, bool fallback) {
    std::string v = setting(key);
    return v.empty() ? fallback : v == "1";
}
int number(const char *key, int fallback, int max) {
    std::string v = setting(key);
    int n = v.empty() ? fallback : std::atoi(v.c_str());
    return std::clamp(n, 0, max);
}
void saveFlag(const char *key, bool on) { setSetting(key, on ? "1" : "0"); }

std::set<std::string> hiddenPrograms() {
    std::string v = setting("mapHiddenPrograms");
    if (v.empty() && setting("mapHiddenProgramsSet").empty()) return {"IOTA"};  // callbooks fill IOTA in for every island station
    std::set<std::string> out;
    for (size_t b = 0; b < v.size();) {
        size_t e = v.find(',', b);
        if (e == std::string::npos) e = v.size();
        if (e > b) out.insert(v.substr(b, e - b));
        b = e + 1;
    }
    return out;
}

void saveHidden(const std::set<std::string> &hidden) {
    std::string v;
    for (const std::string &p : hidden) v += (v.empty() ? "" : ",") + p;
    setSetting("mapHiddenPrograms", v);
    setSetting("mapHiddenProgramsSet", "1");
}

ADIFMapStyle savedStyle() {
    ADIFMapStyle s;
    static const double kSizes[] = {0.75, 1.0, 1.4, 1.9};
    s.colorBy = number("mapColorBy", 0, 4);
    s.palette = number("mapPalette", 0, 3);
    s.shape = number("mapMarkerShape", 0, 2);
    s.fill = number("mapSquareFill", 0, 2);
    s.marker = kSizes[number("mapMarkerSize", 1, 3)];
    s.contact = number("mapContactMarker", 0, 2);
    s.grid = flag("mapGrid", true);
    s.cqZones = flag("mapCqZones", false);
    s.ituZones = flag("mapItuZones", false);
    s.states = flag("mapUsStates", false);
    s.countries = flag("mapCountries", false);
    s.labels = flag("mapLabels", true);
    s.legend = flag("mapLegend", true);
    s.rings = flag("mapRings", false);
    s.paths = flag("mapPaths", false);
    s.lineStyle = number("mapLineStyle", 0, 2);
    s.lineWidth = number("mapLineWidth", 1, 2);
    s.mine = flag("mapMine", true);
    return s;
}

void setStatus(const std::string &text) { mw.status.stringValue = ADIFString(text); }

std::string callsOf(const std::vector<size_t> &qsos) {
    std::vector<std::string> calls;
    for (size_t i : qsos)
        if (i < mw.data.qsos.size() && std::find(calls.begin(), calls.end(), mw.data.qsos[i].call) == calls.end()) calls.push_back(mw.data.qsos[i].call);
    std::string out;
    for (size_t k = 0; k < calls.size() && k < 5; ++k) out += (out.empty() ? "" : ", ") + calls[k];
    if (calls.size() > 5) out += ", +" + std::to_string(calls.size() - 5);
    return out;
}

std::string describe(const ADIFMapHit &h) {
    std::string where;
    if (!mw.home.empty() && !h.square.empty()) {
        std::string d = adif::gridDistanceText(mw.home, h.square);
        if (!d.empty()) where = " " + d + " from " + mw.home + ".";
    }
    switch (h.kind) {
        case ADIFMapHit::Square: {
            const adif::MapSquare &sq = mw.data.squares[h.index];
            return sq.grid + ": " + plural(sq.qsos, "QSO") + (sq.confirmed ? ", confirmed" : "") + " (" + callsOf(sq.qsoIndex) + ")." + where;
        }
        case ADIFMapHit::Dxcc: {
            const ADIFMapEntity &e = mw.dxcc[h.index];
            return e.name + " (DXCC " + std::to_string(e.dxcc) + "): " + plural(e.qsos.size(), "QSO") + (e.confirmed ? ", confirmed" : "") + " (" +
                   callsOf(e.qsos) + ")";
        }
        case ADIFMapHit::Park: {
            const adif::MapPark &p = mw.data.parks[h.index];
            size_t n = 0;
            for (const adif::MapPark &o : mw.data.parks) n += o.reference == p.reference && o.program == p.program;
            const adif::MapQso &q = mw.data.qsos[p.qso];
            return p.program + " " + p.reference + ": " + plural(n, "QSO") + ", in " + p.grid + " (" + q.call + " " + q.date + ")";
        }
        case ADIFMapHit::Contact: {
            const ADIFMapContact &c = mw.view.contacts[h.index];
            const adif::MapQso &q = mw.data.qsos[c.qsos[0]];
            char at[64];
            snprintf(at, sizeof at, "%.4f %c, %.4f %c", std::fabs(c.lat), c.lat < 0 ? 'S' : 'N', std::fabs(c.lon), c.lon < 0 ? 'W' : 'E');
            std::string from;
            double hlat, hlon;
            if (!mw.home.empty() && adif::gridToLatLon(mw.home, &hlat, &hlon)) {
                char d[96];
                snprintf(d, sizeof d, " %ld km at %.0f° from %s.", std::lround(adif::greatCircleKm(hlat, hlon, c.lat, c.lon)),
                         adif::initialBearing(hlat, hlon, c.lat, c.lon), mw.home.c_str());
                from = d;
            }
            return callsOf(c.qsos) + ": " + plural(c.qsos.size(), "QSO") + " at " + at + " (from " + q.locatedBy + ")." + from;
        }
        case ADIFMapHit::Empty: return h.square + ": no QSOs." + where;
        case ADIFMapHit::None: break;
    }
    return "";
}

void showList(const std::vector<size_t> &qsos) {
    mw.listed = qsos;
    std::vector<std::vector<std::string>> rows;
    for (size_t i : qsos) {
        if (i >= mw.data.qsos.size()) continue;
        const adif::MapQso &q = mw.data.qsos[i];
        rows.push_back({std::to_string(q.record), q.call, q.date, q.time, q.band, q.mode, q.grid, q.confirmed ? "yes" : ""});
    }
    mw.list.rows = rows;
    [mw.table reloadData];
}

void selected(const ADIFMapHit &h) {
    std::vector<size_t> qsos;
    if (h.kind == ADIFMapHit::Square) qsos = mw.data.squares[h.index].qsoIndex;
    else if (h.kind == ADIFMapHit::Dxcc) qsos = mw.dxcc[h.index].qsos;
    else if (h.kind == ADIFMapHit::Contact) qsos = mw.view.contacts[h.index].qsos;
    else if (h.kind == ADIFMapHit::Park)
        for (const adif::MapPark &p : mw.data.parks)
            if (p.reference == mw.data.parks[h.index].reference && p.program == mw.data.parks[h.index].program) qsos.push_back(p.qso);
    showList(qsos);
    mw.chosen = h.kind == ADIFMapHit::None ? "" : describe(h) + (qsos.empty() ? "" : " Double-click a QSO to go to it in the log.");
    setStatus(mw.chosen.empty() ? mw.summary : mw.chosen);
}

void updateZoomLabel() {
    double z = mw.view.zoom;
    mw.zoomLabel.stringValue = z < 10 ? [NSString stringWithFormat:@"%.1f×", z] : [NSString stringWithFormat:@"%.0f×", z];
}

// The map's projection; the globe is centred on home, else on the log's squares.
void applyProjection() {
    double lat = 0, lon = 0;
    bool home = !mw.home.empty() && adif::gridToLatLon(mw.home, &lat, &lon);
    int p = number("mapProjection", 0, 3);
    static const adif::Projection kinds[] = {adif::Projection::Equirectangular, adif::Projection::Mercator, adif::Projection::EqualEarth,
                                             adif::Projection::Globe};
    double clat = lat, clon = lon;
    if (!home) {  // the middle of the squares worked (the mean of their directions from the Earth's centre)
        double x = 0, y = 0, z = 0;
        for (const adif::MapSquare &sq : mw.data.squares) {
            double a, o;
            if (!adif::gridToLatLon(sq.grid, &a, &o)) continue;
            a *= M_PI / 180, o *= M_PI / 180;
            x += std::cos(a) * std::cos(o), y += std::cos(a) * std::sin(o), z += std::sin(a);
        }
        if (std::hypot(x, y, z) > 1e-9) clat = std::atan2(z, std::hypot(x, y)) * 180 / M_PI, clon = std::atan2(y, x) * 180 / M_PI;
        else clat = 20, clon = 0;
    }
    adif::Projector pr(kinds[p], clat, clon);
    [mw.view setProjector:pr home:home ? ADIFString(mw.home) : @"" lat:lat lon:lon];
    [mw.projection itemAtIndex:3].title = home ? [NSString stringWithFormat:@"Globe from %@", ADIFString(mw.home)] : @"Globe";
    [mw.projection selectItemAtIndex:p];
}

void applyStyle() {
    mw.view.style = savedStyle();
    mw.view.hiddenPrograms = hiddenPrograms();
}

NSImage *swatch(NSColor *color, bool diamond) {
    return [NSImage imageWithSize:NSMakeSize(12, 12)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect r) {
                       NSBezierPath *p = [NSBezierPath bezierPath];
                       if (diamond) {
                           [p moveToPoint:NSMakePoint(6, 11)];
                           [p lineToPoint:NSMakePoint(1, 6)];
                           [p lineToPoint:NSMakePoint(6, 1)];
                           [p lineToPoint:NSMakePoint(11, 6)];
                           [p closePath];
                       } else {
                           p = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 1, 1)];
                       }
                       [color setFill];
                       [p fill];
                       return YES;
                   }];
}

NSMenuItem *menuItem(NSMenu *menu, NSString *title, bool on, void (^action)(void)) {
    NSMenuItem *i = [menu addItemWithTitle:title action:nil keyEquivalent:@""];
    i.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    if (action) ADIFBlockMenuItem(i, action);
    else i.enabled = NO;
    return i;
}

void refresh();
void fillPrograms();
void fillStyle();

// The Other programs list: the common programs, then any other SIG in the log, each with its count.
void fillPrograms() {
    NSMenu *menu = mw.programs.menu;
    menu.autoenablesItems = NO;
    [menu removeAllItems];
    [menu addItemWithTitle:@"Other programs" action:nil keyEquivalent:@""];  // the pull-down's own title
    std::map<std::string, std::set<std::string>> refs;
    for (const adif::MapPark &p : mw.data.parks)
        if (!p.park()) refs[p.program].insert(p.reference);
    std::vector<std::pair<std::string, std::string>> list;  // key, label
    for (size_t i = 0; i < kProgramCount; ++i) list.emplace_back(kPrograms[i].key, kPrograms[i].label);
    for (const auto &kv : refs) {
        bool known = false;
        for (size_t i = 0; i < kProgramCount; ++i) known |= kv.first == kPrograms[i].key;
        if (!known) list.emplace_back(kv.first, kv.first);
    }
    std::set<std::string> hidden = hiddenPrograms();
    menuItem(menu, @"Show All", false, ^{
        saveHidden({});
        applyStyle();
        fillPrograms();
    });
    menuItem(menu, @"Hide All", false, ^{
        std::set<std::string> all;
        for (size_t i = 0; i < kProgramCount; ++i) all.insert(kPrograms[i].key);
        for (const adif::MapPark &p : mw.data.parks)
            if (!p.park()) all.insert(p.program);
        saveHidden(all);
        applyStyle();
        fillPrograms();
    });
    [menu addItem:[NSMenuItem separatorItem]];
    for (const auto &[key, label] : list) {
        size_t n = refs.count(key) ? refs[key].size() : 0;
        NSString *title = n ? [NSString stringWithFormat:@"%@: %zu", ADIFString(label), n]
                            : [NSString stringWithFormat:@"%@: none in this log", ADIFString(label)];
        std::string k = key;
        NSMenuItem *item = menuItem(menu, title, !hidden.count(key), ^{
            std::set<std::string> h = hiddenPrograms();
            if (!h.erase(k)) h.insert(k);
            saveHidden(h);
            applyStyle();
            fillPrograms();
        });
        item.image = swatch([mw.view programColor:key], true);
    }
}

// Options: palette, marker size and shape, contact markers, square fill, lines to contacts,
// legend, distance rings.
void fillStyle() {
    NSMenu *menu = mw.style.menu;
    menu.autoenablesItems = NO;
    [menu removeAllItems];
    [menu addItemWithTitle:@"Options" action:nil keyEquivalent:@""];
    ADIFMapStyle s = savedStyle();
    auto choose = [](const char *key, int value) {
        return ^{
            setSetting(key, std::to_string(value));
            applyStyle();
            fillStyle();
            fillPrograms();  // program swatches follow the palette
        };
    };
    auto toggle = [](const char *key, bool now) {
        return ^{
            saveFlag(key, !now);
            applyStyle();
            fillStyle();
        };
    };
    menuItem(menu, @"Colours", false, nil);
    NSArray *palettes = @[ @"Standard", @"Colour-blind safe", @"High contrast", @"Light (for printing)" ];
    for (NSInteger i = 0; i < 4; ++i) menuItem(menu, palettes[(NSUInteger)i], s.palette == i, choose("mapPalette", (int)i)).indentationLevel = 1;
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Marker size", false, nil);
    NSArray *sizes = @[ @"Small", @"Medium", @"Large", @"Extra large" ];
    int size = number("mapMarkerSize", 1, 3);
    for (NSInteger i = 0; i < 4; ++i) menuItem(menu, sizes[(NSUInteger)i], size == i, choose("mapMarkerSize", (int)i)).indentationLevel = 1;
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Markers", false, nil);
    NSArray *shapes = @[ @"By layer: dots, triangles, diamonds", @"All circles", @"All squares" ];
    for (NSInteger i = 0; i < 3; ++i) menuItem(menu, shapes[(NSUInteger)i], s.shape == i, choose("mapMarkerShape", (int)i)).indentationLevel = 1;
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Contacts", false, nil);
    NSArray *contactShapes = @[ @"Pins", @"Dots", @"Crosshairs" ];
    for (NSInteger i = 0; i < 3; ++i)
        menuItem(menu, contactShapes[(NSUInteger)i], s.contact == i, choose("mapContactMarker", (int)i)).indentationLevel = 1;
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Worked squares", false, nil);
    NSArray *fills = @[ @"Solid", @"See-through", @"Outline" ];
    for (NSInteger i = 0; i < 3; ++i) menuItem(menu, fills[(NSUInteger)i], s.fill == i, choose("mapSquareFill", (int)i)).indentationLevel = 1;
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Lines to contacts", s.paths, toggle("mapPaths", s.paths)).toolTip =
        @"Great-circle lines from your station (each QSO's MY_GRIDSQUARE, else home) to each contact (its LAT and LON, else its grid, else "
        @"its DXCC entity), coloured as the map colours";
    NSArray *lineStyles = @[ @"Solid line", @"Dashed line", @"Dotted line" ];
    for (NSInteger i = 0; i < 3; ++i) {
        NSMenuItem *item = menuItem(menu, lineStyles[(NSUInteger)i], s.lineStyle == i, choose("mapLineStyle", (int)i));
        item.indentationLevel = 1;
        item.enabled = s.paths;
    }
    NSArray *lineWidths = @[ @"Thin line", @"Medium line", @"Thick line" ];
    for (NSInteger i = 0; i < 3; ++i) {
        NSMenuItem *item = menuItem(menu, lineWidths[(NSUInteger)i], s.lineWidth == i, choose("mapLineWidth", (int)i));
        item.indentationLevel = 1;
        item.enabled = s.paths;
    }
    [menu addItem:[NSMenuItem separatorItem]];
    menuItem(menu, @"Legend", s.legend, toggle("mapLegend", s.legend));
    menuItem(menu, @"Distance rings from my grid", s.rings, toggle("mapRings", s.rings)).enabled = !mw.home.empty();
}

// Home: Settings → Your Station's grid, else the log's most used MY_GRIDSQUARE.
std::string homeGrid() {
    std::string g = setting("stationGrid");
    double lat, lon;
    if (!g.empty() && adif::gridToLatLon(g, &lat, &lon)) return g;
    std::map<std::string, size_t> n;
    for (const adif::MapQso &q : mw.data.qsos)
        if (q.myGrid.size() >= 4 && !adif::isPlaceholderGrid(q.myGrid)) ++n[q.myGrid];
    size_t most = 0;
    for (const auto &kv : n)
        if (kv.second > most) most = kv.second, g = kv.first;
    return most ? g : "";
}

void refresh() {
    if (!mw.window) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        mw.buffer = buffer();
        mw.target.stringValue = [@"Log: " stringByAppendingString:ADIFString(documentName())];
        // The bands, modes and years in the log, for the filters.
        std::set<std::string> bands, modes, years;
        std::map<std::string, size_t> qsosPerBand;
        for (const adif::Record &rec : adif::records(text, r.model)) {
            if (std::string b = adif::effectiveBand(rec); !b.empty()) bands.insert(b), ++qsosPerBand[b];
            if (std::string m = rec.get("MODE"); !m.empty()) modes.insert(m);
            if (std::string d = rec.get("QSO_DATE"); d.size() == 8) years.insert(d.substr(0, 4));
        }
        auto fill = [](NSPopUpButton *p, NSArray<NSString *> *first, const std::vector<std::string> &items) {
            NSString *keep = p.indexOfSelectedItem > 0 ? p.titleOfSelectedItem : nil;
            [p removeAllItems];
            [p addItemsWithTitles:first];
            for (const std::string &i : items) [p addItemWithTitle:ADIFString(i)];
            if (keep && [p itemWithTitle:keep]) [p selectItemWithTitle:keep];
        };
        fill(mw.band, @[ @"All bands" ], std::vector<std::string>(bands.begin(), bands.end()));
        fill(mw.mode, @[ @"All modes" ], std::vector<std::string>(modes.begin(), modes.end()));
        fill(mw.dates, @[ @"All dates", @"Last 30 days", @"Last 12 months", @"This year" ], std::vector<std::string>(years.rbegin(), years.rend()));
        adif::MapFilter f;
        f.band = mw.band.indexOfSelectedItem > 0 ? ADIFStd(mw.band.titleOfSelectedItem) : "";
        f.mode = mw.mode.indexOfSelectedItem > 0 ? ADIFStd(mw.mode.titleOfSelectedItem) : "";
        f.confirmed = (int)std::clamp<NSInteger>(mw.confirmed.indexOfSelectedItem, 0, 2);
        std::string today = utcNow("%Y%m%d");
        auto daysAgo = [](int days) {
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"yyyyMMdd";
            df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            return ADIFStd([df stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-86400.0 * days]]);
        };
        switch (mw.dates.indexOfSelectedItem) {
            case 1: f.from = daysAgo(30); break;
            case 2: f.from = daysAgo(365); break;
            case 3: f.from = today.substr(0, 4) + "0101"; break;
            default:
                if (mw.dates.indexOfSelectedItem > 3) {
                    std::string y = ADIFStd(mw.dates.titleOfSelectedItem);
                    f.from = y + "0101", f.to = y + "1231";
                }
                break;
        }
        mw.data = adif::mapData(text, r.model, f);
        // DXCC from the calls, by country data.
        std::map<int, ADIFMapEntity> byDxcc;
        const adif::CountryTable &countries = ADIFCountries();
        for (size_t i = 0; i < mw.data.qsos.size(); ++i) {
            adif::CountryInfo info;
            if (countries.empty() || !countries.lookup(mw.data.qsos[i].call, &info) || !info.dxcc) continue;
            ADIFMapEntity &e = byDxcc[info.dxcc];
            e.dxcc = info.dxcc, e.lat = info.lat, e.lon = info.lon, e.name = info.name;
            e.qsos.push_back(i);
            e.confirmed |= mw.data.qsos[i].confirmed;
        }
        mw.dxcc.clear();
        size_t confirmedDxcc = 0, confirmedSquares = 0;
        for (auto &kv : byDxcc) {
            confirmedDxcc += kv.second.confirmed;
            mw.dxcc.push_back(kv.second);
        }
        for (const adif::MapSquare &sq : mw.data.squares) confirmedSquares += sq.confirmed;
        mw.view.showSquares = mw.squares.state == NSControlStateValueOn;
        mw.view.showEntities = mw.entities.state == NSControlStateValueOn;
        mw.view.showParks = mw.parks.state == NSControlStateValueOn;
        mw.view.showContacts = mw.contacts.state == NSControlStateValueOn;
        mw.view.qsosPerBand = qsosPerBand;
        mw.home = homeGrid();
        applyStyle();
        applyProjection();
        [mw.view setData:mw.data entities:mw.dxcc];
        fillPrograms();
        fillStyle();
        showList({});
        size_t located = 0;
        for (const adif::MapQso &q : mw.data.qsos) located += q.located;
        std::set<std::string> parkRefs, otherRefs;
        for (const adif::MapPark &p : mw.data.parks) (p.park() ? parkRefs : otherRefs).insert(p.program + " " + p.reference);
        mw.summary = plural(mw.data.squares.size(), "grid square") + " (" + std::to_string(confirmedSquares) + " confirmed), " +
                     std::to_string(mw.dxcc.size()) + " DXCC (" + std::to_string(confirmedDxcc) + " confirmed), " +
                     plural(parkRefs.size(), "park") + " (POTA, WWFF) where the QSO has a grid, " + plural(otherRefs.size(), "other reference") +
                     " (IOTA, SOTA, GMA... under Other programs)" + (mw.home.empty() ? "" : "; home " + mw.home) + ". " +
                     (mw.data.withoutGrid ? plural(mw.data.withoutGrid, "QSO") + " without GRIDSQUARE " + (mw.data.withoutGrid == 1 ? "isn't" : "aren't") +
                                                " on the squares. "
                                          : "") +
                     plural(located, "QSO") + " with an exact place (Contacts" +
                     (mw.data.unusedLatLon ? "; " + std::to_string(mw.data.unusedLatLon) + " LAT/LON not used: a placeholder, or far from the QSO's grid" : "") +
                     "). "
                     "The legend shows the colours. Scroll or pinch to zoom, drag to move (on the globe, to turn it), "
                     "click a square, dot, pin or park for its QSOs.";
        mw.chosen.clear();
        setStatus(mw.summary);
    } catch (...) {
    }
}

void goToQso(NSInteger row) {
    if (row < 0 || (size_t)row >= mw.listed.size()) return;
    const adif::MapQso &q = mw.data.qsos[mw.listed[(size_t)row]];
    if (buffer() != mw.buffer) {
        setStatus("Switch back to the map's log to go to the record.");
        return;
    }
    NppHandle h = scintilla();
    const adif::LintResult &r = lint(h);
    if (q.group >= 0 && (size_t)q.group < r.model.groups.size()) goTo(h, adif::groupStart(r.model, r.model.groups[(size_t)q.group]), true);
}

void exportPng() {
    std::string base = documentName();
    if (size_t dot = base.rfind('.'); dot != std::string::npos) base.resize(dot);
    std::string path;
    if (const char *dir = getenv("ADIFLINT_TEST_SAVE_DIR")) {
        path = std::string(dir) + "/" + base + " map.png";
    } else {
        NSSavePanel *p = [NSSavePanel savePanel];
        p.nameFieldStringValue = ADIFString(base + " map.png");
        if (UTType *t = [UTType typeWithFilenameExtension:@"png"]) p.allowedContentTypes = @[ t ];
        if ([p runModal] != NSModalResponseOK || !p.URL) return;
        path = ADIFStd(p.URL.path);
    }
    // What the map shows now, legend included, at twice the screen's size.
    NSRect r = mw.view.bounds;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
                                                                    pixelsWide:(NSInteger)(r.size.width * 2)
                                                                    pixelsHigh:(NSInteger)(r.size.height * 2)
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    rep.size = r.size;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [mw.view drawRect:r];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:ADIFString(path) atomically:YES]) {
        setStatus("Could not save the map.");
        return;
    }
    setStatus("Saved " + ADIFStd(ADIFString(path).lastPathComponent) + ". " + mw.summary);
}

NSButton *smallButton(NSString *title, NSString *tip, void (^action)(void)) {
    NSButton *b = [NSButton buttonWithTitle:title target:nil action:nil];
    b.toolTip = tip;
    ADIFOnAction(b, action);
    return b;
}

NSPopUpButton *pullDown(NSString *title, NSString *tip) {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [p addItemWithTitle:title];
    p.toolTip = tip;
    return p;
}

}  // namespace

void cmdMap() {
    if (!mw.window) {
        mw.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 820)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                         NSWindowStyleMaskUtilityWindow
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
        mw.window.title = @"Map";
        mw.window.releasedWhenClosed = NO;
        mw.window.hidesOnDeactivate = NO;
        mw.window.contentMinSize = NSMakeSize(920, 620);
        NSView *root = mw.window.contentView;
        mw.target = ADIFLabel(@"");
        // Row 1: what to show.
        mw.squares = ADIFCheckbox(@"Worked squares", flag("mapSquares", true));
        mw.grid = ADIFCheckbox(@"Maidenhead grid", flag("mapGrid", true));
        mw.grid.toolTip = @"The grid's fields (20 x 10 degrees), and its squares (2 x 1) when zoomed in";
        mw.labels = ADIFCheckbox(@"Labels", flag("mapLabels", true));
        mw.labels.toolTip = @"Field names (FN, EM...), and square names (FN31) when zoomed in";
        mw.cqZones = ADIFCheckbox(@"CQ zones", flag("mapCqZones", false));
        mw.ituZones = ADIFCheckbox(@"ITU zones", flag("mapItuZones", false));
        mw.states = ADIFCheckbox(@"US states", flag("mapUsStates", false));
        mw.states.toolTip = @"State lines and postal codes (Natural Earth, public domain)";
        mw.countries = ADIFCheckbox(@"Countries", flag("mapCountries", false));
        mw.countries.toolTip = @"Every country outlined, coasts and borders, with its name where it fits (Natural Earth, public domain)";
        mw.cqZones.toolTip = @"CQ zones 1-40 with their numbers (HB9HIL's hamradio-zones-geojson, MIT); approximate";
        mw.ituZones.toolTip = @"ITU zones 1-90 with their numbers (HB9HIL's hamradio-zones-geojson, MIT); approximate";
        mw.entities = ADIFCheckbox(@"DXCC", flag("mapDxcc", true));
        mw.contacts = ADIFCheckbox(@"Contacts", flag("mapContacts", false));
        mw.contacts.toolTip = @"A marker at each contact's own place: its LAT and LON, else a GRIDSQUARE of 6 or 8 characters (a 4-character "
                              @"square is 100 km or more across: Worked squares shows those). Style chooses pins, dots or crosshairs";
        mw.parks = ADIFCheckbox(@"Parks", flag("mapParks", true));
        mw.parks.toolTip = @"POTA and WWFF parks you hunted, where the QSO has a grid";
        mw.programs = pullDown(@"Other programs", @"Other programs' references, a colour each: SOTA summits, IOTA islands, GMA, bunkers, "
                                                  @"castles... (IOTA starts hidden: callbooks fill it in for every island station)");
        mw.mine = ADIFCheckbox(@"My station", flag("mapMine", true));
        mw.mine.toolTip = @"A star at each MY_GRIDSQUARE in the log";
        // Row 2: which QSOs, and how to colour them.
        mw.band = ADIFPopup(@[ @"All bands" ]);
        mw.mode = ADIFPopup(@[ @"All modes" ]);
        mw.dates = ADIFPopup(@[ @"All dates", @"Last 30 days", @"Last 12 months", @"This year" ]);
        mw.confirmed = ADIFPopup(@[ @"All QSOs", @"Confirmed", @"Not confirmed" ]);
        mw.colorBy = ADIFPopup(@[ @"Colour by confirmation", @"Colour by band", @"Colour by mode", @"Colour by QSO count",
                                  @"Colour by year first worked" ]);
        [mw.colorBy selectItemAtIndex:number("mapColorBy", 0, 4)];
        // Row 3: zoom, projection, style.
        mw.projection = ADIFPopup(@[ @"Equirectangular", @"Mercator", @"Equal Earth", @"Globe" ]);
        mw.projection.autoenablesItems = NO;
        mw.projection.toolTip = @"Equirectangular: the grid as rectangles. Mercator: familiar shapes. Equal Earth: true sizes. Globe: the Earth "
                                @"as seen from space, centred on your grid; drag (or the arrow keys) to turn it any way, zoom in for detail, "
                                @"World to come home. Bearings from the centre are true (beam headings)";
        mw.style = pullDown(@"Options", @"Colours, marker size and shape, contact markers, how worked squares are filled, lines to contacts "
                                        @"and their style, the legend, distance rings");
        mw.region = pullDown(@"Region", @"Zoom to a continent (on the globe, turn to face it)");
        {
            // Continents as ADIF's CONT names them, each a box of longitude and latitude to show.
            struct Box {
                NSString *name;
                double w, s, e, n;
            };
            static const Box kRegions[] = {{@"Africa", -20, -36, 53, 38},           {@"Antarctica", -180, -90, 180, -60},
                                           {@"Asia", 25, -11, 180, 78},             {@"Europe", -25, 34, 45, 72},
                                           {@"North America", -170, 5, -50, 75},    {@"Oceania", 110, -48, 180, 0},
                                           {@"South America", -82, -56, -34, 13}};
            for (const Box &b : kRegions) {
                NSMenuItem *item = [mw.region.menu addItemWithTitle:b.name action:nil keyEquivalent:@""];
                Box box = b;
                ADIFBlockMenuItem(item, ^{ [mw.view showWest:box.w south:box.s east:box.e north:box.n]; });
            }
        }
        for (NSControl *c in @[ mw.squares, mw.entities, mw.contacts, mw.parks, mw.band, mw.mode, mw.dates, mw.confirmed ]) ADIFOnAction(c, ^{
            saveFlag("mapSquares", mw.squares.state == NSControlStateValueOn);
            saveFlag("mapDxcc", mw.entities.state == NSControlStateValueOn);
            saveFlag("mapContacts", mw.contacts.state == NSControlStateValueOn);
            saveFlag("mapParks", mw.parks.state == NSControlStateValueOn);
            refresh();
        });
        for (NSButton *b in @[ mw.grid, mw.labels, mw.mine, mw.cqZones, mw.ituZones, mw.states, mw.countries ]) ADIFOnAction(b, ^{
            saveFlag("mapGrid", mw.grid.state == NSControlStateValueOn);
            saveFlag("mapLabels", mw.labels.state == NSControlStateValueOn);
            saveFlag("mapCqZones", mw.cqZones.state == NSControlStateValueOn);
            saveFlag("mapItuZones", mw.ituZones.state == NSControlStateValueOn);
            saveFlag("mapUsStates", mw.states.state == NSControlStateValueOn);
            saveFlag("mapCountries", mw.countries.state == NSControlStateValueOn);
            saveFlag("mapMine", mw.mine.state == NSControlStateValueOn);
            applyStyle();
            fillStyle();
        });
        ADIFOnAction(mw.colorBy, ^{
            setSetting("mapColorBy", std::to_string(mw.colorBy.indexOfSelectedItem));
            applyStyle();
        });
        ADIFOnAction(mw.projection, ^{
            setSetting("mapProjection", std::to_string(mw.projection.indexOfSelectedItem));
            applyProjection();
        });
        mw.zoomLabel = ADIFLabel(@"1.0×");
        [mw.zoomLabel.widthAnchor constraintEqualToConstant:40].active = YES;
        NSButton *out = smallButton(@"−", @"Zoom out (−)", ^{ [mw.view zoomBy:1 / 1.5]; });
        NSButton *in = smallButton(@"+", @"Zoom in (+, or double-click the map)", ^{ [mw.view zoomBy:1.5]; });
        NSButton *fit = smallButton(@"Fit Log", @"Zoom to the log's QSOs", ^{ [mw.view fitLog]; });
        NSButton *world = smallButton(@"World", @"The whole world (0)", ^{ [mw.view showWorld]; });
        NSButton *save = smallButton(@"Export PNG...", @"Save the map as it is shown now, with its legend", ^{ exportPng(); });
        NSStackView *row = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Show:"), mw.squares, mw.entities, mw.contacts, mw.parks, mw.programs, mw.mine ]];
        row.spacing = 10;
        NSStackView *row2 = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Only:"), mw.band, mw.mode, mw.dates, mw.confirmed, mw.colorBy ]];
        row2.spacing = 8;
        [row2 setCustomSpacing:24 afterView:mw.confirmed];
        NSStackView *overlays =
            [NSStackView stackViewWithViews:@[ ADIFLabel(@"Overlays:"), mw.grid, mw.labels, mw.countries, mw.states, mw.cqZones, mw.ituZones ]];
        overlays.spacing = 10;
        NSStackView *row3 = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Zoom:"), out, mw.zoomLabel, in, fit, world, mw.region, mw.projection, mw.style, save ]];
        row3.spacing = 8;
        [row3 setCustomSpacing:24 afterView:world];
        mw.view = [[ADIFMapView alloc] initWithFrame:NSZeroRect];
        mw.view.onHover = ^(const ADIFMapHit &h) {
            std::string d = describe(h);
            setStatus(!d.empty() ? d : !mw.chosen.empty() ? mw.chosen : mw.summary);
        };
        mw.view.onSelect = ^(const ADIFMapHit &h) { selected(h); };
        mw.view.onViewChanged = ^{ updateZoomLabel(); };
        mw.list = [[ADIFMapList alloc] init];
        mw.list.onActivate = ^(NSInteger rowIndex) { goToQso(rowIndex); };
        mw.table = [[NSTableView alloc] initWithFrame:NSZeroRect];
        const char *titles[] = {"Record", "Call", "Date", "UTC", "Band", "Mode", "Grid", "Confirmed"};
        const CGFloat widths[] = {60, 100, 90, 60, 60, 70, 80, 80};
        for (size_t i = 0; i < 8; ++i) {
            NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:[NSString stringWithFormat:@"%zu", i]];
            c.title = @(titles[i]);
            c.width = widths[i];
            [mw.table addTableColumn:c];
        }
        mw.table.dataSource = mw.list;
        mw.table.delegate = mw.list;
        mw.table.target = mw.list;
        mw.table.doubleAction = @selector(activated:);
        mw.table.usesAlternatingRowBackgroundColors = YES;
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        scroll.documentView = mw.table;
        scroll.hasVerticalScroller = YES;
        scroll.borderType = NSBezelBorder;
        mw.status = [NSTextField wrappingLabelWithString:@""];
        mw.status.maximumNumberOfLines = 3;
        mw.status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        for (NSView *v in @[ mw.target, row, overlays, row2, row3, mw.view, scroll, mw.status ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [root addSubview:v];
        }
        CGFloat m = 14;
        [NSLayoutConstraint activateConstraints:@[
            [mw.target.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
            [mw.target.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [row.topAnchor constraintEqualToAnchor:mw.target.bottomAnchor constant:8],
            [row.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [row.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [overlays.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:6],
            [overlays.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [overlays.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [row2.topAnchor constraintEqualToAnchor:overlays.bottomAnchor constant:6],
            [row2.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [row2.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [row3.topAnchor constraintEqualToAnchor:row2.bottomAnchor constant:6],
            [row3.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [row3.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [mw.view.topAnchor constraintEqualToAnchor:row3.bottomAnchor constant:8],
            [mw.view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [mw.view.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [scroll.topAnchor constraintEqualToAnchor:mw.view.bottomAnchor constant:8],
            [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [scroll.heightAnchor constraintEqualToConstant:120],
            [mw.status.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:8],
            [mw.status.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [mw.status.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [mw.status.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-m],
            [mw.status.heightAnchor constraintGreaterThanOrEqualToConstant:30],
        ]];
        [mw.window center];
    }
    refresh();
    [mw.window makeKeyAndOrderFront:nil];
    [mw.window makeFirstResponder:mw.view];
}

void documentChanged() {
    if (mw.window && mw.window.visible) refresh();
}

}  // namespace worldmap
