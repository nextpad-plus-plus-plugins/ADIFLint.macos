#import "Families.h"

#import "Imports.h"
#import "LogTools.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#import "Uploads.h"

#include <string>

namespace families {
namespace {

struct Member {
    NSString *label;    // in the popup
    NSString *title;    // the window's title
    void (*open)();     // shows the window
    bool remember = true;  // Import... opens it next time (not a window without the family popup)
};

const Member kImports[] = {
    {@"LoTW", @"Import from LoTW", imports::cmdImportLotw},
    {@"QRZ.com Logbook", @"Import from QRZ.com Logbook", imports::cmdImportQrzLogbook},
    {@"eQSL", @"Import from eQSL", imports::cmdImportEqsl},
    {@"CSV file", @"Import CSV", logtools::cmdImportCsv},
    {@"WSJT-X log file", @"Merge Another Log", logtools::cmdImportWsjtxLog, false},
};
const Member kExports[] = {
    {@"Activation logs (POTA, WWFF, SOTA)", @"Export Activation Logs", logtools::cmdExportPota},
    {@"CSV", @"Export CSV", logtools::cmdExportCsv},
    {@"Cabrillo", @"Export Cabrillo", logtools::cmdExportCabrillo},
};
const Member kUploads[] = {
    {@"QRZ.com Logbook", @"Upload to QRZ.com Logbook", uploads::cmdUploadQrz},
    {@"LoTW (TQSL)", @"Upload to LoTW (TQSL)", uploads::cmdUploadLotw},
    {@"Club Log", @"Upload to Club Log", uploads::cmdUploadClubLog},
    {@"eQSL", @"Upload to eQSL", uploads::cmdUploadEqsl},
};

const Member *members(Family f, size_t *n) {
    switch (f) {
        case kImport: *n = std::size(kImports); return kImports;
        case kExport: *n = std::size(kExports); return kExports;
        case kUpload: *n = std::size(kUploads); return kUploads;
    }
    *n = 0;
    return nullptr;
}

const char *settingKey(Family f) { return f == kImport ? "importLast" : f == kExport ? "exportLast" : "uploadLast"; }

NSWindow *windowTitled(NSString *title) {
    for (NSWindow *w in NSApp.windows)
        if ([w.title isEqualToString:title]) return w;
    return nil;
}

// Open member `index`; with `from`, in its place (same top-left corner), hiding it.
void open(Family f, NSInteger index, NSWindow *from) {
    size_t n = 0;
    const Member *m = members(f, &n);
    if (index < 0 || (size_t)index >= n) index = 0;
    if (m[index].remember) adifhost::setSetting(settingKey(f), std::to_string(index));
    m[index].open();
    NSWindow *to = windowTitled(m[index].title);
    if (!from || !to || to == from) return;
    NSRect r = to.frame;
    r.origin.x = NSMinX(from.frame);
    r.origin.y = NSMaxY(from.frame) - r.size.height;
    [to setFrame:r display:YES];
    [to makeKeyAndOrderFront:nil];
    [from orderOut:nil];
}

void openLast(Family f) {
    std::string s = adifhost::setting(settingKey(f));
    open(f, s.empty() ? 0 : (NSInteger)std::atoi(s.c_str()), nil);
}

}  // namespace

NSPopUpButton *popup(Family f, NSInteger current) {
    size_t n = 0;
    const Member *m = members(f, &n);
    NSMutableArray *labels = [NSMutableArray array];
    for (size_t i = 0; i < n; ++i) [labels addObject:m[i].label];
    NSPopUpButton *p = ADIFPopup(labels);
    [p selectItemAtIndex:current];
    __weak NSPopUpButton *weak = p;
    ADIFOnAction(p, ^{
        NSPopUpButton *me = weak;
        NSInteger chosen = me.indexOfSelectedItem;
        [me selectItemAtIndex:current];  // this window stays what it is
        if (chosen != current) open(f, chosen, me.window);
    });
    return p;
}

void cmdImport() { openLast(kImport); }
void cmdExport() { openLast(kExport); }
void cmdUpload() { openLast(kUpload); }

}  // namespace families
