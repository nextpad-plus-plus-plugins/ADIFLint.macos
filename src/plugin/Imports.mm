#import "Imports.h"
#import "Uploads.h"

#import "Families.h"
#import "Lookup.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#include "adif_import.h"
#include "adif_tools.h"
#include "adif_upload.h"

#include <set>

using namespace adifhost;

namespace {

enum { kColAction, kColCall, kColDate, kColTime, kColBand, kColMode, kColConfirmed, kColRecord, kColChanges };

std::string plural(size_t n, const char *word) { return std::to_string(n) + " " + word + (n == 1 ? "" : "s"); }

ADIFSource accountSource(adif::ImportSite s) {
    return s == adif::ImportSite::LoTW ? ADIFSourceLoTW : s == adif::ImportSite::QRZLogbook ? ADIFSourceQRZLogbook : ADIFSourceEQSL;
}

adif::LintResult lintText(std::string_view text) {
    adif::LintOptions opt;
    opt.lengthUnit = lengthUnit();
    opt.buildModel = true;
    return adif::lint(text, opt);
}

// Why the log's structure rules out rebuilding it, or "".
std::string structureProblem(const adif::LintResult &r) {
    if (!adif::canReformat(r))
        return "The log has structural problems (wrong lengths or broken tags). Run Fix Lengths, then fix the errors "
               "marked in red.";
    for (const adif::ModelGroup &g : r.model.groups)
        if (!g.header && g.markerB == adif::kNoPos) return "A record has no <EOR>. Add it, then try again.";
    return "";
}

// "2026-10-06" from YYYYMMDD.
std::string dashed(const std::string &d) { return d.size() == 8 ? d.substr(0, 4) + "-" + d.substr(4, 2) + "-" + d.substr(6, 2) : d; }

struct Import {
    adif::ImportSite site = adif::ImportSite::LoTW;
    ADIFToolWindow *w = nil;
    NSTextField *account = nil;
    NSPopUpButton *dates = nil;
    NSButton *includeInLog = nil, *sort = nil, *download = nil, *apply = nil;
    bool running = false;
    bool downloaded = false;
    std::string from, to;                // the date range asked for (YYYYMMDD), empty for all
    std::vector<adif::SiteQso> qsos;     // the download
    std::vector<adif::ImportItem> items; // planned against the log now
    std::vector<size_t> rowItem;         // table row -> index into items
};
Import imps[3];

Import &imp(adif::ImportSite s) { return imps[(size_t)s]; }

NSString *accountLine(adif::ImportSite s) {
    ADIFSource src = accountSource(s);
    if (!ADIFSavedAccount(src) || !ADIFHasSecret(src))
        return [NSString stringWithFormat:@"No %@ account yet: add it in Settings.", ADIFSourceName(src)];
    if (s == adif::ImportSite::QRZLogbook) return @"QRZ.com Logbook API key saved in your Keychain";
    return [NSString stringWithFormat:@"%@ (saved in your Keychain)", ADIFSavedAccount(src)];
}

// The log's first and last QSO_DATE, or false when it has none.
bool logDates(const adif::LintResult &r, std::string_view text, std::string *lo, std::string *hi) {
    *lo = "99999999";
    *hi = "00000000";
    for (const adif::ModelGroup &g : r.model.groups) {
        if (g.header) continue;
        std::string d(adif::groupValue(text, r.model, g, "QSO_DATE"));
        if (d.size() != 8) continue;
        *lo = std::min(*lo, d);
        *hi = std::max(*hi, d);
    }
    return *lo <= *hi;
}

std::string changeSummary(const adif::ImportItem &i) {
    std::string s;
    for (const adif::EnrichChange &c : i.changes) s += (s.empty() ? "" : ", ") + c.field + "=" + c.value;
    return s;
}

size_t countTicked(Import &u) {
    std::vector<bool> ticks = [u.w ticked];
    size_t n = 0;
    for (size_t row = 0; row < ticks.size() && row < u.rowItem.size(); ++row) {
        const adif::ImportItem &i = u.items[u.rowItem[row]];
        if (!ticks[row]) continue;
        if (i.kind == adif::ImportItem::Kind::Add && u.qsos[i.qso].problem.empty()) ++n;
        if (i.kind == adif::ImportItem::Kind::Update) ++n;
    }
    return n;
}

void updateApplyButton(Import &u) {
    size_t n = countTicked(u);
    u.apply.title = n ? [NSString stringWithFormat:@"Apply %zu Change%@", n, n == 1 ? @"" : @"s"] : @"Apply Changes";
    u.apply.enabled = n > 0 && !u.running;
}

std::string itemKey(const adif::SiteQso &q) { return q.call + "|" + q.date + "|" + q.time + "|" + q.band + "|" + q.mode; }

// Match the download against the log as it is now, and fill the table.
// keepTicks: re-planned after an edit, so rows you unticked stay unticked.
void plan(Import &u, bool keepTicks) {
    if (!u.w || u.running) return;
    [u.w setTarget:[@"Log: " stringByAppendingString:ADIFString(documentName())]];
    u.account.stringValue = accountLine(u.site);
    if (!u.downloaded) {
        u.items.clear();
        u.rowItem.clear();
        static const std::vector<std::vector<std::string>> noRows;
        static const std::vector<int> noSeverities;
        [u.w setRows:noRows severities:noSeverities];
        updateApplyButton(u);
        return;
    }
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        u.items = adif::planImport(text, r.model, u.qsos, u.site);
        bool includeInLog = u.includeInLog.state == NSControlStateValueOn;
        std::vector<std::vector<std::string>> rows;
        std::vector<int> sev;
        std::vector<std::string> keys;
        std::vector<bool> ticks;
        u.rowItem.clear();
        size_t add = 0, update = 0, inLog = 0, cannot = 0;
        for (size_t k = 0; k < u.items.size(); ++k) {
            const adif::ImportItem &i = u.items[k];
            const adif::SiteQso &q = u.qsos[i.qso];
            std::string action, changes;
            int severity = -1;
            switch (i.kind) {
                case adif::ImportItem::Kind::Add:
                    if (!q.problem.empty()) {
                        ++cannot;
                        action = "can't add";
                        changes = q.problem;
                        severity = 2;
                    } else {
                        ++add;
                        action = "add";
                        changes = "new record";
                        severity = 3;
                    }
                    break;
                case adif::ImportItem::Kind::Update:
                    ++update;
                    action = "update";
                    changes = changeSummary(i);
                    break;
                case adif::ImportItem::Kind::InLog:
                    ++inLog;
                    if (!includeInLog) continue;
                    action = "in log";
                    changes = "nothing to add";
                    severity = 0;
                    break;
            }
            rows.push_back({action, q.call, adif::displayDate(q.date), adif::displayTime(q.time), q.band, q.mode,
                            q.confirmed ? "Y" : "", i.record ? std::to_string(i.record) : "", changes});
            sev.push_back(severity);
            keys.push_back(itemKey(q));
            ticks.push_back(i.kind == adif::ImportItem::Kind::Update ||
                            (i.kind == adif::ImportItem::Kind::Add && q.problem.empty() && q.addByDefault));
            u.rowItem.push_back(k);
        }
        [u.w setRows:rows severities:sev keys:keys ticks:ticks keepTicks:keepTicks];
        std::string range = u.from.empty() ? "" : " from " + dashed(u.from) + " to " + dashed(u.to);
        std::string st = plural(u.qsos.size(), "QSO") + " downloaded from " + adif::importSiteName(u.site) + range + ": " +
                         plural(add, "QSO") + " to add, " + plural(update, "record") + " to update, " + std::to_string(inLog) +
                         " already in the log with nothing to add" + (cannot ? ", " + std::to_string(cannot) + " that can't be added" : "") +
                         ". Untick any you don't want, then Apply.";
        [u.w setStatus:ADIFString(st) severity:-1];
    } catch (...) {
        [u.w setStatus:@"Something went wrong comparing the download with the log." severity:2];
    }
    updateApplyButton(u);
}

void setRunning(Import &u, bool running) {
    u.running = running;
    u.download.enabled = !running;
    u.dates.enabled = !running;
    updateApplyButton(u);
}

void startDownload(Import &u) {
    if (u.running) return;
    ADIFSource src = accountSource(u.site);
    if (!ADIFSavedAccount(src) || !ADIFHasSecret(src)) {
        [u.w setStatus:[NSString stringWithFormat:@"No %@ account yet. Add it in Settings, then press Download.", ADIFSourceName(src)]
              severity:2];
        return;
    }
    u.from.clear();
    u.to.clear();
    if (u.dates.indexOfSelectedItem == 0) {
        try {
            NppHandle h = scintilla();
            if (!logDates(lint(h), adifhost::text(h), &u.from, &u.to)) {
                u.from.clear();
                u.to.clear();
            }
        } catch (...) {
        }
    }
    setRunning(u, true);
    [u.w setStatus:ADIFString(std::string("Downloading your QSOs from ") + adif::importSiteName(u.site) + "...") severity:-1];
    Import *pu = &u;
    ADIFDownloadSiteQsos(u.site, ADIFString(u.from), ADIFString(u.to), ^(NSString *adifText, NSString *error) {
        setRunning(*pu, false);
        if (error) {
            [pu->w setStatus:error severity:2];
            return;
        }
        std::string body = adifText.UTF8String ?: "";
        adif::LintResult dr = lintText(body);
        std::vector<adif::SiteQso> qsos = adif::siteQsos(pu->site, body, dr.model, utcNow("%Y%m%d"));
        // Only the log's dates, when that was asked for (a site may return more).
        if (!pu->from.empty()) {
            std::vector<adif::SiteQso> kept;
            for (adif::SiteQso &q : qsos)
                if (q.date >= pu->from && q.date <= pu->to) kept.push_back(std::move(q));
            qsos = std::move(kept);
        }
        pu->qsos = std::move(qsos);
        pu->downloaded = true;
        uploads::downloaded((int)pu->site);
        plan(*pu, false);
    });
}

void applyImport(Import &u) {
    if (u.running || !u.downloaded) return;
    try {
        NppHandle h = scintilla();
        if (readOnly(h)) {
            [u.w setStatus:@"This document is read-only." severity:2];
            return;
        }
        plan(u, true);  // against the log as it is now
        adif::LintResult r = lint(h);  // a copy: the edits below change the document
        std::string_view text = adifhost::text(h);
        bool blank = text.find_first_not_of(" \t\r\n") == std::string_view::npos;
        std::string problem = structureProblem(r);
        if (!blank && !problem.empty()) {
            [u.w setStatus:ADIFString("This log: " + problem) severity:2];
            return;
        }
        std::vector<bool> ticks = [u.w ticked];
        std::vector<adif::EnrichChange> changes;
        std::vector<int> changedData;  // records whose QSO data changed: an earlier upload is out of date
        std::vector<size_t> adds;
        std::set<int> updated;
        for (size_t row = 0; row < ticks.size() && row < u.rowItem.size(); ++row) {
            if (!ticks[row]) continue;
            const adif::ImportItem &i = u.items[u.rowItem[row]];
            if (i.kind == adif::ImportItem::Kind::Add && u.qsos[i.qso].problem.empty()) adds.push_back(i.qso);
            if (i.kind != adif::ImportItem::Kind::Update) continue;
            updated.insert(i.group);
            for (const adif::EnrichChange &c : i.changes) {
                changes.push_back(c);
                if (!adif::isTrackingField(c.field)) changedData.push_back(c.group);
            }
        }
        if (adds.empty() && changes.empty()) {
            [u.w setStatus:@"Nothing ticked to apply." severity:1];
            return;
        }
        std::string eolText = eol(h);
        std::string merged(text);
        if (!changes.empty()) {
            std::vector<adif::TextEdit> edits = adif::enrichmentEdits(text, r.model, changes, lengthUnit(), utf8(h));
            edits = adif::mergeEdits(edits, adif::markModified(text, r.model, changedData, lengthUnit(), utf8(h)));
            merged = adif::applyTextEdits(text, edits);
        }
        std::string note;
        if (!adds.empty()) {
            adif::LintResult mr = lintText(merged);
            adif::Layout layout = blank ? adif::Layout::RecordPerLine : adif::recordLayout(merged, mr.model);
            std::string records = adif::importedRecords(u.qsos, adds, layout, eolText, lengthUnit(), utf8(h));
            if (blank) {
                merged = adif::newLogHeader(ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"), eolText) + records;
            } else {
                size_t start = 0;
                merged = adif::applyTextEdits(merged, {adif::appendRecord(merged, mr.model, records, eolText, &start)});
            }
            if (u.sort.state == NSControlStateValueOn) {
                adif::LintResult sr = lintText(merged);
                if (structureProblem(sr).empty()) {
                    bool changed = false;
                    merged = adif::sortedByTime(merged, sr.model, eolText, &changed);
                    if (changed) note = ", sorted by date and time";
                }
            }
        }
        adifhost::apply(h, {adif::TextEdit{0, text.size(), merged}});
        std::string st = "Added " + plural(adds.size(), "QSO") + " and updated " + plural(updated.size(), "record") + " from " +
                         adif::importSiteName(u.site) + note + " (one undo step).";
        u.downloaded = false;  // applied: download again to compare afresh
        u.qsos.clear();
        plan(u, false);
        [u.w setStatus:ADIFString(st) severity:-1];
    } catch (...) {
        [u.w setStatus:@"Something went wrong applying the import." severity:2];
    }
}

void openImport(adif::ImportSite s) {
    Import &u = imp(s);
    u.site = s;
    if (!u.w) {
        NSString *title = [NSString stringWithFormat:@"Import from %s", adif::importSiteName(s)];
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:title size:NSMakeSize(900, 560) headline:NO];
        u.w = w;
        Import *pu = &u;
        [w addOptionRow:@[ ADIFLabel(@"Import from:"), families::popup(families::kImport, (NSInteger)s) ]];
        u.account = ADIFLabel(@"");
        u.account.lineBreakMode = NSLineBreakByTruncatingTail;
        NSButton *settings = [NSButton buttonWithTitle:@"Settings..." target:nil action:nil];
        ADIFOnAction(settings, ^{ openSettings(accountSource(pu->site)); });
        [w addOptionRow:@[ ADIFLabel(@"Account:"), u.account, settings ]];
        u.dates = ADIFPopup(@[ @"QSOs on the log's dates", @"All your QSOs" ]);
        u.dates.toolTip = @"Which QSOs to download: those on the dates this log covers (all of them for an empty log), or "
                          @"every QSO the site holds for you";
        u.includeInLog = ADIFCheckbox(@"Also list QSOs already in the log", NO);
        u.sort = ADIFCheckbox(@"Sort by date and time afterwards", YES);
        ADIFOnAction(u.includeInLog, ^{ plan(*pu, true); });
        [w addOptionRow:@[ ADIFLabel(@"Download:"), u.dates, u.includeInLog, u.sort ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"action", "Action", 70}, {"call", "Call", 84}, {"date", "Date", 80},
                                                  {"time", "Time", 56}, {"band", "Band", 50}, {"mode", "Mode", 60},
                                                  {"confirmed", "Confirmed", 70}, {"record", "Record", 56},
                                                  {"changes", "Changes", 300}}
            checkboxes:YES
              sortable:NO];
        u.download = [w addButton:@"Download" trailing:NO action:^{ startDownload(*pu); }];
        [w addButton:@"Tick All" trailing:NO action:^{
            [pu->w setAllTicked:YES];
            updateApplyButton(*pu);
        }];
        [w addButton:@"Untick All" trailing:NO action:^{
            [pu->w setAllTicked:NO];
            updateApplyButton(*pu);
        }];
        u.apply = [w addButton:@"Apply Changes" trailing:YES action:^{ applyImport(*pu); }];
        [w setDefaultButton:u.download];
        w.onTicksChanged = ^{ updateApplyButton(*pu); };
        [w setStatus:ADIFString(std::string("Download your QSOs from ") + adif::importSiteName(s) +
                                ": QSOs this log lacks are added, and the ones it has gain the site's confirmation. "
                                "Nothing changes until you press Apply.")
              severity:-1];
        setRunning(u, false);
    }
    plan(u, true);
    [u.w show];
}

}  // namespace

namespace imports {

void cmdImportLotw() { openImport(adif::ImportSite::LoTW); }
void cmdImportQrzLogbook() { openImport(adif::ImportSite::QRZLogbook); }
void cmdImportEqsl() { openImport(adif::ImportSite::EQSL); }

void documentChanged() {
    static int64_t token = 0;
    int64_t mine = ++token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine != token) return;
        for (Import &u : imps)
            if (u.w && u.w.window.visible && !u.running && u.downloaded) plan(u, true);
    });
}

}  // namespace imports
