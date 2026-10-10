#import "CheckLog.h"

#import "PluginHost.h"
#import "ToolWindow.h"
#include "adif_edit.h"
#include "adif_tools.h"

#include "Scintilla.h"

#include <cctype>
#include <set>

using namespace adifhost;

namespace {

std::string plural(size_t n, const char *word) { return std::to_string(n) + " " + word + (n == 1 ? "" : "s"); }

const char *kShow[] = {"All problems", "With a repair", "Errors", "Warnings", "Notes"};

struct Check {
    ADIFToolWindow *w = nil;
    NSPopUpButton *show = nil;
    NSButton *repair = nil, *fixLengths = nil;
    intptr_t buffer = 0;
    std::vector<adif::Diagnostic> diags;  // the problems listed, in table-row order
};
Check chk;

// A problem's identity while the text is unchanged: where it is and what it says.
std::string key(const adif::Diagnostic &d) { return std::to_string(d.start) + "|" + d.code + "|" + d.message; }

bool wanted(const adif::Diagnostic &d, NSInteger show) {
    switch (show) {
        case 1: return !d.fixes.empty();
        case 2: return d.severity == adif::Severity::Error;
        case 3: return d.severity == adif::Severity::Warning;
        case 4: return d.severity == adif::Severity::Info;
        default: return true;
    }
}

size_t tickedRepairs() {
    std::vector<bool> ticks = [chk.w ticked];
    size_t n = 0;
    for (size_t i = 0; i < ticks.size() && i < chk.diags.size(); ++i) n += ticks[i] && !chk.diags[i].fixes.empty();
    return n;
}

void updateButtons(const adif::LintResult &r) {
    size_t n = tickedRepairs();
    chk.repair.title = n ? [NSString stringWithFormat:@"Repair %zu Ticked", n] : @"Repair Ticked";
    chk.repair.enabled = n > 0;
    chk.fixLengths.enabled = !r.fixes.empty();
}

// List the active log's problems. keepTicks: after an edit, rows you unticked stay unticked.
void plan(bool keepTicks) {
    if (!chk.w) return;
    try {
        NppHandle h = scintilla();
        chk.buffer = buffer();
        const adif::LintResult &r = lint(h);
        [chk.w setTarget:[@"Log: " stringByAppendingString:ADIFString(documentName())]];
        NSInteger show = chk.show.indexOfSelectedItem;
        chk.diags.clear();
        std::vector<std::vector<std::string>> rows;
        std::vector<int> severities;
        std::vector<std::string> keys;
        std::vector<bool> ticks, tickable;
        size_t repairable = 0;
        std::string_view doc = text(h);
        for (const adif::Diagnostic &d : r.diagnostics) {
            repairable += !d.fixes.empty();
            if (!wanted(d, show)) continue;
            int gi = adif::groupAt(r.model, d.start);
            int record = gi >= 0 ? adif::recordNumber(r.model, gi) : 0;
            intptr_t line = sci(h, SCI_LINEFROMPOSITION, d.start) + 1;
            const char *sev = d.severity == adif::Severity::Error ? "error" : d.severity == adif::Severity::Warning ? "warning" : "note";
            // The field the problem is on, when the check didn't say.
            std::string field = d.field;
            if (field.empty()) {
                int fi = adif::fieldAt(r.model, d.start);
                if (fi >= 0) field = std::string(adif::fieldName(doc, r.model.fields[(size_t)fi]));
                for (char &c : field) c = (char)std::toupper((unsigned char)c);
            }
            rows.push_back({record ? std::to_string(record) : std::string(gi >= 0 ? "header" : ""), std::to_string(line), sev,
                            field, d.message, d.fixes.empty() ? std::string() : d.fixLabel});
            severities.push_back(d.severity == adif::Severity::Error ? 2 : d.severity == adif::Severity::Warning ? 1 : 0);
            keys.push_back(key(d));
            ticks.push_back(!d.fixes.empty() && !d.dropsData);  // a removal waits for your tick
            tickable.push_back(!d.fixes.empty());
            chk.diags.push_back(d);
        }
        [chk.w setRows:rows severities:severities keys:keys ticks:ticks keepTicks:keepTicks];
        [chk.w setTickable:tickable];  // a tick box only where there is a repair
        if (r.diagnostics.empty()) {
            [chk.w setHeadline:@"No problems found." severity:3];
        } else {
            std::string head = plural(r.errors, "error") + ", " + plural(r.warnings, "warning") + ", " + plural(r.infos, "note");
            if (repairable) head += "  ·  " + std::to_string(repairable) + " can be repaired";
            [chk.w setHeadline:ADIFString(head) severity:r.errors ? 2 : r.warnings ? 1 : 0];
        }
        std::string st;
        if (r.structuralErrors)
            st = "Wrong data lengths or broken tags leave some records' boundaries unclear: press Fix Lengths first. Their other "
                 "repairs wait until then.";
        else if (repairable)
            st = "Ticked rows with a repair are fixed together as one undo step. Click a row to see it in the editor.";
        else
            st = "Click a row to see it in the editor. Rows without a repair need your judgement.";
        if (r.truncated) st += " Only the first " + std::to_string(r.diagnostics.size()) + " problems are listed.";
        [chk.w setStatus:ADIFString(st) severity:r.structuralErrors ? 1 : -1];
        updateButtons(r);
    } catch (...) {
    }
}

void repairTicked() {
    try {
        NppHandle h = scintilla();
        if (buffer() != chk.buffer) {
            [chk.w setStatus:@"Switch back to the log the list shows." severity:2];
            return;
        }
        if (readOnly(h)) {
            [chk.w setStatus:@"This document is read-only." severity:2];
            return;
        }
        adif::LintResult r = lint(h);  // a copy: the edits change the document
        std::vector<bool> ticks = [chk.w ticked];
        std::set<std::string> chosen;
        for (size_t i = 0; i < ticks.size() && i < chk.diags.size(); ++i)
            if (ticks[i] && !chk.diags[i].fixes.empty()) chosen.insert(key(chk.diags[i]));
        std::vector<adif::Diagnostic> todo;
        for (const adif::Diagnostic &d : r.diagnostics)
            if (!d.fixes.empty() && chosen.count(key(d))) todo.push_back(d);
        size_t applied = 0;
        std::vector<adif::TextEdit> edits = adif::quickFixEdits(text(h), r.model, todo, lengthUnit(), utf8(h), &applied);
        if (edits.empty()) {
            [chk.w setStatus:todo.empty() ? @"The log changed since the list was made; it has been checked again."
                                          : @"Those repairs wait for Fix Lengths (their records have wrong lengths)."
                    severity:1];
            plan(true);
            return;
        }
        adifhost::apply(h, edits);
        plan(true);
        [chk.w setStatus:ADIFString("Repaired " + plural(applied, "problem") +
                                    " (one undo step). A repair can reveal another: the list shows what is left.")
                severity:3];
    } catch (...) {
        [chk.w setStatus:@"Something went wrong repairing the log." severity:2];
    }
}

void goToRow(NSInteger row, bool focus) {
    if (row < 0 || (size_t)row >= chk.diags.size() || buffer() != chk.buffer) return;
    goTo(scintilla(), chk.diags[(size_t)row].start, focus);
}

}  // namespace

namespace checklog {

void cmdCheckLog() {
    if (!chk.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Check Log" size:NSMakeSize(960, 580) headline:YES];
        chk.w = w;
        NSMutableArray *items = [NSMutableArray array];
        for (const char *s : kShow) [items addObject:@(s)];
        chk.show = ADIFPopup(items);
        ADIFOnAction(chk.show, ^{ plan(true); });
        NSSearchField *filter = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        filter.placeholderString = @"Filter: field, words...";
        filter.sendsSearchStringImmediately = YES;
        [filter.widthAnchor constraintEqualToConstant:240].active = YES;
        ADIFOnAction(filter, ^{ [chk.w setFilter:filter.stringValue]; });
        [w addOptionRow:@[ ADIFLabel(@"Show:"), chk.show, filter ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"record", "Record", 56}, {"line", "Line", 48}, {"severity", "Kind", 60},
                                                  {"field", "Field", 110}, {"problem", "Problem", 380}, {"repair", "Repair", 250}}
            checkboxes:YES
              sortable:YES];
        chk.repair = [w addButton:@"Repair Ticked" trailing:NO action:^{ repairTicked(); }];
        chk.fixLengths = [w addButton:@"Fix Lengths" trailing:NO action:^{
            fixLengths();
            plan(true);
        }];
        [w addButton:@"Tick All" trailing:NO action:^{
            [chk.w setAllTicked:YES];
            try {
                updateButtons(lint(scintilla()));
            } catch (...) {
            }
        }];
        [w addButton:@"Untick All" trailing:NO action:^{
            [chk.w setAllTicked:NO];
            try {
                updateButtons(lint(scintilla()));
            } catch (...) {
            }
        }];
        [w setDefaultButton:chk.repair];
        w.onTicksChanged = ^{
            try {
                updateButtons(lint(scintilla()));
            } catch (...) {
            }
        };
        w.onSelectionChanged = ^{
            std::vector<NSInteger> sel = [chk.w selectedRows];
            if (sel.size() == 1) goToRow(sel[0], false);
        };
        w.onActivateRow = ^(NSInteger row) { goToRow(row, true); };
    }
    try {
        validate(scintilla());  // treat the active document as ADIF, whatever its extension
    } catch (...) {
    }
    plan(true);
    [chk.w show];
}

void documentChanged() {
    static int64_t token = 0;
    int64_t mine = ++token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine != token || !chk.w || !chk.w.window.visible) return;
        plan(true);
    });
}

}  // namespace checklog
