// Draws ADIF Lint's toolbar icons: original line art, light and dark, as PNGs.
//
//   clang -fobjc-arc -framework AppKit tools/make-toolbar-icons.m -o /tmp/icons && /tmp/icons data/toolbar
//
// Nextpad++ looks for <hint>.png and, in dark mode, <hint>_dark.png in the
// plugin folder (MainWindowController _resolvePluginToolbarIconForDir:hint:,
// commit d50c226) and shows them at 26 points, or more with a larger toolbar
// scale. 104 px (four times 26) keeps them sharp when scaled down.
#import <AppKit/AppKit.h>

static const CGFloat kSize = 104, kLine = 7;

typedef void (^Draw)(CGContextRef c);

static void stroke(CGContextRef c, CGPathRef p) {
    CGContextAddPath(c, p);
    CGContextStrokePath(c);
}

static CGPathRef roundRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat r) {
    return CGPathCreateWithRoundedRect(CGRectMake(x, y, w, h), r, r, NULL);
}

static void line(CGContextRef c, CGFloat x0, CGFloat y0, CGFloat x1, CGFloat y1) {
    CGContextMoveToPoint(c, x0, y0);
    CGContextAddLineToPoint(c, x1, y1);
    CGContextStrokePath(c);
}

static void writeIcon(NSString *dir, NSString *name, NSColor *color, Draw draw) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                     pixelsWide:(NSInteger)kSize
                                                                     pixelsHigh:(NSInteger)kSize
                                                                  bitsPerSample:8
                                                                samplesPerPixel:4
                                                                       hasAlpha:YES
                                                                       isPlanar:NO
                                                                 colorSpaceName:NSDeviceRGBColorSpace
                                                                    bytesPerRow:0
                                                                   bitsPerPixel:0];
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    CGContextRef c = gc.CGContext;
    CGContextClearRect(c, CGRectMake(0, 0, kSize, kSize));
    CGContextSetStrokeColorWithColor(c, color.CGColor);
    CGContextSetFillColorWithColor(c, color.CGColor);
    CGContextSetLineWidth(c, kLine);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    draw(c);
    [gc flushGraphics];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
    if (![png writeToFile:path atomically:YES]) {
        fprintf(stderr, "cannot write %s\n", path.UTF8String);
        exit(1);
    }
    printf("%s\n", path.UTF8String);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: make-toolbar-icons DIR\n");
            return 2;
        }
        NSString *dir = @(argv[1]);
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary<NSString *, Draw> *icons = @{
            // New QSO: a log sheet with a plus.
            @"toolbar-newqso" : ^(CGContextRef c) {
                CGPathRef page = roundRect(14, 14, 58, 76, 8);
                stroke(c, page);
                CGPathRelease(page);
                line(c, 27, 70, 59, 70);
                line(c, 27, 52, 59, 52);
                line(c, 27, 34, 45, 34);
                CGContextSetFillColorWithColor(c, NSColor.clearColor.CGColor);
                CGContextSetBlendMode(c, kCGBlendModeClear);
                CGContextFillEllipseInRect(c, CGRectMake(52, 6, 46, 46));
                CGContextSetBlendMode(c, kCGBlendModeNormal);
                line(c, 75, 15, 75, 43);
                line(c, 61, 29, 89, 29);
            },
            // Log Table: a grid with a heading row.
            @"toolbar-table" : ^(CGContextRef c) {
                CGPathRef box = roundRect(10, 16, 84, 72, 9);
                stroke(c, box);
                CGPathRelease(box);
                line(c, 10, 66, 94, 66);
                line(c, 10, 42, 94, 42);
                line(c, 38, 16, 38, 88);
                line(c, 66, 16, 66, 88);
            },
            // Check Log: a sheet with a tick.
            @"toolbar-check" : ^(CGContextRef c) {
                CGPathRef page = roundRect(18, 10, 68, 84, 9);
                stroke(c, page);
                CGPathRelease(page);
                CGContextSetLineWidth(c, kLine + 2);
                CGContextMoveToPoint(c, 33, 52);
                CGContextAddLineToPoint(c, 47, 37);
                CGContextAddLineToPoint(c, 72, 68);
                CGContextStrokePath(c);
            },
            // Spots: a mast radiating.
            @"toolbar-spots" : ^(CGContextRef c) {
                line(c, 52, 12, 52, 56);
                line(c, 38, 12, 66, 12);
                CGContextFillEllipseInRect(c, CGRectMake(45, 54, 14, 14));
                for (int i = 1; i <= 2; ++i) {
                    CGFloat r = 16.0 * i + 6;
                    CGContextAddArc(c, 52, 61, r, (CGFloat)(M_PI * 0.30), (CGFloat)(-M_PI * 0.30), 1);
                    CGContextStrokePath(c);
                    CGContextAddArc(c, 52, 61, r, (CGFloat)(M_PI * 0.70), (CGFloat)(M_PI * 1.30), 0);
                    CGContextStrokePath(c);
                }
            },
        };
        NSColor *light = [NSColor colorWithSRGBRed:0.23 green:0.23 blue:0.24 alpha:1];
        NSColor *dark = [NSColor colorWithSRGBRed:0.90 green:0.90 blue:0.91 alpha:1];
        for (NSString *name in icons) {
            writeIcon(dir, name, light, icons[name]);
            writeIcon(dir, [name stringByAppendingString:@"_dark"], dark, icons[name]);
        }
    }
    return 0;
}
