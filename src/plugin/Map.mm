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
    double lat = 0, lon = 0;
    size_t qsos = 0;
    bool confirmed = false;
    std::string name;
};

// The map itself: equirectangular, the whole world, as large as the view allows at 2:1.
@interface ADIFMapView : NSView
@property(nonatomic) BOOL showSquares, showEntities, showParks;
@property(nonatomic, copy) void (^onClick)(double lon, double lat);
- (void)setData:(const adif::MapData &)data entities:(const std::vector<ADIFMapEntity> &)entities;
- (NSRect)mapRect;
@end

@implementation ADIFMapView {
    adif::MapData _data;
    std::vector<ADIFMapEntity> _entities;
    std::vector<NSBezierPath *> _land;  // in degrees; scaled when drawn
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _showSquares = _showEntities = _showParks = YES;
        for (size_t i = 0; i < adif::landRingCount(); ++i) {
            NSBezierPath *p = [NSBezierPath bezierPath];
            bool first = true;
            for (const auto &pt : adif::landRing(i)) {
                NSPoint q = NSMakePoint(pt.first, pt.second);
                if (first) [p moveToPoint:q];
                else [p lineToPoint:q];
                first = false;
            }
            [p closePath];
            _land.push_back(p);
        }
    }
    return self;
}

- (BOOL)isFlipped {
    return NO;
}

- (void)setData:(const adif::MapData &)data entities:(const std::vector<ADIFMapEntity> &)entities {
    _data = data;
    _entities = entities;
    self.needsDisplay = YES;
}

- (NSRect)mapRect {
    NSRect b = self.bounds;
    CGFloat w = std::min(b.size.width, b.size.height * 2), h = w / 2;
    return NSMakeRect(NSMidX(b) - w / 2, NSMidY(b) - h / 2, w, h);
}

- (NSPoint)pointForLon:(double)lon lat:(double)lat {
    NSRect r = [self mapRect];
    return NSMakePoint(NSMinX(r) + (lon + 180) / 360 * r.size.width, NSMinY(r) + (lat + 90) / 180 * r.size.height);
}

- (void)drawRect:(NSRect)dirty {
    NSRect r = [self mapRect];
    [[NSColor colorWithCalibratedRed:0.13 green:0.20 blue:0.29 alpha:1] setFill];
    NSRectFill(r);
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:NSMinX(r) + r.size.width / 2 yBy:NSMinY(r) + r.size.height / 2];
    [t scaleXBy:r.size.width / 360 yBy:r.size.height / 180];
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(r);
    [[NSColor colorWithCalibratedRed:0.33 green:0.38 blue:0.33 alpha:1] setFill];
    for (NSBezierPath *p : _land) [[t transformBezierPath:p] fill];
    // Maidenhead fields: 20 degrees of longitude by 10 of latitude.
    [[NSColor colorWithCalibratedWhite:1 alpha:0.12] setStroke];
    NSBezierPath *grid = [NSBezierPath bezierPath];
    grid.lineWidth = 0.5;
    for (int lon = -180; lon <= 180; lon += 20) {
        [grid moveToPoint:[self pointForLon:lon lat:-90]];
        [grid lineToPoint:[self pointForLon:lon lat:90]];
    }
    for (int lat = -90; lat <= 90; lat += 10) {
        [grid moveToPoint:[self pointForLon:-180 lat:lat]];
        [grid lineToPoint:[self pointForLon:180 lat:lat]];
    }
    [grid stroke];
    if (_showSquares)
        for (const adif::MapSquare &sq : _data.squares) {
            double w, s, e, n;
            if (!adif::squareBounds(sq.grid, &w, &s, &e, &n)) continue;
            NSPoint a = [self pointForLon:w lat:s], b = [self pointForLon:e lat:n];
            NSRect cell = NSMakeRect(a.x, a.y, std::max<CGFloat>(1.5, b.x - a.x), std::max<CGFloat>(1.5, b.y - a.y));
            [(sq.confirmed ? [NSColor.systemGreenColor colorWithAlphaComponent:0.85] : [NSColor.systemOrangeColor colorWithAlphaComponent:0.85]) setFill];
            NSRectFill(cell);
        }
    if (_showEntities)
        for (const ADIFMapEntity &e : _entities) {
            NSPoint p = [self pointForLon:e.lon lat:e.lat];
            CGFloat radius = (CGFloat)std::min(7.0, 2.5 + std::log2((double)e.qsos + 1));
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - radius, p.y - radius, 2 * radius, 2 * radius)];
            [(e.confirmed ? NSColor.systemTealColor : NSColor.systemBlueColor) setFill];
            [dot fill];
            [[NSColor colorWithCalibratedWhite:1 alpha:0.6] setStroke];
            [dot stroke];
        }
    if (_showParks)
        for (const adif::MapPark &pk : _data.parks) {
            double lat = 0, lon = 0;
            if (!adif::gridToLatLon(pk.grid, &lat, &lon)) continue;
            NSPoint p = [self pointForLon:lon lat:lat];
            NSBezierPath *tri = [NSBezierPath bezierPath];
            [tri moveToPoint:NSMakePoint(p.x, p.y + 5)];
            [tri lineToPoint:NSMakePoint(p.x - 4.5, p.y - 3.5)];
            [tri lineToPoint:NSMakePoint(p.x + 4.5, p.y - 3.5)];
            [tri closePath];
            [NSColor.systemPurpleColor setFill];
            [tri fill];
        }
    for (const std::string &g : _data.mine) {  // your station: a star
        double lat = 0, lon = 0;
        if (!adif::gridToLatLon(g, &lat, &lon)) continue;
        NSPoint c = [self pointForLon:lon lat:lat];
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
    [NSGraphicsContext restoreGraphicsState];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect r = [self mapRect];
    if (!NSPointInRect(p, r) || !self.onClick) return;
    self.onClick((p.x - NSMinX(r)) / r.size.width * 360 - 180, (p.y - NSMinY(r)) / r.size.height * 180 - 90);
}

@end

namespace worldmap {
namespace {

struct {
    NSPanel *window = nil;
    ADIFMapView *view = nil;
    NSButton *squares = nil, *entities = nil, *parks = nil;
    NSPopUpButton *band = nil, *mode = nil;
    NSTextField *target = nil, *status = nil;
    adif::MapData data;
    std::string summary;
} mw;

std::string plural(size_t n, const char *w) {
    std::string word = w;
    if (n != 1) word = word.back() == 'y' ? word.substr(0, word.size() - 1) + "ies" : word + "s";
    return std::to_string(n) + " " + word;
}

void setStatus(const std::string &text) { mw.status.stringValue = ADIFString(text); }

void refresh() {
    if (!mw.window) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
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
        // DXCC entities from the calls, by country data.
        std::map<int, ADIFMapEntity> byDxcc;
        const adif::CountryTable &countries = ADIFCountries();
        for (const auto &[call, confirmed] : mw.data.calls) {
            adif::CountryInfo info;
            if (countries.empty() || !countries.lookup(call, &info) || !info.dxcc) continue;
            ADIFMapEntity &e = byDxcc[info.dxcc];
            e.lat = info.lat, e.lon = info.lon, e.name = info.name;
            ++e.qsos;
            e.confirmed |= confirmed;
        }
        std::vector<ADIFMapEntity> entities;
        size_t confirmedEntities = 0, confirmedSquares = 0;
        for (auto &kv : byDxcc) {
            confirmedEntities += kv.second.confirmed;
            entities.push_back(kv.second);
        }
        for (const adif::MapSquare &sq : mw.data.squares) confirmedSquares += sq.confirmed;
        mw.view.showSquares = mw.squares.state == NSControlStateValueOn;
        mw.view.showEntities = mw.entities.state == NSControlStateValueOn;
        mw.view.showParks = mw.parks.state == NSControlStateValueOn;
        [mw.view setData:mw.data entities:entities];
        std::set<std::string> parkRefs;
        for (const adif::MapPark &p : mw.data.parks) parkRefs.insert(p.reference);
        mw.summary = plural(mw.data.squares.size(), "grid square") + " (" + std::to_string(confirmedSquares) +
                     " confirmed: green, else orange), " + plural(entities.size(), "entity") + " (" + std::to_string(confirmedEntities) +
                     " confirmed: teal, else blue), " + plural(parkRefs.size(), "park") + " where the QSO has a grid (purple)" +
                     (mw.data.mine.empty() ? "" : ", your grid as a red star") + ". " +
                     (mw.data.withoutGrid ? plural(mw.data.withoutGrid, "QSO") + " without GRIDSQUARE aren't on the squares. " : "") +
                     "Click a square for its QSOs.";
        setStatus(mw.summary);
    } catch (...) {
    }
}

void clicked(double lon, double lat) {
    std::string grid = adif::squareAt(lon, lat);
    for (const adif::MapSquare &sq : mw.data.squares)
        if (sq.grid == grid) {
            std::string calls;
            for (const std::string &c : sq.calls) calls += (calls.empty() ? "" : ", ") + c;
            setStatus(grid + ": " + plural(sq.qsos, "QSO") + (sq.confirmed ? ", confirmed" : "") + " (" + calls +
                      (sq.qsos > sq.calls.size() ? ", ..." : "") + ").");
            return;
        }
    setStatus(grid.empty() ? mw.summary : grid + ": no QSOs. " + mw.summary);
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
    NSRect r = [mw.view mapRect];
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
    NSAffineTransform *shift = [NSAffineTransform transform];
    [shift translateXBy:-NSMinX(r) yBy:-NSMinY(r)];
    [shift concat];
    [mw.view drawRect:r];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:ADIFString(path) atomically:YES]) {
        setStatus("Could not save the map.");
        return;
    }
    setStatus("Saved " + ADIFStd(ADIFString(path).lastPathComponent) + ". " + mw.summary);
}

}  // namespace

void cmdMap() {
    if (!mw.window) {
        mw.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 640)
                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                         NSWindowStyleMaskUtilityWindow
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
        mw.window.title = @"Map";
        mw.window.releasedWhenClosed = NO;
        mw.window.hidesOnDeactivate = NO;
        mw.window.contentMinSize = NSMakeSize(640, 420);
        NSView *root = mw.window.contentView;
        mw.target = ADIFLabel(@"");
        mw.squares = ADIFCheckbox(@"Grid squares", YES);
        mw.entities = ADIFCheckbox(@"Entities", YES);
        mw.parks = ADIFCheckbox(@"Parks", YES);
        mw.band = ADIFPopup(@[ @"All bands" ]);
        mw.mode = ADIFPopup(@[ @"All modes" ]);
        NSButton *save = [NSButton buttonWithTitle:@"Export PNG..." target:nil action:nil];
        for (NSControl *c in @[ mw.squares, mw.entities, mw.parks, mw.band, mw.mode ]) ADIFOnAction(c, ^{ refresh(); });
        ADIFOnAction(save, ^{ exportPng(); });
        NSStackView *row = [NSStackView stackViewWithViews:@[ ADIFLabel(@"Show:"), mw.squares, mw.entities, mw.parks, mw.band, mw.mode, save ]];
        row.spacing = 10;
        mw.view = [[ADIFMapView alloc] initWithFrame:NSZeroRect];
        mw.view.onClick = ^(double lon, double lat) { clicked(lon, lat); };
        mw.status = [NSTextField wrappingLabelWithString:@""];
        mw.status.maximumNumberOfLines = 3;
        mw.status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        for (NSView *v in @[ mw.target, row, mw.view, mw.status ]) {
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
            [mw.view.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:8],
            [mw.view.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [mw.view.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [mw.status.topAnchor constraintEqualToAnchor:mw.view.bottomAnchor constant:8],
            [mw.status.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
            [mw.status.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
            [mw.status.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-m],
            [mw.status.heightAnchor constraintGreaterThanOrEqualToConstant:30],
        ]];
        [mw.window center];
    }
    refresh();
    [mw.window makeKeyAndOrderFront:nil];
}

void documentChanged() {
    if (mw.window && mw.window.visible) refresh();
}

}  // namespace worldmap
