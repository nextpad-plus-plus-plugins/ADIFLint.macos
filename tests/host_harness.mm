// Loads the built ADIFLint.dylib the way Nextpad++ does (dlopen + the five C
// exports) and drives it against a simulated host and Scintilla document, so
// the editor glue can be tested without restarting the real editor.
//
//   host_harness path/to/ADIFLint.dylib
//
// The simulated host answers only the messages the plugin sends; any other
// message is reported as a failure so new dependencies on the host are noticed.
#include <sys/stat.h>
#include <unistd.h>

#include <functional>
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"

#import <Cocoa/Cocoa.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <dlfcn.h>
#include <algorithm>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

static int gFailures = 0, gChecks = 0;
#define CHECK(cond, ...)                                              \
    do {                                                              \
        ++gChecks;                                                    \
        if (!(cond)) {                                                \
            ++gFailures;                                              \
            std::printf("FAIL line %d: ", __LINE__);                  \
            std::printf(__VA_ARGS__);                                 \
            std::printf("\n");                                        \
        }                                                             \
    } while (0)

enum : uintptr_t { kNpp = 1, kSciMain = 2, kSciSecond = 3 };

static struct Host {
    std::string doc;
    std::string path = "/tmp/test.adi";
    std::string configDir;
    intptr_t pos = 0;
    intptr_t selStart = -1, selEnd = -1;  // -1: an empty selection at the caret
    int indicatorCurrent = 0;
    std::map<int, std::vector<std::pair<intptr_t, intptr_t>>> fills;  // indicator -> [start, end)
    std::string tip;
    int undoDepth = 0, undoActions = 0;
    intptr_t targetStart = 0, targetEnd = 0;
    std::map<uintptr_t, intptr_t> dwell;
    std::map<uintptr_t, intptr_t> checks;  // cmdID -> checked
    // autocompletion
    bool acActive = false;
    char acSeparator = ' ';
    std::string acList;
    intptr_t acEntered = 0;
    int acShows = 0, acCancels = 0;
    // docking panel
    NSView *panelView = nil;
    NSWindow *panelWindow = nil;
    std::vector<std::pair<uintptr_t, std::string>> toolbar;  // NPPM_ADDTOOLBARICON_FORDARKMODE: command, icon hint
    std::vector<std::string> opened;     // NPPM_DOOPEN requests
    std::vector<std::string> openFiles;  // what NPPM_GETOPENFILENAMES lists besides the active document
    std::vector<uint32_t> unknown;
} H;

static intptr_t lineStart(intptr_t line) {
    intptr_t l = 0, p = 0;
    while (l < line && p < (intptr_t)H.doc.size()) {
        if (H.doc[(size_t)p] == '\n') ++l;
        ++p;
    }
    return p;
}

static intptr_t lineOf(intptr_t pos) {
    return (intptr_t)std::count(H.doc.begin(), H.doc.begin() + std::min<intptr_t>(pos, (intptr_t)H.doc.size()), '\n');
}

static void clearFills(int indicator, intptr_t from, intptr_t to) {
    std::vector<std::pair<intptr_t, intptr_t>> kept;
    for (auto r : H.fills[indicator]) {
        if (r.second <= from || r.first >= to) kept.push_back(r);
        else {
            if (r.first < from) kept.push_back({r.first, from});
            if (r.second > to) kept.push_back({to, r.second});
        }
    }
    H.fills[indicator] = kept;
}

static void notify(unsigned code, int ch = 0, intptr_t position = 0, int modType = 0, int updated = 0, const char *text = nullptr);

static intptr_t sendMessage(uintptr_t handle, uint32_t msg, uintptr_t w, intptr_t l) {
    if (handle == kNpp) {
        switch (msg) {
            case NPPM_GETCURRENTSCINTILLA: *(int *)l = 0; return 0;
            case NPPM_GETCURRENTBUFFERID: return 1;
            case NPPM_GETFULLCURRENTPATH: std::strncpy((char *)l, H.path.c_str(), 1023); return 0;
            case NPPM_GETPLUGINSCONFIGDIR: std::strncpy((char *)l, H.configDir.c_str(), 1023); return (intptr_t)H.configDir.size();
            case NPPM_ALLOCATEINDICATOR: *(int *)l = 9; return w == 7;
            case NPPM_SETMENUITEMCHECK: H.checks[w] = l; return 1;
            case NPPM_ISDARKMODEENABLED: return 0;
            case NPPM_DMM_REGISTERPANEL: H.panelView = (__bridge NSView *)(void *)w; return 1;
            case NPPM_DMM_SHOWPANEL:
                if (!H.panelWindow) {
                    H.panelWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 440)
                                                                styleMask:NSWindowStyleMaskTitled
                                                                  backing:NSBackingStoreBuffered
                                                                    defer:YES];
                    H.panelWindow.releasedWhenClosed = NO;
                }
                H.panelWindow.contentView = H.panelView;
                return 1;
            case NPPM_DMM_HIDEPANEL: H.panelWindow.contentView = [[NSView alloc] init]; return 1;
            case NPPM_DMM_UNREGISTERPANEL: return 1;
            case NPPM_ADDTOOLBARICON_FORDARKMODE: H.toolbar.push_back({w, l ? (const char *)l : ""}); return 1;
            case NPPM_DOOPEN: {  // as the host: the file becomes the active document a moment later
                std::string file = l ? (const char *)l : "";
                H.opened.push_back(file);
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSData *data = [NSData dataWithContentsOfFile:@(file.c_str())];
                    H.doc = data ? std::string((const char *)data.bytes, data.length) : std::string();
                    H.path = file;
                    H.pos = 0;
                    notify(NPPN_BUFFERACTIVATED);
                    notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
                });
                return 1;
            }
            case NPPM_GETNBOPENFILES: return (intptr_t)H.openFiles.size() + (H.path.empty() ? 0 : 1);
            case NPPM_GETOPENFILENAMES: {
                char **files = (char **)w;
                std::vector<std::string> all = H.openFiles;
                if (!H.path.empty()) all.insert(all.begin(), H.path);
                intptr_t n = 0;
                for (; n < l && n < (intptr_t)all.size(); ++n) std::strncpy(files[n], all[(size_t)n].c_str(), 1023);
                return n;
            }
        }
    } else if (handle == kSciMain || handle == kSciSecond) {
        switch (msg) {
            case SCI_GETLENGTH: return (intptr_t)H.doc.size();
            case SCI_GETCHARACTERPOINTER: return (intptr_t)H.doc.c_str();
            case SCI_GETCODEPAGE: return SC_CP_UTF8;
            case SCI_GETEOLMODE: return SC_EOL_LF;
            case SCI_INDICSETSTYLE: case SCI_INDICSETFORE: case SCI_INDICSETUNDER: return 0;
            case SCI_GETINDICATORCURRENT: return H.indicatorCurrent;
            case SCI_SETINDICATORCURRENT: H.indicatorCurrent = (int)w; return 0;
            case SCI_INDICATORCLEARRANGE: clearFills(H.indicatorCurrent, (intptr_t)w, (intptr_t)w + l); return 0;
            case SCI_INDICATORFILLRANGE: H.fills[H.indicatorCurrent].push_back({(intptr_t)w, (intptr_t)w + l}); return 0;
            case SCI_CALLTIPSHOW: H.tip = (const char *)l; return 0;
            case SCI_CALLTIPCANCEL: H.tip.clear(); return 0;
            case SCI_GETCURRENTPOS: return H.pos;
            case SCI_GOTOPOS: H.pos = (intptr_t)w; return 0;
            case SCI_SETSEL: H.pos = l; return 0;
            case SCI_GETSELECTIONSTART: return H.selStart < 0 ? H.pos : H.selStart;
            case SCI_GETSELECTIONEND: return H.selEnd < 0 ? H.pos : H.selEnd;
            case SCI_SCROLLCARET: return 0;
            case SCI_ENSUREVISIBLEENFORCEPOLICY: return 0;
            case SCI_GRABFOCUS: return 0;
            case SCI_GETREADONLY: return 0;
            case SCI_BEGINUNDOACTION: ++H.undoDepth; ++H.undoActions; return 0;
            case SCI_ENDUNDOACTION: --H.undoDepth; return 0;
            case SCI_SETTARGETRANGE: H.targetStart = (intptr_t)w; H.targetEnd = l; return 0;
            case SCI_TARGETWHOLEDOCUMENT: H.targetStart = 0; H.targetEnd = (intptr_t)H.doc.size(); return 0;
            case SCI_REPLACETARGET: {
                std::string text((const char *)l, w);
                H.doc.replace((size_t)H.targetStart, (size_t)(H.targetEnd - H.targetStart), text);
                intptr_t delta = (intptr_t)text.size() - (H.targetEnd - H.targetStart);
                if (H.pos >= H.targetEnd) H.pos += delta;  // Scintilla keeps the caret after the edit
                else if (H.pos > H.targetStart) H.pos = H.targetStart + (intptr_t)text.size();
                return (intptr_t)w;
            }
            case SCI_SETMOUSEDWELLTIME: H.dwell[handle] = (intptr_t)w; return 0;
            case SCI_GETFIRSTVISIBLELINE: return 0;
            case SCI_SETFIRSTVISIBLELINE: return 0;
            case SCI_LINESONSCREEN: return 40;
            case SCI_DOCLINEFROMVISIBLE: return (intptr_t)w;
            case SCI_POSITIONFROMLINE: return lineStart((intptr_t)w);
            case SCI_GETLINEENDPOSITION: {
                intptr_t p = lineStart((intptr_t)w);
                while (p < (intptr_t)H.doc.size() && H.doc[(size_t)p] != '\n') ++p;
                return p;
            }
            case SCI_LINEFROMPOSITION: return lineOf((intptr_t)w);
            case SCI_AUTOCSETSEPARATOR: H.acSeparator = (char)w; return 0;
            case SCI_AUTOCSETIGNORECASE: return 0;
            case SCI_AUTOCSHOW: H.acActive = true; H.acEntered = (intptr_t)w; H.acList = (const char *)l; ++H.acShows; return 0;
            case SCI_AUTOCCANCEL: H.acActive = false; ++H.acCancels; return 0;
            case SCI_AUTOCACTIVE: return H.acActive;
        }
    }
    H.unknown.push_back(msg);
    return 0;
}

// Network senders for the Monitor tests: what WSJT-X, N1MM or GridTracker would send.
static void sendUdp(int port, const std::string &bytes) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    sockaddr_in a{};
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sendto(fd, bytes.data(), bytes.size(), 0, (sockaddr *)&a, sizeof a);
    close(fd);
}
static bool sendTcp(int port, const std::string &bytes) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in a{};
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bool ok = connect(fd, (sockaddr *)&a, sizeof a) == 0 && send(fd, bytes.data(), bytes.size(), 0) == (ssize_t)bytes.size();
    close(fd);
    return ok;
}
// WSJT-X's NetworkMessage.hpp layout: big endian, utf8 = length + bytes, QDateTime = Julian day, ms, timespec.
static void bigEndian(std::string &o, uint64_t v, int n) {
    for (int i = n - 1; i >= 0; --i) o.push_back((char)((v >> (8 * i)) & 0xff));
}
static std::string qString(const std::string &s) {
    std::string o;
    bigEndian(o, s.size(), 4);
    return o + s;
}
static std::string wsjtxMessage(uint32_t type) {
    std::string o;
    bigEndian(o, 0xadbccbda, 4);
    bigEndian(o, 3, 4);
    bigEndian(o, type, 4);
    return o + qString("WSJT-X");
}
static std::string qDateTime(uint32_t ms) {  // 2026-10-09 (Julian day 2461323), UTC
    std::string o;
    bigEndian(o, 2461323, 8);
    bigEndian(o, ms, 4);
    bigEndian(o, 1, 1);
    return o;
}
static std::string wsjtxQsoLogged(const std::string &call, const std::string &mode, uint64_t hz, uint32_t onMs) {
    std::string o = wsjtxMessage(5) + qDateTime(onMs + 60000) + qString(call) + qString("FN31");
    bigEndian(o, hz, 8);
    o += qString(mode) + qString("-10") + qString("-12") + qString("30") + qString("") + qString("");
    o += qDateTime(onMs) + qString("") + qString("KW9D") + qString("EN52") + qString("") + qString("") + qString("");
    return o;
}
static std::string fileText(const std::string &path) {
    NSData *d = [NSData dataWithContentsOfFile:@(path.c_str())];
    return d ? std::string((const char *)d.bytes, d.length) : std::string();
}

static void pump(double seconds) {
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static PBENOTIFIED gNotify;

static void notify(unsigned code, int ch, intptr_t position, int modType, int updated, const char *text) {
    SCNotification n{};
    n.nmhdr.code = code;
    n.ch = ch;
    n.position = position;
    n.modificationType = modType;
    n.updated = updated;
    n.text = text;
    gNotify(&n);
}

// Type one character at the caret as Scintilla would: insert, SCN_MODIFIED, SCN_CHARADDED.
static void type(char c) {
    H.doc.insert((size_t)H.pos, 1, c);
    ++H.pos;
    notify(SCN_MODIFIED, 0, H.pos - 1, SC_MOD_INSERTTEXT);
    notify(SCN_CHARADDED, (unsigned char)c);
}

static void typeString(const char *s) {
    for (; *s; ++s) {
        type(*s);
        pump(0.01);
    }
}

static bool filledAt(int indicator, intptr_t pos) {
    for (auto r : H.fills[indicator])
        if (r.first <= pos && pos < r.second) return true;
    return false;
}

static size_t countFills(int indicator) { return H.fills[indicator].size(); }

static bool listHas(const char *item) {
    std::string sep(1, H.acSeparator), hay = sep + H.acList + sep, needle = sep + item + sep;
    return hay.find(needle) != std::string::npos;
}

static NSTableView *findTable(NSView *v) {
    if ([v isKindOfClass:NSTableView.class]) return (NSTableView *)v;
    for (NSView *s in v.subviews)
        if (NSTableView *t = findTable(s)) return t;
    return nil;
}

static NSString *findTitle(NSView *v) {
    for (NSView *s in v.subviews)
        if ([s isKindOfClass:NSTextField.class] && ((NSTextField *)s).font.pointSize > NSFont.smallSystemFontSize &&
            !((NSTextField *)s).editable)
            return ((NSTextField *)s).stringValue;
    return @"";
}

static NSString *cell(NSTableView *t, NSInteger row, NSString *column) {
    NSTableColumn *col = [t tableColumnWithIdentifier:column];
    NSView *v = [t.delegate tableView:t viewForTableColumn:col row:row];
    return [v isKindOfClass:NSTextField.class] ? ((NSTextField *)v).stringValue : @"";
}

static NSGridView *findGrid(NSView *v) {
    if ([v isKindOfClass:NSGridView.class]) return (NSGridView *)v;
    for (NSView *s in v.subviews)
        if (NSGridView *g = findGrid(s)) return g;
    return nil;
}

static NSButton *findButton(NSView *v, NSString *title) {
    if ([v isKindOfClass:NSButton.class] && [((NSButton *)v).title isEqualToString:title]) return (NSButton *)v;
    for (NSView *s in v.subviews)
        if (NSButton *b = findButton(s, title)) return b;
    return nil;
}

static NSTextField *summaryLabel(NSView *v) {  // the wrapping label under the grid
    for (NSView *s in v.subviews)
        if ([s isKindOfClass:NSTextField.class] && !((NSTextField *)s).editable && ((NSTextField *)s).maximumNumberOfLines == 4)
            return (NSTextField *)s;
    return nil;
}

// The New QSO window's control for a field.
static NSTextField *qsoControl(NSWindow *w, NSString *name) {
    NSGridView *grid = findGrid(w.contentView);
    for (NSInteger r = 0; r < grid.numberOfRows; ++r) {
        NSTextField *label = (NSTextField *)[grid cellAtColumnIndex:0 rowIndex:r].contentView;
        if ([label.stringValue isEqualToString:name]) return (NSTextField *)[grid cellAtColumnIndex:1 rowIndex:r].contentView;
    }
    return nil;
}

static NSWindow *qsoWindow() {
    for (NSWindow *w in NSApp.windows)
        if ([w.title isEqualToString:@"New QSO"]) return w;
    return nil;
}

static void collect(NSView *v, Class cls, NSMutableArray *out);

static NSView *viewWithIdentifier(NSView *v, NSString *ident);

// The New QSO "Look up:" row (label and popup) and the line under it.
static NSStackView *lookupRow(NSWindow *w) {
    NSMutableArray *stacks = [NSMutableArray array];
    collect(w.contentView, NSStackView.class, stacks);
    for (NSStackView *s in stacks) {
        NSArray *v = s.arrangedSubviews;
        if (v.count >= 2 && [v[0] isKindOfClass:NSTextField.class] && [((NSTextField *)v[0]).stringValue isEqualToString:@"Look up:"])
            return s;
    }
    return nil;
}
static std::string lookupInfo(NSWindow *w) {
    NSTextField *f = (NSTextField *)viewWithIdentifier(w.contentView, @"qso.lookupInfo");
    return f ? std::string(f.stringValue.UTF8String) : std::string("(no lookup line)");
}

static std::string utcDate() {
    time_t now = time(nullptr);
    struct tm t;
    gmtime_r(&now, &t);
    char b[16];
    strftime(b, sizeof b, "%Y%m%d", &t);
    return b;
}

static NSWindow *windowTitled(NSString *title) {
    for (NSWindow *w in NSApp.windows)
        if ([w.title isEqualToString:title]) return w;
    return nil;
}

// The popup offering `item` (a window can have several).
static NSPopUpButton *findPopupWith(NSView *v, NSString *item) {
    if ([v isKindOfClass:NSPopUpButton.class] && [(NSPopUpButton *)v itemWithTitle:item]) return (NSPopUpButton *)v;
    for (NSView *s in v.subviews)
        if (NSPopUpButton *p = findPopupWith(s, item)) return p;
    return nil;
}

static NSPopUpButton *findPopup(NSView *v) {
    if ([v isKindOfClass:NSPopUpButton.class]) return (NSPopUpButton *)v;
    for (NSView *s in v.subviews)
        if (NSPopUpButton *p = findPopup(s)) return p;
    return nil;
}

// A visible label containing `text`, or nil.
static NSString *labelContaining(NSView *v, NSString *text) {
    if (v.hidden) return nil;
    if ([v isKindOfClass:NSTextField.class] && [((NSTextField *)v).stringValue containsString:text]) return ((NSTextField *)v).stringValue;
    for (NSView *s in v.subviews)
        if (NSString *found = labelContaining(s, text)) return found;
    return nil;
}

static NSString *labelWithLines(NSView *v, NSInteger lines) {  // the status label (wrapping, N lines)
    for (NSView *s in v.subviews)
        if ([s isKindOfClass:NSTextField.class] && !((NSTextField *)s).editable && ((NSTextField *)s).maximumNumberOfLines == lines)
            return ((NSTextField *)s).stringValue;
    return @"";
}

// The review table as "record CALL FIELD=value" strings.
static std::vector<std::string> reviewRows(NSTableView *t) {
    std::vector<std::string> out;
    NSInteger n = [t.dataSource numberOfRowsInTableView:t];
    for (NSInteger r = 0; r < n; ++r) {
        auto text = [&](NSString *col) {
            NSView *v = [t.delegate tableView:t viewForTableColumn:[t tableColumnWithIdentifier:col] row:r];
            return std::string(((NSTextField *)v).stringValue.UTF8String);
        };
        out.push_back(text(@"record") + " " + text(@"call") + " " + text(@"field") + "=" + text(@"value"));
    }
    return out;
}

static bool hasRow(const std::vector<std::string> &rows, const std::string &row) {
    return std::find(rows.begin(), rows.end(), row) != rows.end();
}

static void waitForStatus(NSWindow *w, NSString *needle, double seconds) {
    for (int i = 0; i < (int)(seconds / 0.05) && ![labelWithLines(w.contentView, 3) containsString:needle]; ++i) pump(0.05);
}

static void collect(NSView *v, Class cls, NSMutableArray *out) {
    if ([v isKindOfClass:cls]) [out addObject:v];
    for (NSView *s in v.subviews) collect(s, cls, out);
}

// The Settings window's controls for a source (sections are identified "settings.source.N").
struct SettingsRow {
    NSTextField *user = nil;
    NSSecureTextField *secret = nil;
    NSTextField *status = nil;
    NSTextField *title = nil;
    NSView *box = nil;
};
static NSView *viewWithIdentifier(NSView *v, NSString *ident) {
    if ([v.identifier isEqualToString:ident]) return v;
    for (NSView *s in v.subviews)
        if (NSView *f = viewWithIdentifier(s, ident)) return f;
    return nil;
}
static SettingsRow settingsRow(NSWindow *w, NSInteger source) {
    SettingsRow r;
    r.box = viewWithIdentifier(w.contentView, [NSString stringWithFormat:@"settings.source.%ld", (long)source]);
    if (!r.box) return r;
    NSMutableArray *fields = [NSMutableArray array];
    collect(r.box, NSTextField.class, fields);
    for (NSTextField *f in fields) {
        if ([f isKindOfClass:NSSecureTextField.class]) r.secret = (NSSecureTextField *)f;
        else if (f.editable && !r.user) r.user = f;
        else if (!f.editable && !r.title) r.title = f;  // the first label is the section title
        else if (!f.editable) r.status = f;             // the last label is the status
    }
    return r;
}

// With ADIFLINT_SNAPSHOT_DIR set, save a window as a PNG (dark appearance, like
// the user's setup) so its layout can be looked at without the real editor.
static void snapshot(NSWindow *w, const char *name) {
    const char *dir = getenv("ADIFLINT_SNAPSHOT_DIR");
    if (!dir || !w) return;
    w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSView *v = w.contentView;
    [v layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    // The window background is drawn by the window frame, not the content view:
    // compose the content over a dark-mode window colour so light text shows.
    NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:rep.pixelsWide
                                                                    pixelsHigh:rep.pixelsHigh
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSCalibratedRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    out.size = rep.size;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:out]];
    [[NSColor colorWithCalibratedRed:0.17 green:0.17 blue:0.18 alpha:1] setFill];
    NSRectFill(NSMakeRect(0, 0, rep.size.width, rep.size.height));
    [rep drawInRect:NSMakeRect(0, 0, rep.size.width, rep.size.height)
           fromRect:NSZeroRect
          operation:NSCompositingOperationSourceOver
           fraction:1
     respectFlipped:NO
              hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [out representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:[NSString stringWithFormat:@"%s/%s.png", dir, name] atomically:YES];
}

// A view's area in window coordinates, clipped by the scroll views it is in:
// table rows scrolled out of sight are hidden, not overlapping.
static NSRect visibleInWindow(NSView *v) {
    NSRect r = [v convertRect:v.bounds toView:nil];
    for (NSView *p = v.superview; p; p = p.superview)
        if ([p isKindOfClass:NSClipView.class]) r = NSIntersectionRect(r, [p convertRect:p.bounds toView:nil]);
    return r;
}

// Overlapping controls are the symptom of a broken layout: no two sibling
// controls in a window may intersect.
static int overlaps(NSView *root) {
    NSMutableArray *controls = [NSMutableArray array];
    collect(root, NSControl.class, controls);
    int n = 0;
    for (NSUInteger i = 0; i < controls.count; ++i)
        for (NSUInteger j = i + 1; j < controls.count; ++j) {
            NSView *a = controls[i], *b = controls[j];
            if (a.hidden || b.hidden || [a isDescendantOf:b] || [b isDescendantOf:a]) continue;
            // Overlay scroll bars are drawn over their content by design.
            if ([a isKindOfClass:NSScroller.class] || [b isKindOfClass:NSScroller.class]) continue;
            if (!a.window || a.superview.hidden || b.superview.hidden) continue;
            NSRect ra = visibleInWindow(a), rb = visibleInWindow(b);
            if (NSIsEmptyRect(ra) || NSIsEmptyRect(rb)) continue;
            if (NSWidth(NSIntersectionRect(ra, rb)) > 1 && NSHeight(NSIntersectionRect(ra, rb)) > 1) {
                ++n;
                if (getenv("ADIFLINT_DEBUG_OVERLAPS"))
                    std::printf("  overlap: %s %s / %s %s\n", NSStringFromClass([a class]).UTF8String, NSStringFromRect(ra).UTF8String,
                                NSStringFromClass([b class]).UTF8String, NSStringFromRect(rb).UTF8String);
            }
        }
    return n;
}

static std::vector<std::string> qsoRowNames(NSWindow *w) {
    std::vector<std::string> out;
    NSGridView *grid = findGrid(w.contentView);
    for (NSInteger r = 0; r < grid.numberOfRows; ++r)
        out.push_back(((NSTextField *)[grid cellAtColumnIndex:0 rowIndex:r].contentView).stringValue.UTF8String);
    return out;
}

static NSInteger tableRowNamed(NSTableView *t, NSString *name) {
    NSInteger n = [t.dataSource numberOfRowsInTableView:t];
    for (NSInteger r = 0; r < n; ++r) {
        NSView *v = [t.delegate tableView:t viewForTableColumn:[t tableColumnWithIdentifier:@"name"] row:r];
        if ([((NSTextField *)v).stringValue isEqualToString:name]) return r;
    }
    return -1;
}

static bool contains(const std::vector<std::string> &v, const char *x) { return std::find(v.begin(), v.end(), x) != v.end(); }

int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // Keep test windows (New QSO) from taking focus on the desktop.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (argc < 3) {
            std::fprintf(stderr, "usage: host_harness ADIFLint.dylib LOOKUP_FIXTURE_DIR\n");
            return 2;
        }
        setenv("ADIFLINT_FAKE_LOOKUP_DIR", argv[2], 1);  // lookups read fixtures, never the network
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        NSString *tqslDir = [tmp stringByAppendingPathComponent:@"tqsl-data"];  // never the developer's own TQSL data
        setenv("ADIFLINT_TEST_TQSL_DIR", tqslDir.UTF8String, 1);
        [[NSFileManager defaultManager] createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
        H.configDir = tmp.UTF8String;

        void *lib = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
        if (!lib) {
            std::printf("FAIL dlopen: %s\n", dlerror());
            return 1;
        }
        auto setInfo = (PFUNCSETINFO)dlsym(lib, "setInfo");
        auto getName = (PFUNCGETNAME)dlsym(lib, "getName");
        auto getFuncsArray = (PFUNCGETFUNCSARRAY)dlsym(lib, "getFuncsArray");
        gNotify = (PBENOTIFIED)dlsym(lib, "beNotified");
        auto messageProc = (PMESSAGEPROC)dlsym(lib, "messageProc");
        CHECK(setInfo && getName && getFuncsArray && gNotify && messageProc, "all five exports resolve");
        if (gFailures) return 1;

        // A header and one record whose CALL length is wrong (4, data is 6 bytes).
        H.doc = "test\n<ADIF_VER:5>3.1.7\n<EOH>\n"
                "<QSO_DATE:8>20240115 <TIME_ON:4>1830 <CALL:4>VE3AAA <BAND:3>20m <MODE:2>CW <EOR>\n";
        const intptr_t callTag = (intptr_t)H.doc.find("<CALL:4>");

        NppData data{kNpp, kSciMain, kSciSecond, sendMessage};
        setInfo(data);
        CHECK(std::strcmp(getName(), "ADIF Lint") == 0, "plugin name: %s", getName());
        int n = 0;
        FuncItem *items = getFuncsArray(&n);
        CHECK(n == 34, "34 menu entries (28 commands, 6 separators), got %d", n);
        std::map<std::string, FuncItem *> byName;
        int nextId = 22000;
        for (int i = 0; i < n; ++i) {
            if (items[i]._pFunc) items[i]._cmdID = nextId++;  // as the host does
            byName[items[i]._itemName] = &items[i];
            CHECK(items[i]._pShKey == nullptr, "no default shortcuts (host ignores them)");
        }
        auto runItem = [&](const char *name) {
            FuncItem *f = byName.count(name) ? byName[name] : nullptr;
            CHECK(f && f->_pFunc, "menu item %s exists", name);
            if (f && f->_pFunc) f->_pFunc();
        };
        // Windows reached through Import..., Export..., Upload... and Enrich...: the menu
        // item opens the one used last, and its popup switches (the way a user gets there).
        struct Hub {
            const char *old, *menu;
            NSString *item;
        };
        // An item only that family's popup has (Import and Upload both offer eQSL).
        auto marker = [](const char *menu) {
            return !std::strcmp(menu, "Import...") ? @"CSV file" : !std::strcmp(menu, "Export...") ? @"Cabrillo"
                   : !std::strcmp(menu, "Upload...") ? @"Club Log" : @"HamQTH";
        };
        static const Hub kHubs[] = {
            {"Import from LoTW...", "Import...", @"LoTW"},
            {"Import from QRZ.com Logbook...", "Import...", @"QRZ.com Logbook"},
            {"Import from eQSL...", "Import...", @"eQSL"},
            {"Import CSV...", "Import...", @"CSV file"},
            {"Import WSJT-X Log...", "Import...", @"WSJT-X log file"},
            {"Export Activation Logs...", "Export...", @"Activation logs (POTA, WWFF, SOTA)"},
            {"Export CSV...", "Export...", @"CSV"},
            {"Export Cabrillo...", "Export...", @"Cabrillo"},
            {"Print QSL Labels...", "Export...", @"QSL labels (PDF)"},
            {"Upload to QRZ.com Logbook...", "QSL Sync (Upload, Confirmations)...", @"QRZ.com Logbook"},
            {"Upload to LoTW (TQSL)...", "QSL Sync (Upload, Confirmations)...", @"LoTW (TQSL)"},
            {"Upload to Club Log...", "QSL Sync (Upload, Confirmations)...", @"Club Log"},
            {"Upload to eQSL...", "QSL Sync (Upload, Confirmations)...", @"eQSL"},
            {"Enrich from QRZ.com...", "Enrich...", @"QRZ.com"},
            {"Enrich from HamQTH...", "Enrich...", @"HamQTH"},
            {"Enrich from Country Data...", "Enrich...", @"Country Data (offline)"},
        };
        auto run = [&](const char *name) {
            for (const Hub &hub : kHubs) {
                if (std::strcmp(hub.old, name) != 0) continue;
                if (!std::strcmp(hub.menu, "QSL Sync (Upload, Confirmations)...")) {  // the service's row, then Upload...
                    runItem(hub.menu);
                    pump(0.05);
                    NSWindow *qw = windowTitled(@"QSL Sync");
                    NSTableView *qt = qw ? findTable(qw.contentView) : nil;
                    NSInteger row = -1;
                    for (NSInteger i = 0; qt && i < [qt.dataSource numberOfRowsInTableView:qt]; ++i)
                        if ([cell(qt, i, @"0") isEqualToString:hub.item]) row = i;
                    CHECK(row >= 0, "%s: QSL Sync lists %s", name, hub.item.UTF8String);
                    if (row >= 0) {
                        [qt selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
                        NSButton *upload = findButton(qw.contentView, @"Upload...");
                        CHECK(upload.enabled, "%s: Upload... is enabled for the selected service", name);
                        [upload performClick:nil];
                        pump(0.05);
                    }
                    [qw orderOut:nil];
                    return;
                }
                runItem(hub.menu);
                pump(0.05);
                NSPopUpButton *p = nil;
                for (NSWindow *w in NSApp.windows) {  // orderedWindows leaves out panels
                    NSPopUpButton *x = w.visible ? findPopupWith(w.contentView, marker(hub.menu)) : nil;
                    if (x && [x itemWithTitle:hub.item]) p = x;
                    if (p && w.isKeyWindow) break;
                }
                CHECK(p != nil, "%s: the %s window offers %s", name, hub.menu, hub.item.UTF8String);
                if (p && ![p.titleOfSelectedItem isEqualToString:hub.item]) {
                    [p selectItemWithTitle:hub.item];
                    [p sendAction:p.action to:p.target];
                    pump(0.05);
                }
                if (!std::strcmp(name, "Export CSV...")) {  // the window, then its Save button
                    NSWindow *cw = nil;
                    for (NSWindow *w in NSApp.windows)
                        if (w.visible && [w.title isEqualToString:@"Export CSV"]) cw = w;
                    [cw.contentView layoutSubtreeIfNeeded];
                    snapshot(cw, "export-csv");
                    CHECK(cw && overlaps(cw.contentView) == 0, "Export CSV does not overlap");
                    [findButton(cw.contentView, @"Save CSV...") performClick:nil];
                    [cw orderOut:nil];
                }
                return;
            }
            runItem(name);
        };
        // Check Log's headline (it replaced Validate Now): "No problems found." or the counts.
        auto checkLogHeadline = [&]() -> std::string {
            run("Check Log...");
            NSWindow *w = nil;
            for (NSWindow *x in NSApp.windows)
                if ([x.title isEqualToString:@"Check Log"]) w = x;
            std::string h = w ? std::string(labelWithLines(w.contentView, 2).UTF8String ?: "") : "";
            [w orderOut:nil];
            return h;
        };
        auto noErrors = [&](std::string *h) {
            *h = checkLogHeadline();
            return *h == "No problems found." || h->rfind("0 errors", 0) == 0;
        };
        auto noWarnings = [&](std::string *h) {
            *h = checkLogHeadline();
            return *h == "No problems found." || h->rfind("0 errors, 0 warnings", 0) == 0;
        };
        for (const char *name : {"New QSO...", "Spots (POTA, WWFF, More)...", "Start Activation...", "Log Table...", "Check Log...", "Fix Lengths", "Next Problem",
                                 "Previous Problem", "Bulk Edit...", "Time Shift...", "Sort and Organize...", "Remove Duplicates...",
                                 "Compare and Merge Logs...", "Log Summary...", "Activation Tracker (POTA, WWFF, SOTA)...", "Worked Before...", "Map (Grids, DXCC, Parks)...",
                                 "Import...", "Export...", "QSL Sync (Upload, Confirmations)...", "Enrich...", "Monitor (WSJT-X, N1MM, Loggers)...", "Record Panel", "Reformat: One Record per Line",
                                 "Reformat: One Field per Line", "Check .adi Files While Typing", "Settings...", "About ADIF Lint..."})
            CHECK(byName.count(name), "menu item %s", name);
        CHECK(byName.count("Check .adi Files While Typing") && byName["Check .adi Files While Typing"]->_init2Check &&
                  byName.count("Record Panel") && !byName["Record Panel"]->_init2Check,
              "default settings");

        {   // The layout check itself must catch a real overlap.
            NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled
                                                        backing:NSBackingStoreBuffered defer:YES];
            NSButton *a = [NSButton buttonWithTitle:@"A" target:nil action:nil], *b = [NSButton buttonWithTitle:@"B" target:nil action:nil];
            a.frame = NSMakeRect(10, 10, 80, 30);
            b.frame = NSMakeRect(50, 20, 80, 30);
            [w.contentView addSubview:a];
            [w.contentView addSubview:b];
            CHECK(overlaps(w.contentView) == 1, "the overlap check detects overlapping controls");
            b.frame = NSMakeRect(100, 10, 80, 30);
            CHECK(overlaps(w.contentView) == 0, "and accepts separate ones");
        }
        setenv("ADIFLINT_TEST_WELCOME", "1", 1);  // a first run: no ADIFLint.ini yet
        notify(NPPN_READY);
        unsetenv("ADIFLINT_TEST_WELCOME");
        CHECK(H.dwell[kSciMain] == 500 && H.dwell[kSciSecond] == 500, "dwell time armed on both views");
        {   // The welcome: Settings, with Your Station at the top.
            pump(0.2);
            NSWindow *sw = windowTitled(@"ADIF Lint Settings");
            NSString *welcome = sw ? labelContaining(sw.contentView, @"Welcome to ADIF Lint") : nil;
            CHECK(sw.visible && welcome != nil, "first run: Settings opens with a welcome");
            if (sw) {
                [sw.contentView layoutSubtreeIfNeeded];
                snapshot(sw, "settings-welcome");
                CHECK(overlaps(sw.contentView) == 0, "Settings does not overlap (%d)", overlaps(sw.contentView));
            }
            // Your Station: saved upper case; a bad grid is refused.
            NSMutableArray *fields = [NSMutableArray array];
            collect(sw.contentView, NSTextField.class, fields);
            NSTextField *callField = nil, *gridField = nil;
            for (NSTextField *f in fields) {
                if ([f.placeholderString isEqualToString:@"e.g. KW9D"]) callField = f;
                if ([f.placeholderString isEqualToString:@"e.g. EN52"]) gridField = f;
            }
            NSButton *save = sw ? findButton(sw.contentView, @"Save") : nil;  // the first Save: Your Station's
            callField.stringValue = @"kw9d";
            gridField.stringValue = @"EN5";
            [save performClick:nil];
            CHECK(labelContaining(sw.contentView, @"Maidenhead locator") != nil, "a bad grid is refused");
            gridField.stringValue = @"en52";
            [save performClick:nil];
            NSString *ini = [NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"ADIFLint.ini"]
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
            CHECK([ini containsString:@"stationCall=KW9D\n"] && [ini containsString:@"stationGrid=EN52\n"] &&
                      [ini containsString:@"firstRunDone=1\n"],
                  "Your Station saved: %s", ini.UTF8String);
            callField.stringValue = @"";  // later tests log into logs that name their own station
            gridField.stringValue = @"";
            [save performClick:nil];
            [sw orderOut:nil];
        }
        {   // Toolbar buttons: New QSO, Log Table, Check Log, Spots, each with a light and dark icon.
            notify(NPPN_TBMODIFICATION);
            std::vector<std::string> hints;
            for (const auto &t : H.toolbar) hints.push_back(t.second);
            CHECK(hints == std::vector<std::string>({"toolbar-newqso.png", "toolbar-table.png", "toolbar-check.png", "toolbar-spots.png"}) &&
                      H.toolbar[0].first == (uintptr_t)byName["New QSO..."]->_cmdID &&
                      H.toolbar[2].first == (uintptr_t)byName["Check Log..."]->_cmdID,
                  "four toolbar buttons (%zu)", H.toolbar.size());
            NSString *fixtures = [NSURL fileURLWithPath:@(argv[2])].URLByStandardizingPath.path;  // <repo>/tests/fixtures/lookup
            NSString *root = [fixtures.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent
                stringByAppendingPathComponent:@"data/toolbar"];
            bool files = true;
            for (const std::string &h : hints) {
                NSString *png = [root stringByAppendingPathComponent:@(h.c_str())];
                NSString *dark = [[png stringByDeletingPathExtension] stringByAppendingString:@"_dark.png"];
                files &= [[NSFileManager defaultManager] fileExistsAtPath:png] && [[NSFileManager defaultManager] fileExistsAtPath:dark];
            }
            CHECK(files, "each icon has a light and a dark PNG in data/toolbar");
        }
        const int kError = 9, kName = 12, kPunct = 13, kMarker = 14, kComment = 15;

        // ── Validation and colouring after READY ──
        pump(0.4);
        CHECK(countFills(kError) == 1, "one error marked, got %zu", countFills(kError));
        if (countFills(kError) == 1) CHECK(H.fills[kError][0].first == callTag, "error marks the <CALL:4> tag");
        CHECK(filledAt(kName, callTag + 1) && filledAt(kName, callTag + 4) && !filledAt(kName, callTag + 5), "field name coloured");
        CHECK(filledAt(kPunct, callTag) && filledAt(kPunct, callTag + 6) && !filledAt(kPunct, callTag + 8), "'<' and ':4>' greyed");
        CHECK(filledAt(kMarker, (intptr_t)H.doc.find("<EOH>")) && filledAt(kMarker, (intptr_t)H.doc.find("<EOR>") + 4), "markers coloured");
        CHECK(filledAt(kComment, 0) && filledAt(kComment, 3) && !filledAt(kComment, 4), "header text coloured");
        CHECK(!filledAt(kName, callTag + 9), "data not coloured");

        // ── Hover, Next Problem, Fix Lengths ──
        notify(SCN_DWELLSTART, 0, callTag + 2);
        CHECK(H.tip.find("Error: Length 4 does not match the data 'VE3AAA'") == 0, "hover tip: %s", H.tip.c_str());
        notify(SCN_DWELLEND);
        CHECK(H.tip.empty(), "tip cancelled on dwell end");
        H.pos = 0;
        run("Next Problem");
        CHECK(H.pos == callTag, "caret moved to the problem: %ld", (long)H.pos);
        run("Fix Lengths");
        CHECK(H.doc.find("<CALL:6>VE3AAA") != std::string::npos, "length fixed");
        CHECK(H.undoDepth == 0 && H.undoActions == 1, "one balanced undo action");
        CHECK(H.tip.find("Fixed 1 data length") == 0, "fix tip: %s", H.tip.c_str());
        CHECK(countFills(kError) == 0, "no errors after fixing");

        // ── Reformat ──
        int undoBefore = H.undoActions;
        H.pos = (intptr_t)H.doc.find("VE3AAA") + 2;  // keep the caret on CALL
        run("Reformat: One Field per Line");
        const std::string fieldLayout = "test\n<ADIF_VER:5>3.1.7\n<EOH>\n\n<QSO_DATE:8>20240115\n<TIME_ON:4>1830\n<CALL:6>VE3AAA\n"
                                        "<BAND:3>20m\n<MODE:2>CW\n<EOR>\n";
        CHECK(H.doc == fieldLayout, "field-per-line layout:\n%s", H.doc.c_str());
        CHECK(H.undoActions == undoBefore + 1 && H.undoDepth == 0, "reformat is one undo step");
        CHECK(H.pos == (intptr_t)H.doc.find("VE3AAA") + 2, "caret stays on the same field");
        run("Reformat: One Record per Line");
        CHECK(H.doc.find("<QSO_DATE:8>20240115 <TIME_ON:4>1830 <CALL:6>VE3AAA <BAND:3>20m <MODE:2>CW <EOR>\n") != std::string::npos,
              "record-per-line layout:\n%s", H.doc.c_str());
        std::string saved = H.doc;
        H.doc.replace(H.doc.find("<CALL:6>"), 8, "<CALL:2>");
        notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
        run("Reformat: One Field per Line");
        CHECK(H.tip.find("Run Fix Lengths first") != std::string::npos, "reformat refuses with a wrong length: %s", H.tip.c_str());
        CHECK(H.doc.find("<CALL:2>VE3AAA <BAND") != std::string::npos, "document untouched when refused");
        H.doc = saved;
        notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
        pump(0.5);

        // ── Autocomplete: names, then values, with the length set ──
        H.pos = (intptr_t)H.doc.find("<EOR>");
        type('<');
        CHECK(!H.acActive, "list opens only after the host has handled the key");
        pump(0.05);
        CHECK(H.acActive && H.acSeparator == ' ' && listHas("BAND_RX") && listHas("EOR") && !listHas("ADIF_VER"),
              "field name list after '<'");
        const intptr_t nameStart = H.pos;
        type('B');
        H.acActive = false;  // the host's word completion replaces or closes the list here
        pump(0.05);
        CHECK(H.acActive && H.acEntered == 1, "list re-shown after the host handled 'B' (entered %ld)", (long)H.acEntered);
        int cancels = H.acCancels;
        notify(SCN_AUTOCSELECTION, 0, nameStart, 0, 0, "BAND_RX");
        CHECK(H.acCancels == cancels + 1, "selection cancelled so Scintilla does not insert it");
        pump(0.05);
        CHECK(H.doc.find("<BAND_RX:0><EOR>") != std::string::npos, "name written as <BAND_RX:0>:\n%s", H.doc.c_str());
        CHECK(H.acActive && H.acSeparator == '\n' && listHas("20m") && listHas("2m"), "value list for BAND_RX");
        const intptr_t valueStart = H.pos;
        notify(SCN_AUTOCSELECTION, 0, valueStart, 0, 0, "40m");
        pump(0.05);
        CHECK(H.doc.find("<BAND_RX:3>40m<EOR>") != std::string::npos, "value written with its length:\n%s", H.doc.c_str());
        CHECK(H.pos == (intptr_t)H.doc.find("40m<EOR>") + 3, "caret after the value");

        // Free text: the length is filled in when the caret leaves the data.
        type(' ');
        type('<');
        pump(0.05);
        intptr_t s2 = H.pos;
        notify(SCN_AUTOCSELECTION, 0, s2, 0, 0, "NAME");
        pump(0.05);
        CHECK(H.doc.find("<NAME:0>") != std::string::npos, "NAME inserted");
        CHECK(H.tip.find("NAME (String)") == 0, "hint for a free-text field: %s", H.tip.c_str());
        typeString("Bob Smith");
        type('\n');
        pump(0.1);
        CHECK(H.doc.find("<NAME:9>Bob Smith\n") != std::string::npos, "length set on Enter:\n%s", H.doc.c_str());

        // Escape ends the session: typing no longer re-shows the list.
        type('<');
        pump(0.05);
        notify(SCN_AUTOCCANCELLED);
        H.acActive = false;
        pump(0.05);
        int shows = H.acShows;
        type('X');
        pump(0.05);
        CHECK(H.acShows == shows, "no list after Escape");
        // Remove the stray "<X" and settle.
        H.doc.erase((size_t)H.pos - 2, 2);
        H.pos -= 2;
        notify(SCN_MODIFIED, 0, 0, SC_MOD_DELETETEXT);
        pump(0.6);

        // ── Record panel ──
        H.pos = (intptr_t)H.doc.find("VE3AAA");
        run("Record Panel");
        CHECK(H.panelView != nil && H.panelView.window != nil, "panel registered and shown");
        CHECK(H.checks[(uintptr_t)byName["Record Panel"]->_cmdID] == 1, "Record Panel checked");
        NSTableView *table = findTable(H.panelView);
        CHECK(table != nil, "panel has a table");
        snapshot(H.panelWindow, "record-panel");
        if (table) {
            NSInteger rows = [table.dataSource numberOfRowsInTableView:table];
            CHECK(rows == 7, "7 fields in the record, got %ld", (long)rows);
            CHECK([cell(table, 2, @"field") isEqualToString:@"CALL"] && [cell(table, 2, @"value") isEqualToString:@"VE3AAA"],
                  "CALL row: %s = %s", cell(table, 2, @"field").UTF8String, cell(table, 2, @"value").UTF8String);
            CHECK(table.selectedRow == 2, "the field under the caret is selected (%ld)", (long)table.selectedRow);
            CHECK([findTitle(H.panelView) hasPrefix:@"Record 1 of 1"], "title: %s", findTitle(H.panelView).UTF8String);

            id panel = table.dataSource;
            void (^edit)(NSInteger, NSString *) = [panel valueForKey:@"onEditValue"];
            edit(2, @"VE3AAA/P");
            pump(0.1);
            CHECK(H.doc.find("<CALL:8>VE3AAA/P") != std::string::npos, "panel edit writes the length:\n%s", H.doc.c_str());
            void (^add)(NSString *, NSString *) = [panel valueForKey:@"onAddField"];
            add(@"RST_SENT", @"599");
            pump(0.1);
            CHECK(H.doc.find("<NAME:9>Bob Smith\n<RST_SENT:3>599 <EOR>") != std::string::npos ||
                      H.doc.find("<RST_SENT:3>599") != std::string::npos,
                  "panel add:\n%s", H.doc.c_str());
            CHECK([table.dataSource numberOfRowsInTableView:table] == 8, "panel shows the new field");
            void (^remove)(NSInteger) = [panel valueForKey:@"onRemoveField"];
            remove(5);  // BAND_RX
            pump(0.1);
            CHECK(H.doc.find("BAND_RX") == std::string::npos, "panel remove:\n%s", H.doc.c_str());
            CHECK([table.dataSource numberOfRowsInTableView:table] == 7, "panel row removed");
            NSInteger callRow = -1;
            for (NSInteger r = 0; r < 7; ++r)
                if ([cell(table, r, @"field") isEqualToString:@"BAND"]) callRow = r;
            CHECK(callRow >= 0, "BAND row present");
            NSTableColumn *valueCol = [table tableColumnWithIdentifier:@"value"];
            NSView *bandCell = callRow >= 0 ? [table.delegate tableView:table viewForTableColumn:valueCol row:callRow] : nil;
            CHECK([bandCell isKindOfClass:NSComboBox.class] && ((NSComboBox *)bandCell).numberOfItems >= 30,
                  "BAND is a combo box of bands");

            // Click a heading: the rows sort; an edit still goes to its field; # brings back the record's order.
            table.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"field" ascending:YES] ];
            std::vector<std::string> names;
            for (NSInteger r = 0; r < [table.dataSource numberOfRowsInTableView:table]; ++r)
                names.push_back(cell(table, r, @"field").UTF8String);
            CHECK(names.size() == 7 && std::is_sorted(names.begin(), names.end()) && names[0] != "QSO_DATE",
                  "rows sorted by field name: %s first", names.empty() ? "" : names[0].c_str());
            NSInteger nameRow = -1;
            for (NSInteger r = 0; r < (NSInteger)names.size(); ++r)
                if (names[(size_t)r] == "NAME") nameRow = r;
            NSTextField *nameCell =
                nameRow >= 0 ? [table viewAtColumn:[table columnWithIdentifier:@"value"] row:nameRow makeIfNecessary:YES] : nil;
            CHECK([nameCell isKindOfClass:NSTextField.class] && [nameCell.stringValue isEqualToString:@"Bob Smith"],
                  "NAME's value in the sorted view: %s", nameCell.stringValue.UTF8String);
            nameCell.stringValue = @"Bob Smyth";
            [(id)panel controlTextDidEndEditing:[NSNotification notificationWithName:NSControlTextDidEndEditingNotification
                                                                              object:nameCell]];
            pump(0.2);
            CHECK(H.doc.find("<NAME:9>Bob Smyth") != std::string::npos && H.doc.find("Bob Smith") == std::string::npos,
                  "an edit in the sorted view goes to NAME:\n%s", H.doc.c_str());
            NSString *panelIni = [NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"ADIFLint.ini"]
                                                           encoding:NSUTF8StringEncoding
                                                              error:nil];
            CHECK([panelIni containsString:@"panelSort=field:a"], "the panel's sort is remembered");
            // Problem: a field with an error comes first (an unknown MODE, put back afterwards).
            NSInteger modeModel = -1;
            NSString *oldMode = nil;
            for (NSInteger r = 0; r < [table.dataSource numberOfRowsInTableView:table]; ++r)
                if ([cell(table, r, @"field") isEqualToString:@"MODE"]) {
                    modeModel = [cell(table, r, @"pos") integerValue] - 1;
                    oldMode = cell(table, r, @"value");
                }
            edit(modeModel, @"XYZ");
            pump(0.3);
            table.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"note" ascending:YES] ];
            CHECK([cell(table, 0, @"field") isEqualToString:@"MODE"] && [cell(table, 0, @"note") length] > 0,
                  "Problem: the field with an error first (%s)", cell(table, 0, @"field").UTF8String);
            edit(modeModel, oldMode);
            pump(0.3);
            table.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"pos" ascending:YES] ];
            CHECK([cell(table, 0, @"pos") isEqualToString:@"1"] && [cell(table, 2, @"field") isEqualToString:@"CALL"],
                  "# restores the record's order");

            // Moving the caret to another record updates the panel.
            H.doc += "<CALL:5>K1ABC <BAND:3>40m <EOR>\n";
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.6);
            H.pos = (intptr_t)H.doc.find("K1ABC");
            notify(SCN_UPDATEUI, 0, 0, 0, SC_UPDATE_SELECTION);
            pump(0.3);
            CHECK([findTitle(H.panelView) hasPrefix:@"Record 2 of 2"], "title after caret move: %s", findTitle(H.panelView).UTF8String);
            CHECK([table.dataSource numberOfRowsInTableView:table] == 2, "record 2 has 2 fields");
        }

        // ── Settings ──
        {
            run("Settings...");
            NSWindow *sw = windowTitled(@"ADIF Lint Settings");
            NSButton *countBox = sw ? findButton(sw.contentView, @"Count lengths in characters, not bytes (for UTF-8 logs)") : nil;
            NSButton *colourBox = sw ? findButton(sw.contentView, @"Colour ADIF syntax") : nil;
            CHECK(countBox && colourBox && countBox.state == NSControlStateValueOff && colourBox.state == NSControlStateValueOn,
                  "Settings > Editor shows the options");
            [countBox performClick:nil];
            [colourBox performClick:nil];
            CHECK(countFills(kName) == 0, "colours cleared when switched off");
            [sw orderOut:nil];
        }
        NSString *ini = [NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"ADIFLint.ini"]
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        CHECK(ini && [ini containsString:@"countCharacters=1"] && [ini containsString:@"colour=0"] &&
                  [ini containsString:@"recordPanel=1"],
              "settings saved: %s", ini.UTF8String);

        {
            std::string hl;
            CHECK(noErrors(&hl), "Check Log headline: %s", hl.c_str());
        }

        // ── New QSO ──
        run("New QSO...");
        NSWindow *qw = qsoWindow();
        CHECK(qw != nil, "New QSO window created");
        if (qw) {
            [qw.contentView layoutSubtreeIfNeeded];
            CHECK(overlaps(qw.contentView) == 0, "New QSO controls do not overlap (%d overlaps)", overlaps(qw.contentView));
            snapshot(qw, "new-qso");
            NSTextField *call = qsoControl(qw, @"CALL"), *band = qsoControl(qw, @"BAND"), *freq = qsoControl(qw, @"FREQ");
            NSTextField *date = qsoControl(qw, @"QSO_DATE"), *rst = qsoControl(qw, @"RST_SENT");
            CHECK(call && band && freq && date && rst, "core rows present");
            CHECK(call.stringValue.length == 0, "CALL starts empty");
            CHECK([band.stringValue isEqualToString:@"40m"], "BAND carried from the last record: %s", band.stringValue.UTF8String);
            CHECK([band isKindOfClass:NSComboBox.class], "BAND is a combo box");
            CHECK([date.stringValue isEqualToString:@(utcDate().c_str())] && !date.editable, "QSO_DATE is today's UTC date, filled at logging");
            NSButton *logButton = findButton(qw.contentView, @"Log QSO");
            CHECK(logButton != nil && [logButton.keyEquivalent isEqualToString:@"\r"], "Log QSO is the Return button");

            // Required fields block logging.
            std::string before = H.doc;
            [logButton performClick:nil];
            CHECK(H.doc == before, "nothing logged without CALL and MODE");
            CHECK([summaryLabel(qw.contentView).stringValue containsString:@"marked in red"], "summary asks for the fields");

            call.stringValue = @"n0call";
            freq.stringValue = @"7.074";
            qsoControl(qw, @"MODE").stringValue = @"CW";
            [logButton performClick:nil];
            pump(0.2);
            CHECK([band.stringValue isEqualToString:@"40m"], "BAND follows FREQ");
            size_t rec = H.doc.find("<CALL:6>N0CALL");
            CHECK(rec != std::string::npos, "logged with an upper-case call and its length:\n%s", H.doc.c_str());
            CHECK(H.doc.find("<FREQ:5>7.074") != std::string::npos && H.doc.find("<MODE:2>CW <RST_SENT:3>599 <RST_RCVD:3>599 <EOR>\n", rec) != std::string::npos,
                  "fields and <EOR> appended:\n%s", H.doc.substr(rec == std::string::npos ? 0 : rec).c_str());
            CHECK(H.doc.find("<QSO_DATE:8>" + utcDate(), rec) != std::string::npos, "logged with the UTC date");
            CHECK(H.pos == (intptr_t)rec, "caret on the new record");
            CHECK([summaryLabel(qw.contentView).stringValue hasPrefix:@"Logged N0CALL as record 3"], "summary: %s",
                  summaryLabel(qw.contentView).stringValue.UTF8String);
            CHECK(call.stringValue.length == 0 && [freq.stringValue isEqualToString:@"7.074"], "CALL cleared, FREQ kept");
            CHECK([rst.stringValue isEqualToString:@"599"], "RST reset to the CW default: %s", rst.stringValue.UTF8String);

            // The same contact again is logged, with a warning.
            call.stringValue = @"N0CALL";
            [logButton performClick:nil];
            pump(0.2);
            CHECK([summaryLabel(qw.contentView).stringValue containsString:@"already in this log"], "duplicate warned: %s",
                  summaryLabel(qw.contentView).stringValue.UTF8String);

            // A brand-new empty document gets a header first.
            H.doc.clear();
            H.pos = 0;
            H.path = "/tmp/new.txt";
            notify(SCN_MODIFIED, 0, 0, SC_MOD_DELETETEXT);
            run("New QSO...");
            call = qsoControl(qw, @"CALL");
            call.stringValue = @"W1AW";
            qsoControl(qw, @"BAND").stringValue = @"20m";
            qsoControl(qw, @"MODE").stringValue = @"SSB";
            [findButton(qw.contentView, @"Log QSO") performClick:nil];
            pump(0.2);
            CHECK(H.doc.rfind("ADIF log created with ADIF Lint\n<ADIF_VER:5>3.1.7\n<PROGRAMID:9>ADIF Lint\n", 0) == 0 &&
                      H.doc.find("<EOH>\n\n<CALL:4>W1AW ") != std::string::npos,
                  "new log with a header:\n%s", H.doc.c_str());
            CHECK(H.doc.find("<RST_SENT:2>59 ") != std::string::npos, "SSB report defaults to 59");

            {
                std::string hl;
                CHECK(noWarnings(&hl), "new log lints clean: %s", hl.c_str());
            }
            // ── Choosing the New QSO fields ──
            H.doc = "log\n<ADIF_VER:5>3.1.7\n<EOH>\n<CALL:5>K1ABC <QSO_DATE:8>20261006 <TIME_ON:4>2300 <BAND:3>20m "
                    "<MODE:3>SSB <STATION_CALLSIGN:4>KW9D <MY_SIG_INFO:7>US-7929 <EOR>\n";
            H.path = "/tmp/pota.adi";
            H.pos = (intptr_t)H.doc.size();
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            run("New QSO...");
            std::vector<std::string> names = qsoRowNames(qw);
            CHECK(contains(names, "MY_SIG_INFO") && contains(names, "RST_RCVD"), "automatic: the log's fields plus the core ones");
            [findButton(qw.contentView, @"Fields...") performClick:nil];
            NSWindow *fw = windowTitled(@"New QSO Fields");
            CHECK(fw != nil, "New QSO Fields window opened");
            if (fw) {
                [fw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(fw.contentView) == 0, "Fields controls do not overlap (%d overlaps)", overlaps(fw.contentView));
                snapshot(fw, "qso-fields-all");
                NSTableView *ft = findTable(fw.contentView);
                CHECK([ft.dataSource numberOfRowsInTableView:ft] == (NSInteger)names.size(), "the list starts as the window's rows");
                auto selectRow = [&](NSString *name) {
                    NSInteger r = tableRowNamed(ft, name);
                    if (r >= 0) [ft selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)r] byExtendingSelection:NO];
                    return r;
                };
                NSButton *remove = findButton(fw.contentView, @"Remove");
                selectRow(@"CALL");
                CHECK(!remove.enabled, "CALL cannot be removed");
                for (NSString *n in @[ @"MY_SIG_INFO", @"STATION_CALLSIGN", @"RST_RCVD" ]) {
                    selectRow(n);
                    CHECK(remove.enabled, "%s can be removed", n.UTF8String);
                    [remove performClick:nil];
                }
                selectRow(@"FREQ");
                [remove performClick:nil];
                selectRow(@"BAND");
                CHECK(!remove.enabled, "BAND stays when FREQ is gone");
                // Search the available fields, which carry brief descriptions.
                NSMutableArray *searches = [NSMutableArray array];
                collect(fw.contentView, NSSearchField.class, searches);
                NSSearchField *search = searches.firstObject;
                NSMutableArray *tables = [NSMutableArray array];
                collect(fw.contentView, NSTableView.class, tables);
                NSTableView *avail = tables.count > 1 ? tables[1] : nil;
                CHECK(search && avail, "search field and available list");
                auto availRows = [&]() {
                    std::vector<std::string> v;
                    NSInteger n = [avail.dataSource numberOfRowsInTableView:avail];
                    for (NSInteger r = 0; r < n; ++r) {
                        NSView *nv = [avail.delegate tableView:avail viewForTableColumn:[avail tableColumnWithIdentifier:@"name"] row:r];
                        NSView *dv = [avail.delegate tableView:avail viewForTableColumn:[avail tableColumnWithIdentifier:@"brief"] row:r];
                        v.push_back(std::string(((NSTextField *)nv).stringValue.UTF8String) + " | " +
                                    ((NSTextField *)dv).stringValue.UTF8String);
                    }
                    return v;
                };
                CHECK(availRows().size() > 100, "every addable field is listed (%zu)", availRows().size());
                auto setSearch = [&](NSString *q) {
                    search.stringValue = q;
                    [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:search];
                };
                setSearch(@"park");
                std::vector<std::string> park = availRows();
                bool potaListed = false;
                for (const std::string &r : park) potaListed |= r.rfind("POTA_REF | A comma-delimited list of one or more of the contacted station's POTA (Parks on the Air) reference(s)", 0) == 0;
                CHECK(potaListed, "search by description finds POTA_REF, with its description (%zu rows)", park.size());
                setSearch(@"sig_info");
                std::vector<std::string> sig = availRows();
                CHECK(!sig.empty() && sig[0].rfind("SIG_INFO | Information associated with the contacted station's activity", 0) == 0,
                      "SIG_INFO and its description: %s", sig.empty() ? "" : sig[0].c_str());
                NSView *typeCell = [avail.delegate tableView:avail viewForTableColumn:[avail tableColumnWithIdentifier:@"type"] row:0];
                CHECK([((NSTextField *)typeCell).stringValue isEqualToString:@"String"], "type shown");
                CHECK(((NSTextField *)typeCell).toolTip.length > 0, "full description on hover");
                setSearch(@"zzzz");
                CHECK(availRows().empty(), "no match, no rows");
                setSearch(@"sig_info");
                [avail selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
                selectRow(@"RST_SENT");  // add after this one
                [findButton(fw.contentView, @"Add to New QSO") performClick:nil];
                CHECK(tableRowNamed(ft, @"SIG_INFO") == tableRowNamed(ft, @"RST_SENT") + 1, "added after the selected field");
                bool stillAvailable = false;
                for (const std::string &r : availRows()) stillAvailable |= r.rfind("SIG_INFO |", 0) == 0;
                CHECK(!stillAvailable, "an added field leaves the available list");
                NSInteger sigRow = selectRow(@"SIG_INFO");
                [findButton(fw.contentView, @"Move Up") performClick:nil];
                CHECK(tableRowNamed(ft, @"SIG_INFO") == sigRow - 1, "Move Up");
                snapshot(fw, "qso-fields");
                [findButton(fw.contentView, @"Save") performClick:nil];
                names = qsoRowNames(qw);
                CHECK(contains(names, "SIG_INFO") && !contains(names, "MY_SIG_INFO") && !contains(names, "RST_RCVD") &&
                          !contains(names, "FREQ"),
                      "the window shows the chosen fields");
                CHECK([labelWithLines(qw.contentView, 3) containsString:@"STATION_CALLSIGN KW9D"] &&
                          [labelWithLines(qw.contentView, 3) containsString:@"MY_SIG_INFO US-7929"],
                      "hidden station fields are listed: %s", labelWithLines(qw.contentView, 3).UTF8String);
                NSString *ini2 = [NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"ADIFLint.ini"]
                                                           encoding:NSUTF8StringEncoding
                                                              error:nil];
                CHECK([ini2 containsString:@"SIG_INFO"] && [ini2 containsString:@"qsoFields=CALL,"] && ![ini2 containsString:@"RST_RCVD"],
                      "the list is saved: %s", ini2.UTF8String);
                snapshot(qw, "new-qso-custom");

                qsoControl(qw, @"CALL").stringValue = @"n1abc";
                qsoControl(qw, @"MODE").stringValue = @"SSB";
                qsoControl(qw, @"SIG_INFO").stringValue = @"US-1234";
                [findButton(qw.contentView, @"Log QSO") performClick:nil];
                pump(0.2);
                size_t rec = H.doc.find("<CALL:5>N1ABC");
                CHECK(rec != std::string::npos && H.doc.find("<SIG_INFO:7>US-1234", rec) != std::string::npos &&
                          H.doc.find("<STATION_CALLSIGN:4>KW9D <MY_SIG_INFO:7>US-7929 <EOR>", rec) != std::string::npos,
                      "hidden station fields written:\n%s", H.doc.substr(rec == std::string::npos ? 0 : rec).c_str());

                // Back to the log's own fields.
                [findButton(qw.contentView, @"Fields...") performClick:nil];
                [findButton(fw.contentView, @"Use the Log's Fields") performClick:nil];
                names = qsoRowNames(qw);
                CHECK(contains(names, "MY_SIG_INFO") && contains(names, "SIG_INFO") && contains(names, "RST_RCVD"),
                      "automatic again: the last record's fields");
                ini2 = [NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"ADIFLint.ini"]
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
                CHECK([ini2 containsString:@"qsoFields=\n"], "automatic is saved as an empty list");
            }
            [qw orderOut:nil];
        }

        // ── Enrich Log ──
        H.doc = "log\n<ADIF_VER:5>3.1.7\n<EOH>\n"
                "<CALL:5>AA7BQ <QSO_DATE:8>20261006 <TIME_ON:4>2300 <BAND:3>20m <MODE:3>SSB <EOR>\n"
                "<CALL:7>AA7BQ/P <QSO_DATE:8>20261006 <TIME_ON:4>2305 <BAND:3>20m <MODE:3>SSB <EOR>\n"
                "<CALL:5>W1XYZ <QSO_DATE:8>20261006 <TIME_ON:4>2310 <BAND:3>20m <MODE:3>SSB <EOR>\n"
                "<CALL:6>OK2CQR <QSO_DATE:8>20261006 <TIME_ON:4>2315 <BAND:3>20m <MODE:2>CW <EOR>\n";
        H.path = "/tmp/enrich.adi";
        H.pos = 0;
        notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
        pump(0.5);
        run("Enrich from QRZ.com...");
        NSWindow *ew = windowTitled(@"Enrich from QRZ.com");
        CHECK(ew != nil, "Enrich from QRZ.com window created");
        if (ew) {
            NSTableView *review = findTable(ew.contentView);
            NSButton *findData = findButton(ew.contentView, @"Find Data");
            CHECK(review && findData && findButton(ew.contentView, @"Settings..."), "window controls present");
            NSPopUpButton *sourcePopup = findPopupWith(ew.contentView, @"HamQTH");
            CHECK(sourcePopup && sourcePopup.numberOfItems == 3 && [sourcePopup.titleOfSelectedItem isEqualToString:@"QRZ.com"],
                  "Enrich from: QRZ.com, HamQTH, Country Data");
            [ew.contentView layoutSubtreeIfNeeded];
            CHECK(overlaps(ew.contentView) == 0, "Enrich controls do not overlap (%d overlaps)", overlaps(ew.contentView));
            auto choose = [&](NSInteger i) {
                const char *items[] = {"Enrich from QRZ.com...", "Enrich from HamQTH...", "Enrich from Country Data..."};
                run(items[i]);
            };

            // QRZ: missing fields for AA7BQ, the name only for AA7BQ/P, W1XYZ not found.
            choose(0);
            [findData performClick:nil];
            waitForStatus(ew, @"Untick", 3);
            std::vector<std::string> rows = reviewRows(review);
            snapshot(ew, "enrich-review");
            CHECK(hasRow(rows, "1 AA7BQ GRIDSQUARE=DM32af") && hasRow(rows, "1 AA7BQ CNTY=AZ,Maricopa") &&
                      hasRow(rows, "1 AA7BQ COUNTRY=UNITED STATES OF AMERICA") && hasRow(rows, "2 AA7BQ/P NAME=FRED L LLOYD"),
                  "QRZ proposals (%zu rows)", rows.size());
            bool portableLocation = false;
            for (const std::string &r : rows) portableLocation |= r.rfind("2 AA7BQ/P GRIDSQUARE", 0) == 0;
            CHECK(!portableLocation, "no callbook location for the portable call");
            CHECK([labelWithLines(ew.contentView, 3) containsString:@"Found 1 of 3 calls (2 not found)"], "status: %s",
                  labelWithLines(ew.contentView, 3).UTF8String);
            NSButton *apply = findButton(ew.contentView, [NSString stringWithFormat:@"Apply %zu Changes", rows.size()]);
            CHECK(apply != nil, "Apply button names the count");
            int undo = H.undoActions;
            [apply performClick:nil];
            pump(0.1);
            CHECK(H.undoActions == undo + 1, "applied as one undo step");
            CHECK(H.doc.find("<MODE:3>SSB <NAME:12>FRED L LLOYD <QTH:10>SCOTTSDALE ") != std::string::npos &&
                      H.doc.find("<GRIDSQUARE:6>DM32af") != std::string::npos && H.doc.find("<CNTY:11>AZ,Maricopa") != std::string::npos,
                  "QRZ data written with lengths:\n%s", H.doc.c_str());
            CHECK([labelWithLines(ew.contentView, 3) hasPrefix:@"Applied"], "applied status: %s", labelWithLines(ew.contentView, 3).UTF8String);
            {
                std::string hl;
                CHECK(noWarnings(&hl), "enriched log lints clean: %s", hl.c_str());
            }

            // Run again: nothing left to add.
            [findData performClick:nil];
            waitForStatus(ew, @"Nothing to add", 3);
            CHECK([labelWithLines(ew.contentView, 3) containsString:@"Nothing to add"], "second run: nothing to add");

            // HamQTH.
            choose(1);
            CHECK([ew.title isEqualToString:@"Enrich from HamQTH"] && reviewRows(review).empty(), "switched to HamQTH: %s",
                  ew.title.UTF8String);
            [findData performClick:nil];
            waitForStatus(ew, @"Untick", 3);
            rows = reviewRows(review);
            CHECK(hasRow(rows, "4 OK2CQR GRIDSQUARE=jo70gg") && hasRow(rows, "4 OK2CQR CONT=EU") &&
                      hasRow(rows, "4 OK2CQR COUNTRY=CZECH REPUBLIC"),
                  "HamQTH proposals (%zu rows)", rows.size());
            CHECK(findButton(ew.contentView, @"Untick All") != nil, "untick control");
            [findButton(ew.contentView, @"Untick All") performClick:nil];
            CHECK(findButton(ew.contentView, @"Apply Changes") != nil && !findButton(ew.contentView, @"Apply Changes").enabled,
                  "nothing ticked: Apply disabled");
            [findButton(ew.contentView, @"Tick All") performClick:nil];
            [findButton(ew.contentView, [NSString stringWithFormat:@"Apply %zu Changes", rows.size()]) performClick:nil];
            pump(0.1);
            CHECK(H.doc.find("<CONT:2>EU") != std::string::npos && H.doc.find("<GRIDSQUARE:6>jo70gg") != std::string::npos,
                  "HamQTH data written");

            // Country data: CONT is still missing for AA7BQ.
            choose(2);
            [findData performClick:nil];
            waitForStatus(ew, @"known prefix", 3);
            rows = reviewRows(review);
            CHECK(hasRow(rows, "1 AA7BQ CONT=NA"), "country proposals (%zu rows): %s", rows.size(),
                  labelWithLines(ew.contentView, 3).UTF8String);

            // An edit after Find Data: that record's changes are skipped, not misapplied.
            H.doc.replace(H.doc.find("<CALL:5>AA7BQ"), 13, "<CALL:5>AA7BX");
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            [findButton(ew.contentView, [NSString stringWithFormat:@"Apply %zu Change%@", rows.size(), rows.size() == 1 ? @"" : @"s"])
                performClick:nil];
            pump(0.1);
            CHECK([labelWithLines(ew.contentView, 3) containsString:@"Skipped"], "changed record skipped: %s",
                  labelWithLines(ew.contentView, 3).UTF8String);
            size_t bx = H.doc.find("<CALL:5>AA7BX");
            CHECK(bx != std::string::npos && H.doc.substr(bx, H.doc.find("<EOR>", bx) - bx).find("<CONT:") == std::string::npos,
                  "nothing written to the changed record");

        // ── Settings: accounts in the (test) Keychain ──
        run("Settings...");
        NSWindow *sw = windowTitled(@"ADIF Lint Settings");
        CHECK(sw != nil, "Settings window created");
        if (sw) {
            SettingsRow qrz = settingsRow(sw, 0), lotw = settingsRow(sw, 2);
            CHECK(qrz.user && qrz.secret && qrz.status && lotw.secret, "a section per source with username, password, status");
            CHECK([qrz.title.stringValue isEqualToString:@"QRZ.com"] && [settingsRow(sw, 1).title.stringValue isEqualToString:@"HamQTH"] &&
                      [lotw.title.stringValue isEqualToString:@"LoTW"],
                  "sections titled by source");
            [sw.contentView layoutSubtreeIfNeeded];
            CHECK(overlaps(sw.contentView) == 0, "Settings controls do not overlap (%d overlaps)", overlaps(sw.contentView));
            // The sections scroll when the screen is short: the last one can be scrolled into view.
            SettingsRow last = settingsRow(sw, 7);
            [last.status scrollRectToVisible:last.status.bounds];
            NSRect lastRect = visibleInWindow(last.status);
            CHECK(last.status && NSHeight(lastRect) > 0 && NSMaxY(lastRect) <= NSHeight(sw.contentView.bounds) && NSMinY(lastRect) >= 0,
                  "the last section scrolls into the window");
            NSMutableArray *scrolls = [NSMutableArray array];
            collect(sw.contentView, NSScrollView.class, scrolls);
            [((NSScrollView *)scrolls.firstObject).documentView scrollPoint:NSZeroPoint];
            snapshot(sw, "settings");
            CHECK([qrz.user.stringValue isEqualToString:@"TEST"] && qrz.secret.stringValue.length == 0 &&
                      [qrz.secret.placeholderString hasPrefix:@"Saved in your Keychain"],
                  "saved username shown, saved password never shown");
            [findButton(qrz.box, @"Remove") performClick:nil];
            CHECK([qrz.status.stringValue hasPrefix:@"Removed"] && qrz.user.stringValue.length == 0, "removed: %s",
                  qrz.status.stringValue.UTF8String);

            // Without an account, Find Data says where to add one.
            choose(0);
            [findData performClick:nil];
            pump(0.05);
            CHECK([labelWithLines(ew.contentView, 3) containsString:@"No QRZ.com account yet. Add one in Settings"],
                  "no account: %s", labelWithLines(ew.contentView, 3).UTF8String);

            run("Settings...");
            qrz.user.stringValue = @"KW9D";
            qrz.secret.stringValue = @"not-a-real-password";
            [findButton(qrz.box, @"Save") performClick:nil];
            CHECK([qrz.status.stringValue hasPrefix:@"Saved in your Keychain"] && qrz.secret.stringValue.length == 0,
                  "saved, and the password field cleared: %s", qrz.status.stringValue.UTF8String);
            [findButton(qrz.box, @"Test Sign-In") performClick:nil];
            pump(0.1);
            CHECK([qrz.status.stringValue hasPrefix:@"Signed in. QRZ.com XML subscription until"], "test sign-in: %s",
                  qrz.status.stringValue.UTF8String);
            [findButton(lotw.box, @"Test Sign-In") performClick:nil];
            pump(0.1);
            CHECK([lotw.status.stringValue hasPrefix:@"LoTW accepted the login"], "LoTW test: %s", lotw.status.stringValue.UTF8String);
            qrz.user.stringValue = @"KW9D";
            qrz.secret.stringValue = @"";
            [findButton(qrz.box, @"Save") performClick:nil];
            CHECK([qrz.status.stringValue isEqualToString:@"Enter both fields."], "both fields required: %s",
                  qrz.status.stringValue.UTF8String);
            [sw orderOut:nil];

            // With the account back, lookups work again.
            choose(0);
            [findData performClick:nil];
            waitForStatus(ew, @"Found", 3);
            CHECK([labelWithLines(ew.contentView, 3) containsString:@"Found 1 of"], "lookups after saving: %s",
                  labelWithLines(ew.contentView, 3).UTF8String);
            [ew orderOut:nil];
        }
        }  // if (ew)

        // ── Log tools ──
        {
            NSString *outDir = [tmp stringByAppendingPathComponent:@"out"];
            [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("ADIFLINT_TEST_SAVE_DIR", outDir.UTF8String, 1);
            setenv("ADIFLINT_TEST_FOLDER", outDir.UTF8String, 1);
            auto spec = [](const char *name, const std::string &v) { return "<" + std::string(name) + ":" + std::to_string(v.size()) + ">" + v + " "; };
            auto rec = [&](const char *call, const char *time) {
                return spec("CALL", call) + spec("QSO_DATE", "20261006") + spec("TIME_ON", time) + spec("BAND", "20m") +
                       spec("MODE", "SSB") + spec("STATION_CALLSIGN", "KW9D") + spec("MY_SIG", "POTA") +
                       spec("MY_SIG_INFO", "US-7929") + "<EOR>\n";
            };
            // An activation logged out of order, with K1AC twice.
            H.doc = "log\n<ADIF_VER:5>3.1.7\n<EOH>\n" + rec("K1AA", "2210") + rec("K1AB", "2200") + rec("K1AC", "2205") +
                    rec("K1AC", "2206") + rec("K1AD", "2215") + rec("K1AE", "2220") + rec("K1AF", "2225") + rec("K1AG", "2230") +
                    rec("K1AH", "2235") + rec("K1AI", "2238") + rec("K1AJ", "2240");
            H.path = "/tmp/US-7929.adi";
            H.pos = 0;
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.5);
            auto tableRows = [](NSTableView *t) { return t ? [t.dataSource numberOfRowsInTableView:t] : -1; };
            auto status = [](NSWindow *w) { return std::string(labelWithLines(w.contentView, 4).UTF8String); };

            // Log Table: every record, filter, sort, click to show it in the editor.
            run("Log Table...");
            NSWindow *tw = windowTitled(@"Log Table");
            NSTableView *t = tw ? findTable(tw.contentView) : nil;
            CHECK(t && tableRows(t) == 11, "Log Table lists 11 records (%ld)", (long)tableRows(t));
            if (t) {
                CHECK([t.tableColumns[0].title isEqualToString:@"#"] && [t.tableColumns[1].title isEqualToString:@"QSO_DATE"] &&
                          [t.tableColumns[3].title isEqualToString:@"CALL"],
                      "columns: #, QSO_DATE, TIME_ON, CALL...");
                NSMutableArray *searches = [NSMutableArray array];
                collect(tw.contentView, NSSearchField.class, searches);
                NSSearchField *sf = searches.firstObject;
                sf.stringValue = @"k1ac";
                [sf sendAction:sf.action to:sf.target];
                CHECK(tableRows(t) == 2, "filter K1AC: 2 rows (%ld)", (long)tableRows(t));
                sf.stringValue = @"";
                [sf sendAction:sf.action to:sf.target];
                t.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"2" ascending:YES] ];
                CHECK([cell(t, 0, @"2") isEqualToString:@"22:00"] && [cell(t, 0, @"3") isEqualToString:@"K1AB"],
                      "sorted by TIME_ON: %s", cell(t, 0, @"3").UTF8String);
                [t selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
                CHECK(H.pos == (intptr_t)H.doc.find("<CALL:4>K1AB"), "selecting a row moves the caret to its record");
                [tw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(tw.contentView) == 0, "Log Table controls do not overlap (%d)", overlaps(tw.contentView));
                snapshot(tw, "log-table");
                // Typing elsewhere must not pull the caret to the selected row, and the selection
                // stays on its record when another record is added above it.
                std::string savedDoc = H.doc;
                H.pos = 3;
                H.doc += "\n";
                notify(SCN_MODIFIED, 0, (intptr_t)H.doc.size() - 1, SC_MOD_INSERTTEXT);
                pump(1.2);
                CHECK(H.pos == 3, "a re-check leaves the caret where you typed (%ld)", (long)H.pos);
                size_t firstRec = H.doc.find("<EOH>\n") + 6;
                H.doc.insert(firstRec, "<CALL:4>W0NE <QSO_DATE:8>20261005 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <EOR>\n");
                notify(SCN_MODIFIED, 0, (intptr_t)firstRec, SC_MOD_INSERTTEXT);
                pump(1.2);
                CHECK([cell(t, t.selectedRow, @"3") isEqualToString:@"K1AB"] && H.pos == 3,
                      "the selection stays on K1AB (%s), caret unmoved", cell(t, t.selectedRow, @"3").UTF8String);
                H.doc = savedDoc;
                notify(SCN_MODIFIED, 0, 0, SC_MOD_DELETETEXT);
                pump(1.0);
            }

            // Summary.
            run("Log Summary...");
            NSWindow *sw2 = windowTitled(@"Log Summary");
            NSMutableArray *tvs = [NSMutableArray array];
            if (sw2) collect(sw2.contentView, NSTextView.class, tvs);
            NSString *report = ((NSTextView *)tvs.firstObject).string;
            CHECK([report containsString:@"Records               11"] && [report containsString:@"Parks on the Air"] &&
                      [report containsString:@"US-7929"],
                  "summary report:\n%s", report.UTF8String);
            if (sw2) {
                CHECK(overlaps(sw2.contentView) == 0, "Summary controls do not overlap");
                snapshot(sw2, "summary");
            }

            // Activation Tracker: 10 unique QSOs (the repeat doesn't count).
            run("Activation Tracker (POTA, WWFF, SOTA)...");
            NSWindow *aw = windowTitled(@"Activation Tracker");
            NSTableView *at = aw ? findTable(aw.contentView) : nil;
            CHECK(at && tableRows(at) == 1, "one park-day");
            if (at) {
                CHECK([cell(at, 0, @"3") isEqualToString:@"10"] && [cell(at, 0, @"4") isEqualToString:@"done"] &&
                          [cell(at, 0, @"6") isEqualToString:@"1"],
                      "10 QSOs, activated, 1 duplicate: %s %s %s", cell(at, 0, @"3").UTF8String, cell(at, 0, @"4").UTF8String,
                      cell(at, 0, @"6").UTF8String);
                CHECK([labelWithLines(aw.contentView, 2) containsString:@"US-7929 on 2026-10-06: 10 QSOs, activated"],
                      "headline: %s", labelWithLines(aw.contentView, 2).UTF8String);
                [aw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(aw.contentView) == 0, "Tracker controls do not overlap (%d)", overlaps(aw.contentView));
                snapshot(aw, "activation-tracker");
            }

            // Sort by date and time: one undo step.
            int undo = H.undoActions;
            run("Sort and Organize...");
            NSWindow *sow = windowTitled(@"Sort and Organize");
            NSButton *fieldsBox = sow ? findButton(sow.contentView, @"Put the fields of every record in this order:") : nil;
            if (fieldsBox.state == NSControlStateValueOn) [fieldsBox performClick:nil];
            [findButton(sow.contentView, @"Date and Time") performClick:nil];
            [findButton(sow.contentView, @"Apply") performClick:nil];
            pump(0.3);
            CHECK(sow && H.doc.find("K1AB") < H.doc.find("K1AC") && H.doc.find("K1AC") < H.doc.find("K1AA") && H.undoActions == undo + 1,
                  "sorted by the Date and Time preset:\n%s", H.doc.c_str());
            [sow orderOut:nil];
            pump(0.4);
            CHECK(tableRows(t) == 11 && [cell(t, 0, @"0") isEqualToString:@"1"], "Log Table followed the edit");

            // Remove Duplicates.
            run("Remove Duplicates...");
            NSWindow *dw = windowTitled(@"Remove Duplicates");
            NSTableView *dt = dw ? findTable(dw.contentView) : nil;
            CHECK(dt && tableRows(dt) == 1, "one duplicate set");
            NSButton *removeButton = dw ? findButton(dw.contentView, @"Remove 1 Record") : nil;
            CHECK(removeButton != nil, "Remove 1 Record button");
            if (dw) {
                [dw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(dw.contentView) == 0, "Duplicates controls do not overlap (%d)", overlaps(dw.contentView));
                snapshot(dw, "duplicates");
            }
            [removeButton performClick:nil];
            size_t first = H.doc.find("<CALL:4>K1AC");
            CHECK(first != std::string::npos && H.doc.find("<CALL:4>K1AC", first + 1) == std::string::npos &&
                      H.doc.find("<TIME_ON:4>2206") == std::string::npos,
                  "the later K1AC is gone");
            CHECK(status(dw).find("Removed 1 duplicate record") == 0, "status: %s", status(dw).c_str());

            // Bulk Edit: add MY_STATE to every record.
            run("Bulk Edit...");
            NSWindow *bw = windowTitled(@"Bulk Edit");
            CHECK(bw != nil, "Bulk Edit window");
            if (bw) {
                NSMutableArray *combos = [NSMutableArray array], *fields = [NSMutableArray array];
                collect(bw.contentView, NSComboBox.class, combos);
                collect(bw.contentView, NSTextField.class, fields);
                NSTextField *value = nil;
                NSMutableArray<NSTextField *> *shiftFields = [NSMutableArray array];
                for (NSTextField *f in fields) {
                    if ([f.placeholderString isEqualToString:@"new value"]) value = f;
                    if ([f.placeholderString isEqualToString:@"0"]) [shiftFields addObject:f];
                }
                ((NSComboBox *)combos[0]).stringValue = @"my_state";
                value.stringValue = @"KS";
                [findButton(bw.contentView, @"Preview") performClick:nil];
                NSTableView *bt = findTable(bw.contentView);
                CHECK(tableRows(bt) == 10, "10 changes previewed (%ld): %s", (long)tableRows(bt), status(bw).c_str());
                CHECK(status(bw).find("10 changes in 10 records. No new problems") == 0, "preview status: %s", status(bw).c_str());
                [bw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(bw.contentView) == 0, "Bulk Edit controls do not overlap (%d)", overlaps(bw.contentView));
                snapshot(bw, "bulk-edit");
                undo = H.undoActions;
                [findButton(bw.contentView, @"Apply 10 Changes") performClick:nil];
                size_t n = 0;
                for (size_t p = H.doc.find("<MY_STATE:2>KS <EOR>"); p != std::string::npos; p = H.doc.find("<MY_STATE:2>KS <EOR>", p + 1)) ++n;
                CHECK(n == 10 && H.undoActions == undo + 1, "MY_STATE added to 10 records in one undo step (%zu)", n);
                CHECK(status(bw).find("Applied 10 changes to 10 records") == 0, "applied: %s", status(bw).c_str());

                // Time Shift: the same window, 30 minutes later.
                run("Time Shift...");
                CHECK([bw.title isEqualToString:@"Time Shift"], "titled Time Shift");
                NSPopUpButton *convert = nil;
                NSMutableArray *pops = [NSMutableArray array];
                collect(bw.contentView, NSPopUpButton.class, pops);
                for (NSPopUpButton *pb in pops)
                    if ([pb indexOfItemWithTitle:@"By a fixed amount"] >= 0) convert = pb;
                NSComboBox *zone = nil;
                for (NSComboBox *c in combos)
                    if ([c.placeholderString isEqualToString:@"e.g. America/Chicago"]) zone = c;
                CHECK(convert && zone && [convert.titleOfSelectedItem isEqualToString:@"From local time to UTC"] &&
                          zone.stringValue.length > 0,
                      "Time Shift opens on local time to UTC, with a zone filled in");
                auto choose = [&](NSString *title) {
                    [convert selectItemWithTitle:title];
                    [convert sendAction:convert.action to:convert.target];
                };
                auto shiftOnce = [&](NSString *mode) {
                    choose(mode);
                    [findButton(bw.contentView, @"Preview") performClick:nil];
                    NSButton *ap = findButton(bw.contentView, @"Apply 10 Changes");
                    if (!ap) ap = findButton(bw.contentView, @"Apply 20 Changes");
                    [ap performClick:nil];
                };
                // Local (Central) time to UTC and back: CDT is UTC-5 in October.
                zone.stringValue = @"America/Chicago";
                [zone sendAction:zone.action to:zone.target];
                choose(@"From local time to UTC");
                [bw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(bw.contentView) == 0, "Time Shift (zone) controls do not overlap (%d)", overlaps(bw.contentView));
                snapshot(bw, "time-shift-zone");
                shiftOnce(@"From local time to UTC");
                CHECK(H.doc.find("<CALL:4>K1AB <QSO_DATE:8>20261007 <TIME_ON:4>0300") != std::string::npos,
                      "22:00 CDT on 6 Oct is 03:00 UTC on 7 Oct:\n%s", H.doc.c_str());
                shiftOnce(@"From UTC to local time");
                CHECK(H.doc.find("<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>2200") != std::string::npos, "and back to local time");
                // A time the clocks skipped and one they repeated are listed and left alone.
                std::string saved = H.doc;
                H.doc += "<CALL:4>GAPP <QSO_DATE:8>20260308 <TIME_ON:4>0230 <BAND:3>20m <MODE:3>SSB <EOR>\n"
                         "<CALL:4>REPT <QSO_DATE:8>20261101 <TIME_ON:4>0130 <BAND:3>20m <MODE:3>SSB <EOR>\n";
                notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
                pump(0.5);
                choose(@"From local time to UTC");
                [findButton(bw.contentView, @"Preview") performClick:nil];
                CHECK(status(bw).find("(GAPP): 2026-03-08 02:30 didn't happen in America/Chicago (the clocks went forward)") !=
                              std::string::npos &&
                          status(bw).find("(REPT): 2026-11-01 01:30 happened twice in America/Chicago") != std::string::npos &&
                          status(bw).find("2 records skipped") != std::string::npos,
                      "DST gaps and repeats: %s", status(bw).c_str());
                H.doc = saved;
                notify(SCN_MODIFIED, 0, 0, SC_MOD_DELETETEXT);
                pump(0.5);
                choose(@"By a fixed amount");
                if (shiftFields.count == 3) shiftFields[2].stringValue = @"30";
                [findButton(bw.contentView, @"Preview") performClick:nil];
                CHECK(tableRows(bt) == 10, "10 TIME_ON changes (%ld): %s", (long)tableRows(bt), status(bw).c_str());
                snapshot(bw, "time-shift");
                [findButton(bw.contentView, @"Apply 10 Changes") performClick:nil];
                CHECK(H.doc.find("<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>2230") != std::string::npos &&
                          H.doc.find("<TIME_ON:4>2310") != std::string::npos,
                      "times moved 30 minutes:\n%s", H.doc.c_str());
                [bw orderOut:nil];
            }

            // CSV export (the save dialog is replaced by ADIFLINT_TEST_SAVE_DIR).
            run("Export CSV...");
            NSString *csv = [NSString stringWithContentsOfFile:[outDir stringByAppendingPathComponent:@"US-7929.csv"]
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
            CHECK([csv hasPrefix:@"QSO_DATE,TIME_ON,CALL,BAND,MODE"] && [csv containsString:@"\r\n20261006,2230,K1AB,20m,SSB"],
                  "CSV saved: %s", csv.UTF8String);

            // POTA export: one file named callsign@park-date.
            run("Export Activation Logs...");
            NSWindow *pw = windowTitled(@"Export Activation Logs");
            NSTableView *pt = pw ? findTable(pw.contentView) : nil;
            CHECK(pt && tableRows(pt) == 1 && [cell(pt, 0, @"0") isEqualToString:@"KW9D@US-7929-20261006.adi"], "POTA file: %s",
                  pt ? cell(pt, 0, @"0").UTF8String : "");
            if (pw) {
                [pw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(pw.contentView) == 0, "POTA export controls do not overlap (%d)", overlaps(pw.contentView));
                snapshot(pw, "pota-export");
                NSButton *save = findButton(pw.contentView, @"Save 1 File");
                [save performClick:nil];
                NSString *potaPath = [outDir stringByAppendingPathComponent:@"KW9D@US-7929-20261006.adi"];
                NSString *pf = [NSString stringWithContentsOfFile:potaPath encoding:NSUTF8StringEncoding error:nil];
                CHECK([pf containsString:@"<CALL:4>K1AB"] && [pf containsString:@"<MY_SIG_INFO:7>US-7929"], "POTA file written");
                CHECK(status(pw).find("Saved 1 file") == 0, "saved: %s", status(pw).c_str());
                [save performClick:nil];
                CHECK(status(pw).find("Already in the folder: KW9D@US-7929-20261006.adi") == 0, "asks before replacing: %s",
                      status(pw).c_str());
                [save performClick:nil];
                CHECK(status(pw).find("Saved 1 file") == 0, "replaced on the second press: %s", status(pw).c_str());
                [pw orderOut:nil];
            }

            // Compare and Merge Logs: one QSO in both (the other has a field this one lacks), one new.
            NSString *other = [tmp stringByAppendingPathComponent:@"other.adi"];
            std::string otherText = "other\n<ADIF_VER:5>3.1.7\n<EOH>\n" + spec("CALL", "K1AB") + spec("QSO_DATE", "20261006") +
                                    spec("TIME_ON", "223030") + spec("BAND", "20m") + spec("MODE", "SSB") +
                                    spec("APP_HARNESS_NOTE", "from the other log") + "<EOR>\n" + spec("CALL", "W2XY") +
                                    spec("QSO_DATE", "20261006") + spec("TIME_ON", "2233") + spec("BAND", "20m") + spec("MODE", "SSB") +
                                    "<EOR>\n";
            [@(otherText.c_str()) writeToFile:other atomically:YES encoding:NSUTF8StringEncoding error:nil];
            setenv("ADIFLINT_TEST_OPEN_FILE", other.UTF8String, 1);
            run("Compare and Merge Logs...");
            NSWindow *mw = windowTitled(@"Compare and Merge Logs");
            CHECK(mw != nil, "Compare and Merge Logs opens");
            if (mw) {
                [findButton(mw.contentView, @"Choose...") performClick:nil];
                NSTableView *mt = findTable(mw.contentView);
                NSInteger k1ab = -1, w2xy = -1;
                for (NSInteger row = 0; row < tableRows(mt); ++row) {
                    if ([cell(mt, row, @"2") isEqualToString:@"K1AB"]) k1ab = row;
                    if ([cell(mt, row, @"2") isEqualToString:@"W2XY"]) w2xy = row;
                }
                CHECK(k1ab >= 0 && w2xy >= 0 && [cell(mt, w2xy, @"7") isEqualToString:@"only in that log"] &&
                          [cell(mt, k1ab, @"7") containsString:@"APP_HARNESS_NOTE — | from the other log"],
                      "compare: K1AB differs (%s), W2XY only there", k1ab >= 0 ? cell(mt, k1ab, @"7").UTF8String : "");
                CHECK(status(mw).find("1 QSO only there") != std::string::npos && findButton(mw.contentView, @"Apply 2") != nil,
                      "compare status: %s", status(mw).c_str());
                [mw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(mw.contentView) == 0, "Compare controls do not overlap (%d)", overlaps(mw.contentView));
                snapshot(mw, "compare");
                int undoBefore = H.undoActions;
                [findButton(mw.contentView, @"Apply 2") performClick:nil];
                size_t w2 = H.doc.find("<CALL:4>W2XY");
                CHECK(w2 != std::string::npos && w2 > H.doc.find("<TIME_ON:4>2230") && w2 < H.doc.find("<TIME_ON:4>2235") &&
                          H.doc.find("<APP_HARNESS_NOTE:18>from the other log") != std::string::npos && H.undoActions == undoBefore + 1,
                      "W2XY added and sorted into place, K1AB's field copied, one undo step:\n%s", H.doc.c_str());
                CHECK(status(mw).find("From other.adi: added 1 QSO, updated 1 record, sorted by date and time") == 0, "compare status: %s",
                      status(mw).c_str());
                [mw orderOut:nil];
            }

            // Worked Before: index the output folder (it holds the POTA file).
            run("Worked Before...");
            NSWindow *ww = windowTitled(@"Worked Before");
            if (ww) {
                [findButton(ww.contentView, @"Choose...") performClick:nil];
                for (int i = 0; i < 60 && status(ww).find("Searched") == std::string::npos; ++i) pump(0.05);
                NSMutableArray *searches = [NSMutableArray array];
                collect(ww.contentView, NSSearchField.class, searches);
                NSSearchField *callField = searches.firstObject;
                callField.stringValue = @"VE3/K1AD/P";
                [callField sendAction:callField.action to:callField.target];
                NSTableView *wt = findTable(ww.contentView);
                CHECK(tableRows(wt) == 1 && [cell(wt, 0, @"0") isEqualToString:@"KW9D@US-7929-20261006.adi"],
                      "K1AD found in the exported log (%ld): %s", (long)tableRows(wt), status(ww).c_str());
                CHECK(status(ww).find("K1AD: 1 QSO in 1 other log; last 2026-10-06 22:45 on 20m SSB") == 0, "worked status: %s",
                      status(ww).c_str());
                [ww.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(ww.contentView) == 0, "Worked Before controls do not overlap (%d)", overlaps(ww.contentView));
                snapshot(ww, "worked-before");
                [ww orderOut:nil];
            }
            // ...and New QSO mentions it.
            run("New QSO...");
            NSWindow *qw2 = qsoWindow();
            if (qw2) {
                NSTextField *callField = qsoControl(qw2, @"CALL");
                callField.stringValue = @"K1AE";
                [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:callField];
                pump(0.4);
                CHECK([summaryLabel(qw2.contentView).stringValue containsString:@"K1AE: 1 QSO in 1 other log"],
                      "New QSO shows worked before: %s", summaryLabel(qw2.contentView).stringValue.UTF8String);
                [qw2 orderOut:nil];
            }
            for (NSWindow *w in @[ tw ?: NSNull.null, sw2 ?: NSNull.null, aw ?: NSNull.null, dw ?: NSNull.null ])
                if ([w isKindOfClass:NSWindow.class]) [w orderOut:nil];
            unsetenv("ADIFLINT_TEST_SAVE_DIR");
            unsetenv("ADIFLINT_TEST_FOLDER");
            unsetenv("ADIFLINT_TEST_OPEN_FILE");
        }

        // ── POTA and WWFF spots ──
        {
            // New QSO with an SSB entry, so a CW spot must clear its SUBMODE.
            run("New QSO...");
            NSWindow *qw3 = qsoWindow();
            if (qw3) {
                qsoControl(qw3, @"MODE").stringValue = @"SSB";
                qsoControl(qw3, @"SUBMODE").stringValue = @"USB";
                [qw3.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(qw3.contentView) == 0, "New QSO does not overlap (%d)", overlaps(qw3.contentView));
            }

            // POTA spots (fixture): the malformed spot is dropped; one fills New QSO.
            run("Spots (POTA, WWFF, More)...");
            NSWindow *spw = windowTitled(@"Spots");
            NSTableView *spt = spw ? findTable(spw.contentView) : nil;
            for (int i = 0; i < 40 && spt && [spt.dataSource numberOfRowsInTableView:spt] == 0; ++i) pump(0.05);
            CHECK(spt && [spt.dataSource numberOfRowsInTableView:spt] == 3, "3 usable spots (%ld)",
                  spt ? (long)[spt.dataSource numberOfRowsInTableView:spt] : -1L);
            if (spt) {
                NSInteger wg = -1;
                for (NSInteger r = 0; r < [spt.dataSource numberOfRowsInTableView:spt]; ++r)
                    if ([cell(spt, r, @"1") isEqualToString:@"WG0Y"]) wg = r;
                CHECK(wg >= 0 && [cell(spt, wg, @"4") isEqualToString:@"US-12593"] && [cell(spt, wg, @"2") isEqualToString:@"14059.1"],
                      "WG0Y spot row");
                [spw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(spw.contentView) == 0, "Spots controls do not overlap (%d)", overlaps(spw.contentView));
                snapshot(spw, "pota-spots");
                [spt selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)wg] byExtendingSelection:NO];
                // A refresh that brings a newer spot keeps WG0Y selected (the rows move down one).
                NSString *more = [tmp stringByAppendingPathComponent:@"spots2"];
                [[NSFileManager defaultManager] createDirectoryAtPath:[more stringByAppendingPathComponent:@"pota"]
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:nil];
                NSMutableArray *list = [[NSJSONSerialization
                    JSONObjectWithData:[NSData dataWithContentsOfFile:[@(argv[2]) stringByAppendingPathComponent:@"pota/spots.json"]]
                               options:NSJSONReadingMutableContainers
                                 error:nil] mutableCopy];
                NSMutableDictionary *newer = [list[0] mutableCopy];
                newer[@"spotId"] = @99;
                newer[@"activator"] = @"N9NEW";
                newer[@"spotTime"] = @"2026-10-07T21:15:00";
                [list insertObject:newer atIndex:0];
                [[NSJSONSerialization dataWithJSONObject:list options:0 error:nil]
                    writeToFile:[more stringByAppendingPathComponent:@"pota/spots.json"]
                     atomically:YES];
                setenv("ADIFLINT_FAKE_LOOKUP_DIR", more.UTF8String, 1);
                [findButton(spw.contentView, @"Refresh") performClick:nil];
                pump(0.3);
                setenv("ADIFLINT_FAKE_LOOKUP_DIR", argv[2], 1);
                CHECK([spt.dataSource numberOfRowsInTableView:spt] == 4 && spt.selectedRow == wg + 1 &&
                          [cell(spt, spt.selectedRow, @"1") isEqualToString:@"WG0Y"],
                      "refresh keeps WG0Y selected (%ld)", (long)spt.selectedRow);
                [findButton(spw.contentView, @"Use in New QSO") performClick:nil];
                pump(0.3);
                NSWindow *qw4 = qsoWindow();
                CHECK(qw4 && [qsoControl(qw4, @"CALL").stringValue isEqualToString:@"WG0Y"] &&
                          [qsoControl(qw4, @"FREQ").stringValue isEqualToString:@"14.0591"] &&
                          [qsoControl(qw4, @"MODE").stringValue isEqualToString:@"CW"] &&
                          [qsoControl(qw4, @"SIG").stringValue isEqualToString:@"POTA"] &&
                          [qsoControl(qw4, @"SIG_INFO").stringValue isEqualToString:@"US-12593"],
                      "spot copied to New QSO, with SIG and SIG_INFO rows added");
                if (qw4) {
                    pump(0.8);  // the lookup line (country, the park's history) fills in after a pause
                    std::string spotInfo = lookupInfo(qw4);
                    CHECK(spotInfo.find("UNITED STATES OF AMERICA") == 0 && spotInfo.find("US-12593: a new park!") != std::string::npos,
                          "a spot runs the lookup: %s", spotInfo.c_str());
                    snapshot(qw4, "new-qso-spot");
                }
                CHECK(qw4 && qsoControl(qw4, @"SUBMODE").stringValue.length == 0, "the spot's CW clears an earlier USB");
                if (qw4) {
                    // Park-to-park: the same activator at another park is a new contact, not a repeat.
                    [findButton(qw4.contentView, @"Log QSO") performClick:nil];
                    pump(0.2);
                    if (getenv("ADIFLINT_DEBUG")) {
                        std::printf("after Log QSO: %s\n", summaryLabel(qw4.contentView).stringValue.UTF8String);
                        NSGridView *grid = findGrid(qw4.contentView);
                        for (NSInteger gr = 0; gr < grid.numberOfRows; ++gr)
                            std::printf("  %s = [%s] %s\n", ((NSTextField *)[grid cellAtColumnIndex:0 rowIndex:gr].contentView).stringValue.UTF8String,
                                        ((NSTextField *)[grid cellAtColumnIndex:1 rowIndex:gr].contentView).stringValue.UTF8String,
                                        ((NSTextField *)[grid cellAtColumnIndex:2 rowIndex:gr].contentView).stringValue.UTF8String);
                    }
                    auto summaryFor = [&](NSString *park) {
                        qsoControl(qw4, @"CALL").stringValue = @"WG0Y";
                        qsoControl(qw4, @"SIG_INFO").stringValue = park;
                        [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification
                                                                            object:qsoControl(qw4, @"CALL")];
                        pump(0.4);
                        return std::string(summaryLabel(qw4.contentView).stringValue.UTF8String);
                    };
                    std::string other = summaryFor(@"US-99999"), same = summaryFor(@"US-12593");
                    CHECK(other.find("already in this log") == std::string::npos, "another park is not a repeat: %s", other.c_str());
                    CHECK(same.find("already in this log") != std::string::npos, "the same park is: %s", same.c_str());
                    qsoControl(qw4, @"CALL").stringValue = @"";
                    qsoControl(qw4, @"SIG_INFO").stringValue = @"";
                }
                // Band filter.
                NSMutableArray *pops = [NSMutableArray array];
                collect(spw.contentView, NSPopUpButton.class, pops);
                NSPopUpButton *programPop = nil, *bandPop = nil;
                for (NSPopUpButton *pb in pops) {
                    if ([pb indexOfItemWithTitle:@"WWFF"] >= 0) programPop = pb;
                    if ([pb indexOfItemWithTitle:@"40m"] >= 0) bandPop = pb;
                }
                [bandPop selectItemWithTitle:@"40m"];
                [bandPop sendAction:bandPop.action to:bandPop.target];
                CHECK([spt.dataSource numberOfRowsInTableView:spt] == 1 && [cell(spt, 0, @"1") isEqualToString:@"K1AE"],
                      "40m filter: K1AE only");
                [bandPop selectItemAtIndex:0];
                [bandPop sendAction:bandPop.action to:bandPop.target];
                // The station just logged shows as worked today; a park not in any log is NEW.
                [findButton(spw.contentView, @"Refresh") performClick:nil];
                for (int i = 0; i < 40 && [spt.dataSource numberOfRowsInTableView:spt] < 3; ++i) pump(0.05);
                std::map<std::string, std::string> workedCol;
                for (NSInteger r = 0; r < [spt.dataSource numberOfRowsInTableView:spt]; ++r)
                    workedCol[cell(spt, r, @"1").UTF8String] = cell(spt, r, @"7").UTF8String;
                CHECK(workedCol["WG0Y"] == "today" && workedCol["K1AE"] == "NEW", "Worked column: WG0Y %s, K1AE %s",
                      workedCol["WG0Y"].c_str(), workedCol["K1AE"].c_str());
                // WWFF spots from spots.wwff.co (fixture).
                [programPop selectItemWithTitle:@"WWFF"];
                [programPop sendAction:programPop.action to:programPop.target];
                for (int i = 0; i < 40 && ![cell(spt, 0, @"4") hasSuffix:@"FF-5255"] && ![cell(spt, 0, @"4") hasSuffix:@"FF-0100"]; ++i)
                    pump(0.05);
                NSInteger k3 = -1;
                for (NSInteger r = 0; r < [spt.dataSource numberOfRowsInTableView:spt]; ++r)
                    if ([cell(spt, r, @"1") isEqualToString:@"K3MTO"]) k3 = r;
                CHECK([spt.dataSource numberOfRowsInTableView:spt] == 2 && k3 >= 0 && [cell(spt, k3, @"4") isEqualToString:@"KFF-5255"] &&
                          [cell(spt, k3, @"2") isEqualToString:@"14025"] && [cell(spt, k3, @"7") isEqualToString:@"NEW"],
                      "WWFF spots: %ld rows", (long)[spt.dataSource numberOfRowsInTableView:spt]);
                if (k3 >= 0) {
                    [spt selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)k3] byExtendingSelection:NO];
                    [findButton(spw.contentView, @"Use in New QSO") performClick:nil];
                    pump(0.3);
                    NSWindow *qw5 = qsoWindow();
                    CHECK(qw5 && [qsoControl(qw5, @"CALL").stringValue isEqualToString:@"K3MTO"] &&
                              [qsoControl(qw5, @"FREQ").stringValue isEqualToString:@"14.025"] &&
                              [qsoControl(qw5, @"SIG").stringValue isEqualToString:@"WWFF"] &&
                              [qsoControl(qw5, @"SIG_INFO").stringValue isEqualToString:@"KFF-5255"],
                          "WWFF spot copied to New QSO");
                    pump(0.8);
                    std::string info = qw5 ? lookupInfo(qw5) : "";
                    CHECK(info.find("KFF-5255: a new reference!") != std::string::npos, "the reference's history: %s", info.c_str());
                    if (qw5) {
                        qsoControl(qw5, @"CALL").stringValue = @"";
                        qsoControl(qw5, @"SIG").stringValue = @"";
                        qsoControl(qw5, @"SIG_INFO").stringValue = @"";
                        [qw5 orderOut:nil];
                    }
                }
                // More programs, from Spothole (fixtures): its programs without SOTA, POTA or WWFF, and a program filter.
                [programPop selectItemWithTitle:@"More programs (Spothole)"];
                [programPop sendAction:programPop.action to:programPop.target];
                for (int i = 0; i < 40 && ![cell(spt, 0, @"6") isEqualToString:@"GMA"]; ++i) pump(0.05);
                NSInteger gma = -1;
                for (NSInteger r = 0; r < [spt.dataSource numberOfRowsInTableView:spt]; ++r)
                    if ([cell(spt, r, @"1") isEqualToString:@"DL1ABC/P"]) gma = r;
                CHECK([spt.dataSource numberOfRowsInTableView:spt] == 3 && gma >= 0 && [cell(spt, gma, @"2") isEqualToString:@"7032.5"] &&
                          [cell(spt, gma, @"4") isEqualToString:@"DA/NI-001"] && [cell(spt, gma, @"6") isEqualToString:@"GMA"] &&
                          [cell(spt, gma, @"7") isEqualToString:@"NEW"],
                      "Spothole spots: %ld rows", (long)[spt.dataSource numberOfRowsInTableView:spt]);
                NSMutableArray *pops2 = [NSMutableArray array];
                collect(spw.contentView, NSPopUpButton.class, pops2);
                NSPopUpButton *programs = nil;
                for (NSPopUpButton *pb in pops2)
                    if ([pb indexOfItemWithTitle:@"All programs"] >= 0) programs = pb;
                CHECK(programs && !programs.hidden && [programs indexOfItemWithTitle:@"WWBOTA"] >= 0 && [programs indexOfItemWithTitle:@"ZLOTA"] >= 0 &&
                          [programs indexOfItemWithTitle:@"SOTA"] < 0 && [programs indexOfItemWithTitle:@"POTA"] < 0 &&
                          [programs indexOfItemWithTitle:@"WWFF"] < 0 && [programs indexOfItemWithTitle:@"JOTA"] < 0,
                      "Spothole's programs: outdoor ones with references, never SOTA (%ld)", (long)programs.numberOfItems);
                [programs selectItemWithTitle:@"WWBOTA"];
                [programs sendAction:programs.action to:programs.target];
                CHECK([spt.dataSource numberOfRowsInTableView:spt] == 1 && [cell(spt, 0, @"1") isEqualToString:@"M1DDD/P"], "the program filter");
                [programs selectItemAtIndex:0];
                [programs sendAction:programs.action to:programs.target];
                CHECK([labelWithLines(spw.contentView, 4) containsString:@"from Spothole (spothole.app; refreshed every 2 minutes; SOTA left out)"],
                      "the status names Spothole: %s", labelWithLines(spw.contentView, 4).UTF8String);
                if (spw) {
                    [spw.contentView layoutSubtreeIfNeeded];
                    CHECK(overlaps(spw.contentView) == 0, "Spots with Spothole does not overlap");
                    snapshot(spw, "spots-spothole");
                }
                for (NSInteger r = 0; r < [spt.dataSource numberOfRowsInTableView:spt]; ++r)
                    if ([cell(spt, r, @"1") isEqualToString:@"DL1ABC/P"]) gma = r;
                if (gma >= 0) {
                    [spt selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)gma] byExtendingSelection:NO];
                    [findButton(spw.contentView, @"Use in New QSO") performClick:nil];
                    pump(0.3);
                    NSWindow *qw6 = qsoWindow();
                    CHECK(qw6 && [qsoControl(qw6, @"CALL").stringValue isEqualToString:@"DL1ABC/P"] &&
                              [qsoControl(qw6, @"FREQ").stringValue isEqualToString:@"7.0325"] &&
                              [qsoControl(qw6, @"SIG").stringValue isEqualToString:@"GMA"] &&
                              [qsoControl(qw6, @"SIG_INFO").stringValue isEqualToString:@"DA/NI-001"],
                          "a GMA spot from Spothole copied to New QSO");
                    if (qw6) {
                        qsoControl(qw6, @"CALL").stringValue = @"";
                        qsoControl(qw6, @"SIG").stringValue = @"";
                        qsoControl(qw6, @"SIG_INFO").stringValue = @"";
                        [qw6 orderOut:nil];
                    }
                }
                [programPop selectItemWithTitle:@"POTA"];
                [programPop sendAction:programPop.action to:programPop.target];
                pump(0.2);
                [spw orderOut:nil];
                if (qw4) [qw4 orderOut:nil];
            }
        }

        // ── Uploads (test mode: no network; fake TQSL) ──
        {
            NSString *fake = @(argv[2]);
            NSString *logPath = [fake stringByAppendingPathComponent:@"uploads.log"];
            [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
            auto uploadsLog = [&]() {
                return std::string(([NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil] ?: @"").UTF8String);
            };
            auto count = [](const std::string &hay, const std::string &needle) {
                size_t n = 0;
                for (size_t p = hay.find(needle); p != std::string::npos; p = hay.find(needle, p + 1)) ++n;
                return n;
            };
            // One QSO the logbook already has, and one that can't be sent (no MODE).
            H.doc += "<CALL:4>DUPE <QSO_DATE:8>20261006 <TIME_ON:4>2315 <BAND:3>20m <MODE:3>SSB <STATION_CALLSIGN:4>KW9D <EOR>\n"
                     "<CALL:4>NOMO <QSO_DATE:8>20261006 <TIME_ON:4>2320 <BAND:3>20m <STATION_CALLSIGN:4>KW9D <EOR>\n";
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.5);
            size_t records = count(H.doc, "<EOR>");
            auto status = [](NSWindow *w) { return std::string(labelWithLines(w.contentView, 4).UTF8String); };
            auto waitDone = [&](NSWindow *w) {
                for (int i = 0; i < 200; ++i) {
                    std::string s = status(w);
                    if (s.find("Sending") == std::string::npos && s.find("is signing") == std::string::npos) break;
                    pump(0.05);
                }
            };

            // Settings lists the upload accounts.
            run("Settings...");
            NSWindow *setw = windowTitled(@"ADIF Lint Settings");
            if (setw) {
                SettingsRow club = settingsRow(setw, 4);
                CHECK(club.title && [club.title.stringValue isEqualToString:@"Club Log"] &&
                          [club.user.placeholderString isEqualToString:@"Email"],
                      "Club Log section asks for an email");
                NSView *eq = viewWithIdentifier(setw.contentView, @"settings.source.6");
                NSButton *test = eq ? findButton(eq, @"Test Sign-In") : nil;
                CHECK(eq && test && test.hidden, "eQSL has no sign-in test button");
                NSView *ql = viewWithIdentifier(setw.contentView, @"settings.source.3");
                CHECK(ql && !findButton(ql, @"Test Sign-In").hidden, "QRZ Logbook key can be tested");
                [setw orderOut:nil];
            }

            // QRZ.com Logbook: lists what it would send; nothing goes until Upload.
            run("Upload to QRZ.com Logbook...");
            NSWindow *qz = windowTitled(@"Upload to QRZ.com Logbook");
            NSTableView *qt = qz ? findTable(qz.contentView) : nil;
            CHECK(qt && (size_t)[qt.dataSource numberOfRowsInTableView:qt] == records, "every record listed (%ld of %zu)",
                  qt ? (long)[qt.dataSource numberOfRowsInTableView:qt] : -1L, records);
            NSButton *send = qz ? findButton(qz.contentView, [NSString stringWithFormat:@"Upload %zu QSOs", records - 1]) : nil;
            CHECK(send != nil && status(qz).find("Nothing is sent until you press Upload") != std::string::npos,
                  "Upload button counts the sendable QSOs: %s", status(qz).c_str());
            CHECK(uploadsLog().empty(), "nothing sent before Upload");
            if (qt) {
                [qz.contentView layoutSubtreeIfNeeded];
                NSButton *box = [qt viewAtColumn:0 row:0 makeIfNecessary:YES];
                [box performClick:nil];
                NSString *less = [NSString stringWithFormat:@"Upload %zu QSOs", records - 2];
                CHECK(findButton(qz.contentView, less) != nil, "the count follows the ticks");
                H.doc += "\n";
                notify(SCN_MODIFIED, 0, (intptr_t)H.doc.size() - 1, SC_MOD_INSERTTEXT);
                pump(1.2);
                CHECK(![qz.contentView isHidden] && findButton(qz.contentView, less) != nil && ![(NSButton *)[qt viewAtColumn:0 row:0 makeIfNecessary:YES] state],
                      "an unticked QSO stays unticked after an edit to the log");
                [findButton(qz.contentView, @"Tick All") performClick:nil];
                send = findButton(qz.contentView, [NSString stringWithFormat:@"Upload %zu QSOs", records - 1]);
            }
            if (qz) {
                [qz.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(qz.contentView) == 0, "Upload controls do not overlap (%d)", overlaps(qz.contentView));
                snapshot(qz, "upload-qrz");
            }
            [send performClick:nil];
            waitDone(qz);
            std::string log = uploadsLog();
            CHECK(count(log, "QRZ <CALL:") == records - 1 && log.find("QRZCOM_QSO_UPLOAD") == std::string::npos &&
                      log.find("<CALL:4>NOMO") == std::string::npos,
                  "one INSERT per QSO, no status fields, nothing for the record without MODE");
            CHECK(count(H.doc, "<QRZCOM_QSO_UPLOAD_STATUS:1>Y") == records - 1 && count(H.doc, "<QRZCOM_QSO_UPLOAD_DATE:8>" + utcDate()) == records - 1,
                  "status Y and today's date on the %zu sent (DUPE counts: already in the logbook)", records - 1);
            CHECK(status(qz).find("Sent " + std::to_string(records - 1) + " of " + std::to_string(records - 1)) == 0 &&
                      status(qz).find("one undo step") != std::string::npos,
                  "QRZ summary: %s", status(qz).c_str());
            if (qt) {
                bool dupeShown = false;
                for (NSInteger r = 0; r < [qt.dataSource numberOfRowsInTableView:qt]; ++r)
                    if ([cell(qt, r, @"1") isEqualToString:@"DUPE"]) dupeShown = [cell(qt, r, @"7") isEqualToString:@"already in the logbook"];
                CHECK(dupeShown, "the duplicate is reported as already in the logbook");
                snapshot(qz, "upload-qrz-done");
            }
            CHECK(!findButton(qz.contentView, @"Upload").enabled, "Upload is off after a run until Refresh");
            [findButton(qz.contentView, @"Refresh") performClick:nil];
            CHECK(status(qz).find("Nothing to send") == 0, "afterwards nothing is left to send: %s", status(qz).c_str());
            // Sending uploaded QSOs again replaces QRZ's copies.
            NSButton *listSent = nil;
            NSMutableArray *qboxes = [NSMutableArray array];
            collect(qz.contentView, NSButton.class, qboxes);
            for (NSButton *b in qboxes)
                if ([b.title isEqualToString:@"Also list QSOs already sent"]) listSent = b;
            [listSent performClick:nil];
            [findButton(qz.contentView, [NSString stringWithFormat:@"Upload %zu QSOs", records - 1]) performClick:nil];
            waitDone(qz);
            CHECK(count(uploadsLog(), "QRZ REPLACE <CALL:") == records - 1, "re-sent with OPTION=REPLACE (%zu)",
                  count(uploadsLog(), "QRZ REPLACE <CALL:"));
            [listSent performClick:nil];
            // Editing an uploaded QSO by hand makes it M: modified since upload.
            size_t k1 = H.doc.find("<CALL:4>K1AB");
            size_t st = H.doc.find("<MY_STATE:2>KS", k1);
            H.doc.replace(st + 12, 2, "MO");
            notify(SCN_MODIFIED, 0, (intptr_t)st + 12, SC_MOD_INSERTTEXT | SC_PERFORMED_USER);
            pump(1.0);
            std::string k1rec = H.doc.substr(k1, H.doc.find("<EOR>", k1) - k1);
            CHECK(k1rec.find("<QRZCOM_QSO_UPLOAD_STATUS:1>M") != std::string::npos, "hand edit marks M:\n%s", k1rec.c_str());
            [qz orderOut:nil];

            // eQSL, with a QTH nickname.
            run("Upload to eQSL...");
            NSWindow *eq = windowTitled(@"Upload to eQSL");
            if (eq) {
                NSMutableArray *fields = [NSMutableArray array];
                collect(eq.contentView, NSTextField.class, fields);
                for (NSTextField *f in fields)
                    if ([f.placeholderString isEqualToString:@"optional"]) f.stringValue = @"PARK";
                [findButton(eq.contentView, [NSString stringWithFormat:@"Upload %zu QSOs", records - 1]) performClick:nil];
                waitDone(eq);
                log = uploadsLog();
                CHECK(count(log, "EQSL ") == records - 1 && count(log, "<APP_EQSL_QTH_NICKNAME:4>PARK <EOR>") == records - 1 &&
                          count(log, "<EOH>") >= records - 1,
                      "eQSL: one file per QSO with the nickname");
                CHECK(count(H.doc, "<EQSL_QSL_SENT:1>Y") == records - 1, "EQSL_QSL_SENT set: %s", status(eq).c_str());
                [eq orderOut:nil];
            }

            // Club Log: one batch to putlogs.php.
            run("Upload to Club Log...");
            NSWindow *cl = windowTitled(@"Upload to Club Log");
            if (cl) {
                [findButton(cl.contentView, [NSString stringWithFormat:@"Upload %zu QSOs", records - 1]) performClick:nil];
                waitDone(cl);
                log = uploadsLog();
                CHECK(count(log, "CLUBLOG KW9D adiflint.adi") == 1, "Club Log: one upload into KW9D");
                CHECK(count(H.doc, "<CLUBLOG_QSO_UPLOAD_STATUS:1>Y") == records - 1 &&
                          status(cl).find("Club Log accepted " + std::to_string(records - 1) + " QSOs") == 0,
                      "Club Log status: %s", status(cl).c_str());
                snapshot(cl, "upload-clublog");
                [cl orderOut:nil];
            }

            // LoTW through a stand-in TQSL that records its arguments.
            NSString *script = [tmp stringByAppendingPathComponent:@"tqsl"];
            NSString *argsFile = [tmp stringByAppendingPathComponent:@"tqsl-args.txt"];
            NSString *body = [NSString stringWithFormat:@"#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done > '%@'\n"
                                                        @"echo 'Signed and uploaded' >&2\nexit ${FAKE_TQSL_EXIT:-0}\n", argsFile];
            [body writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:nil];
            chmod(script.fileSystemRepresentation, 0755);
            setenv("ADIFLINT_TEST_OPEN_FILE", script.UTF8String, 1);
            run("Upload to LoTW (TQSL)...");
            NSWindow *lw = windowTitled(@"Upload to LoTW (TQSL)");
            if (lw) {
                [findButton(lw.contentView, @"Choose...") performClick:nil];
                NSMutableArray *combos = [NSMutableArray array];
                collect(lw.contentView, NSComboBox.class, combos);
                ((NSComboBox *)combos.firstObject).stringValue = @"Home QTH";
                [lw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(lw.contentView) == 0, "LoTW controls do not overlap (%d)", overlaps(lw.contentView));
                snapshot(lw, "upload-lotw");
                [findButton(lw.contentView, [NSString stringWithFormat:@"Upload %zu QSOs", records - 1]) performClick:nil];
                waitDone(lw);
                NSString *args = [NSString stringWithContentsOfFile:argsFile encoding:NSUTF8StringEncoding error:nil];
                CHECK([args hasPrefix:@"-x\n-d\n-u\n-a\ncompliant\n-l\nHome QTH\n"] && [args containsString:@"adiflint-lotw-"],
                      "TQSL arguments:\n%s", args.UTF8String);
                CHECK([args containsString:@"\n-p\ntest\n"], "the saved certificate password goes to TQSL with -p");
                CHECK(count(H.doc, "<LOTW_QSL_SENT:1>Y") == records - 1 && status(lw).find("TQSL: all QSOs were signed and uploaded") == 0,
                      "LoTW: %s", status(lw).c_str());
                // Exit 9 (some ignored): nothing is marked, and TQSL's report is shown.
                setenv("FAKE_TQSL_EXIT", "9", 1);
                NSButton *again = nil;
                NSMutableArray *boxes = [NSMutableArray array];
                collect(lw.contentView, NSButton.class, boxes);
                for (NSButton *b in boxes)
                    if ([b.title isEqualToString:@"Also list QSOs already sent"]) again = b;
                [again performClick:nil];
                std::string before = H.doc;
                [findButton(lw.contentView, [NSString stringWithFormat:@"Upload %zu QSOs", records - 1]) performClick:nil];
                waitDone(lw);
                CHECK(H.doc == before && status(lw).find("some QSOs were uploaded") != std::string::npos &&
                          status(lw).find("Signed and uploaded") != std::string::npos,
                      "exit 9 marks nothing: %s", status(lw).c_str());
                unsetenv("FAKE_TQSL_EXIT");
                // A TQSL that never finishes is stopped after the time limit.
                NSString *slow = [tmp stringByAppendingPathComponent:@"tqsl-slow"];
                [@"#!/bin/sh\nexec sleep 30\n" writeToFile:slow atomically:YES encoding:NSUTF8StringEncoding error:nil];
                chmod(slow.fileSystemRepresentation, 0755);
                setenv("ADIFLINT_TEST_OPEN_FILE", slow.UTF8String, 1);
                [findButton(lw.contentView, @"Choose...") performClick:nil];
                setenv("ADIFLINT_TEST_TQSL_SECONDS", "1", 1);
                [findButton(lw.contentView, [NSString stringWithFormat:@"Upload %zu QSOs", records - 1]) performClick:nil];
                for (int i = 0; i < 80 && status(lw).find("did not finish") == std::string::npos; ++i) pump(0.1);
                CHECK(status(lw).find("did not finish within 1 seconds, so it was stopped") != std::string::npos,
                      "TQSL time limit: %s", status(lw).c_str());
                unsetenv("ADIFLINT_TEST_TQSL_SECONDS");

                // Pre-flight: QSOs whose station fields disagree with the Station Location, as TQSL compares them.
                [[NSFileManager defaultManager] createDirectoryAtPath:tqslDir withIntermediateDirectories:YES attributes:nil error:nil];
                [@"<StationDataFile>\n  <StationData name=\"Home QTH\">\n    <CALL>KW9D</CALL>\n    <DXCC>291</DXCC>\n"
                 @"    <GRIDSQUARE>EN52wa</GRIDSQUARE>\n    <US_STATE>IL</US_STATE>\n  </StationData>\n"
                 @"  <StationData name=\"Portable\">\n    <CALL>KW9D</CALL>\n    <DXCC>291</DXCC>\n    <GRIDSQUARE>EN61</GRIDSQUARE>\n"
                 @"    <US_STATE>IL</US_STATE>\n  </StationData>\n</StationDataFile>\n"
                    writeToFile:[tqslDir stringByAppendingPathComponent:@"station_data"]
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:nil];
                std::string savedDoc = H.doc;
                auto spec = [](const char *name, const std::string &v) {
                    return "<" + std::string(name) + ":" + std::to_string(v.size()) + ">" + v + " ";
                };
                H.doc = "pre\n<ADIF_VER:5>3.1.7\n<EOH>\n" + spec("CALL", "K1AA") + spec("QSO_DATE", "20261009") + spec("TIME_ON", "1200") +
                        spec("BAND", "20m") + spec("MODE", "CW") + spec("STATION_CALLSIGN", "KW9D") + spec("MY_GRIDSQUARE", "EN52") +
                        spec("MY_STATE", "IL") + "<EOR>\n" + spec("CALL", "K2BB") + spec("QSO_DATE", "20261009") + spec("TIME_ON", "1210") +
                        spec("BAND", "20m") + spec("MODE", "CW") + spec("STATION_CALLSIGN", "KW9D") + spec("MY_GRIDSQUARE", "EN61") +
                        "<EOR>\n" + spec("CALL", "K3CC") + spec("QSO_DATE", "20261009") + spec("TIME_ON", "1220") + spec("BAND", "20m") +
                        spec("MODE", "CW") + spec("STATION_CALLSIGN", "KW9D") + spec("MY_STATE", "WI") + "<EOR>\n";
                notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
                pump(0.3);
                NSMutableArray *combos2 = [NSMutableArray array];
                collect(lw.contentView, NSComboBox.class, combos2);
                NSComboBox *loc = combos2.firstObject;
                loc.stringValue = @"Home QTH";
                [loc sendAction:loc.action to:loc.target];
                CHECK([loc.objectValues containsObject:@"Portable"], "the Station Locations come from station_data");
                NSTableView *lt2 = findTable(lw.contentView);
                std::string rowsText;
                for (NSInteger row = 0; row < [lt2.dataSource numberOfRowsInTableView:lt2]; ++row)
                    rowsText += std::string(cell(lt2, row, @"1").UTF8String) + ": " + cell(lt2, row, @"6").UTF8String + "\n";
                CHECK(rowsText == "K1AA: \nK2BB: can't send: TQSL would refuse it: MY_GRIDSQUARE EN61 (the location: EN52wa); it "
                                  "matches Portable\nK3CC: can't send: TQSL would refuse it: MY_STATE WI (the location: IL)\n" &&
                          findButton(lw.contentView, @"Upload 1 QSO") != nil &&
                          status(lw).find("2 QSOs disagree with the Station Location Home QTH") != std::string::npos,
                      "LoTW pre-flight:\n%s%s", rowsText.c_str(), status(lw).c_str());
                loc.stringValue = @"Nowhere";
                [loc sendAction:loc.action to:loc.target];
                CHECK(status(lw).find("TQSL has no Station Location named Nowhere (2 locations in") != std::string::npos,
                      "an unknown location: %s", status(lw).c_str());
                H.doc = savedDoc;
                notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
                pump(0.3);
                [lw orderOut:nil];
            }
            unsetenv("ADIFLINT_TEST_OPEN_FILE");

            // QSL Sync sums the log up per service.
            runItem("QSL Sync (Upload, Confirmations)...");
            NSWindow *sync = windowTitled(@"QSL Sync");
            NSTableView *syncTable = sync ? findTable(sync.contentView) : nil;
            CHECK(syncTable && [syncTable.dataSource numberOfRowsInTableView:syncTable] == 4 && [cell(syncTable, 3, @"0") isEqualToString:@"eQSL"] &&
                      [cell(syncTable, 3, @"4") isEqualToString:@(std::to_string(records - 1).c_str())] && [cell(syncTable, 2, @"6") isEqualToString:@"—"] &&
                      [cell(syncTable, 1, @"8") isEqualToString:@"never"],
                  "QSL Sync: eQSL uploaded %s, Club Log confirmations %s, LoTW last download %s", cell(syncTable, 3, @"4").UTF8String,
                  cell(syncTable, 2, @"6").UTF8String, cell(syncTable, 1, @"8").UTF8String);
            [syncTable selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
            CHECK(findButton(sync.contentView, @"Upload...").enabled && !findButton(sync.contentView, @"Download Confirmations...").enabled,
                  "Club Log: Upload, but no confirmations to download");
            if (sync) {
                [sync.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(sync.contentView) == 0, "QSL Sync does not overlap");
                snapshot(sync, "qsl-sync");
            }
            [sync orderOut:nil];
            [[NSFileManager defaultManager] removeItemAtPath:logPath error:nil];
        }

        // ── 0.8: confirmations, country data, lookup, table edits, distance, Cabrillo, CSV, WWFF and SOTA ──
        {
            NSString *outDir = [tmp stringByAppendingPathComponent:@"out8"];
            [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("ADIFLINT_TEST_SAVE_DIR", outDir.UTF8String, 1);
            setenv("ADIFLINT_TEST_FOLDER", outDir.UTF8String, 1);
            auto tableRows = [](NSTableView *t) { return t ? (long)[t.dataSource numberOfRowsInTableView:t] : -1L; };
            auto status = [](NSWindow *w) { return std::string(labelWithLines(w.contentView, 4).UTF8String); };
            auto has = [](const std::string &s) { return H.doc.find(s) != std::string::npos; };
            auto ini = [&]() {
                NSString *f = [NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"ADIFLint.ini"]
                                                        encoding:NSUTF8StringEncoding
                                                           error:nil];
                return std::string((f ?: @"").UTF8String);
            };
            H.doc = "features\n<ADIF_VER:5>3.1.7\n<EOH>\n"
                    "<CALL:4>K1AD <QSO_DATE:8>20261006 <TIME_ON:4>2250 <BAND:3>20m <MODE:3>SSB <STATION_CALLSIGN:4>KW9D "
                    "<MY_GRIDSQUARE:4>EN52 <GRIDSQUARE:6>FN42aa <QRZCOM_QSO_UPLOAD_STATUS:1>Y <EOR>\n"
                    "<CALL:4>K1AE <QSO_DATE:8>20261006 <TIME_ON:4>2255 <BAND:3>20m <MODE:3>SSB <STATION_CALLSIGN:4>KW9D "
                    "<MY_GRIDSQUARE:4>EN52 <GRIDSQUARE:4>FN31 <CLUBLOG_QSO_UPLOAD_STATUS:1>Y <EOR>\n"
                    "<CALL:5>DL1AB <QSO_DATE:8>20261006 <TIME_ON:4>2300 <BAND:3>20m <MODE:2>CW <STATION_CALLSIGN:4>KW9D "
                    "<MY_GRIDSQUARE:4>EN52 <GRIDSQUARE:4>JO62 <EOR>\n";
            H.path = "/tmp/features.adi";
            H.pos = 0;
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.5);

            // Import from a site (fixtures): QSOs the log lacks are added, the ones it has gain confirmations.
            auto findData = [&](const char *item, NSString *title, NSString *wait) {
                run(item);
                NSWindow *ew = windowTitled(title);
                CHECK(ew != nil, "%s window", title.UTF8String);
                if (!ew) return std::make_pair((NSWindow *)nil, std::vector<std::string>());
                [findButton(ew.contentView, @"Find Data") performClick:nil];
                waitForStatus(ew, wait, 3);
                return std::make_pair(ew, reviewRows(findTable(ew.contentView)));
            };
            auto applyAll = [&](NSWindow *ew, size_t n) {
                NSButton *b = findButton(ew.contentView, [NSString stringWithFormat:@"Apply %zu Change%@", n, n == 1 ? @"" : @"s"]);
                CHECK(b != nil, "Apply %zu", n);
                [b performClick:nil];
                pump(0.1);
            };
            // One row per downloaded QSO: action, call, ..., changes; ticks as shown.
            auto importRows = [&](NSWindow *iw) {
                std::vector<std::string> out;
                NSTableView *it = findTable(iw.contentView);
                NSInteger n = it ? [it.dataSource numberOfRowsInTableView:it] : 0;
                for (NSInteger r = 0; r < n; ++r) {
                    NSView *tick = [it.delegate tableView:it viewForTableColumn:[it tableColumnWithIdentifier:@"__use"] row:r];
                    bool on = [tick isKindOfClass:NSButton.class] && ((NSButton *)tick).state == NSControlStateValueOn;
                    out.push_back(std::string(on ? "[x] " : "[ ] ") + cell(it, r, @"0").UTF8String + " " + cell(it, r, @"1").UTF8String +
                                  " " + cell(it, r, @"8").UTF8String);
                }
                return out;
            };
            auto download = [&](const char *item, NSString *title) {
                run(item);
                NSWindow *iw = windowTitled(title);
                CHECK(iw != nil, "%s window", title.UTF8String);
                if (!iw) return (NSWindow *)nil;
                [findButton(iw.contentView, @"Download") performClick:nil];
                for (int i = 0; i < 60 && ![labelWithLines(iw.contentView, 4) containsString:@"downloaded from"]; ++i) pump(0.05);
                return iw;
            };
            auto dumpRows = [](const std::vector<std::string> &rows) {
                std::string d;
                for (const std::string &r : rows) d += "\n  " + r;
                return d;
            };
            NSWindow *qi = download("Import from QRZ.com Logbook...", @"Import from QRZ.com Logbook");
            if (qi) {
                std::vector<std::string> rows = importRows(qi);
                CHECK(rows.size() == 2 &&
                          hasRow(rows, "[x] update K1AE QRZCOM_QSO_UPLOAD_STATUS=Y, QRZCOM_QSO_DOWNLOAD_STATUS=Y, QRZCOM_QSO_DOWNLOAD_DATE=" +
                                           utcDate() + ", APP_QRZLOG_STATUS=C, APP_QRZLOG_QSLDATE=20261007") &&
                          hasRow(rows, "[x] add W8NEW new record"),
                      "QRZ.com Logbook rows (K1AD has nothing to add):%s", dumpRows(rows).c_str());
                CHECK([labelWithLines(qi.contentView, 4) containsString:@"3 QSOs downloaded from QRZ.com Logbook from 2026-10-06 to 2026-10-06: "
                                                                        @"1 QSO to add, 1 record to update, 1 already in the log"],
                      "QRZ status: %s", labelWithLines(qi.contentView, 4).UTF8String);
                NSButton *also = findButton(qi.contentView, @"Also list QSOs already in the log");
                [also performClick:nil];
                CHECK(importRows(qi).size() == 3 && hasRow(importRows(qi), "[ ] in log K1AD nothing to add"), "in-log rows listed:%s",
                      dumpRows(importRows(qi)).c_str());
                [also performClick:nil];
                [qi.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(qi.contentView) == 0, "Import controls do not overlap (%d)", overlaps(qi.contentView));
                snapshot(qi, "import-qrz");
                int undo = H.undoActions;
                applyAll(qi, 2);
                CHECK(H.undoActions == undo + 1 && has("<APP_QRZLOG_STATUS:1>C") && has("<CLUBLOG_QSO_UPLOAD_STATUS:1>Y") &&
                          has("<CALL:5>W8NEW <QSO_DATE:8>20261006 <TIME_ON:4>2310 <BAND:3>20m <MODE:3>SSB <STATION_CALLSIGN:4>KW9D "
                              "<MY_GRIDSQUARE:4>EN52 <GRIDSQUARE:4>EN61 <RST_SENT:2>59 <RST_RCVD:2>57 <QRZCOM_QSO_UPLOAD_STATUS:1>Y <EOR>") &&
                          !has("APP_QRZLOG_LOGID"),
                      "QRZ import in one undo step; confirmation fields don't make K1AE modified:\n%s", H.doc.c_str());
                CHECK([labelWithLines(qi.contentView, 4) hasPrefix:@"Added 1 QSO and updated 1 record from QRZ.com Logbook"],
                      "QRZ applied: %s", labelWithLines(qi.contentView, 4).UTF8String);
                [qi orderOut:nil];
            }
            NSWindow *ei = download("Import from eQSL...", @"Import from eQSL");
            if (ei) {
                std::vector<std::string> rows = importRows(ei);
                CHECK(rows.size() == 2 && hasRow(rows, "[x] update K1AD EQSL_QSL_RCVD=Y, EQSL_QSLRDATE=20261007") &&
                          hasRow(rows, "[ ] add W9NO new record"),
                      "eQSL rows (W9NO offered, not ticked):%s", dumpRows(rows).c_str());
                applyAll(ei, 1);
                CHECK(has("<EQSL_QSL_RCVD:1>Y") && has("<QRZCOM_QSO_UPLOAD_STATUS:1>Y") && !has("W9NO"),
                      "eQSL confirmation written, W9NO not added, upload status kept");
                [ei orderOut:nil];
            }
            NSWindow *li = download("Import from LoTW...", @"Import from LoTW");
            if (li) {
                std::vector<std::string> rows = importRows(li);
                CHECK(rows.size() == 3 && hasRow(rows, "[x] add AA7BQ new record") &&
                          hasRow(rows, "[x] update K1AD STATE=MA, LOTW_QSL_SENT=Y, LOTW_QSLSDATE=20261007, LOTW_QSL_RCVD=Y, LOTW_QSLRDATE=20261008") &&
                          hasRow(rows, "[x] update DL1AB LOTW_QSL_SENT=Y, LOTW_QSLSDATE=20261007"),
                      "LoTW rows:%s", dumpRows(rows).c_str());
                // Untick AA7BQ: it is not added.
                NSTableView *lt = findTable(li.contentView);
                NSInteger aa = -1;
                for (NSInteger r = 0; r < (NSInteger)rows.size(); ++r)
                    if ([cell(lt, r, @"1") isEqualToString:@"AA7BQ"]) aa = r;
                NSButton *tick = aa >= 0 ? [lt viewAtColumn:[lt columnWithIdentifier:@"__use"] row:aa makeIfNecessary:YES] : nil;
                [tick performClick:nil];
                applyAll(li, 2);
                CHECK(!has("AA7BQ") && has("<STATE:2>MA") && has("<LOTW_QSL_RCVD:1>Y") && has("<QRZCOM_QSO_UPLOAD_STATUS:1>M"),
                      "LoTW applied without AA7BQ; K1AD's new STATE makes its QRZ upload out of date (M):\n%s", H.doc.c_str());
                [li orderOut:nil];
            }

            // Log Table: readable dates and times, edits written back, columns chosen, sort remembered.
            CHECK(ini().find("tableSort=TIME_ON:a") != std::string::npos, "the Log Table sort is saved:\n%s", ini().c_str());
            run("Log Table...");
            NSWindow *tw = windowTitled(@"Log Table");
            NSTableView *t = tw ? findTable(tw.contentView) : nil;
            if (t) {
                NSSortDescriptor *sd = t.sortDescriptors.firstObject;
                CHECK(sd && [sd.key isEqualToString:@"2"] && sd.ascending, "the saved sort is applied (%s)", sd.key.UTF8String);
                CHECK([cell(t, 0, @"1") isEqualToString:@"2026-10-06"] && [cell(t, 0, @"2") isEqualToString:@"22:50"],
                      "dates and times readable: %s %s", cell(t, 0, @"1").UTF8String, cell(t, 0, @"2").UTF8String);
                NSTextField *f = [t viewAtColumn:[t columnWithIdentifier:@"2"] row:0 makeIfNecessary:YES];
                CHECK(f.editable, "value cells are editable");
                int undo = H.undoActions;
                f.stringValue = @"22:51";
                [f sendAction:f.action to:f.target];
                pump(0.5);
                CHECK(has("<CALL:4>K1AD <QSO_DATE:8>20261006 <TIME_ON:4>2251 ") && H.undoActions == undo + 1,
                      "TIME_ON edited as 2251 in one undo step");
                CHECK(has("<QRZCOM_QSO_UPLOAD_STATUS:1>M"), "the edited, uploaded QSO stays marked modified (M)");
                NSMenu *menu = t.headerView.menu;
                NSInteger gi = [menu indexOfItemWithTitle:@"GRIDSQUARE"];
                CHECK(menu && gi >= 0 && menu.itemArray[(NSUInteger)gi].state == NSControlStateValueOn, "heading menu lists GRIDSQUARE, ticked");
                if (gi >= 0) {
                    [menu performActionForItemAtIndex:gi];
                    pump(0.1);
                    bool shown = false;
                    for (NSTableColumn *c in t.tableColumns) shown |= [c.title isEqualToString:@"GRIDSQUARE"];
                    CHECK(!shown && ini().find("tableHidden=GRIDSQUARE") != std::string::npos, "GRIDSQUARE hidden and remembered");
                    gi = [menu indexOfItemWithTitle:@"GRIDSQUARE"];
                    if (gi >= 0) [menu performActionForItemAtIndex:gi];
                    pump(0.1);
                    shown = false;
                    for (NSTableColumn *c in t.tableColumns) shown |= [c.title isEqualToString:@"GRIDSQUARE"];
                    CHECK(shown, "and shown again");
                }
                [tw.contentView layoutSubtreeIfNeeded];
                snapshot(tw, "log-table-edit");
                [tw orderOut:nil];
            }

            // Country data (the AD1C file installed beside the plugin).
            auto [ce, crows] = findData("Enrich from Country Data...", @"Enrich from Country Data", @"known prefix");
            if (ce) {
                CHECK(hasRow(crows, "3 DL1AB DXCC=230") && hasRow(crows, "3 DL1AB CQZ=14") && hasRow(crows, "3 DL1AB CONT=EU") &&
                          hasRow(crows, "1 K1AD DXCC=291") && hasRow(crows, "2 K1AE ITUZ=8"),
                      "country proposals (%zu rows): %s", crows.size(), labelWithLines(ce.contentView, 3).UTF8String);
                CHECK([labelWithLines(ce.contentView, 3) containsString:@"4 of 4 calls have a known prefix"], "country status: %s",
                      labelWithLines(ce.contentView, 3).UTF8String);
                applyAll(ce, crows.size());
                CHECK(has("<DXCC:3>230") && has("<CLUBLOG_QSO_UPLOAD_STATUS:1>M"), "country data written; the uploaded QSO is now M");
                snapshot(ce, "enrich-country");
                [ce orderOut:nil];
            }

            // New QSO looks the call up as you type: country, zones, distance and bearing.
            run("New QSO...");
            NSWindow *qw = qsoWindow();
            if (qw) {
                NSStackView *row = lookupRow(qw);
                NSPopUpButton *pop = row ? (NSPopUpButton *)row.arrangedSubviews[1] : nil;
                CHECK(pop && [pop.titleOfSelectedItem isEqualToString:@"Country data"], "Look up: country data by default");
                qsoControl(qw, @"GRIDSQUARE").stringValue = @"JO62";
                qsoControl(qw, @"CALL").stringValue = @"DL2XYZ";
                [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:qsoControl(qw, @"CALL")];
                for (int i = 0; i < 40 && lookupInfo(qw).find("km") == std::string::npos; ++i) pump(0.05);
                std::string info = lookupInfo(qw);
                CHECK(info.find("FEDERAL REPUBLIC OF GERMANY (DXCC 230, CQ 14, ITU 28)") != std::string::npos &&
                          info.find(" km at ") != std::string::npos,
                      "lookup line: %s", info.c_str());
                CHECK([qsoControl(qw, @"DXCC").stringValue isEqualToString:@"230"] && [qsoControl(qw, @"CONT").stringValue isEqualToString:@"EU"],
                      "empty fields filled from the prefix");
                [qw.contentView layoutSubtreeIfNeeded];
                NSTextField *infoField = (NSTextField *)viewWithIdentifier(qw.contentView, @"qso.lookupInfo");
                NSRect need = [infoField.cell titleRectForBounds:NSMakeRect(0, 0, NSWidth(infoField.bounds), 1000)];
                NSSize text = [infoField.attributedStringValue boundingRectWithSize:NSMakeSize(NSWidth(need), 1000)
                                                                            options:NSStringDrawingUsesLineFragmentOrigin]
                                  .size;
                CHECK(text.height <= NSHeight(infoField.bounds) + 1, "the lookup line is not cut off (%.0f of %.0f points)", text.height,
                      NSHeight(infoField.bounds));
                [qw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(qw.contentView) == 0, "New QSO with the lookup row does not overlap (%d)", overlaps(qw.contentView));
                snapshot(qw, "new-qso-lookup");
                // Another call takes back what the lookup filled.
                qsoControl(qw, @"CALL").stringValue = @"";
                [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:qsoControl(qw, @"CALL")];
                pump(0.8);
                CHECK(qsoControl(qw, @"DXCC").stringValue.length == 0, "cleared with the call");
                qsoControl(qw, @"GRIDSQUARE").stringValue = @"";
                [qw orderOut:nil];
            }

            // Bulk Edit: DISTANCE from both grid squares.
            run("Bulk Edit...");
            NSWindow *bw = windowTitled(@"Bulk Edit");
            if (bw) {
                NSMutableArray *pops = [NSMutableArray array], *buttons = [NSMutableArray array];
                collect(bw.contentView, NSPopUpButton.class, pops);
                collect(bw.contentView, NSButton.class, buttons);
                for (NSPopUpButton *p in pops) {
                    if ([p indexOfItemWithTitle:@"Fill DISTANCE from grid squares"] >= 0) {
                        [p selectItemWithTitle:@"Fill DISTANCE from grid squares"];
                        [p sendAction:p.action to:p.target];
                    }
                    if ([p indexOfItemWithTitle:@"All records"] >= 0) {
                        [p selectItemWithTitle:@"All records"];
                        [p sendAction:p.action to:p.target];
                    }
                }
                for (NSButton *b in buttons)
                    if ([b.title isEqualToString:@"Only where"] && b.state == NSControlStateValueOn) [b performClick:nil];
                [findButton(bw.contentView, @"Preview") performClick:nil];
                CHECK(status(bw).find("4 changes in 4 records") == 0, "distance preview: %s", status(bw).c_str());
                [bw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(bw.contentView) == 0, "Bulk Edit distance does not overlap (%d)", overlaps(bw.contentView));
                [findButton(bw.contentView, @"Apply 4 Changes") performClick:nil];
                size_t n = 0;
                for (size_t p = H.doc.find("<DISTANCE:"); p != std::string::npos; p = H.doc.find("<DISTANCE:", p + 1)) ++n;
                CHECK(n == 4, "DISTANCE on 4 records (%zu)", n);
                [bw orderOut:nil];
            }

            // Cabrillo.
            run("Export Cabrillo...");
            NSWindow *cw = windowTitled(@"Export Cabrillo");
            if (cw) {
                NSMutableArray *tvs = [NSMutableArray array];
                collect(cw.contentView, NSTextView.class, tvs);
                NSString *cab = @"";  // the longest: a field editor may be in the window too
                for (NSTextView *tv in tvs)
                    if (tv.string.length > cab.length) cab = tv.string;
                CHECK([cab hasPrefix:@"START-OF-LOG: 3.0\nCALLSIGN: KW9D\n"] &&
                          [cab containsString:@"\nQSO: 14000 CW 2026-10-06 2300 KW9D "] && [cab hasSuffix:@"END-OF-LOG:\n"],
                      "Cabrillo:\n%s", cab.UTF8String);
                [cw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(cw.contentView) == 0, "Cabrillo controls do not overlap (%d)", overlaps(cw.contentView));
                snapshot(cw, "export-cabrillo");
                [findButton(cw.contentView, @"Save...") performClick:nil];
                NSString *saved = [NSString stringWithContentsOfFile:[outDir stringByAppendingPathComponent:@"features.log"]
                                                            encoding:NSUTF8StringEncoding
                                                               error:nil];
                CHECK([saved isEqualToString:cab] && status(cw).find("Saved 4 QSOs to features.log") == 0, "Cabrillo saved: %s",
                      status(cw).c_str());
                [cw orderOut:nil];
            }

            // Import CSV: a spreadsheet's names and formats become ADIF.
            NSString *csvPath = [tmp stringByAppendingPathComponent:@"park.csv"];
            [@"\xEF\xBB\xBF" @"Callsign,Date,UTC,Freq (kHz),Mode,Notes\r\nW1AW,2026-10-06,23:10,14250,SSB,\"hello, world\"\r\n"
                writeToFile:csvPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            setenv("ADIFLINT_TEST_OPEN_FILE", csvPath.UTF8String, 1);
            run("Import CSV...");
            NSWindow *iw = windowTitled(@"Import CSV");
            if (iw) {
                [findButton(iw.contentView, @"Choose...") performClick:nil];
                NSTableView *it = findTable(iw.contentView);
                CHECK(tableRows(it) == 1 && [cell(it, 0, @"0") isEqualToString:@"W1AW"] && [cell(it, 0, @"3") isEqualToString:@"20m"],
                      "CSV preview: %s", status(iw).c_str());
                [iw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(iw.contentView) == 0, "Import CSV controls do not overlap (%d)", overlaps(iw.contentView));
                snapshot(iw, "import-csv");
                int undo = H.undoActions;
                [findButton(iw.contentView, @"Add 1 QSO") performClick:nil];
                pump(0.2);
                CHECK(has("<CALL:4>W1AW") && has("<TIME_ON:4>2310") && has("<FREQ:6>14.250") && has("<COMMENT:12>hello, world") &&
                          H.undoActions == undo + 1,
                      "CSV row added in one undo step:\n%s", H.doc.c_str());
                CHECK(status(iw).find("Added 1 QSO from park.csv") == 0, "import status: %s", status(iw).c_str());
                [iw orderOut:nil];
            }
            unsetenv("ADIFLINT_TEST_OPEN_FILE");
            {
                std::string hl;
                CHECK(noErrors(&hl), "the log lints clean after all of that: %s", hl.c_str());
            }

            // Sort and Organize: records by CALL (descending), CALL first in every record.
            run("Sort and Organize...");
            NSWindow *ow = windowTitled(@"Sort and Organize");
            NSTableView *ot = ow ? findTable(ow.contentView) : nil;
            if (ow && ot) {
                NSMutableArray *combos = [NSMutableArray array], *pops = [NSMutableArray array], *boxes = [NSMutableArray array];
                collect(ow.contentView, NSComboBox.class, combos);
                collect(ow.contentView, NSPopUpButton.class, pops);
                collect(ow.contentView, NSButton.class, boxes);
                CHECK(combos.count == 3 && pops.count == 3 && [((NSComboBox *)combos[0]).stringValue isEqualToString:@"QSO_DATE"] &&
                          [((NSComboBox *)combos[1]).stringValue isEqualToString:@"TIME_ON"],
                      "three sort keys, date and time by default");
                ((NSComboBox *)combos[0]).stringValue = @"call";
                ((NSComboBox *)combos[1]).stringValue = @"";
                [(NSPopUpButton *)pops[0] selectItemWithTitle:@"Descending"];
                for (NSButton *b in boxes)
                    if ([b.title hasPrefix:@"Put the fields"] && b.state != NSControlStateValueOn) [b performClick:nil];
                NSInteger callRow = -1;
                for (NSInteger r = 0; r < [ot.dataSource numberOfRowsInTableView:ot]; ++r)
                    if ([cell(ot, r, @"1") isEqualToString:@"CALL"]) callRow = r;
                CHECK(callRow == 2, "the fields in the Log Table's order: CALL third (%ld)", (long)callRow);
                [ot selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)callRow] byExtendingSelection:NO];
                [findButton(ow.contentView, @"Move Up") performClick:nil];
                [findButton(ow.contentView, @"Move Up") performClick:nil];
                CHECK([cell(ot, 0, @"1") isEqualToString:@"CALL"] && ot.selectedRow == 0, "CALL moved to the top, still selected");
                [ow.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(ow.contentView) == 0, "Sort and Organize controls do not overlap (%d)", overlaps(ow.contentView));
                snapshot(ow, "sort-organize");
                int undo = H.undoActions;
                [findButton(ow.contentView, @"Apply") performClick:nil];
                pump(0.2);
                std::vector<std::string> order;
                bool callFirst = true;
                for (size_t p = H.doc.find("<EOH>"); (p = H.doc.find('\n', p)) != std::string::npos;) {
                    ++p;
                    if (H.doc.compare(p, 1, "<") != 0) continue;
                    callFirst &= H.doc.compare(p, 6, "<CALL:") == 0;
                    size_t v = H.doc.find('>', p) + 1;
                    order.push_back(H.doc.substr(v, H.doc.find(' ', v) - v));
                }
                CHECK(order == std::vector<std::string>({"W8NEW", "W1AW", "K1AE", "K1AD", "DL1AB"}) && callFirst && H.undoActions == undo + 1,
                      "sorted by CALL descending, CALL first, one undo step:\n%s", H.doc.c_str());
                CHECK(status(ow).find("Sorted 5 records by CALL (descending). Put the fields of 4 records in order.") == 0,
                      "organize status: %s", status(ow).c_str());
                CHECK(ini().find("organizeSort=CALL:d\n") != std::string::npos && ini().find("organizeFields=CALL,QSO_DATE,TIME_ON,") != std::string::npos,
                      "the choices are remembered");
                {
                    std::string hl;
                    CHECK(noErrors(&hl), "still clean after organizing: %s", hl.c_str());
                }
                [ow orderOut:nil];
            }
            // From the Log Table: its sort fills in the window.
            run("Log Table...");
            NSWindow *tw2 = windowTitled(@"Log Table");
            NSTableView *tt = tw2 ? findTable(tw2.contentView) : nil;
            if (tt) {
                NSInteger timeCol = -1;
                for (NSTableColumn *c in tt.tableColumns)
                    if ([c.title isEqualToString:@"TIME_ON"]) timeCol = c.identifier.integerValue;
                tt.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:[NSString stringWithFormat:@"%ld", (long)timeCol] ascending:NO] ];
                [findButton(tw2.contentView, @"Organize Log...") performClick:nil];
                NSWindow *ow2 = windowTitled(@"Sort and Organize");
                NSMutableArray *combos = [NSMutableArray array], *pops = [NSMutableArray array];
                if (ow2) {
                    collect(ow2.contentView, NSComboBox.class, combos);
                    collect(ow2.contentView, NSPopUpButton.class, pops);
                }
                CHECK(combos.count == 3 && [((NSComboBox *)combos[0]).stringValue isEqualToString:@"TIME_ON"] &&
                          ((NSPopUpButton *)pops[0]).indexOfSelectedItem == 1 && ((NSComboBox *)combos[1]).stringValue.length == 0,
                      "Organize Log... takes the table's sort (TIME_ON descending)");
                [ow2 orderOut:nil];
                tt.sortDescriptors = @[];
                [tw2 orderOut:nil];
            }

            // WWFF and SOTA: the tracker and the export follow the program.
            auto spec = [](const char *name, const std::string &v) { return "<" + std::string(name) + ":" + std::to_string(v.size()) + ">" + v + " "; };
            auto prec = [&](const char *call, const char *date, const char *time, const char *refField, const char *ref) {
                return spec("CALL", call) + spec("QSO_DATE", date) + spec("TIME_ON", time) + spec("BAND", "40m") + spec("MODE", "CW") +
                       spec("STATION_CALLSIGN", "KW9D") + spec(refField, ref) + "<EOR>\n";
            };
            H.doc = "programs\n<ADIF_VER:5>3.1.7\n<EOH>\n" + prec("K1AA", "20261006", "1500", "MY_WWFF_REF", "KFF-1234") +
                    prec("K1AB", "20261006", "1501", "MY_WWFF_REF", "KFF-1234") + prec("K1AC", "20261006", "1502", "MY_WWFF_REF", "KFF-1234") +
                    prec("N7AA", "20261007", "1800", "MY_SOTA_REF", "W7A/AE-001") + prec("N7AB", "20261007", "1801", "MY_SOTA_REF", "W7A/AE-001") +
                    prec("N7AC", "20261007", "1802", "MY_SOTA_REF", "W7A/AE-001") + prec("N7AD", "20261007", "1803", "MY_SOTA_REF", "W7A/AE-001");
            H.path = "/tmp/programs.adi";
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.5);
            run("Activation Tracker (POTA, WWFF, SOTA)...");
            NSWindow *aw = windowTitled(@"Activation Tracker");
            NSTableView *at = aw ? findTable(aw.contentView) : nil;
            NSPopUpButton *prog = aw ? findPopup(aw.contentView) : nil;
            if (at && prog) {
                CHECK(tableRows(at) == 0 && [labelWithLines(aw.contentView, 2) containsString:@"No POTA activations"], "no POTA here");
                [prog selectItemWithTitle:@"WWFF"];
                [prog sendAction:prog.action to:prog.target];
                CHECK(tableRows(at) == 1 && [cell(at, 0, @"0") isEqualToString:@"KFF-1234"] && [cell(at, 0, @"3") isEqualToString:@"3"] &&
                          [cell(at, 0, @"4") isEqualToString:@"41 more"],
                      "WWFF: %s %s %s", cell(at, 0, @"0").UTF8String, cell(at, 0, @"3").UTF8String, cell(at, 0, @"4").UTF8String);
                CHECK([labelWithLines(aw.contentView, 2) containsString:@"KFF-1234 (all days): 3 QSOs, 41 more to activate"],
                      "WWFF headline: %s", labelWithLines(aw.contentView, 2).UTF8String);
                [prog selectItemWithTitle:@"SOTA"];
                [prog sendAction:prog.action to:prog.target];
                CHECK(tableRows(at) == 1 && [cell(at, 0, @"0") isEqualToString:@"W7A/AE-001"] && [cell(at, 0, @"4") isEqualToString:@"done"],
                      "SOTA: %s %s", cell(at, 0, @"0").UTF8String, cell(at, 0, @"4").UTF8String);
                CHECK([labelWithLines(aw.contentView, 2) containsString:@"W7A/AE-001 on 2026-10-07: 4 stations, points scored"],
                      "SOTA headline: %s", labelWithLines(aw.contentView, 2).UTF8String);
                CHECK(ini().find("trackerProgram=SOTA") != std::string::npos, "the program is remembered");
                [aw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(aw.contentView) == 0, "Tracker with the program row does not overlap (%d)", overlaps(aw.contentView));
                snapshot(aw, "activation-tracker-sota");
                [findButton(aw.contentView, @"Export Logs...") performClick:nil];
                NSWindow *pw = windowTitled(@"Export Activation Logs");
                NSTableView *pt = pw ? findTable(pw.contentView) : nil;
                CHECK(pt && tableRows(pt) == 1 && [cell(pt, 0, @"0") isEqualToString:@"KW9D_W7A-AE-001_20261007.adi"], "SOTA file: %s",
                      pt ? cell(pt, 0, @"0").UTF8String : "");
                if (pw && pt) {
                    [findButton(pw.contentView, @"Save 1 File") performClick:nil];
                    // The folder chosen in the POTA export earlier is remembered.
                    NSString *sf = [NSString stringWithContentsOfFile:[[tmp stringByAppendingPathComponent:@"out"]
                                                                          stringByAppendingPathComponent:@"KW9D_W7A-AE-001_20261007.adi"]
                                                             encoding:NSUTF8StringEncoding
                                                                error:nil];
                    CHECK([sf containsString:@"<MY_SOTA_REF:10>W7A/AE-001"] && [sf containsString:@"<CALL:4>N7AD"], "SOTA file written:\n%s",
                          sf.UTF8String);
                    NSPopUpButton *ep = findPopupWith(pw.contentView, @"WWFF");
                    [ep selectItemWithTitle:@"WWFF"];
                    [ep sendAction:ep.action to:ep.target];
                    CHECK(tableRows(pt) == 1 && [cell(pt, 0, @"0") isEqualToString:@"KW9D @ KFF-1234 20261006.adi"], "WWFF file: %s",
                          cell(pt, 0, @"0").UTF8String);
                    [pw.contentView layoutSubtreeIfNeeded];
                    CHECK(overlaps(pw.contentView) == 0, "Export with the program row does not overlap (%d)", overlaps(pw.contentView));
                    snapshot(pw, "export-wwff");
                    [pw orderOut:nil];
                }
                [prog selectItemWithTitle:@"POTA"];
                [prog sendAction:prog.action to:prog.target];
                [aw orderOut:nil];
            }

            // Settings: Update the country file (fixture), saved beside ADIFLint.ini.
            run("Settings...");
            NSWindow *setw = windowTitled(@"ADIF Lint Settings");
            NSView *country = setw ? viewWithIdentifier(setw.contentView, @"settings.country") : nil;
            CHECK(country && findButton(country, @"Update"), "Country Data section with Update");
            if (country) {
                auto countryStatus = [&]() {
                    NSMutableArray *labels = [NSMutableArray array];
                    collect(country, NSTextField.class, labels);
                    return std::string(((NSTextField *)labels.lastObject).stringValue.UTF8String);
                };
                CHECK(countryStatus().find("(installed with ADIF Lint)") != std::string::npos, "country status: %s", countryStatus().c_str());
                [findButton(country, @"Update") performClick:nil];
                for (int i = 0; i < 40 && countryStatus().find("Updated") == std::string::npos; ++i) pump(0.05);
                CHECK(countryStatus().find("Updated to bigcty-test") == 0 &&
                          [[NSFileManager defaultManager] fileExistsAtPath:[tmp stringByAppendingPathComponent:@"ADIFLint-cty.csv"]],
                      "country file updated: %s", countryStatus().c_str());
                [setw orderOut:nil];
            }
        }

        // ── Check Log: every problem, and the known repairs applied together ──
        {
            H.doc = "check\n<ADIF_VER:5>3.1.7\n<EOH>\n"
                    "<CALL:4>k1aa <QSO_DATE:10>2026-10-06 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>USB <STATION_CALLSIGN:4>KW9D <EOR>\n"
                    "<CALL:4>K1BB <QSO_DATE:8>20261006 <TIME_ON:5>22:05 <FREQ:5>14074 <BAND:3>20m <MODE:3>FT8 <SAT_NAME:4>AO-7 "
                    "<STATION_CALLSIGN:4>KW9D <EOR>\n";
            H.path = "/tmp/check.adi";
            H.pos = 0;
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.5);
            run("Check Log...");
            NSWindow *cw = windowTitled(@"Check Log");
            NSTableView *ct = cw ? findTable(cw.contentView) : nil;
            long rows = ct ? (long)[ct.dataSource numberOfRowsInTableView:ct] : -1L;
            NSInteger modeRow = -1;
            for (NSInteger r = 0; r < rows; ++r)
                if ([cell(ct, r, @"5") isEqualToString:@"MODE SSB, SUBMODE USB"]) modeRow = r;
            CHECK(cw && rows == 6 && modeRow >= 0 && [cell(ct, modeRow, @"0") isEqualToString:@"1"],
                  "Check Log lists 6 problems, MODE USB with its repair (%ld rows)", rows);
            if (cw) {
                [cw.contentView layoutSubtreeIfNeeded];
                snapshot(cw, "check-log");
                CHECK(overlaps(cw.contentView) == 0, "Check Log does not overlap (%d)", overlaps(cw.contentView));
            }
            NSButton *repair = cw ? findButton(cw.contentView, @"Repair 6 Ticked") : nil;
            CHECK(repair != nil, "the button counts the 6 ticked repairs");
            [repair performClick:nil];
            pump(0.5);
            auto has = [](const std::string &x) { return H.doc.find(x) != std::string::npos; };
            CHECK(has("<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>SSB") && has("<SUBMODE:3>USB") &&
                      has("<TIME_ON:4>2205 <FREQ:6>14.074") && has("<PROP_MODE:3>SAT"),
                  "the repairs, as one change:\n%s", H.doc.c_str());
            NSString *head = cw ? labelWithLines(cw.contentView, 2) : nil;
            CHECK([head isEqualToString:@"No problems found."], "nothing left: %s", head.UTF8String);

            // The Record Panel's right-click repair.
            H.doc = "panel\n<ADIF_VER:5>3.1.7\n<EOH>\n<CALL:4>K1CC <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>FT4 <EOR>\n";
            H.pos = (intptr_t)H.doc.find("<MODE");
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.5);
            CHECK(labelContaining(H.panelView, @"1 error, 0 warnings") != nil, "the panel's log line counts the error");
            NSTableView *pt = findTable(H.panelView);
            id panel = pt.menu.delegate;
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
            item.tag = 4;  // MODE, the record's fifth field
            if ([panel respondsToSelector:@selector(repairRow:)]) [panel performSelector:@selector(repairRow:) withObject:item];
            pump(0.3);
            CHECK(has("<MODE:4>MFSK <SUBMODE:3>FT4 <EOR>"), "the panel repaired MODE FT4:\n%s", H.doc.c_str());
            CHECK(labelContaining(H.panelView, @"No problems") != nil, "the log line after the repair");

            // The log line: QSOs waiting for a service the log uses, and today's activation.
            std::string today = utcDate();
            H.doc = "health\n<ADIF_VER:5>3.1.7\n<EOH>\n<CALL:4>K1AA <QSO_DATE:8>" + today +
                    " <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <STATION_CALLSIGN:4>KW9D <MY_POTA_REF:7>US-7929 "
                    "<QRZCOM_QSO_UPLOAD_STATUS:1>Y <EOR>\n<CALL:4>K1AB <QSO_DATE:8>" + today +
                    " <TIME_ON:4>1201 <BAND:3>20m <MODE:2>CW <STATION_CALLSIGN:4>KW9D <MY_POTA_REF:7>US-7929 <EOR>\n";
            H.pos = 0;
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.5);
            NSString *line = labelContaining(H.panelView, @"to upload");
            CHECK([line containsString:@"to upload: QRZ 1"] && [line containsString:@"US-7929 today: 2 of 10"] &&
                      ![line containsString:@"LoTW"],
                  "the log line: %s", line.UTF8String);

            // Problems with no repair: their field is named, and they have no tick box. A service
            // that only says N (QRZ.com writes EQSL_QSL_SENT N) isn't "to upload".
            H.doc = "norepair\n<ADIF_VER:5>3.1.7\n<EOH>\n<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m "
                    "<MODE:4>DATA <USER_DEFINED_9:8>20230721 <QRZCOM_QSO_UPLOAD_STATUS:1>Y <EQSL_QSL_SENT:1>N <EOR>\n";
            H.pos = 0;
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.5);
            run("Check Log...");
            long nr = ct ? (long)[ct.dataSource numberOfRowsInTableView:ct] : -1L;
            bool named = nr == 2, hidden = nr == 2;
            for (NSInteger r = 0; r < nr; ++r) {
                NSString *field = cell(ct, r, @"3");
                named &= [field isEqualToString:@"MODE"] || [field isEqualToString:@"USER_DEFINED_9"];
                NSView *tick = [ct.delegate tableView:ct viewForTableColumn:[ct tableColumnWithIdentifier:@"__use"] row:r];
                hidden &= tick.hidden;
            }
            CHECK(named && hidden, "no-repair rows: field named, no tick box (%ld rows)", nr);
            NSString *noEqsl = labelContaining(H.panelView, @"error");
            CHECK(noEqsl && ![noEqsl containsString:@"eQSL"] && ![noEqsl containsString:@"to upload"], "N alone isn't a service in use: %s",
                  noEqsl.UTF8String);

            // A problem repeated in many records is one row; repairing it repairs them all.
            H.doc = "grouped\n<ADIF_VER:5>3.1.7\n<EOH>\n";
            for (int i = 0; i < 3; ++i)
                H.doc += "<CALL:4>K1A" + std::to_string(i) + " <QSO_DATE:10>2026-10-06 <TIME_ON:4>120" + std::to_string(i) +
                         " <BAND:3>20m <MODE:2>CW <IOTA:4>none <USER_DEFINED_9:8>20230721 <EOR>\n";
            H.pos = 0;
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.5);
            run("Check Log...");
            long gr = ct ? (long)[ct.dataSource numberOfRowsInTableView:ct] : -1L;
            NSString *firstWhere = gr > 0 ? cell(ct, 0, @"0") : @"";
            CHECK(gr == 3 && [firstWhere isEqualToString:@"1 +2"] && [cell(ct, 0, @"4") hasPrefix:@"(3 records) "],
                  "three problems in three records: three rows (%ld), the first '%s'", gr, firstWhere.UTF8String);
            if (cw) {
                [cw.contentView layoutSubtreeIfNeeded];
                snapshot(cw, "check-log-grouped");
                CHECK(overlaps(cw.contentView) == 0, "Check Log with grouping does not overlap");
            }
            NSButton *repairAll = cw ? findButton(cw.contentView, @"Repair 6 Ticked") : nil;
            CHECK(repairAll != nil, "two ticked rows repair six problems");
            [repairAll performClick:nil];
            pump(0.4);
            CHECK(!has("2026-10-06") && !has("<IOTA") && has("<USER_DEFINED_9"), "dates and IOTA none repaired in every record:\n%s",
                  H.doc.c_str());
            [cw close];
        }

        // ── Log Table as a spreadsheet ──
        {
            NSString *savedClipboard = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
            H.doc = "grid\n<ADIF_VER:5>3.1.7\n<EOH>\n"
                    "<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:2>CW <STATION_CALLSIGN:4>KW9D <EOR>\n"
                    "<CALL:4>K1BB <QSO_DATE:8>20261006 <TIME_ON:4>2205 <BAND:3>20m <MODE:2>CW <STATION_CALLSIGN:4>KW9D <EOR>\n"
                    "<CALL:4>K1CC <QSO_DATE:8>20261006 <TIME_ON:4>2210 <BAND:3>40m <MODE:3>SSB <STATION_CALLSIGN:4>KW9D <EOR>\n";
            H.path = "/tmp/grid.adi";
            H.pos = 0;
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.5);
            run("Log Table...");
            NSWindow *gw = windowTitled(@"Log Table");
            NSTableView *gt = gw ? findTable(gw.contentView) : nil;
            id tw = gt.delegate;
            auto has = [](const std::string &x) { return H.doc.find(x) != std::string::npos; };
            auto colOf = [&](NSString *title) -> NSInteger {
                for (NSTableColumn *c in gt.tableColumns)
                    if ([c.title isEqualToString:title]) return c.identifier.integerValue;
                return -1;
            };
            auto shownCol = [&](NSString *title) { return [gt columnWithIdentifier:[NSString stringWithFormat:@"%ld", (long)colOf(title)]]; };
            auto key = [&](unsigned short code, NSString *chars, NSEventModifierFlags mods) {
                NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods timestamp:0
                                          windowNumber:gw.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars
                                             isARepeat:NO keyCode:code];
                [gt keyDown:e];
            };
            // The cell being edited: the field editor's delegate (a view-based table has no editedRow).
            auto editing = [&]() -> NSTextField * {
                id fr = gw.firstResponder;
                if (![fr isKindOfClass:NSTextView.class]) return nil;
                id f = ((NSTextView *)fr).delegate;
                return [f isKindOfClass:NSTextField.class] && [(NSView *)f isDescendantOf:gt] ? (NSTextField *)f : nil;
            };
            auto editedRow = [&]() { return editing() ? [gt rowForView:editing()] : (NSInteger)-1; };
            auto editedCol = [&]() { return editing() ? [gt columnForView:editing()] : (NSInteger)-1; };
            auto editor = [&]() { return editing() ? (NSTextView *)gw.firstResponder : (NSTextView *)nil; };
            auto command = [&](SEL sel) {  // a key pressed while a cell is edited
                NSTextField *field = editing();
                return field ? (BOOL)[tw control:field textView:editor() doCommandBySelector:sel] : NO;
            };
            auto menuItem = [&](NSMenu *menu, NSString *title) {
                NSInteger i = [menu indexOfItemWithTitle:title];
                CHECK(i >= 0, "menu item %s", title.UTF8String);
                if (i >= 0) [menu performActionForItemAtIndex:i];
                pump(0.1);
            };
            auto select = [&](std::vector<NSInteger> rows) {
                NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
                for (NSInteger r : rows) [set addIndex:(NSUInteger)r];
                [gt selectRowIndexes:set byExtendingSelection:NO];
            };
            CHECK(gt && [tw valueForKey:@"spreadsheet"] && [[tw valueForKey:@"spreadsheet"] boolValue], "the Log Table is a spreadsheet");
            if (gt) {
                // Return edits the active cell; Tab saves and edits the next cell; Return saves and moves down.
                select({0});
                [tw setValue:@(colOf(@"CALL")) forKey:@"activeColumn"];
                int undo = H.undoActions;
                key(36, @"\r", 0);
                CHECK(editedRow() == 0 && editedCol() == shownCol(@"CALL"), "Return edits CALL (%ld, %ld)", (long)editedRow(),
                      (long)editedCol());
                editor().string = @"k1ax";
                CHECK(command(@selector(insertTab:)) && has("<CALL:4>k1ax <QSO_DATE") && editedCol() == shownCol(@"BAND"),
                      "Tab saved CALL and edits BAND:\n%s", H.doc.c_str());
                editor().string = @"17m";
                CHECK(command(@selector(insertNewline:)) && has("<BAND:3>17m <MODE:2>CW <STATION_CALLSIGN:4>KW9D <EOR>\n<CALL:4>K1BB") &&
                          editedRow() == -1 && gt.selectedRow == 1 && H.undoActions == undo + 2,
                      "Return saved BAND and moved down; one undo step per cell");
                // Typing starts editing the active cell with the character; Esc puts the value back.
                key(18, @"1", 0);
                CHECK(editedRow() == 1 && [editor().string isEqualToString:@"1"], "typing starts editing");
                CHECK(command(@selector(cancelOperation:)) && editedRow() == -1 &&
                          has("<CALL:4>K1BB <QSO_DATE:8>20261006 <TIME_ON:4>2205 <BAND:3>20m"),
                      "Esc leaves BAND as it was");
                snapshot(gw, "log-table-grid");

                // Fill Down: the first selected row's MODE to the others.
                select({0, 1, 2});
                [tw setValue:@(colOf(@"MODE")) forKey:@"activeColumn"];
                menuItem(gt.menu, @"Fill Down");
                CHECK(has("<CALL:4>K1CC <QSO_DATE:8>20261006 <TIME_ON:4>2210 <BAND:3>40m <MODE:2>CW"), "MODE filled down:\n%s", H.doc.c_str());

                // Copy: the selected rows with a heading row, tab-separated, dates and times readable.
                select({0, 1});
                menuItem(gt.menu, @"Copy");
                NSString *copied = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
                CHECK([copied hasPrefix:@"QSO_DATE\tTIME_ON\tCALL\tBAND\tMODE\tSTATION_CALLSIGN\r\n2026-10-06\t22:00\tk1ax\t17m\tCW\tKW9D\r\n"],
                      "copied:\n%s", copied.UTF8String);

                // Paste with a heading row and nothing selected: new QSOs at the end.
                [NSPasteboard.generalPasteboard clearContents];
                [NSPasteboard.generalPasteboard setString:@"CALL\tQSO_DATE\tTIME_ON\tBAND\tMODE\r\nN0NEW\t2026-10-07\t01:15\t40m\tSSB\r\n"
                                                  forType:NSPasteboardTypeString];
                [gt deselectAll:nil];
                undo = H.undoActions;
                menuItem(gt.menu, @"Paste");
                CHECK(has("<CALL:5>N0NEW <QSO_DATE:8>20261007 <TIME_ON:4>0115 <BAND:3>40m <MODE:3>SSB <EOR>") && H.undoActions == undo + 1,
                      "pasted rows become new QSOs:\n%s", H.doc.c_str());
                // Paste a block of cells from the active cell down.
                [NSPasteboard.generalPasteboard clearContents];
                [NSPasteboard.generalPasteboard setString:@"15m\tFT8\r\n10m\tSSB\r\n" forType:NSPasteboardTypeString];
                select({1});
                [tw setValue:@(colOf(@"BAND")) forKey:@"activeColumn"];
                menuItem(gt.menu, @"Paste");
                CHECK(has("<CALL:4>K1BB <QSO_DATE:8>20261006 <TIME_ON:4>2205 <BAND:3>15m <MODE:3>FT8") &&
                          has("<CALL:4>K1CC <QSO_DATE:8>20261006 <TIME_ON:4>2210 <BAND:3>10m <MODE:3>SSB"),
                      "a block pasted into BAND and MODE of two rows:\n%s", H.doc.c_str());

                // Delete clears the active cell; Command-Delete deletes the rows.
                select({2});
                [tw setValue:@(colOf(@"STATION_CALLSIGN")) forKey:@"activeColumn"];
                key(51, @"\x7f", 0);
                CHECK(has("<BAND:3>10m <MODE:3>SSB <EOR>"), "Delete removed STATION_CALLSIGN from K1CC:\n%s", H.doc.c_str());
                NSInteger newRow = -1;
                for (NSInteger r = 0; r < [gt.dataSource numberOfRowsInTableView:gt]; ++r)
                    if ([cell(gt, r, [NSString stringWithFormat:@"%ld", (long)colOf(@"CALL")]) isEqualToString:@"N0NEW"]) newRow = r;
                select({newRow});
                key(51, @"\x7f", NSEventModifierFlagCommand);
                CHECK(!has("N0NEW") && has("K1CC"), "Command-Delete deleted N0NEW only");

                // Add Row: today's date and time, the station's fields, and CALL being edited.
                [findButton(gw.contentView, @"Add Row") performClick:nil];
                pump(0.1);
                CHECK(editedCol() == shownCol(@"CALL") && has("<QSO_DATE:8>" + utcDate()), "Add Row: a new QSO, CALL edited (%ld)",
                      (long)editedCol());
                if (editedRow() >= 0) {
                    editor().string = @"W9NEW";
                    command(@selector(insertNewline:));
                }
                // The last record had STATION_CALLSIGN cleared above, so BAND and MODE are what carry over.
                size_t w9 = H.doc.find("<CALL:5>W9NEW");
                size_t w9b = w9 == std::string::npos ? 0 : H.doc.rfind("\n", w9) + 1;
                CHECK(w9 != std::string::npos &&
                          H.doc.compare(w9b, std::string("<QSO_DATE:8>" + utcDate()).size(), "<QSO_DATE:8>" + utcDate()) == 0 &&
                          H.doc.find("<BAND:3>10m <MODE:3>SSB", w9b) < w9,
                      "the new QSO: today's date, BAND and MODE carried from the last record, CALL typed:\n%s", H.doc.c_str());

                // Add a field as a column, fill one cell, then remove the field from every record.
                menuItem(gt.headerView.menu, @"Add Field...");
                NSMutableArray *combos = [NSMutableArray array];
                collect(gw.contentView, NSComboBox.class, combos);
                NSComboBox *addName = nil;
                for (NSComboBox *c in combos)
                    if ([c.placeholderString isEqualToString:@"e.g. RST_SENT"]) addName = c;
                CHECK(addName && !addName.superview.hidden, "Add field row shown");
                addName.stringValue = @"rst_sent";
                [findButton(gw.contentView, @"Add Column") performClick:nil];
                pump(0.1);
                CHECK(colOf(@"RST_SENT") > 0 && [[tw valueForKey:@"activeColumn"] integerValue] == colOf(@"RST_SENT"),
                      "RST_SENT column added and active");
                select({0});
                key(36, @"\r", 0);
                editor().string = @"599";
                command(@selector(insertNewline:));
                CHECK(has("<CALL:4>k1ax") && has("<RST_SENT:3>599 <EOR>"), "RST_SENT typed into the new column:\n%s", H.doc.c_str());
                void (^menuOpen)(NSInteger) = [tw valueForKey:@"onHeaderMenuOpen"];
                menuOpen(colOf(@"RST_SENT"));
                menuItem(gt.headerView.menu, @"Remove RST_SENT from Every Record");
                CHECK(!has("RST_SENT") && colOf(@"RST_SENT") < 0, "RST_SENT removed from every record");
                [gw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(gw.contentView) == 0, "Log Table controls do not overlap (%d)", overlaps(gw.contentView));
                {
                    std::string hl;
                    CHECK(noErrors(&hl), "the log is clean after all that: %s", hl.c_str());
                }
                [gw orderOut:nil];
            }
            [NSPasteboard.generalPasteboard clearContents];
            if (savedClipboard) [NSPasteboard.generalPasteboard setString:savedClipboard forType:NSPasteboardTypeString];
        }

        // ── Station profiles and activations ──
        {
            NSString *work = [tmp stringByAppendingPathComponent:@"activations"];
            [[NSFileManager defaultManager] createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
            run("Settings...");
            NSWindow *sw = windowTitled(@"ADIF Lint Settings");
            [findButton(sw.contentView, @"Station Profiles...") performClick:nil];
            [sw orderOut:nil];
            NSWindow *pw = windowTitled(@"Station Profiles");
            NSTableView *pt = pw ? findTable(pw.contentView) : nil;
            [findButton(pw.contentView, @"Add") performClick:nil];
            pump(0.1);
            [pw makeFirstResponder:nil];  // Add starts editing the name; the test types through onEditCell
            id ptw = pt.delegate;
            void (^editCell)(NSInteger, size_t, NSString *) = [ptw valueForKey:@"onEditCell"];
            CHECK(pw && editCell && [pt.dataSource numberOfRowsInTableView:pt] == 1, "Station Profiles: a profile added");
            if (editCell) {
                editCell(0, 0, @"Portable");
                editCell(0, 1, @"kw9d");
                editCell(0, 3, @"en52WA");
                editCell(0, 8, @"5W");
                CHECK([labelWithLines(pw.contentView, 4) containsString:@"number of watts"], "a power with its unit is refused");
                editCell(0, 8, @"5");
                editCell(0, 6, @"Elecraft T1");
            }
            NSString *saved = [NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"ADIFLint-profiles.adi"]
                                                        encoding:NSUTF8StringEncoding
                                                           error:nil];
            CHECK([saved containsString:@"<APP_ADIFLINT_PROFILE:8>Portable <STATION_CALLSIGN:4>KW9D <MY_GRIDSQUARE:6>EN52wa"] &&
                      [saved containsString:@"<TX_PWR:1>5"] && [saved containsString:@"<MY_RIG:11>Elecraft T1"],
                  "the profile saved: %s", saved.UTF8String);
            if (pw) {
                [pw.contentView layoutSubtreeIfNeeded];
                snapshot(pw, "station-profiles");
                CHECK(overlaps(pw.contentView) == 0, "Station Profiles does not overlap");
            }
            [pw orderOut:nil];

            // Start Activation: a two-fer into a new log, New QSO opening on it.
            H.doc = "old\n<ADIF_VER:5>3.1.7\n<EOH>\n";
            H.path = "/tmp/old.adi";
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.3);
            run("Start Activation...");
            NSWindow *aw = windowTitled(@"Start Activation");
            NSMutableArray *fields = [NSMutableArray array];
            collect(aw.contentView, NSTextField.class, fields);
            NSTextField *refs = nil;
            for (NSTextField *f in fields)
                if ([f.placeholderString hasPrefix:@"e.g. US-7929"]) refs = f;
            refs.stringValue = @"us-7929, US-1234";
            [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:refs];
            NSPopUpButton *profile = findPopupWith(aw.contentView, @"Portable");
            [profile selectItemWithTitle:@"Portable"];
            [profile sendAction:profile.action to:profile.target];
            setenv("ADIFLINT_TEST_FOLDER", work.UTF8String, 1);
            [findButton(aw.contentView, @"Choose...") performClick:nil];
            unsetenv("ADIFLINT_TEST_FOLDER");
            std::string name = "KW9D@US-7929+US-1234-" + utcDate() + ".adi";
            CHECK(labelContaining(aw.contentView, @(name.c_str())) != nil, "the new log's name: %s", name.c_str());
            if (aw) {
                [aw.contentView layoutSubtreeIfNeeded];
                snapshot(aw, "start-activation");
                CHECK(overlaps(aw.contentView) == 0, "Start Activation does not overlap");
            }
            [findButton(aw.contentView, @"Start") performClick:nil];
            pump(0.5);
            std::string file = std::string(work.UTF8String) + "/" + name;
            CHECK(!H.opened.empty() && H.opened.back() == file && H.path == file && H.doc.find("<EOH>") != std::string::npos,
                  "the new log created and opened: %s", H.path.c_str());
            NSWindow *qw5 = windowTitled(@"New QSO");
            CHECK(qw5.visible, "New QSO opened on the new log");
            NSString *note = qw5 ? labelContaining(qw5.contentView, @"activating") : nil;
            CHECK([note containsString:@"profile Portable, activating US-7929, US-1234"] &&
                      [note containsString:@"MY_POTA_REF US-7929,US-1234"],
                  "New QSO names what it will write: %s", note.UTF8String);
            qsoControl(qw5, @"CALL").stringValue = @"K1PRK";
            qsoControl(qw5, @"BAND").stringValue = @"20m";
            qsoControl(qw5, @"MODE").stringValue = @"CW";
            [findButton(qw5.contentView, @"Log QSO") performClick:nil];
            pump(0.3);
            CHECK(H.doc.find("<CALL:5>K1PRK") != std::string::npos && H.doc.find("<MY_POTA_REF:15>US-7929,US-1234") != std::string::npos &&
                      H.doc.find("<MY_SIG:4>POTA") != std::string::npos && H.doc.find("<STATION_CALLSIGN:4>KW9D") != std::string::npos &&
                      H.doc.find("<MY_GRIDSQUARE:6>EN52wa") != std::string::npos && H.doc.find("<TX_PWR:1>5") != std::string::npos,
                  "the QSO carries the profile and the activation:\n%s", H.doc.c_str());
            CHECK(labelContaining(qw5.contentView, @"US-7929 today: 1 of 10") != nil, "New QSO shows the activation's progress");

            // Finish: Check Log and the export open; New QSO stops writing the activation.
            [findButton(aw.contentView, @"Finish...") performClick:nil];
            pump(0.3);
            CHECK(windowTitled(@"Check Log").visible && windowTitled(@"Export Activation Logs").visible, "Finish opens Check Log and Export");
            NSString *settingsText = [NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"ADIFLint.ini"]
                                                               encoding:NSUTF8StringEncoding
                                                                  error:nil];
            CHECK([settingsText containsString:@"activationActive=0\n"], "the activation is over");
            for (NSString *t in @[ @"Check Log", @"Export Activation Logs", @"Start Activation", @"New QSO" ]) [windowTitled(t) orderOut:nil];
        }


        // ── Monitor: QSOs other programs announce, into the chosen log ──
        {
            NSString *work = [tmp stringByAppendingPathComponent:@"monitor"];
            [[NSFileManager defaultManager] createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];
            const int base = 47000 + (int)(getpid() % 500) * 4;  // WSJT-X, ADIF, N1MM, TCP: away from the real ports
            setenv("ADIFLINT_TEST_PORTS", std::to_string(base).c_str(), 1);
            const std::string logPath = std::string(work.UTF8String) + "/station.adi";
            const std::string otherPath = std::string(work.UTF8String) + "/other.adi";
            const std::string otherDoc = "other\n<ADIF_VER:5>3.1.7\n<EOH>\n";
            auto count = [](const std::string &hay, const std::string &needle) {
                size_t n = 0;
                for (size_t at = hay.find(needle); at != std::string::npos; at = hay.find(needle, at + 1)) ++n;
                return n;
            };
            auto activate = [&](const std::string &path, const std::string &doc, std::vector<std::string> others) {
                H.doc = doc;
                H.path = path;
                H.openFiles = std::move(others);
                notify(NPPN_BUFFERACTIVATED);
                notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
                pump(0.3);
            };
            activate(logPath, "station\n<ADIF_VER:5>3.1.7\n<EOH>\n", {});
            run("Monitor (WSJT-X, N1MM, Loggers)...");
            NSWindow *mw = windowTitled(@"Monitor");
            NSTableView *mt = mw ? findTable(mw.contentView) : nil;
            CHECK(mw.visible && mt, "Monitor opens");
            [findButton(mw.contentView, @"Use the Open Log") performClick:nil];
            for (NSString *t in @[ @"N1MM Logger+ contacts (XML) port", @"Logger commands over TCP (DXKeeper, HRD form) port" ]) {
                NSButton *b = findButton(mw.contentView, t);
                CHECK(b && b.state == NSControlStateValueOff, "%s is off at first", t.UTF8String);
                [b performClick:nil];
            }
            [findButton(mw.contentView, @"Start") performClick:nil];
            pump(0.2);
            NSString *head = labelWithLines(mw.contentView, 2);
            std::string ports = std::to_string(base);
            CHECK([head containsString:@(("Listening: WSJT-X " + ports).c_str())] && [head containsString:@"N1MM"] && [head containsString:@"TCP"] &&
                      findButton(mw.contentView, @"Stop") != nil,
                  "Monitor listens: %s", head.UTF8String);
            auto lastResult = [&]() { return std::string(cell(mt, 0, @"7").UTF8String ?: ""); };  // the Result column

            // WSJT-X sends QSO Logged, then Logged ADIF, for one QSO: one record, from the ADIF.
            std::string adif = "\n<adif_ver:5>3.1.0\n<programid:6>WSJT-X\n<EOH>\n<call:4>W1AW <gridsquare:4>FN31 <mode:3>FT8 "
                               "<rst_sent:3>-10 <rst_rcvd:3>-12 <qso_date:8>20261009 <time_on:6>120015 <qso_date_off:8>20261009 "
                               "<time_off:6>120130 <band:3>20m <freq:9>14.075123 <station_callsign:4>KW9D <my_gridsquare:4>EN52 <eor>";
            sendUdp(base, wsjtxQsoLogged("W1AW", "FT8", 14075123, (12 * 3600 + 15) * 1000));
            sendUdp(base, wsjtxMessage(12) + qString(adif));
            pump(0.4);
            CHECK(count(H.doc, "<CALL:4>W1AW") == 1 && H.doc.find("<FREQ:9>14.075123") != std::string::npos &&
                      lastResult() == "Added as record 1",
                  "WSJT-X: one record from QSO Logged + Logged ADIF (%s):\n%s", lastResult().c_str(), H.doc.c_str());
            // QSO Logged alone (an older program) is used after a moment.
            sendUdp(base, wsjtxQsoLogged("K2XYZ", "FT4", 14080000, (12 * 3600 + 30 * 60) * 1000));
            pump(0.3);
            CHECK(H.doc.find("K2XYZ") == std::string::npos, "QSO Logged waits for a Logged ADIF");
            pump(1.8);
            CHECK(H.doc.find("<CALL:5>K2XYZ") != std::string::npos && H.doc.find("<MODE:4>MFSK") != std::string::npos &&
                      H.doc.find("<SUBMODE:3>FT4") != std::string::npos && H.doc.find("<TIME_ON:6>123000") != std::string::npos &&
                      H.doc.find("<BAND:3>20m") != std::string::npos,
                  "QSO Logged on its own becomes a record:\n%s", H.doc.c_str());
            // A burst of decodes (WSJT-X sends a datagram for each) doesn't crowd out a QSO; JS8Call's
            // JSON LOG.QSO arrives on the same port.
            for (int i = 0; i < 40; ++i) sendUdp(base, wsjtxMessage(2) + qString("decode"));
            sendUdp(base, "{\"type\":\"LOG.QSO\",\"value\":\"<call:5>K8JSC <qso_date:8>20261009 <time_on:6>121000 <band:3>40m "
                          "<mode:4>MFSK <submode:3>JS8\",\"params\":{\"CALL\":\"K8JSC\"}}");
            pump(0.4);
            CHECK(H.doc.find("<CALL:5>K8JSC") != std::string::npos && H.doc.find("<SUBMODE:3>JS8") != std::string::npos,
                  "JS8Call's LOG.QSO after a burst of decodes");

            // Plain ADIF over UDP (Log4OM's "ADD"), N1MM's add, replace and delete, HRD's command over TCP.
            sendUdp(base + 1, "ADD <CALL:5>K3ADD <QSO_DATE:8>20261009 <TIME_ON:4>1215 <FREQ:5>7.074 <MODE:3>FT8 <EOR>");
            pump(0.3);
            CHECK(H.doc.find("<CALL:5>K3ADD") != std::string::npos && H.doc.find("<BAND:3>40m") != std::string::npos, "ADIF over UDP");
            std::string n1mm = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<contactinfo><app>N1MM</app><contestname>CQ-WW-CW</contestname>"
                               "<timestamp>2026-10-09 16:43:38</timestamp><mycall>KW9D</mycall><band>3.5</band><rxfreq>352519</rxfreq>"
                               "<txfreq>352519</txfreq><mode>CW</mode><call>W1N1M</call><snt>599</snt><rcv>599</rcv>"
                               "<ID>abc123</ID></contactinfo>";
            sendUdp(base + 2, n1mm);
            pump(0.3);
            size_t before = count(H.doc, "<EOR>");
            CHECK(H.doc.find("<CALL:5>W1N1M") != std::string::npos && H.doc.find("<APP_N1MM_ID:6>abc123") != std::string::npos &&
                      H.doc.find("<CONTEST_ID:8>CQ-WW-CW") != std::string::npos,
                  "N1MM contact added");
            std::string fixed = n1mm;
            fixed.replace(fixed.find("<contactinfo>"), 13, "<contactreplace>");
            fixed.replace(fixed.find("</contactinfo>"), 14, "</contactreplace>");
            fixed.replace(fixed.find("W1N1M"), 5, "W1N1X");
            sendUdp(base + 2, fixed);
            pump(0.3);
            CHECK(H.doc.find("W1N1M") == std::string::npos && H.doc.find("<CALL:5>W1N1X") != std::string::npos &&
                      count(H.doc, "<EOR>") == before && lastResult().rfind("Replaced record", 0) == 0,
                  "N1MM's correction replaces the record (%s)", lastResult().c_str());
            sendUdp(base + 2, "<?xml version=\"1.0\"?><contactdelete><call>W1N1X</call><ID>abc123</ID></contactdelete>");
            pump(0.3);
            CHECK(H.doc.find("W1N1X") == std::string::npos && count(H.doc, "<EOR>") == before - 1, "N1MM's delete removes it");
            CHECK(sendTcp(base + 3, "ver\rdb add {CALL=\"K4HRD\" QSO_DATE=\"20261009\" TIME_ON=\"121700\" FREQ=\"14074000\" MODE=\"FT8\" }\rexit\r"),
                  "connected to the TCP port");
            pump(0.4);
            CHECK(H.doc.find("<CALL:5>K4HRD") != std::string::npos && H.doc.find("<FREQ:6>14.074") != std::string::npos,
                  "HRD's db add over TCP");
            sendUdp(base + 1, "<CALL:5>K3ADD <QSO_DATE:8>20261009 <TIME_ON:4>1216 <FREQ:5>7.074 <MODE:3>FT8 <EOR>");
            pump(0.3);
            CHECK(count(H.doc, "K3ADD") == 1 && lastResult().rfind("Already in the log", 0) == 0, "a repeat isn't added (%s)",
                  lastResult().c_str());
            std::string hl;
            CHECK(noErrors(&hl), "the captured log is clean: %s", hl.c_str());

            // The log open in another tab: queued, then added when it's active again.
            std::string stationDoc = H.doc;
            activate(otherPath, otherDoc, {logPath});
            sendUdp(base + 1, "<CALL:5>K5QUE <QSO_DATE:8>20261009 <TIME_ON:4>1220 <BAND:3>20m <MODE:2>CW <EOR>");
            pump(0.3);
            std::string queuePath = std::string(tmp.UTF8String) + "/ADIFLint-queue.adi";
            CHECK(H.doc == otherDoc && fileText(queuePath).find("<CALL:5>K5QUE") != std::string::npos &&
                      lastResult().find("station.adi is open in another tab") != std::string::npos &&
                      findButton(mw.contentView, @"Add 1 Queued QSO") != nil,
                  "queued while the log is in another tab (%s)", lastResult().c_str());
            activate(logPath, stationDoc, {otherPath});
            CHECK(H.doc.find("<CALL:5>K5QUE") != std::string::npos && fileText(queuePath).empty() &&
                      lastResult().find("from the queue") != std::string::npos,
                  "the queue goes in when the log is active (%s)", lastResult().c_str());

            // The log not open at all: written to its file.
            [[NSData dataWithBytes:H.doc.data() length:H.doc.size()] writeToFile:@(logPath.c_str()) atomically:YES];
            activate(otherPath, otherDoc, {});
            sendUdp(base + 1, "<CALL:5>K6DSK <QSO_DATE:8>20261009 <TIME_ON:4>1225 <BAND:3>20m <MODE:2>CW <EOR>");
            pump(0.3);
            CHECK(H.doc == otherDoc && fileText(logPath).find("<CALL:5>K6DSK") != std::string::npos &&
                      lastResult().find("(in the file)") != std::string::npos,
                  "written to the log's file when it isn't open (%s)", lastResult().c_str());

            // A watched file: QSOs added to it from now on.
            const std::string watchPath = std::string(work.UTF8String) + "/wsjtx_log.adi";
            std::string watched = "WSJT-X ADIF Export<eoh>\n<call:4>OLD1 <qso_date:8>20261008 <time_on:6>100000 <band:3>20m <mode:3>FT8 <eor>\n";
            [[NSData dataWithBytes:watched.data() length:watched.size()] writeToFile:@(watchPath.c_str()) atomically:NO];
            setenv("ADIFLINT_TEST_WATCH", watchPath.c_str(), 1);
            [findButton(mw.contentView, @"Add File...") performClick:nil];
            unsetenv("ADIFLINT_TEST_WATCH");
            pump(0.3);
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@(watchPath.c_str())];
            [fh seekToEndOfFile];
            [fh writeData:[@"<call:5>K7FIL <qso_date:8>20261009 <time_on:6>122900 <band:3>20m <mode:3>FT8 <eor>\n"
                              dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
            for (int i = 0; i < 30 && fileText(logPath).find("K7FIL") == std::string::npos; ++i) pump(0.1);
            CHECK(fileText(logPath).find("<CALL:5>K7FIL") != std::string::npos && fileText(logPath).find("OLD1") == std::string::npos,
                  "a QSO appended to a watched file is captured, the old ones aren't");
            head = labelWithLines(mw.contentView, 2);
            CHECK([head containsString:@(("Listening: WSJT-X " + ports).c_str())] && [head containsString:@"file wsjtx_log.adi"] &&
                      ![labelWithLines(mw.contentView, 4) containsString:@"in use"],
                  "after a restart the ports are listened to again: %s", head.UTF8String);

            if (mw) {
                [mw.contentView layoutSubtreeIfNeeded];
                snapshot(mw, "monitor");
                CHECK(overlaps(mw.contentView) == 0, "Monitor does not overlap");
            }

            // Another program on the WSJT-X port: said plainly.
            [findButton(mw.contentView, @"Stop") performClick:nil];
            pump(0.1);
            CHECK([labelWithLines(mw.contentView, 2) isEqualToString:@"Stopped"], "Monitor stops");
            int blocker = socket(AF_INET, SOCK_DGRAM, 0);
            sockaddr_in a{};
            a.sin_len = sizeof a;
            a.sin_family = AF_INET;
            a.sin_port = htons((uint16_t)base);
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            bind(blocker, (sockaddr *)&a, sizeof a);
            [findButton(mw.contentView, @"Start") performClick:nil];
            pump(0.2);
            NSString *status = labelWithLines(mw.contentView, 4);
            CHECK([status containsString:@"is in use by another program"] && [status containsString:@"multicast"],
                  "a port in use is explained: %s", status.UTF8String);
            [findButton(mw.contentView, @"Stop") performClick:nil];
            close(blocker);
            NSString *ini = [NSString stringWithContentsOfFile:[tmp stringByAppendingPathComponent:@"ADIFLint.ini"]
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
            CHECK([ini containsString:@(("monitorTarget=" + logPath + "\n").c_str())] && [ini containsString:@"monitorN1mm=1\n"],
                  "the Monitor's choices are kept");
            [mw orderOut:nil];
            unsetenv("ADIFLINT_TEST_PORTS");

            // Import... offers WSJT-X's own log (Merge, from that file).
            setenv("ADIFLINT_TEST_WSJTX_LOG", watchPath.c_str(), 1);
            run("Import WSJT-X Log...");
            unsetenv("ADIFLINT_TEST_WSJTX_LOG");
            NSWindow *gw2 = windowTitled(@"Compare and Merge Logs");
            CHECK(gw2.visible && labelContaining(gw2.contentView, @"wsjtx_log.adi") != nil, "Import: the WSJT-X log, in Compare");
            [gw2 orderOut:nil];
        }


        // ── Contests in New QSO: Field Day, then serial numbers ──
        {
            H.doc = "fd\n<ADIF_VER:5>3.1.7\n<EOH>\n";
            H.path = std::string(tmp.UTF8String) + "/fieldday.adi";
            H.openFiles.clear();
            notify(NPPN_BUFFERACTIVATED);
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.3);
            run("New QSO...");
            NSWindow *qwc = qsoWindow();
            CHECK(qwc && findButton(qwc.contentView, @"Contest...") != nil, "New QSO has a Contest button");
            [findButton(qwc.contentView, @"Contest...") performClick:nil];
            NSWindow *cwin = windowTitled(@"Contest");
            CHECK(cwin.visible, "the Contest window opens");
            NSMutableArray *cfields = [NSMutableArray array];
            collect(cwin.contentView, NSTextField.class, cfields);
            NSTextField *sent = nil, *cid = nil;
            for (NSTextField *f in cfields) {
                if ([f.placeholderString hasPrefix:@"e.g. 1D"]) sent = f;
                if ([f.placeholderString hasPrefix:@"e.g. CQ-WPX"]) cid = f;
            }
            NSPopUpButton *preset = findPopupWith(cwin.contentView, @"Winter Field Day");
            [preset selectItemAtIndex:0];
            [preset sendAction:preset.action to:preset.target];
            sent.stringValue = @"1d";
            [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:sent];
            CHECK(!findButton(cwin.contentView, @"Start").enabled && [labelWithLines(cwin.contentView, 4) containsString:@"class and section"],
                  "Start waits for a whole exchange: %s", labelWithLines(cwin.contentView, 4).UTF8String);
            sent.stringValue = @"1D IL";
            [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:sent];
            [findButton(cwin.contentView, @"Start") performClick:nil];
            pump(0.3);
            qwc = qsoWindow();
            CHECK(qsoControl(qwc, @"CLASS") && qsoControl(qwc, @"ARRL_SECT"), "New QSO asks for CLASS and ARRL_SECT");
            auto logOne = [&](NSString *call, NSString *band, NSString *mode, NSString *cls, NSString *sect) {
                qsoControl(qwc, @"CALL").stringValue = call;
                qsoControl(qwc, @"BAND").stringValue = band;
                qsoControl(qwc, @"MODE").stringValue = mode;
                if (cls) qsoControl(qwc, @"CLASS").stringValue = cls;
                if (sect) qsoControl(qwc, @"ARRL_SECT").stringValue = sect;
                [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:qsoControl(qwc, @"CALL")];
                pump(0.3);
                std::string summary = summaryLabel(qwc.contentView).stringValue.UTF8String;
                [findButton(qwc.contentView, @"Log QSO") performClick:nil];
                pump(0.3);
                return summary;
            };
            logOne(@"K1ABC", @"20m", @"SSB", @"3a", @"ema");
            CHECK(H.doc.find("<CONTEST_ID:14>ARRL-FIELD-DAY") != std::string::npos && H.doc.find("<STX_STRING:5>1D IL") != std::string::npos &&
                      H.doc.find("<SRX_STRING:6>3A EMA") != std::string::npos && H.doc.find("<MY_ARRL_SECT:2>IL") != std::string::npos &&
                      H.doc.find("<CLASS:2>3A") != std::string::npos,
                  "a Field Day QSO:\n%s", H.doc.c_str());
            logOne(@"G4XYZ", @"20m", @"CW", @"1A", @"DX");
            CHECK(H.doc.find("<SRX_STRING:5>1A DX") != std::string::npos && H.doc.find("<ARRL_SECT:2>DX") == std::string::npos,
                  "DX goes into SRX_STRING, not ARRL_SECT");
            std::string dupSummary = logOne(@"K1ABC", @"20m", @"FM", @"3A", @"EMA");
            CHECK(dupSummary.find("already in the contest on 20m Phone") != std::string::npos, "FM after SSB is a Field Day dupe: %s",
                  dupSummary.c_str());
            std::string hl;
            CHECK(noErrors(&hl), "the Field Day log is clean: %s", hl.c_str());
            if (cwin) {
                [cwin.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(cwin.contentView) == 0, "Contest does not overlap");
                snapshot(cwin, "contest");
            }
            if (qwc) {
                [qwc.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(qwc.contentView) == 0, "New QSO with contest rows does not overlap (%d)", overlaps(qwc.contentView));
            }
            // Serial numbers count up.
            [findButton(cwin.contentView, @"Stop") performClick:nil];
            [preset selectItemAtIndex:2];
            [preset sendAction:preset.action to:preset.target];
            cid.stringValue = @"CQ-WPX-SSB";
            [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:cid];
            [findButton(cwin.contentView, @"Start") performClick:nil];
            pump(0.3);
            qwc = qsoWindow();
            CHECK(qsoControl(qwc, @"SRX") != nil, "serials: New QSO asks for SRX");
            qsoControl(qwc, @"SRX").stringValue = @"15";
            logOne(@"W2AA", @"40m", @"SSB", nil, nil);
            qsoControl(qwc, @"SRX").stringValue = @"22";
            logOne(@"W3BB", @"40m", @"SSB", nil, nil);
            size_t w2 = H.doc.find("<CALL:4>W2AA"), w3 = H.doc.find("<CALL:4>W3BB");
            auto recordAt = [&](size_t at) { return at == std::string::npos ? std::string() : H.doc.substr(at, H.doc.find("<EOR>", at) - at); };
            CHECK(recordAt(w2).find("<CONTEST_ID:10>CQ-WPX-SSB") != std::string::npos && recordAt(w2).find("<SRX:2>15") != std::string::npos &&
                      recordAt(w2).find("<STX:1>1") != std::string::npos && recordAt(w3).find("<STX:1>2") != std::string::npos,
                  "serials 1 and 2:\n%s", H.doc.c_str());
            [findButton(cwin.contentView, @"Stop") performClick:nil];
            pump(0.2);
            logOne(@"W4CC", @"40m", @"SSB", nil, nil);
            size_t w4 = H.doc.find("<CALL:4>W4CC");
            CHECK(w4 != std::string::npos && H.doc.find("CONTEST_ID", w4) == std::string::npos && H.doc.find("<STX:", w4) == std::string::npos,
                  "after Stop, QSOs carry no contest fields:\n%s", w4 == std::string::npos ? "" : H.doc.substr(w4).c_str());
            [cwin orderOut:nil];
            [qsoWindow() orderOut:nil];
        }


        // ── QSL labels ──
        {
            NSString *labelDir = [tmp stringByAppendingPathComponent:@"labels"];
            [[NSFileManager defaultManager] createDirectoryAtPath:labelDir withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("ADIFLINT_TEST_SAVE_DIR", labelDir.UTF8String, 1);
            H.doc = "cards\n<ADIF_VER:5>3.1.7\n<EOH>\n"
                    "<CALL:4>K1AB <QSO_DATE:8>20261009 <TIME_ON:4>1230 <BAND:3>20m <MODE:3>SSB <RST_SENT:2>59 <QSL_SENT:1>R <EOR>\n"
                    "<CALL:4>K1AB <QSO_DATE:8>20261009 <TIME_ON:4>1330 <BAND:3>40m <MODE:2>CW <RST_SENT:3>599 <QSL_SENT:1>Q <EOR>\n"
                    "<CALL:4>W2CD <QSO_DATE:8>20261009 <TIME_ON:4>1240 <BAND:3>20m <MODE:2>CW <QSL_SENT:1>R <QSL_VIA:4>W2XX <EOR>\n"
                    "<CALL:4>W3EF <QSO_DATE:8>20261009 <TIME_ON:4>1250 <BAND:3>20m <MODE:2>CW <QSL_SENT:1>Y <EOR>\n";
            H.path = std::string(tmp.UTF8String) + "/cards.adi";
            notify(NPPN_BUFFERACTIVATED);
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.3);
            run("Print QSL Labels...");
            NSWindow *lwin = windowTitled(@"Print QSL Labels");
            NSTableView *lt = lwin ? findTable(lwin.contentView) : nil;
            CHECK(lt && [lt.dataSource numberOfRowsInTableView:lt] == 2 && [cell(lt, 1, @"2") isEqualToString:@"W2XX"] &&
                      [cell(lt, 0, @"3") containsString:@"1330Z 40m CW 599"],
                  "two labels, K1AB's two QSOs on one: %s", lt ? cell(lt, 0, @"3").UTF8String : "");
            [findButton(lwin.contentView, @"Save PDF...") performClick:nil];
            NSString *pdfPath = [labelDir stringByAppendingPathComponent:@"cards QSL labels.pdf"];
            CGPDFDocumentRef pdf = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:pdfPath]);
            CHECK(pdf && CGPDFDocumentGetNumberOfPages(pdf) == 1, "the PDF has one page");
            if (pdf) CGPDFDocumentRelease(pdf);
            if (const char *snap = getenv("ADIFLINT_SNAPSHOT_DIR")) {
                NSString *copy = [@(snap) stringByAppendingPathComponent:@"qsl-labels.pdf"];
                [[NSFileManager defaultManager] removeItemAtPath:copy error:nil];
                [[NSFileManager defaultManager] copyItemAtPath:pdfPath toPath:copy error:nil];
            }
            NSMutableArray *lfields = [NSMutableArray array];
            collect(lwin.contentView, NSTextField.class, lfields);
            for (NSTextField *f in lfields)
                if ([f.placeholderString isEqualToString:@"1"]) {
                    f.stringValue = @"30";  // the last label of a 5160 sheet: the second label goes on a new page
                    [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:f];
                }
            [[NSFileManager defaultManager] removeItemAtPath:pdfPath error:nil];
            [findButton(lwin.contentView, @"Save PDF...") performClick:nil];
            pdf = CGPDFDocumentCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:pdfPath]);
            CHECK(pdf && CGPDFDocumentGetNumberOfPages(pdf) == 2, "starting at label 30 takes two pages");
            if (pdf) CGPDFDocumentRelease(pdf);
            if (lwin) {
                [lwin.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(lwin.contentView) == 0, "Print QSL Labels does not overlap");
                snapshot(lwin, "qsl-labels");
            }
            [findButton(lwin.contentView, @"Mark 3 QSOs as Sent") performClick:nil];
            CHECK(std::count(H.doc.begin(), H.doc.end(), 'Y') >= 4 && H.doc.find("<QSL_SENT:1>R") == std::string::npos &&
                      H.doc.find("<QSL_SENT:1>Q") == std::string::npos && H.doc.find("<QSLSDATE:8>" + utcDate()) != std::string::npos,
                  "marked sent:\n%s", H.doc.c_str());
            unsetenv("ADIFLINT_TEST_SAVE_DIR");
            [lwin orderOut:nil];
        }


        // ── LoTW users: off until asked, then in New QSO's lookup line ──
        {
            run("Settings...");
            NSWindow *sw = windowTitled(@"ADIF Lint Settings");
            NSView *section = sw ? viewWithIdentifier(sw.contentView, @"settings.lotwusers") : nil;
            NSButton *on = section ? findButton(section, @"Show LoTW users") : nil;
            CHECK(on && on.state == NSControlStateValueOff, "LoTW users are off at first");
            [on performClick:nil];
            [findButton(section, @"Update") performClick:nil];
            for (int i = 0; i < 30 && ![labelContaining(section, @"calls") length]; ++i) pump(0.05);
            CHECK([labelContaining(section, @"5 calls, downloaded") length] > 0, "the list downloaded: %s",
                  labelContaining(section, @"calls").UTF8String);
            [sw orderOut:nil];
            H.doc = "lotw\n<ADIF_VER:5>3.1.7\n<EOH>\n";
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.2);
            run("New QSO...");
            NSWindow *qwl = qsoWindow();
            auto lookupLine = [&](NSString *call) {
                qsoControl(qwl, @"CALL").stringValue = call;
                [[NSNotificationCenter defaultCenter] postNotificationName:NSControlTextDidChangeNotification object:qsoControl(qwl, @"CALL")];
                pump(0.9);  // the lookup runs 0.6 s after typing
                NSView *info = viewWithIdentifier(qwl.contentView, @"qso.lookupInfo");
                return std::string([info isKindOfClass:NSTextField.class] ? ((NSTextField *)info).stringValue.UTF8String : "");
            };
            std::string recent = lookupLine(@"K1AB"), old = lookupLine(@"K1PRK"), none = lookupLine(@"W9ZZZ");
            CHECK(recent.find("LoTW user (last upload 2026-09-30)") != std::string::npos &&
                      old.find("LoTW: last upload 2019-01-02") != std::string::npos && none.find("LoTW") == std::string::npos,
                  "LoTW in the lookup line: %s | %s | %s", recent.c_str(), old.c_str(), none.c_str());
            [qwl orderOut:nil];
        }


        // ── Map ──
        {
            H.doc = "map\n<ADIF_VER:5>3.1.7\n<EOH>\n"
                    "<CALL:4>K1AB <QSO_DATE:8>20261009 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <GRIDSQUARE:6>FN31pr <MY_GRIDSQUARE:6>EN52wa "
                    "<LOTW_QSL_RCVD:1>Y <EOR>\n"
                    "<CALL:5>G4ABC <QSO_DATE:8>20261009 <TIME_ON:4>1210 <BAND:3>20m <MODE:3>SSB <GRIDSQUARE:4>IO91 <EOR>\n"
                    "<CALL:5>JA1XY <QSO_DATE:8>20261009 <TIME_ON:4>1220 <BAND:3>15m <MODE:3>FT8 <GRIDSQUARE:4>PM95 <EOR>\n"
                    "<CALL:4>W2CD <QSO_DATE:8>20261009 <TIME_ON:4>1230 <BAND:3>20m <MODE:3>SSB <GRIDSQUARE:4>FN20 <POTA_REF:7>US-1234 <EOR>\n"
                    "<CALL:4>1A0C <QSO_DATE:8>20261009 <TIME_ON:4>1240 <BAND:3>20m <MODE:2>CW <QSL_RCVD:1>Y <EOR>\n";  // in the test country file
            H.path = std::string(tmp.UTF8String) + "/map.adi";
            notify(NPPN_BUFFERACTIVATED);
            notify(SCN_MODIFIED, 0, 0, SC_MOD_INSERTTEXT);
            pump(0.3);
            run("Map (Grids, DXCC, Parks)...");
            NSWindow *mapw = windowTitled(@"Map");
            NSString *mapStatus = mapw ? labelContaining(mapw.contentView, @"grid square") : nil;
            CHECK(mapw.visible && [mapStatus hasPrefix:@"4 grid squares (1 confirmed"] && [mapStatus containsString:@"1 park"] &&
                      [mapStatus containsString:@"1 DXCC (1 confirmed"] && [mapStatus containsString:@"1 QSO without GRIDSQUARE"],
                  "the map's summary: %s", mapStatus.UTF8String);
            NSString *mapDir = [tmp stringByAppendingPathComponent:@"mapout"];
            [[NSFileManager defaultManager] createDirectoryAtPath:mapDir withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("ADIFLINT_TEST_SAVE_DIR", mapDir.UTF8String, 1);
            [findButton(mapw.contentView, @"Export PNG...") performClick:nil];
            unsetenv("ADIFLINT_TEST_SAVE_DIR");
            NSData *png = [NSData dataWithContentsOfFile:[mapDir stringByAppendingPathComponent:@"map map.png"]];
            CHECK(png.length > 1000 && ((const unsigned char *)png.bytes)[1] == 'P', "the map exported as PNG (%lu bytes)", (unsigned long)png.length);
            if (const char *snap = getenv("ADIFLINT_SNAPSHOT_DIR"))
                [png writeToFile:[@(snap) stringByAppendingPathComponent:@"map-export.png"] atomically:YES];
            NSPopUpButton *bandPopup = findPopupWith(mapw.contentView, @"All bands");
            [bandPopup selectItemWithTitle:@"15m"];
            [bandPopup sendAction:bandPopup.action to:bandPopup.target];
            CHECK([labelContaining(mapw.contentView, @"grid square") hasPrefix:@"1 grid square"], "the band filter");
            [bandPopup selectItemAtIndex:0];
            [bandPopup sendAction:bandPopup.action to:bandPopup.target];
            if (mapw) {
                [mapw.contentView layoutSubtreeIfNeeded];
                CHECK(overlaps(mapw.contentView) == 0, "Map does not overlap");
                snapshot(mapw, "map");
            }

            // Interacting: zoom, a click on a square lists its QSOs, a hover names a DXCC, the list goes to the record.
            NSView *mapView = nil;
            for (NSView *v in mapw.contentView.subviews)
                if ([NSStringFromClass(v.class) isEqualToString:@"ADIFMapView"]) mapView = v;
            auto zoomShown = [&]() {
                NSMutableArray *labels = [NSMutableArray array];
                collect(mapw.contentView, NSTextField.class, labels);
                for (NSTextField *f in labels)
                    if ([f.stringValue hasSuffix:@"×"]) return std::string(f.stringValue.UTF8String);
                return std::string();
            };
            [findButton(mapw.contentView, @"+") performClick:nil];
            [findButton(mapw.contentView, @"+") performClick:nil];
            CHECK(zoomShown() == "2.2×", "zoomed in twice: %s", zoomShown().c_str());
            [findButton(mapw.contentView, @"World") performClick:nil];
            CHECK(zoomShown() == "1.0×", "back to the world: %s", zoomShown().c_str());
            auto pointFor = [&](double lon, double lat) {
                SEL sel = NSSelectorFromString(@"viewPointForLon:lat:");
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[mapView methodSignatureForSelector:sel]];
                inv.target = mapView;
                inv.selector = sel;
                [inv setArgument:&lon atIndex:2];
                [inv setArgument:&lat atIndex:3];
                [inv invoke];
                NSPoint p;
                [inv getReturnValue:&p];
                return [mapView convertPoint:p toView:nil];
            };
            auto mouse = [&](NSEventType type, NSPoint at, NSInteger clicks) {
                return [NSEvent mouseEventWithType:type location:at modifierFlags:0 timestamp:0 windowNumber:mapw.windowNumber context:nil
                                       eventNumber:0 clickCount:clicks pressure:1];
            };
            [findButton(mapw.contentView, @"Fit Log") performClick:nil];
            CHECK(std::atof(zoomShown().c_str()) > 1.2, "Fit Log zooms to the QSOs: %s", zoomShown().c_str());
            NSPoint fn31 = pointFor(-73, 41.5);  // inside FN31, K1AB's square
            [mapView mouseDown:mouse(NSEventTypeLeftMouseDown, fn31, 1)];
            [mapView mouseUp:mouse(NSEventTypeLeftMouseUp, fn31, 1)];
            NSTableView *qsoList = findTable(mapw.contentView);
            CHECK(qsoList && [qsoList.dataSource numberOfRowsInTableView:qsoList] == 1 && [cell(qsoList, 0, @"1") isEqualToString:@"K1AB"] &&
                      [labelContaining(mapw.contentView, @"FN31:") hasPrefix:@"FN31: 1 QSO, confirmed (K1AB)"],
                  "a click on FN31 lists its QSO: %s", labelContaining(mapw.contentView, @"FN31").UTF8String);
            void (^activate)(NSInteger) = [(NSObject *)qsoList.dataSource valueForKey:@"onActivate"];
            H.pos = 0;
            if (activate) activate(0);
            CHECK(H.pos == (intptr_t)H.doc.find("<CALL:4>K1AB"), "double-clicking the QSO goes to its record (%ld)", (long)H.pos);
            [findButton(mapw.contentView, @"World") performClick:nil];
            [mapView mouseMoved:mouse(NSEventTypeMouseMoved, pointFor(12.43, 41.90), 0)];  // 1A's centre in the test country file
            CHECK([labelContaining(mapw.contentView, @"DXCC 246") containsString:@"(DXCC 246): 1 QSO, confirmed (1A0C)"],
                  "hovering a DXCC dot names it: %s", labelContaining(mapw.contentView, @"DXCC").UTF8String);
            [findButton(mapw.contentView, @"World") performClick:nil];
            for (int i = 0; i < 4; ++i) {  // double-clicks zoom in where they land
                NSPoint at = pointFor(-73, 41.5);
                [mapView mouseDown:mouse(NSEventTypeLeftMouseDown, at, 2)];
                [mapView mouseUp:mouse(NSEventTypeLeftMouseUp, at, 2)];
            }
            CHECK(zoomShown() == "16×", "four double-clicks: %s", zoomShown().c_str());
            if (mapw) snapshot(mapw, "map-zoomed");
            [findButton(mapw.contentView, @"World") performClick:nil];
            for (int i = 0; i < 3; ++i) {  // the Great Lakes at 8x: lakes, rivers, state lines
                NSPoint at = pointFor(-84, 44);
                [mapView mouseDown:mouse(NSEventTypeLeftMouseDown, at, 2)];
                [mapView mouseUp:mouse(NSEventTypeLeftMouseUp, at, 2)];
            }
            if (mapw) snapshot(mapw, "map-great-lakes");
            [mapw orderOut:nil];
        }

        CHECK(messageProc(0, 0, 0) == TRUE, "messageProc answers");
        notify(NPPN_SHUTDOWN);

        for (uint32_t m : H.unknown) CHECK(false, "plugin sent a message the harness does not model: %u", m);
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        std::printf("%d/%d host checks passed\n", gChecks - gFailures, gChecks);
        return gFailures ? 1 : 0;
    }
}
