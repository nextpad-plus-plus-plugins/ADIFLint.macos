#import "Contest.h"

#import "PluginHost.h"
#import "ToolWindow.h"
#include "adif_spec.h"
#include "adif_tools.h"

#include <map>

using namespace adifhost;

namespace contest {
namespace {

struct {
    ADIFToolWindow *w = nil;
    NSPopUpButton *preset = nil;
    NSTextField *sent = nil, *contestId = nil;
    NSStackView *sentRow = nil, *idRow = nil;
    NSButton *start = nil;
} cw;

adif::ContestPreset presetFrom(const std::string &s) {
    return s == "FD" ? adif::ContestPreset::FieldDay : s == "WFD" ? adif::ContestPreset::WinterFieldDay
                     : s == "SERIAL"                 ? adif::ContestPreset::Serial
                                                     : adif::ContestPreset::None;
}
const char *presetKey(adif::ContestPreset p) {
    return p == adif::ContestPreset::FieldDay ? "FD" : p == adif::ContestPreset::WinterFieldDay ? "WFD" : p == adif::ContestPreset::Serial ? "SERIAL" : "";
}

// What the window shows now (not necessarily running).
adif::ContestSetup chosen() {
    adif::ContestSetup s;
    NSInteger i = cw.preset.indexOfSelectedItem;
    s.preset = i == 0 ? adif::ContestPreset::FieldDay : i == 1 ? adif::ContestPreset::WinterFieldDay : adif::ContestPreset::Serial;
    s.sent = ADIFStd(cw.sent.stringValue);
    s.contestId = ADIFStd(cw.contestId.stringValue);
    return s;
}

std::string plural(size_t n, const char *w) { return std::to_string(n) + " " + w + (n == 1 ? "" : "s"); }

void refresh() {
    if (!cw.w) return;
    adif::ContestSetup s = chosen();
    bool fieldDay = s.preset != adif::ContestPreset::Serial;
    cw.sentRow.hidden = !fieldDay;
    cw.idRow.hidden = fieldDay;
    cw.sent.placeholderString = s.preset == adif::ContestPreset::WinterFieldDay ? @"e.g. 2O IL" : @"e.g. 1D IL";
    bool running = setting("contestActive") == "1";
    cw.start.title = running ? @"Stop" : @"Start";
    [cw.w setTarget:[@"Log: " stringByAppendingString:ADIFString(documentName())]];
    // This log's contest QSOs per band and mode, as the Field Days count them.
    std::string id = adif::contestIdFor(s);
    std::map<std::string, std::map<std::string, size_t>> count;
    size_t total = 0;
    int next = 1;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        for (const adif::Record &rec : adif::records(text, r.model)) {
            if (!id.empty() && !adif::equalsNoCase(rec.get("CONTEST_ID"), id)) continue;
            if (id.empty() && rec.get("STX").empty()) continue;
            ++count[adif::effectiveBand(rec)][adif::modeCategory(rec.get("MODE"))];
            ++total;
        }
        next = adif::nextSerial(text, r.model, id);
    } catch (...) {
    }
    std::vector<std::vector<std::string>> rows;
    for (const auto &entry : count) {
        const std::map<std::string, size_t> &modes = entry.second;
        auto n = [&modes](const char *m) {
            auto it = modes.find(m);
            return it == modes.end() ? std::string() : std::to_string(it->second);
        };
        size_t sum = 0;
        for (const auto &kv : modes) sum += kv.second;
        rows.push_back({entry.first.empty() ? "?" : entry.first, n("CW"), n("PH"), n("DG"), std::to_string(sum)});
    }
    [cw.w setRows:rows severities:std::vector<int>()];
    std::string problem = adif::sentProblem(s);
    if (s.preset == adif::ContestPreset::Serial && running)
        problem.clear();
    std::string st;
    int severity = -1;
    if (!problem.empty()) st = problem, severity = 2;
    else if (s.preset == adif::ContestPreset::Serial)
        st = "New QSO asks for SRX and writes STX " + std::to_string(next) + " next, counting up" +
             (id.empty() ? "" : ", with CONTEST_ID " + id) + ". " + plural(total, "QSO") + " so far.";
    else
        st = std::string("New QSO asks for their CLASS and ARRL_SECT and writes CONTEST_ID ") + id + ", your exchange in STX_STRING " +
             "and theirs in SRX_STRING. A station counts once per band and mode (CW, Phone, Digital)" +
             (s.preset == adif::ContestPreset::WinterFieldDay ? "; FT4 and FT8 don't count (2025 rules)" : "") + ". " +
             plural(total, "QSO") + " in this log.";
    if (running) st = "Running: " + st;
    [cw.w setStatus:ADIFString(st) severity:severity];
    cw.start.enabled = running || problem.empty();
}

void startStop() {
    if (setting("contestActive") == "1") {
        setSetting("contestActive", "0");
        setSetting("contestStopped", "1");  // New QSO empties the contest's rows once
    } else {
        adif::ContestSetup s = chosen();
        if (!adif::sentProblem(s).empty()) return refresh();
        setSetting("contestPreset", presetKey(s.preset));
        setSetting("contestSent", s.sent);
        setSetting("contestId", s.contestId);
        setSetting("contestActive", "1");
        openNewQso();
    }
    stationChanged();  // New QSO's rows follow
    refresh();
}

}  // namespace

adif::ContestSetup setup() {
    adif::ContestSetup s;
    if (setting("contestActive") != "1") return s;
    s.preset = presetFrom(setting("contestPreset"));
    s.sent = setting("contestSent");
    s.contestId = setting("contestId");
    return s;
}

std::string label() {
    adif::ContestSetup s = setup();
    if (s.preset == adif::ContestPreset::None) return "";
    std::string out = adif::contestPresetName(s.preset);
    if (s.preset == adif::ContestPreset::Serial) return out + (s.contestId.empty() ? "" : " (" + s.contestId + ")");
    return out + ", sending " + s.sent;
}

void documentChanged() {
    if (cw.w && cw.w.window.visible) refresh();
}

void cmdContest() {
    if (!cw.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Contest" size:NSMakeSize(640, 380) headline:NO];
        cw.w = w;
        cw.preset = ADIFPopup(@[ @"ARRL Field Day", @"Winter Field Day", @"Serial numbers" ]);
        adif::ContestPreset p = presetFrom(setting("contestPreset"));
        [cw.preset selectItemAtIndex:p == adif::ContestPreset::WinterFieldDay ? 1 : p == adif::ContestPreset::Serial ? 2 : 0];
        [w addOptionRow:@[ ADIFLabel(@"Contest:"), cw.preset ]];
        cw.sent = ADIFTextField(@"e.g. 1D IL", 120);
        cw.sent.stringValue = ADIFString(setting("contestSent"));
        cw.sentRow = [w addOptionRow:@[ ADIFLabel(@"Your exchange:"), cw.sent ]];
        cw.contestId = ADIFTextField(@"e.g. CQ-WPX-SSB (optional)", 220);
        cw.contestId.stringValue = ADIFString(setting("contestId"));
        cw.idRow = [w addOptionRow:@[ ADIFLabel(@"CONTEST_ID:"), cw.contestId ]];
        ADIFOnAction(cw.preset, ^{
            if (setting("contestActive") == "1") setSetting("contestActive", "0"), setSetting("contestStopped", "1"), stationChanged();
            refresh();
        });
        for (NSTextField *f in @[ cw.sent, cw.contestId ])
            [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                              object:f
                                                               queue:nil
                                                          usingBlock:^(NSNotification *) { refresh(); }];
        [w setColumns:std::vector<ADIFToolColumn>{{"band", "Band", 70}, {"cw", "CW", 60}, {"ph", "Phone", 60}, {"dg", "Digital", 60},
                                                  {"total", "Total", 60}}
            checkboxes:NO
              sortable:NO];
        cw.start = [w addButton:@"Start" trailing:YES action:^{ startStop(); }];
        [w setDefaultButton:cw.start];
    }
    refresh();
    [cw.w show];
}

}  // namespace contest
