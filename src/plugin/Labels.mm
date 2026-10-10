#import "Labels.h"

#import "Families.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "Scintilla.h"
#include "adif_labels.h"
#include "adif_tools.h"

#include <set>

using namespace adifhost;

namespace labels {
namespace {

struct {
    ADIFToolWindow *w = nil;
    NSPopUpButton *which = nil, *sheet = nil;
    NSTextField *start = nil, *from = nil, *closing = nil;
    NSButton *save = nil, *mark = nil;
    std::vector<adif::QslLabel> labels;
    std::vector<int> groups;  // the records the labels are for
    intptr_t buffer = 0;
} lw;

std::string plural(size_t n, const char *w) { return std::to_string(n) + " " + w + (n == 1 ? "" : "s"); }

const adif::LabelSheet &chosenSheet() {
    const std::vector<adif::LabelSheet> &all = adif::labelSheets();
    NSInteger i = lw.sheet.indexOfSelectedItem;
    return all[(size_t)(i >= 0 && (size_t)i < all.size() ? i : 0)];
}

std::string myCall(std::string_view text, const adif::DocModel &m) {
    std::string typed = ADIFStd(lw.from.stringValue);
    if (!typed.empty()) return typed;
    for (const adif::Record &r : adif::records(text, m))
        if (std::string s = adif::stationCall(r); !s.empty()) return s;
    return setting("stationCall");
}

void plan() {
    if (!lw.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        lw.buffer = buffer();
        [lw.w setTarget:[@"Log: " stringByAppendingString:ADIFString(documentName())]];
        if (lw.which.indexOfSelectedItem == 1) {  // the records the editor selection touches
            size_t b = (size_t)sci(h, SCI_GETSELECTIONSTART), e = (size_t)sci(h, SCI_GETSELECTIONEND);
            lw.groups.clear();
            for (size_t i = 0; i < r.model.groups.size(); ++i) {
                const adif::ModelGroup &g = r.model.groups[i];
                size_t gb = adif::groupStart(r.model, g), ge = adif::groupEnd(r.model, g);
                if (!g.header && (b == e ? (gb <= b && b <= ge) : (gb < e && ge > b))) lw.groups.push_back((int)i);
            }
        } else {
            lw.groups = adif::qslWanted(text, r.model);
        }
        const adif::LabelSheet &sheet = chosenSheet();
        lw.labels = adif::qslLabels(text, r.model, lw.groups, sheet.perLabel);
        std::string me = myCall(text, r.model), closing = ADIFStd(lw.closing.stringValue);
        lw.from.placeholderString = me.empty() ? @"your callsign" : ADIFString(me);
        std::vector<std::vector<std::string>> rows;
        for (size_t i = 0; i < lw.labels.size(); ++i) {
            std::vector<std::string> lines = adif::labelLines(lw.labels[i], me, closing);
            std::string qsos;
            for (size_t k = 1; k + (closing.empty() && me.empty() ? 0 : 1) < lines.size(); ++k) qsos += (qsos.empty() ? "" : "  ·  ") + lines[k];
            rows.push_back({std::to_string(i + 1), lw.labels[i].call, lw.labels[i].via, qsos});
        }
        [lw.w setRows:rows severities:std::vector<int>()];
        long start = std::max(1L, (long)lw.start.integerValue);
        size_t perPage = (size_t)(sheet.columns * sheet.rows);
        size_t pages = lw.labels.empty() ? 0 : ((size_t)start - 1 + lw.labels.size() + perPage - 1) / perPage;
        lw.save.enabled = !lw.labels.empty();
        lw.mark.enabled = !lw.groups.empty();
        lw.mark.title = lw.groups.empty() ? @"Mark as Sent" : ADIFString("Mark " + plural(lw.groups.size(), "QSO") + " as Sent");
        std::string st = lw.labels.empty()
                             ? (lw.which.indexOfSelectedItem == 1 ? "No records in the editor selection."
                                                                  : "No cards to send: no record has QSL_SENT R (requested) or Q (queued).")
                             : plural(lw.labels.size(), "label") + " for " + plural(lw.groups.size(), "QSO") + ", " + plural(pages, "page") +
                                   ". Save PDF... and print it at 100% (no scaling); try a page on plain paper against a sheet first. "
                                   "Mark as Sent then sets QSL_SENT Y and QSLSDATE today (one undo step).";
        [lw.w setStatus:ADIFString(st) severity:lw.labels.empty() ? 1 : -1];
    } catch (...) {
    }
}

std::string chooseSave(NSString *suggested) {
    if (const char *dir = getenv("ADIFLINT_TEST_SAVE_DIR")) return std::string(dir) + "/" + ADIFStd(suggested);
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = suggested;
    if (UTType *t = [UTType typeWithFilenameExtension:@"pdf"]) p.allowedContentTypes = @[ t ];
    p.canCreateDirectories = YES;
    if ([p runModal] != NSModalResponseOK || !p.URL) return "";
    return ADIFStd(p.URL.path);
}

// The labels drawn into a PDF, one sheet per page; `start` skips labels already used on the first sheet.
bool writePdf(const std::string &path, const adif::LabelSheet &sheet, size_t start, const std::string &me, const std::string &closing,
              std::string *error) {
    CGRect box = CGRectMake(0, 0, sheet.pageWidth, sheet.pageHeight);
    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:ADIFString(path)];
    CGContextRef pdf = CGPDFContextCreateWithURL(url, &box, nullptr);
    if (!pdf) {
        *error = "could not create the file";
        return false;
    }
    size_t perPage = (size_t)(sheet.columns * sheet.rows);
    NSGraphicsContext *saved = NSGraphicsContext.currentContext;
    for (size_t i = 0; i < lw.labels.size(); ++i) {
        size_t slot = start + i;
        if (i == 0 || slot % perPage == 0) {
            if (i != 0) {
                [NSGraphicsContext setCurrentContext:saved];
                CGPDFContextEndPage(pdf);
            }
            CGPDFContextBeginPage(pdf, nullptr);
            // AppKit text drawing, with y running down the page as label positions do.
            CGContextTranslateCTM(pdf, 0, sheet.pageHeight);
            CGContextScaleCTM(pdf, 1, -1);
            [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:pdf flipped:YES]];
        }
        double x = 0, y = 0;
        adif::labelPosition(sheet, slot, &x, &y);
        std::vector<std::string> lines = adif::labelLines(lw.labels[i], me, closing);
        double pad = 6, lineHeight = std::min(11.0, (sheet.height - 2 * pad) / (double)std::max<size_t>(1, lines.size()));
        CGFloat size = (CGFloat)std::max(5.0, lineHeight / 1.25);
        // Small enough that the widest line fits across the label.
        double widest = 0;
        for (size_t k = 0; k < lines.size(); ++k) {
            NSFont *f = k == 0 ? [NSFont boldSystemFontOfSize:size * 1.15] : [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
            widest = std::max(widest, (double)[ADIFString(lines[k]) sizeWithAttributes:@{NSFontAttributeName : f}].width);
        }
        if (widest > sheet.width - 2 * pad) size = (CGFloat)std::max(4.0, size * (sheet.width - 2 * pad) / widest);
        CGContextSaveGState(pdf);
        CGContextClipToRect(pdf, CGRectMake(x, y, sheet.width, sheet.height));
        for (size_t k = 0; k < lines.size(); ++k) {
            NSFont *font = k == 0 ? [NSFont boldSystemFontOfSize:size * 1.15] : [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
            NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : NSColor.blackColor};
            [ADIFString(lines[k]) drawAtPoint:NSMakePoint(x + pad, y + pad + lineHeight * (double)k) withAttributes:attrs];
        }
        CGContextRestoreGState(pdf);
    }
    [NSGraphicsContext setCurrentContext:saved];
    if (!lw.labels.empty()) CGPDFContextEndPage(pdf);
    CGPDFContextClose(pdf);
    CGContextRelease(pdf);
    return true;
}

void savePdf() {
    try {
        plan();
        if (lw.labels.empty()) return;
        NppHandle h = scintilla();
        std::string me = myCall(adifhost::text(h), lint(h).model);
        std::string base = documentName();
        if (size_t dot = base.rfind('.'); dot != std::string::npos) base.resize(dot);
        std::string path = chooseSave(ADIFString(base + " QSL labels.pdf"));
        if (path.empty()) return;
        std::string error;
        const adif::LabelSheet &sheet = chosenSheet();
        size_t start = (size_t)std::max(1L, (long)lw.start.integerValue) - 1;
        if (!writePdf(path, sheet, start % (size_t)(sheet.columns * sheet.rows), me, ADIFStd(lw.closing.stringValue), &error)) {
            [lw.w setStatus:ADIFString("Could not save the labels: " + error + ".") severity:2];
            return;
        }
        setSetting("labelSheet", std::to_string(lw.sheet.indexOfSelectedItem));
        setSetting("labelClosing", ADIFStd(lw.closing.stringValue));
        if (!getenv("ADIFLINT_TEST_SAVE_DIR")) [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:ADIFString(path)]];
        [lw.w setStatus:ADIFString("Saved " + plural(lw.labels.size(), "label") + " to " + ADIFStd(ADIFString(path).lastPathComponent) +
                                   ". Print it at 100%, then Mark as Sent.")
                severity:3];
    } catch (...) {
        [lw.w setStatus:@"Something went wrong saving the labels." severity:2];
    }
}

void markSent() {
    try {
        NppHandle h = scintilla();
        if (lw.buffer != buffer()) {
            [lw.w setStatus:@"Switch back to the log the labels are for." severity:2];
            return;
        }
        if (readOnly(h)) {
            [lw.w setStatus:@"This document is read-only." severity:2];
            return;
        }
        adif::LintResult r = lint(h);
        std::string_view text = adifhost::text(h);
        std::vector<int> groups = lw.groups;
        if (groups.empty()) return;
        adifhost::apply(h, adif::cellEdits(text, r.model, adif::qslSentChanges(groups, utcNow("%Y%m%d")), lengthUnit(), utf8(h)));
        plan();
        [lw.w setStatus:ADIFString("Marked " + plural(groups.size(), "QSO") + " QSL_SENT Y with today's QSLSDATE (one undo step).")
                severity:3];
    } catch (...) {
        [lw.w setStatus:@"Something went wrong marking the QSOs." severity:2];
    }
}

}  // namespace

void cmdQslLabels() {
    if (!lw.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Print QSL Labels" size:NSMakeSize(860, 480) headline:NO];
        lw.w = w;
        [w addOptionRow:@[ ADIFLabel(@"Export:"), families::popup(families::kExport, families::kExportLabels) ]];
        lw.which = ADIFPopup(@[ @"Cards to send (QSL_SENT R or Q)", @"Records in the editor selection" ]);
        NSMutableArray *sheets = [NSMutableArray array];
        for (const adif::LabelSheet &s : adif::labelSheets()) [sheets addObject:ADIFString(s.name)];
        lw.sheet = ADIFPopup(sheets);
        NSInteger keep = (NSInteger)std::atoi(setting("labelSheet").c_str());
        if (keep > 0 && keep < lw.sheet.numberOfItems) [lw.sheet selectItemAtIndex:keep];
        [w addOptionRow:@[ ADIFLabel(@"QSOs:"), lw.which, ADIFLabel(@"Sheet:"), lw.sheet ]];
        lw.start = ADIFTextField(@"1", 40);
        lw.start.stringValue = @"1";
        lw.start.toolTip = @"The first free label on the sheet (counting across, then down), to use a sheet already started";
        lw.from = ADIFTextField(@"your callsign", 100);
        lw.closing = ADIFTextField(@"TNX QSO 73", 160);
        lw.closing.stringValue = setting("labelClosing").empty() ? @"TNX QSO 73" : ADIFString(setting("labelClosing"));
        [w addOptionRow:@[ ADIFLabel(@"Start at label:"), lw.start, ADIFLabel(@"From:"), lw.from, ADIFLabel(@"Closing:"), lw.closing ]];
        for (NSControl *c in @[ lw.which, lw.sheet ]) ADIFOnAction(c, ^{ plan(); });
        for (NSTextField *f in @[ lw.start, lw.from, lw.closing ])
            [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                              object:f
                                                               queue:nil
                                                          usingBlock:^(NSNotification *) { plan(); }];
        [w setColumns:std::vector<ADIFToolColumn>{{"n", "Label", 50}, {"call", "To", 90}, {"via", "Via", 80}, {"qsos", "QSOs", 560}}
            checkboxes:NO
              sortable:NO];
        lw.mark = [w addButton:@"Mark as Sent" trailing:NO action:^{ markSent(); }];
        lw.save = [w addButton:@"Save PDF..." trailing:YES action:^{ savePdf(); }];
        [w setDefaultButton:lw.save];
    }
    plan();
    [lw.w show];
}

void documentChanged() {
    if (lw.w && lw.w.window.visible) plan();
}

}  // namespace labels
