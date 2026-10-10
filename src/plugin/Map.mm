#import "Map.h"

#import "Country.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "adif_geo.h"
#include "adif_world.h"

#include <cmath>
#include <map>
#include <set>

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
    enum Kind { None, Square, Dxcc, Park, Empty } kind = None;
    std::string square;  // the 4-character square under the point (always set on the map)
    size_t index = 0;    // into squares, entities or parks
};

namespace {

// A layer as a path in degrees, built once; rivers up to a rank (1 major ... 6).
CGPathRef layerPath(adif::MapLayer l, int maxRank = 99) {
    static std::map<std::pair<int, int>, CGPathRef> paths;
    CGPathRef &p = paths[{(int)l, maxRank}];
    if (!p) {
        bool polygons = l == adif::MapLayer::Land110 || l == adif::MapLayer::Land50 || l == adif::MapLayer::Lakes110 ||
                        l == adif::MapLayer::Lakes50;
        CGMutablePathRef m = CGPathCreateMutable();
        for (size_t i = 0; i < adif::layerShapeCount(l); ++i) {
            if (adif::layerShapeRank(l, i) > maxRank) continue;
            std::vector<std::pair<double, double>> pts = adif::layerShape(l, i);
            for (size_t k = 0; k < pts.size(); ++k) {
                if (k == 0) CGPathMoveToPoint(m, nullptr, pts[k].first, pts[k].second);
                else CGPathAddLineToPoint(m, nullptr, pts[k].first, pts[k].second);
            }
            if (polygons) CGPathCloseSubpath(m);
        }
        p = m;
    }
    return p;
}

constexpr double kMaxZoom = 64;

}  // namespace

// The map: equirectangular. Scroll or pinch to zoom (a trackpad's two-finger scroll pans),
// drag to pan, double-click to zoom in, + and - keys, 0 for the whole world.
@interface ADIFMapView : NSView
@property(nonatomic) BOOL showSquares, showEntities, showParks, showOthers;
@property(nonatomic, readonly) double zoom;
@property(nonatomic, copy) void (^onHover)(const ADIFMapHit &hit);
@property(nonatomic, copy) void (^onSelect)(const ADIFMapHit &hit);
@property(nonatomic, copy) void (^onViewChanged)(void);
- (void)setData:(const adif::MapData &)data entities:(const std::vector<ADIFMapEntity> &)entities;
- (void)zoomBy:(double)factor;  // about the middle
- (void)showWorld;
- (void)fitLog;                 // zoom to what the log shows
- (NSPoint)viewPointForLon:(double)lon lat:(double)lat;
@end

@implementation ADIFMapView {
    adif::MapData _data;
    std::vector<ADIFMapEntity> _entities;
    double _centerLon, _centerLat, _zoom;
    ADIFMapHit _hover, _selected;
    NSPoint _down;
    BOOL _dragged;
    NSTrackingArea *_tracking;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _showSquares = _showEntities = _showParks = YES;
        _showOthers = NO;
        _zoom = 1;
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

- (void)setData:(const adif::MapData &)data entities:(const std::vector<ADIFMapEntity> &)entities {
    _data = data;
    _entities = entities;
    _hover = ADIFMapHit();
    _selected = ADIFMapHit();
    self.needsDisplay = YES;
}

// ── Projection ──

- (double)pixelsPerDegree {
    NSRect b = self.bounds;
    return std::min(b.size.width / 360.0, b.size.height / 180.0) * _zoom;
}

- (void)clampCenter {
    double ppd = [self pixelsPerDegree];
    if (ppd <= 0) return;
    double halfW = self.bounds.size.width / 2 / ppd, halfH = self.bounds.size.height / 2 / ppd;
    _centerLon = halfW >= 180 ? 0 : std::clamp(_centerLon, -180 + halfW, 180 - halfW);
    _centerLat = halfH >= 90 ? 0 : std::clamp(_centerLat, -90 + halfH, 90 - halfH);
}

- (NSPoint)viewPointForLon:(double)lon lat:(double)lat {
    double ppd = [self pixelsPerDegree];
    return NSMakePoint(NSMidX(self.bounds) + (lon - _centerLon) * ppd, NSMidY(self.bounds) + (lat - _centerLat) * ppd);
}

- (void)lonLatAt:(NSPoint)p lon:(double *)lon lat:(double *)lat {
    double ppd = [self pixelsPerDegree];
    *lon = _centerLon + (p.x - NSMidX(self.bounds)) / ppd;
    *lat = _centerLat + (p.y - NSMidY(self.bounds)) / ppd;
}

- (NSRect)squareRect:(const std::string &)grid {
    double w, s, e, n;
    if (!adif::squareBounds(grid, &w, &s, &e, &n)) return NSZeroRect;
    NSPoint a = [self viewPointForLon:w lat:s], b = [self viewPointForLon:e lat:n];
    return NSMakeRect(a.x, a.y, b.x - a.x, b.y - a.y);
}

- (void)viewChanged {
    [self clampCenter];
    self.needsDisplay = YES;
    if (self.onViewChanged) self.onViewChanged();
}

- (void)zoomBy:(double)factor at:(NSPoint)p {
    double lon, lat;
    [self lonLatAt:p lon:&lon lat:&lat];
    double z = std::clamp(_zoom * factor, 1.0, kMaxZoom);
    if (z == _zoom) return;
    _zoom = z;
    // Keep the point under the pointer where it was.
    double ppd = [self pixelsPerDegree];
    _centerLon = lon - (p.x - NSMidX(self.bounds)) / ppd;
    _centerLat = lat - (p.y - NSMidY(self.bounds)) / ppd;
    [self viewChanged];
}

- (void)zoomBy:(double)factor {
    [self zoomBy:factor at:NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds))];
}

- (void)showWorld {
    _zoom = 1, _centerLon = 0, _centerLat = 0;
    [self viewChanged];
}

- (void)fitLog {
    double west = 180, east = -180, south = 90, north = -90;
    auto add = [&](double lon, double lat) {
        west = std::min(west, lon), east = std::max(east, lon), south = std::min(south, lat), north = std::max(north, lat);
    };
    if (_showSquares)
        for (const adif::MapSquare &sq : _data.squares) {
            double w, s, e, n;
            if (adif::squareBounds(sq.grid, &w, &s, &e, &n)) add(w, s), add(e, n);
        }
    if (_showEntities)
        for (const ADIFMapEntity &e : _entities) add(e.lon, e.lat);
    for (const std::string &g : _data.mine) {
        double lat, lon;
        if (adif::gridToLatLon(g, &lat, &lon)) add(lon, lat);
    }
    if (west > east) return [self showWorld];
    double spanLon = std::max(8.0, (east - west) * 1.15), spanLat = std::max(4.0, (north - south) * 1.15);
    NSRect b = self.bounds;
    double base = std::min(b.size.width / 360.0, b.size.height / 180.0);
    _zoom = std::clamp(std::min(b.size.width / spanLon, b.size.height / spanLat) / base, 1.0, kMaxZoom);
    _centerLon = (west + east) / 2, _centerLat = (south + north) / 2;
    [self viewChanged];
}

// ── Drawing ──

- (void)drawLabel:(NSString *)text at:(NSPoint)p size:(CGFloat)size alpha:(CGFloat)alpha {
    NSDictionary *attrs = @{NSFontAttributeName : [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:1 alpha:alpha]};
    NSSize s = [text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint(p.x - s.width / 2, p.y - s.height / 2) withAttributes:attrs];
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    [[NSColor colorWithCalibratedRed:0.09 green:0.12 blue:0.17 alpha:1] setFill];
    NSRectFill(b);
    double ppd = [self pixelsPerDegree];
    NSPoint sw = [self viewPointForLon:-180 lat:-90], ne = [self viewPointForLon:180 lat:90];
    NSRect world = NSMakeRect(sw.x, sw.y, ne.x - sw.x, ne.y - sw.y);
    [[NSColor colorWithCalibratedRed:0.13 green:0.20 blue:0.29 alpha:1] setFill];
    NSRectFill(NSIntersectionRect(world, b));  // zoomed in, the world is far bigger than the view
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, NSRectToCGRect(NSIntersectionRect(world, b)));
    // Land, lakes, rivers and borders, drawn in degrees; finer and fuller as you zoom in.
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, NSMidX(b) - _centerLon * ppd, NSMidY(b) - _centerLat * ppd);
    CGContextScaleCTM(ctx, ppd, ppd);
    bool fine = _zoom >= 3;
    CGContextSetRGBFillColor(ctx, 0.33, 0.38, 0.33, 1);
    CGContextAddPath(ctx, layerPath(fine ? adif::MapLayer::Land50 : adif::MapLayer::Land110));
    CGContextEOFillPath(ctx);
    CGContextSetRGBFillColor(ctx, 0.13, 0.20, 0.29, 1);  // lakes: the ocean's colour; their islands stay land
    CGContextAddPath(ctx, layerPath(fine ? adif::MapLayer::Lakes50 : adif::MapLayer::Lakes110));
    CGContextEOFillPath(ctx);
    CGContextSetRGBStrokeColor(ctx, 0.36, 0.52, 0.70, 0.85);
    CGContextSetLineWidth(ctx, (_zoom >= 8 ? 1.0 : 0.7) / ppd);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextAddPath(ctx, layerPath(adif::MapLayer::Rivers50, _zoom < 2 ? 2 : _zoom < 4 ? 4 : 6));
    CGContextStrokePath(ctx);
    if (_zoom >= 2.5) {  // states and provinces: US, Canada, Australia, Russia...
        CGFloat dash[] = {(CGFloat)(3 / ppd), (CGFloat)(2 / ppd)};
        CGContextSetLineDash(ctx, 0, dash, 2);
        CGContextSetRGBStrokeColor(ctx, 0.80, 0.82, 0.76, 0.4);
        CGContextSetLineWidth(ctx, 0.5 / ppd);
        CGContextAddPath(ctx, layerPath(adif::MapLayer::States50));
        CGContextStrokePath(ctx);
        CGContextSetLineDash(ctx, 0, nullptr, 0);
    }
    CGContextSetRGBStrokeColor(ctx, 0.80, 0.82, 0.76, _zoom >= 2 ? 0.6 : 0.35);
    CGContextSetLineWidth(ctx, (_zoom >= 4 ? 0.9 : 0.6) / ppd);
    CGContextAddPath(ctx, layerPath(adif::MapLayer::Borders50));
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
    // Maidenhead fields (20 x 10 degrees), and squares (2 x 1) when they are big enough to see.
    double fieldW = 20 * ppd, squareW = 2 * ppd;
    NSBezierPath *grid = [NSBezierPath bezierPath];
    grid.lineWidth = 0.6;
    for (int lon = -180; lon <= 180; lon += 20) {
        [grid moveToPoint:[self viewPointForLon:lon lat:-90]];
        [grid lineToPoint:[self viewPointForLon:lon lat:90]];
    }
    for (int lat = -90; lat <= 90; lat += 10) {
        [grid moveToPoint:[self viewPointForLon:-180 lat:lat]];
        [grid lineToPoint:[self viewPointForLon:180 lat:lat]];
    }
    [[NSColor colorWithCalibratedWhite:1 alpha:0.18] setStroke];
    [grid stroke];
    double west, south, east, north;
    [self lonLatAt:NSMakePoint(NSMinX(b), NSMinY(b)) lon:&west lat:&south];
    [self lonLatAt:NSMakePoint(NSMaxX(b), NSMaxY(b)) lon:&east lat:&north];
    if (squareW >= 12) {
        NSBezierPath *fine = [NSBezierPath bezierPath];
        fine.lineWidth = 0.4;
        for (double lon = std::floor(std::max(-180.0, west) / 2) * 2; lon <= std::min(180.0, east); lon += 2) {
            [fine moveToPoint:[self viewPointForLon:lon lat:std::max(-90.0, south)]];
            [fine lineToPoint:[self viewPointForLon:lon lat:std::min(90.0, north)]];
        }
        for (double lat = std::floor(std::max(-90.0, south)); lat <= std::min(90.0, north); lat += 1) {
            [fine moveToPoint:[self viewPointForLon:std::max(-180.0, west) lat:lat]];
            [fine lineToPoint:[self viewPointForLon:std::min(180.0, east) lat:lat]];
        }
        [[NSColor colorWithCalibratedWhite:1 alpha:0.08] setStroke];
        [fine stroke];
    }
    if (_showSquares)
        for (size_t i = 0; i < _data.squares.size(); ++i) {
            const adif::MapSquare &sq = _data.squares[i];
            NSRect cell = [self squareRect:sq.grid];
            if (!NSIntersectsRect(NSInsetRect(cell, -2, -2), b)) continue;
            if (cell.size.width < 2) cell = NSInsetRect(cell, (cell.size.width - 2) / 2, (cell.size.height - 2) / 2);
            [(sq.confirmed ? [NSColor.systemGreenColor colorWithAlphaComponent:0.8] : [NSColor.systemOrangeColor colorWithAlphaComponent:0.8]) setFill];
            NSRectFill(cell);
        }
    // Field and square names, once there is room for them.
    if (fieldW >= 44 && squareW < 36)
        for (int fx = 0; fx < 18; ++fx)
            for (int fy = 0; fy < 18; ++fy) {
                double lon = -180 + fx * 20 + 10, lat = -90 + fy * 10 + 5;
                if (lon + 10 < west || lon - 10 > east || lat + 5 < south || lat - 5 > north) continue;
                [self drawLabel:[NSString stringWithFormat:@"%c%c", 'A' + fx, 'A' + fy] at:[self viewPointForLon:lon lat:lat] size:std::min(16.0, fieldW / 6) alpha:0.35];
            }
    if (squareW >= 36)
        for (double lon = std::floor(std::max(-180.0, west) / 2) * 2; lon < std::min(180.0, east); lon += 2)
            for (double lat = std::floor(std::max(-90.0, south)); lat < std::min(90.0, north); lat += 1) {
                std::string sq = adif::squareAt(lon + 1, lat + 0.5);
                if (!sq.empty()) [self drawLabel:@(sq.c_str()) at:[self viewPointForLon:lon + 1 lat:lat + 0.5] size:std::min(13.0, squareW / 6) alpha:0.32];
            }
    if (_showEntities)
        for (size_t i = 0; i < _entities.size(); ++i) {
            const ADIFMapEntity &e = _entities[i];
            NSPoint p = [self viewPointForLon:e.lon lat:e.lat];
            CGFloat r = (CGFloat)std::min(8.0, 3.0 + std::log2((double)e.qsos.size() + 1));
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - r, p.y - r, 2 * r, 2 * r)];
            [(e.confirmed ? NSColor.systemTealColor : NSColor.systemBlueColor) setFill];
            [dot fill];
            bool lit = (_hover.kind == ADIFMapHit::Dxcc && _hover.index == i) || (_selected.kind == ADIFMapHit::Dxcc && _selected.index == i);
            [[NSColor colorWithCalibratedWhite:1 alpha:lit ? 1 : 0.6] setStroke];
            dot.lineWidth = lit ? 2 : 1;
            [dot stroke];
        }
    for (size_t i = 0; i < _data.parks.size(); ++i) {
        const adif::MapPark &pk = _data.parks[i];
        if (!(pk.park() ? _showParks : _showOthers)) continue;
        double lat = 0, lon = 0;
        if (!adif::gridToLatLon(pk.grid, &lat, &lon)) continue;
        NSPoint p = [self viewPointForLon:lon lat:lat];
        NSBezierPath *tri = [NSBezierPath bezierPath];
        if (pk.park()) {  // a park: a purple triangle
            [tri moveToPoint:NSMakePoint(p.x, p.y + 6)];
            [tri lineToPoint:NSMakePoint(p.x - 5, p.y - 4)];
            [tri lineToPoint:NSMakePoint(p.x + 5, p.y - 4)];
            [NSColor.systemPurpleColor setFill];
        } else {  // another program's reference (IOTA, SOTA, GMA...): a diamond
            [tri moveToPoint:NSMakePoint(p.x, p.y + 5)];
            [tri lineToPoint:NSMakePoint(p.x - 4.5, p.y)];
            [tri lineToPoint:NSMakePoint(p.x, p.y - 5)];
            [tri lineToPoint:NSMakePoint(p.x + 4.5, p.y)];
            [[NSColor colorWithCalibratedRed:0.95 green:0.75 blue:0.2 alpha:1] setFill];
        }
        [tri closePath];
        [tri fill];
        bool lit = (_hover.kind == ADIFMapHit::Park && _hover.index == i) || (_selected.kind == ADIFMapHit::Park && _selected.index == i);
        if (lit) {
            [NSColor.whiteColor setStroke];
            tri.lineWidth = 1.5;
            [tri stroke];
        }
    }
    for (const std::string &g : _data.mine) {  // your station: a star
        double lat = 0, lon = 0;
        if (!adif::gridToLatLon(g, &lat, &lon)) continue;
        NSPoint c = [self viewPointForLon:lon lat:lat];
        NSBezierPath *star = [NSBezierPath bezierPath];
        for (int k = 0; k < 10; ++k) {
            double a = M_PI / 2 + k * M_PI / 5, rad = k % 2 ? 3.0 : 7.5;
            NSPoint q = NSMakePoint(c.x + rad * std::cos(a), c.y + rad * std::sin(a));
            if (k == 0) [star moveToPoint:q];
            else [star lineToPoint:q];
        }
        [star closePath];
        [NSColor.systemRedColor setFill];
        [star fill];
        [NSColor.whiteColor setStroke];
        [star stroke];
    }
    // The square under the pointer and the one chosen, outlined.
    for (const ADIFMapHit *h : {&_hover, &_selected}) {
        if (h->square.empty() || (h->kind != ADIFMapHit::Square && h->kind != ADIFMapHit::Empty)) continue;
        NSRect r = [self squareRect:h->square];
        if (r.size.width < 3) continue;
        NSBezierPath *box = [NSBezierPath bezierPathWithRect:r];
        box.lineWidth = h == &_selected ? 2 : 1;
        [[NSColor colorWithCalibratedWhite:1 alpha:h == &_selected ? 0.95 : 0.6] setStroke];
        [box stroke];
    }
    CGContextRestoreGState(ctx);
}

// ── Pointer and keys ──

- (ADIFMapHit)hitAt:(NSPoint)p {
    ADIFMapHit h;
    double lon, lat;
    [self lonLatAt:p lon:&lon lat:&lat];
    h.square = adif::squareAt(lon, lat);
    if (h.square.empty()) return h;
    for (size_t i = 0; i < _data.parks.size(); ++i) {
        if (!(_data.parks[i].park() ? _showParks : _showOthers)) continue;
        double plat, plon;
        if (!adif::gridToLatLon(_data.parks[i].grid, &plat, &plon)) continue;
        NSPoint q = [self viewPointForLon:plon lat:plat];
        if (std::hypot(q.x - p.x, q.y - p.y) <= 7) return h.kind = ADIFMapHit::Park, h.index = i, h;
    }
    if (_showEntities)
        for (size_t i = 0; i < _entities.size(); ++i) {
            NSPoint q = [self viewPointForLon:_entities[i].lon lat:_entities[i].lat];
            double r = std::min(8.0, 3.0 + std::log2((double)_entities[i].qsos.size() + 1)) + 2;
            if (std::hypot(q.x - p.x, q.y - p.y) <= r) return h.kind = ADIFMapHit::Dxcc, h.index = i, h;
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
    double ppd = [self pixelsPerDegree];
    _centerLon -= event.deltaX / ppd;
    _centerLat += event.deltaY / ppd;
    _dragged = YES;
    [[NSCursor closedHandCursor] set];
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
        double ppd = [self pixelsPerDegree];
        _centerLon -= event.scrollingDeltaX / ppd;
        _centerLat += event.scrollingDeltaY / ppd;
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
    double step = 60 / [self pixelsPerDegree];
    if (k == '+' || k == '=') [self zoomBy:1.5];
    else if (k == '-') [self zoomBy:1 / 1.5];
    else if (k == '0') [self showWorld];
    else if (k == NSLeftArrowFunctionKey) _centerLon -= step, [self viewChanged];
    else if (k == NSRightArrowFunctionKey) _centerLon += step, [self viewChanged];
    else if (k == NSUpArrowFunctionKey) _centerLat += step, [self viewChanged];
    else if (k == NSDownArrowFunctionKey) _centerLat -= step, [self viewChanged];
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
    NSButton *squares = nil, *entities = nil, *parks = nil, *others = nil;
    NSPopUpButton *band = nil, *mode = nil;
    NSTextField *target = nil, *status = nil, *zoomLabel = nil;
    adif::MapData data;
    std::vector<ADIFMapEntity> dxcc;
    std::vector<size_t> listed;   // the table's rows: indexes into data.qsos
    std::string summary, chosen;  // what the status line says when nothing is under the pointer
    intptr_t buffer = 0;
} mw;

std::string plural(size_t n, const char *w) {
    std::string word = w;
    if (n != 1) word = word.back() == 'y' ? word.substr(0, word.size() - 1) + "ies" : word + "s";
    return std::to_string(n) + " " + word;
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
    switch (h.kind) {
        case ADIFMapHit::Square: {
            const adif::MapSquare &sq = mw.data.squares[h.index];
            return sq.grid + ": " + plural(sq.qsos, "QSO") + (sq.confirmed ? ", confirmed" : "") + " (" + callsOf(sq.qsoIndex) + ")";
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
        case ADIFMapHit::Empty: return h.square + ": no QSOs";
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
    else if (h.kind == ADIFMapHit::Park)
        for (const adif::MapPark &p : mw.data.parks)
            if (p.reference == mw.data.parks[h.index].reference && p.program == mw.data.parks[h.index].program) qsos.push_back(p.qso);
    showList(qsos);
    mw.chosen = h.kind == ADIFMapHit::None ? "" : describe(h) + (qsos.empty() ? "" : ". Double-click a QSO to go to it in the log.");
    setStatus(mw.chosen.empty() ? mw.summary : mw.chosen);
}

void updateZoomLabel() {
    double z = mw.view.zoom;
    mw.zoomLabel.stringValue = z < 10 ? [NSString stringWithFormat:@"%.1f×", z] : [NSString stringWithFormat:@"%.0f×", z];
}

void refresh() {
    if (!mw.window) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        mw.buffer = buffer();
        mw.target.stringValue = [@"Log: " stringByAppendingString:ADIFString(documentName())];
        // The bands and modes in the log, for the filters.
        std::set<std::string> bands, modes;
        for (const adif::Record &rec : adif::records(text, r.model)) {
            if (std::string b = adif::effectiveBand(rec); !b.empty()) bands.insert(b);
            if (std::string m = rec.get("MODE"); !m.empty()) modes.insert(m);
        }
        auto fill = [](NSPopUpButton *p, NSString *all, const std::set<std::string> &items) {
            NSString *keep = p.indexOfSelectedItem > 0 ? p.titleOfSelectedItem : nil;
            [p removeAllItems];
            [p addItemWithTitle:all];
            for (const std::string &i : items) [p addItemWithTitle:ADIFString(i)];
            if (keep && [p itemWithTitle:keep]) [p selectItemWithTitle:keep];
        };
        fill(mw.band, @"All bands", bands);
        fill(mw.mode, @"All modes", modes);
        std::string band = mw.band.indexOfSelectedItem > 0 ? ADIFStd(mw.band.titleOfSelectedItem) : "";
        std::string mode = mw.mode.indexOfSelectedItem > 0 ? ADIFStd(mw.mode.titleOfSelectedItem) : "";
        mw.data = adif::mapData(text, r.model, band, mode);
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
        mw.view.showOthers = mw.others.state == NSControlStateValueOn;
        [mw.view setData:mw.data entities:mw.dxcc];
        showList({});
        std::set<std::string> parkRefs, otherRefs;
        for (const adif::MapPark &p : mw.data.parks) (p.park() ? parkRefs : otherRefs).insert(p.program + " " + p.reference);
        mw.summary = plural(mw.data.squares.size(), "grid square") + " (" + std::to_string(confirmedSquares) +
                     " confirmed: green, else orange), " + std::to_string(mw.dxcc.size()) + " DXCC (" + std::to_string(confirmedDxcc) +
                     " confirmed: teal, else blue), " + plural(parkRefs.size(), "park") + " (POTA, WWFF) where the QSO has a grid (purple), " +
                     plural(otherRefs.size(), "other reference") + " (IOTA, SOTA, GMA... yellow, under Other programs)" +
                     (mw.data.mine.empty() ? "" : ", your grid as a red star") + ". " +
                     (mw.data.withoutGrid ? plural(mw.data.withoutGrid, "QSO") + " without GRIDSQUARE " + (mw.data.withoutGrid == 1 ? "isn't" : "aren't") +
                                                " on the squares. "
                                          : "") +
                     "Scroll or pinch to zoom, drag to move, click a square, dot or park for its QSOs.";
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
    // What the map shows now, at twice the screen's size.
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

}  // namespace

void cmdMap() {
    if (!mw.window) {
        mw.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 1040, 760)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                         NSWindowStyleMaskUtilityWindow
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
        mw.window.title = @"Map";
        mw.window.releasedWhenClosed = NO;
        mw.window.hidesOnDeactivate = NO;
        mw.window.contentMinSize = NSMakeSize(760, 560);
        NSView *root = mw.window.contentView;
        mw.target = ADIFLabel(@"");
        mw.squares = ADIFCheckbox(@"Grid squares", YES);
        mw.entities = ADIFCheckbox(@"DXCC", YES);
        mw.parks = ADIFCheckbox(@"Parks", YES);
        mw.parks.toolTip = @"POTA and WWFF parks you hunted, where the QSO has a grid";
        mw.others = ADIFCheckbox(@"Other programs", NO);
        mw.others.toolTip = @"Other programs' references: IOTA islands, SOTA summits, GMA, bunkers... (IOTA is often filled in by a "
                            @"callbook for every island station)";
        mw.band = ADIFPopup(@[ @"All bands" ]);
        mw.mode = ADIFPopup(@[ @"All modes" ]);
        for (NSControl *c in @[ mw.squares, mw.entities, mw.parks, mw.others, mw.band, mw.mode ]) ADIFOnAction(c, ^{ refresh(); });
        mw.zoomLabel = ADIFLabel(@"1.0×");
        [mw.zoomLabel.widthAnchor constraintEqualToConstant:40].active = YES;
        NSButton *out = smallButton(@"−", @"Zoom out (−)", ^{ [mw.view zoomBy:1 / 1.5]; });
        NSButton *in = smallButton(@"+", @"Zoom in (+, or double-click the map)", ^{ [mw.view zoomBy:1.5]; });
        NSButton *fit = smallButton(@"Fit Log", @"Zoom to the log's QSOs", ^{ [mw.view fitLog]; });
        NSButton *world = smallButton(@"World", @"The whole world (0)", ^{ [mw.view showWorld]; });
        NSButton *save = smallButton(@"Export PNG...", @"Save the map as it is shown now", ^{ exportPng(); });
        NSStackView *row = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Show:"), mw.squares, mw.entities, mw.parks, mw.others, mw.band, mw.mode ]];
        row.spacing = 10;
        NSStackView *row2 = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Zoom:"), out, mw.zoomLabel, in, fit, world, save ]];
        row2.spacing = 8;
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
        for (NSView *v in @[ mw.target, row, row2, mw.view, scroll, mw.status ]) {
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
            [row2.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:6],
            [row2.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [row2.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
            [mw.view.topAnchor constraintEqualToAnchor:row2.bottomAnchor constant:8],
            [mw.view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [mw.view.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [scroll.topAnchor constraintEqualToAnchor:mw.view.bottomAnchor constant:8],
            [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [scroll.heightAnchor constraintEqualToConstant:130],
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
