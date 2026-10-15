// ADIF Lint — a Nextpad++ (macOS) plugin for ADIF 3.1.7 .adi log files:
// validation as you type, length repair, syntax colouring, reformatting,
// autocomplete, a record panel, a New QSO window (lookup, spots),
// Enrich (callbooks, country data), Import (LoTW, QRZ.com Logbook, eQSL), log tools (table, summary,
// POTA/WWFF/SOTA tracker and export, worked before, bulk edit, time shift,
// sort, duplicates, merge, CSV, Cabrillo) and uploads.
//
// All ADIF logic lives in src/core (pure C++, tested on its own). This file is
// the editor glue; RecordPanel.mm, NewQsoPanel.mm, EnrichPanel.mm and
// SettingsPanel.mm are the AppKit views, Lookup.mm does the network and
// Keychain work, and LogTools.mm runs the log tools through PluginHost.h.
//
// Host facts this relies on (Nextpad++ 1.1.2, NppPluginInterfaceMac.h, the
// plugin porting playbook in nextpad-plus-plus/nppPluginList, and host source):
//   - Plugins cannot supply a lexer, so colours are INDIC_TEXTFORE indicators,
//     painted for the visible lines only.
//   - NPPM_SETSTATUSBAR is a no-op on macOS, so summaries go in a call tip.
//   - Plugin default shortcuts are ignored, so none are declared.
//   - NPPN_FILEOPENED never fires; NPPN_BUFFERACTIVATED covers newly opened files.
//   - SCN_DWELLSTART/END are forwarded only once a plugin sets SCI_SETMOUSEDWELLTIME.
//   - NPPM_ALLOCATEINDICATOR hands out ids from 9; the host itself uses 8, 17-19, 28 and 31.
//   - Plugins see SCN_CHARADDED before the host, and the host's word completion
//     then cancels any list on a non-word character and may replace it on a
//     word character, so this plugin opens and re-opens its lists from
//     dispatch_async, after the host has handled the keystroke.
//   - In SCN_AUTOCSELECTION, SCI_AUTOCCANCEL stops Scintilla inserting the
//     choice (Scintilla 5.6 ScintillaBase::AutoCompleteCompleted); a new list or
//     edit must wait until the handler returns.
//   - NPPM_DMM_REGISTERPANEL docks an NSView (host 1.0.3 and later).
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"

#import <Cocoa/Cocoa.h>

#import "CheckLog.h"
#import "Families.h"
#import "Country.h"
#import "EnrichPanel.h"
#import "LogTools.h"
#import "Monitor.h"
#import "Contest.h"
#import "Labels.h"
#import "LotwUsers.h"
#import "IotaGroups.h"
#import "PotaParks.h"
#import "Map.h"
#import "Lookup.h"
#import "NewQsoPanel.h"
#import "PluginHost.h"
#import "QsoFieldsPanel.h"
#import "RecordPanel.h"
#import "SettingsPanel.h"
#import "Station.h"
#import "ToolWindow.h"
#import "Imports.h"
#import "Uploads.h"
#include "adif_edit.h"
#include "adif_enrich.h"
#include "adif_lint.h"
#include "adif_spec.h"
#include "adif_tools.h"
#include "adif_upload.h"
#include "adif_geo.h"
#include "adif_programs.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <ctime>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <vector>

#ifndef ADIFLINT_VERSION
#define ADIFLINT_VERSION "1.2.0"
#endif

static const char kPluginName[] = "ADIF Lint";
static const char kProjectUrl[] = "https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint";

NppData nppData;

enum {
    kCmdNewQso,
    kCmdSpots,
    kCmdStartActivation,
    kSepLog,
    kCmdLogTable,
    kCmdCheckLog,
    kCmdFixLengths,
    kCmdNextProblem,
    kCmdPreviousProblem,
    kSepEdit,
    kCmdBulkEdit,
    kCmdTimeShift,
    kCmdOrganize,
    kCmdDupes,
    kCmdMerge,
    kSepReports,
    kCmdSummary,
    kCmdTracker,
    kCmdWorkedBefore,
    kCmdMap,
    kSepServices,
    kCmdImport,
    kCmdExport,
    kCmdUpload,
    kCmdEnrich,
    kCmdMonitor,
    kSepView,
    kCmdRecordPanel,
    kCmdReformatRecords,
    kCmdReformatFields,
    kCmdAutoValidate,
    kSepSettings,
    kCmdSettings,
    kCmdAbout,
    kCmdCount
};
static FuncItem funcItem[kCmdCount];

// Indicators, offset from the allocated base.
enum { kIndError, kIndWarning, kIndNote, kIndName, kIndPunct, kIndMarker, kIndComment, kIndCount };
static const int kFallbackIndicatorBase = 20;  // 20-26: outside the host's allocator range and its own ids
static const int kDwellMs = 500;
static const intptr_t kAutoValidateMaxBytes = 64 << 20;  // larger files: Validate Now only

enum class ListKind { None, Names, Values };

static struct {
    bool ready = false;
    // Settings (ADIFLint.ini)
    bool autoValidate = true;
    bool colour = true;
    bool autocomplete = true;
    bool countCharacters = false;
    bool panelWanted = false;
    bool firstRun = false;  // no ADIFLint.ini yet: show the welcome
    std::string pendingOpen;  // a file asked to open; New QSO opens on it when it becomes active
    std::vector<std::string> qsoFieldList;  // New QSO fields; empty: the log's own fields
    bool qsoCarryHidden = true;             // copy station fields that are not listed
    std::map<std::string, std::string> extra;  // other key=value settings (PluginHost setting())

    // Places you edited by hand: once the log reads cleanly again, an uploaded
    // record's QRZ.com/Club Log status Y there becomes M (ADIF: modified since upload).
    struct {
        intptr_t buffer = 0;
        std::vector<intptr_t> pos;
    } touched;
    bool ownEdit = false;  // the plugin is changing the document itself

    int indicatorBase = kFallbackIndicatorBase;
    std::set<intptr_t> manualBuffers;  // buffers validated on request (any extension)

    // The last lint of the active buffer, with its model. Offsets are valid while
    // the buffer, edit count and length are unchanged.
    adif::LintResult last;
    intptr_t lastBuffer = 0;
    uint64_t lastEdit = ~0ull;
    intptr_t lastLength = -1;
    uint64_t editCount = 0;  // SCN_MODIFIED insert/delete seen
    // The Record Panel's line about the whole log, for (buffer, edit).
    intptr_t healthBuffer = 0, healthLength = -1;
    uint64_t healthEdit = ~0ull;
    std::string health;
    int healthSeverity = -1;

    bool tipFromDwell = false;
    int64_t scheduleToken = 0, paintToken = 0, panelToken = 0;

    // Autocomplete list session.
    struct {
        ListKind kind = ListKind::None;
        intptr_t start = 0;       // where the typed word starts
        std::string list;         // as passed to SCI_AUTOCSHOW
        char separator = ' ';
        bool cancelPending = false;
    } list;

    // A field inserted from autocomplete: its length is set once the caret leaves its data.
    struct {
        bool active = false;
        intptr_t buffer = 0;
        intptr_t tagB = 0, lenB = 0, lenE = 0, valueB = 0;
    } pending;

    // Record panel
    ADIFRecordPanel *panel = nil;
    uint64_t panelHandle = 0;
    NSPanel *panelWindow = nil;  // fallback when the host cannot dock
    intptr_t panelGroupStart = -1;
    std::vector<std::string> panelNames;  // field names shown, to check edits still match

    // Enrich Log
    struct {
        ADIFEnrichPanel *panel = nil;
        bool running = false, cancelled = false;
        intptr_t buffer = 0;
        ADIFSource source = ADIFSourceQRZ;
        std::vector<std::string> fields;
        bool selectionOnly = false, skipAway = true;
        size_t selB = 0, selE = 0;
        std::vector<std::string> calls;  // unique calls to look up: those with a record that lacks a chosen field
        size_t next = 0, notFound = 0, failed = 0;
        size_t inFlight = 0, done = 0, parallel = 4, recordsComplete = 0;
        double started = 0;  // seconds, for the time left
        unsigned run = 0;    // which Find Data an answer belongs to
        std::string firstError;
        std::map<std::string, adif::FieldMap> found;
        std::vector<adif::EnrichChange> changes;
        ADIFCallbookClient *client = nil;
    } enrich;

    ADIFSettingsPanel *settings = nil;

    // New QSO window
    ADIFNewQsoPanel *qso = nil;
    ADIFQsoFieldsPanel *qsoFieldsPanel = nil;
    std::vector<adif::QsoField> qsoFields;  // the rows, with which ones carry over
    std::string qsoMode;                    // MODE at the last check, to follow mode changes
    int64_t qsoToken = 0;

    // New QSO's call lookup (country data, QRZ.com, HamQTH)
    struct {
        std::string call;                           // the call last looked up
        std::map<std::string, std::string> filled;  // fields the lookup filled, with what it put there
        std::string found;                          // what the callbook or country data said, for the info line
        adif::FieldMap callbook;                    // the callbook's data for `call`
        ADIFCallbookClient *client = nil;
        NSInteger clientSource = -1;
        int64_t token = 0;
    } lookup;
} g;

// ── Host and Scintilla helpers ──────────────────────────────────────────────

static intptr_t app(uint32_t msg, uintptr_t wp = 0, intptr_t lp = 0) {
    return nppData._sendMessage(nppData._nppHandle, msg, wp, lp);
}

static NppHandle currentScintilla() {
    int which = -1;
    app(NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return which == 1 ? nppData._scintillaSecondHandle : nppData._scintillaMainHandle;
}

static intptr_t sci(NppHandle h, uint32_t msg, uintptr_t wp = 0, intptr_t lp = 0) {
    return nppData._sendMessage(h, msg, wp, lp);
}

static intptr_t currentBuffer() { return app(NPPM_GETCURRENTBUFFERID); }

static std::string currentPath() {
    char buf[2048] = {0};  // the host writes up to 1024 bytes
    app(NPPM_GETFULLCURRENTPATH, sizeof buf, (intptr_t)buf);
    return buf;
}

// ADIF §IV.A: ADI files use .adi; applications should also accept .adif.
static bool isAdiPath(const std::string &path) {
    size_t dot = path.find_last_of('.');
    if (dot == std::string::npos || path.find('/', dot) != std::string::npos) return false;
    std::string ext = path.substr(dot + 1);
    return adif::equalsNoCase(ext, "adi") || adif::equalsNoCase(ext, "adif");
}

static bool isAdifBuffer(intptr_t buffer) { return g.manualBuffers.count(buffer) || isAdiPath(currentPath()); }

static std::string_view docText(NppHandle h) {
    intptr_t len = sci(h, SCI_GETLENGTH);
    const char *p = (const char *)sci(h, SCI_GETCHARACTERPOINTER);
    if (!p || len <= 0) return {};
    return std::string_view(p, (size_t)len);
}

static bool docUtf8(NppHandle h) { return sci(h, SCI_GETCODEPAGE) == SC_CP_UTF8; }

static adif::LengthUnit lengthUnit() {
    return g.countCharacters ? adif::LengthUnit::Characters : adif::LengthUnit::Bytes;
}

static std::string eolString(NppHandle h) {
    switch (sci(h, SCI_GETEOLMODE)) {
        case SC_EOL_CRLF: return "\r\n";
        case SC_EOL_CR: return "\r";
        default: return "\n";
    }
}

static std::string configPath() {
    char buf[2048] = {0};
    app(NPPM_GETPLUGINSCONFIGDIR, sizeof buf, (intptr_t)buf);
    if (!buf[0]) return {};
    return std::string(buf) + "/ADIFLint.ini";
}

static void loadSettings() {
    std::string path = configPath();
    if (path.empty()) return;
    std::ifstream in(path);
    g.firstRun = !in;  // no settings file yet
    std::string line;
    auto flag = [&](const char *key, bool &v) {
        size_t n = std::strlen(key);
        if (line.compare(0, n, key) == 0 && line.size() > n && line[n] == '=') v = line.substr(n + 1) == "1";
    };
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t eq = line.find('=');
        if (eq != std::string::npos && eq > 0) {
            std::string key = line.substr(0, eq);
            static const std::set<std::string> kOwn = {"autoValidate", "colour", "autocomplete", "countCharacters",
                                                       "recordPanel", "qsoCarryHidden", "qsoFields"};
            // Radio settings from earlier versions (the radio connection was removed): dropped on the next save.
            static const std::set<std::string> kGone = {"radioKind", "radioHost", "radioPort", "radioFollow"};
            if (!kOwn.count(key) && !kGone.count(key)) g.extra[key] = line.substr(eq + 1);
        }
        flag("autoValidate", g.autoValidate);
        flag("colour", g.colour);
        flag("autocomplete", g.autocomplete);
        flag("countCharacters", g.countCharacters);
        flag("recordPanel", g.panelWanted);
        flag("qsoCarryHidden", g.qsoCarryHidden);
        if (line.rfind("qsoFields=", 0) == 0) {
            g.qsoFieldList.clear();
            std::string list = line.substr(10), item;
            for (size_t i = 0; i <= list.size(); ++i) {
                if (i == list.size() || list[i] == ',') {
                    if (!item.empty()) g.qsoFieldList.push_back(item);
                    item.clear();
                } else if (list[i] != ' ' && list[i] != '\r') {
                    item.push_back(list[i]);
                }
            }
        }
    }
}

static void saveSettings() {
    std::string path = configPath();
    if (path.empty()) return;
    std::ofstream out(path, std::ios::trunc);
    out << "autoValidate=" << g.autoValidate << "\n"
        << "colour=" << g.colour << "\n"
        << "autocomplete=" << g.autocomplete << "\n"
        << "countCharacters=" << g.countCharacters << "\n"
        << "recordPanel=" << g.panelWanted << "\n"
        << "qsoCarryHidden=" << g.qsoCarryHidden << "\n"
        << "qsoFields=";
    for (size_t i = 0; i < g.qsoFieldList.size(); ++i) out << (i ? "," : "") << g.qsoFieldList[i];
    out << "\n";
    for (const auto &kv : g.extra)
        if (kv.second.find('\n') == std::string::npos) out << kv.first << "=" << kv.second << "\n";
}

static std::string upperAscii(std::string s) {
    for (char &c : s) c = (char)std::toupper((unsigned char)c);
    return s;
}

static std::string trimmed(std::string_view s) {
    size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
    return b == std::string_view::npos ? std::string() : std::string(s.substr(b, e - b + 1));
}

static void setCheck(int item, bool on) { app(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItem[item]._cmdID, on); }

// Call tips do not wrap, so wrap long messages for readability.
static std::string wrap(const std::string &s, size_t width = 96) {
    std::string out;
    size_t col = 0, i = 0;
    while (i < s.size()) {
        size_t sp = s.find(' ', i);
        std::string word = s.substr(i, sp == std::string::npos ? std::string::npos : sp - i);
        if (col && col + 1 + word.size() > width) {
            out += "\n    ";
            col = 4;
        } else if (col) {
            out += ' ';
            ++col;
        }
        out += word;
        col += word.size();
        if (sp == std::string::npos) break;
        i = sp + 1;
    }
    return out;
}

static void showTip(NppHandle h, intptr_t pos, const std::string &text) {
    sci(h, SCI_CALLTIPSHOW, (uintptr_t)pos, (intptr_t)text.c_str());
}

static const char *severityLabel(adif::Severity s) {
    switch (s) {
        case adif::Severity::Error: return "Error: ";
        case adif::Severity::Warning: return "Warning: ";
        case adif::Severity::Info: return "Note: ";
    }
    return "";
}

// Apply edits (sorted by position, non-overlapping) as one undo step.
// `byUser`: an edit you made through the plugin (Record Panel, autocomplete), which
// counts as hand editing for the upload status; other plugin edits mark it themselves.
static void applyEdits(NppHandle h, const std::vector<adif::TextEdit> &edits, bool byUser = false) {
    g.ownEdit = !byUser;
    sci(h, SCI_BEGINUNDOACTION);
    for (auto it = edits.rbegin(); it != edits.rend(); ++it) {  // from the end: earlier offsets stay valid
        sci(h, SCI_SETTARGETRANGE, (uintptr_t)it->start, (intptr_t)it->end);
        sci(h, SCI_REPLACETARGET, (uintptr_t)it->text.size(), (intptr_t)it->text.data());
    }
    sci(h, SCI_ENDUNDOACTION);
    g.ownEdit = false;
}

// Keep the hand-edit places in step with every change; note the ones you made.
static void noteEdit(const SCNotification *n) {
    intptr_t p = n->position, len = n->length;
    bool insert = (n->modificationType & SC_MOD_INSERTTEXT) != 0;
    for (intptr_t &q : g.touched.pos) {
        if (insert) {
            if (q >= p) q += len;
        } else if (q >= p + len) {
            q -= len;
        } else if (q > p) {
            q = p;
        }
    }
    int mod = n->modificationType;
    if (g.ownEdit || !(mod & SC_PERFORMED_USER) || (mod & (SC_PERFORMED_UNDO | SC_PERFORMED_REDO))) return;
    intptr_t b = currentBuffer();
    if (g.touched.buffer != b) {
        g.touched.pos.clear();
        g.touched.buffer = b;
    }
    if (g.touched.pos.size() < 256) g.touched.pos.push_back(p);
}

static const adif::LintResult &freshLint(NppHandle h);
static const adif::LintResult &validateNow(NppHandle h, bool showDiagnostics);
static std::string utcNow(const char *format);
static std::string documentName();
static void openSettings(NSInteger source);

// ── PluginHost: what the other plugin files use ─────────────────────────────

static void cmdFixLengths();
static void cmdNewQso();
static bool qsoVisible();
// keepStation false: the station changed, so station fields come from it, not the window.
static void loadQsoRows(NppHandle h, const adif::LintResult &r, bool keepValues, bool keepStation = true);
static void refreshQsoTarget();
static void scheduleQsoCheck();

namespace adifhost {
NppHandle scintilla() { return currentScintilla(); }
intptr_t sci(NppHandle h, uint32_t msg, uintptr_t wp, intptr_t lp) { return ::sci(h, msg, wp, lp); }
intptr_t buffer() { return currentBuffer(); }
std::string path() { return currentPath(); }
std::string documentName() { return ::documentName(); }
std::string_view text(NppHandle h) { return docText(h); }
bool utf8(NppHandle h) { return docUtf8(h); }
adif::LengthUnit lengthUnit() { return ::lengthUnit(); }
std::string eol(NppHandle h) { return eolString(h); }
std::string utcNow(const char *format) { return ::utcNow(format); }
std::string plural(size_t n, const char *word) { return std::to_string(n) + " " + word + (n == 1 ? "" : "s"); }
adif::LintResult lintText(std::string_view text) {
    adif::LintOptions opt;
    opt.lengthUnit = ::lengthUnit();
    opt.buildModel = true;
    return adif::lint(text, opt);
}
std::string structureProblem(const adif::LintResult &r) {
    if (!adif::canReformat(r))
        return "The log has structural problems (wrong lengths or broken tags). Run Fix Lengths, then fix the errors "
               "marked in red.";
    for (const adif::ModelGroup &g : r.model.groups)
        if (!g.header && g.markerB == adif::kNoPos) return "A record has no <EOR>. Add it, then try again.";
    return "";
}
const adif::LintResult &lint(NppHandle h) { return freshLint(h); }
void validate(NppHandle h) {
    g.manualBuffers.insert(currentBuffer());
    validateNow(h, g.autoValidate);
}
void apply(NppHandle h, const std::vector<adif::TextEdit> &edits) {
    applyEdits(h, edits);
    g.manualBuffers.insert(currentBuffer());
    validateNow(h, g.autoValidate);
}
bool readOnly(NppHandle h) { return ::sci(h, SCI_GETREADONLY) != 0; }
void fixLengths() { cmdFixLengths(); }
void showTip(NppHandle h, const std::string &text) { ::showTip(h, ::sci(h, SCI_GETCURRENTPOS), wrap(text)); }
void goTo(NppHandle h, size_t pos, bool focus) {
    intptr_t line = ::sci(h, SCI_LINEFROMPOSITION, pos);
    ::sci(h, SCI_ENSUREVISIBLEENFORCEPOLICY, (uintptr_t)line);
    ::sci(h, SCI_GOTOPOS, pos);
    ::sci(h, SCI_SCROLLCARET);
    if (focus) {
        [NSApp.mainWindow makeKeyAndOrderFront:nil];
        ::sci(h, SCI_GRABFOCUS);
    }
}
std::string configDir() {
    std::string p = configPath();
    return p.empty() ? std::string() : p.substr(0, p.find_last_of('/'));
}
std::string setting(const std::string &key) {
    auto it = g.extra.find(key);
    return it == g.extra.end() ? std::string() : it->second;
}
void setSetting(const std::string &key, const std::string &value) {
    if (setting(key) == value) return;
    g.extra[key] = value;
    saveSettings();
}
void openSettings(long source) { ::openSettings((NSInteger)source); }

bool openFile(const std::string &file, bool newQso) {
    if (newQso) g.pendingOpen = file;
    if (app(NPPM_DOOPEN, 0, (intptr_t)file.c_str())) return true;
    g.pendingOpen.clear();
    return false;
}

std::vector<std::string> openFiles(bool *known) {
    std::vector<std::string> out;
    intptr_t n = app(NPPM_GETNBOPENFILES, 0, 0);
    if (n > 0 && n < 4096) {
        std::vector<std::vector<char>> slots((size_t)n, std::vector<char>(1024, 0));
        std::vector<char *> ptrs;
        for (auto &slot : slots) ptrs.push_back(slot.data());
        intptr_t got = app(NPPM_GETOPENFILENAMES, (uintptr_t)ptrs.data(), n);
        for (intptr_t i = 0; i < got && i < n; ++i) out.emplace_back(ptrs[(size_t)i]);
    }
    // An older Nextpad++ answers 0 even with this document open: then it can't say.
    std::string active = currentPath();
    if (known) *known = n > 0 && (active.empty() || std::find(out.begin(), out.end(), active) != out.end());
    return out;
}

void openNewQso() { cmdNewQso(); }

void stationChanged() {
    if (!qsoVisible()) return;
    try {
        NppHandle h = currentScintilla();
        loadQsoRows(h, freshLint(h), true, false);
        refreshQsoTarget();
        scheduleQsoCheck();
    } catch (...) {
    }
}
}  // namespace adifhost

// ── Indicators ──────────────────────────────────────────────────────────────

static int ind(int which) { return g.indicatorBase + which; }

static void styleIndicators(NppHandle h) {
    bool dark = app(NPPM_ISDARKMODEENABLED) != 0;
    // Scintilla colours are 0xBBGGRR.
    struct { int style; int light; int dark; } spec[kIndCount] = {
        {INDIC_SQUIGGLEPIXMAP, 0x241BE0, 0x6B6BFF},  // error: red
        {INDIC_SQUIGGLEPIXMAP, 0x008CF0, 0x40B0FF},  // warning: orange
        {INDIC_DOTS, 0xD8711C, 0xFFB46C},            // note: blue
        {INDIC_TEXTFORE, 0xB45F1A, 0xEDAE78},        // field name: blue
        {INDIC_TEXTFORE, 0x8A8A8A, 0x909090},        // < : length : type >: grey
        {INDIC_TEXTFORE, 0xAC4191, 0xF09BDC},        // <EOH> <EOR>: purple
        {INDIC_TEXTFORE, 0x4E8A26, 0x8FD49A},        // text outside fields: green
    };
    for (int i = 0; i < kIndCount; ++i) {
        sci(h, SCI_INDICSETSTYLE, (uintptr_t)ind(i), spec[i].style);
        sci(h, SCI_INDICSETFORE, (uintptr_t)ind(i), dark ? spec[i].dark : spec[i].light);
        sci(h, SCI_INDICSETUNDER, (uintptr_t)ind(i), 0);
    }
}

static void clearIndicatorRange(NppHandle h, int first, int last, intptr_t from, intptr_t to) {
    if (to <= from) return;
    intptr_t old = sci(h, SCI_GETINDICATORCURRENT);
    for (int i = first; i <= last; ++i) {
        sci(h, SCI_SETINDICATORCURRENT, (uintptr_t)ind(i));
        sci(h, SCI_INDICATORCLEARRANGE, (uintptr_t)from, to - from);
    }
    sci(h, SCI_SETINDICATORCURRENT, (uintptr_t)old);
}

static void clearDiagnosticMarks(NppHandle h) { clearIndicatorRange(h, kIndError, kIndNote, 0, sci(h, SCI_GETLENGTH)); }
static void clearColours(NppHandle h) { clearIndicatorRange(h, kIndName, kIndComment, 0, sci(h, SCI_GETLENGTH)); }

static void paintDiagnostics(NppHandle h, const adif::LintResult &r) {
    clearDiagnosticMarks(h);
    intptr_t old = sci(h, SCI_GETINDICATORCURRENT);
    int current = -1;
    for (const adif::Diagnostic &d : r.diagnostics) {
        int i = ind(d.severity == adif::Severity::Error ? kIndError : d.severity == adif::Severity::Warning ? kIndWarning : kIndNote);
        if (i != current) {
            sci(h, SCI_SETINDICATORCURRENT, (uintptr_t)i);
            current = i;
        }
        sci(h, SCI_INDICATORFILLRANGE, (uintptr_t)d.start, (intptr_t)(d.end - d.start));
    }
    sci(h, SCI_SETINDICATORCURRENT, (uintptr_t)old);
}

// ── Lint cache ──────────────────────────────────────────────────────────────

static bool lastIsFresh(NppHandle h) {
    return g.lastBuffer == currentBuffer() && g.lastEdit == g.editCount && g.lastLength == sci(h, SCI_GETLENGTH);
}

static const adif::LintResult &lintNow(NppHandle h) {
    adif::LintOptions opt;
    opt.lengthUnit = lengthUnit();
    opt.utf8 = docUtf8(h);
    opt.buildModel = true;
    opt.today = adifhost::utcNow("%Y%m%d");
    g.last = adif::lint(docText(h), opt);
    g.lastBuffer = currentBuffer();
    g.lastEdit = g.editCount;
    g.lastLength = sci(h, SCI_GETLENGTH);
    return g.last;
}

static const adif::LintResult &freshLint(NppHandle h) { return lastIsFresh(h) ? g.last : lintNow(h); }

// ── Colouring (visible lines only) ──────────────────────────────────────────

static void paintColours(NppHandle h) {
    if (!g.colour || !lastIsFresh(h)) return;
    const adif::DocModel &m = g.last.model;
    intptr_t len = sci(h, SCI_GETLENGTH);
    intptr_t firstVisible = sci(h, SCI_GETFIRSTVISIBLELINE);
    intptr_t onScreen = sci(h, SCI_LINESONSCREEN);
    intptr_t firstDoc = sci(h, SCI_DOCLINEFROMVISIBLE, (uintptr_t)std::max<intptr_t>(0, firstVisible - onScreen));
    intptr_t lastDoc = sci(h, SCI_DOCLINEFROMVISIBLE, (uintptr_t)(firstVisible + 2 * onScreen + 1));
    intptr_t from = sci(h, SCI_POSITIONFROMLINE, (uintptr_t)firstDoc);
    intptr_t to = sci(h, SCI_GETLINEENDPOSITION, (uintptr_t)lastDoc);
    if (from < 0) from = 0;
    if (to > len || to < from) to = len;

    clearIndicatorRange(h, kIndName, kIndComment, from, to);
    intptr_t old = sci(h, SCI_GETINDICATORCURRENT);
    auto fill = [&](int which, size_t b, size_t e) {
        size_t lo = std::max<size_t>(b, (size_t)from), hi = std::min<size_t>(e, (size_t)to);
        if (hi <= lo) return;
        sci(h, SCI_SETINDICATORCURRENT, (uintptr_t)ind(which));
        sci(h, SCI_INDICATORFILLRANGE, (uintptr_t)lo, (intptr_t)(hi - lo));
    };
    // Fields are in document order; start just before the visible range.
    auto it = std::lower_bound(m.fields.begin(), m.fields.end(), (size_t)from,
                               [](const adif::ModelField &f, size_t pos) { return f.valueE < pos; });
    for (; it != m.fields.end() && (intptr_t)it->tagB < to; ++it) {
        fill(kIndPunct, it->tagB, it->tagB + 1);
        fill(kIndName, it->tagB + 1, it->nameE);
        fill(kIndPunct, it->nameE, it->gt + 1);
    }
    int gi = std::max(0, adif::groupAt(m, (size_t)from));
    for (size_t i = (size_t)gi; i < m.groups.size(); ++i) {
        const adif::ModelGroup &grp = m.groups[i];
        if (grp.markerB == adif::kNoPos) continue;
        if ((intptr_t)grp.markerB >= to) break;
        fill(kIndMarker, grp.markerB, grp.markerE);
    }
    if (m.headerTextE > m.headerTextB) fill(kIndComment, m.headerTextB, m.headerTextE);
    for (const auto &t : m.otherText) {
        if ((intptr_t)t.first >= to) break;
        fill(kIndComment, t.first, t.second);
    }
    sci(h, SCI_SETINDICATORCURRENT, (uintptr_t)old);
}

static void schedulePaint() {
    int64_t mine = ++g.paintToken;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (mine != g.paintToken || !g.ready) return;
        try {
            NppHandle h = currentScintilla();
            if (isAdifBuffer(currentBuffer())) paintColours(h);
        } catch (...) {
        }
    });
}

// ── Validation ──────────────────────────────────────────────────────────────

static void refreshPanel();

// Lint the active buffer, mark its problems and colour it.
static const adif::LintResult &validateNow(NppHandle h, bool showDiagnostics = true) {
    const adif::LintResult &r = lintNow(h);
    styleIndicators(h);
    if (showDiagnostics) paintDiagnostics(h, r);
    else clearDiagnosticMarks(h);
    paintColours(h);
    refreshPanel();
    logtools::documentChanged();
    uploads::documentChanged();
    imports::documentChanged();
    checklog::documentChanged();
    contest::documentChanged();
    labels::documentChanged();
    worldmap::documentChanged();
    return r;
}

static std::string summary(const adif::LintResult &r) {
    using adifhost::plural;
    std::string s = "ADIF " + std::string(adif::kSpecVersion) + ": " + plural(r.records, "record") + ", " +
                    plural(r.errors, "error") + ", " + plural(r.warnings, "warning") + ", " + plural(r.infos, "note") + ".";
    if (!r.fixes.empty()) s += "\nFix Lengths can correct " + plural(r.fixes.size(), "data length") + ".";
    if (r.truncated) s += "\nOnly the first " + std::to_string(r.diagnostics.size()) + " problems are marked.";
    if (r.errors || r.warnings || r.infos) s += "\nHover a squiggle for details, or use Next Problem.";
    return s;
}

// An uploaded record you edited by hand: its QRZ.com/Club Log status Y becomes M,
// once the log reads cleanly (no wrong lengths), as its own undo step.
static void markHandEdits(NppHandle h) {
    if (g.touched.pos.empty()) return;
    if (g.touched.buffer != currentBuffer()) {
        g.touched.pos.clear();
        return;
    }
    const adif::LintResult &r = g.last;
    if (!lastIsFresh(h) || r.structuralErrors || !r.fixes.empty() || g.pending.active) return;  // wait for a clean read
    std::string_view text = docText(h);
    std::vector<int> groups;
    for (intptr_t p : g.touched.pos) {
        int gi = adif::groupAt(r.model, (size_t)p);
        if (gi < 0) continue;
        const adif::ModelGroup &grp = r.model.groups[(size_t)gi];
        if (grp.header || (size_t)p >= adif::groupEnd(r.model, grp)) continue;
        int fi = adif::fieldAt(r.model, (size_t)p);
        if (fi >= 0 && adif::isTrackingField(adif::fieldName(text, r.model.fields[(size_t)fi]))) continue;
        groups.push_back(gi);
    }
    g.touched.pos.clear();
    std::vector<adif::TextEdit> edits = adif::markModified(text, r.model, groups, lengthUnit(), docUtf8(h));
    if (edits.empty() || sci(h, SCI_GETREADONLY)) return;
    applyEdits(h, edits);
    validateNow(h, g.autoValidate);
}

static void runScheduled() {
    if (!g.ready) return;
    try {
        NppHandle h = currentScintilla();
        if (!isAdifBuffer(currentBuffer())) {
            refreshPanel();
            logtools::documentChanged();
            uploads::documentChanged();
            imports::documentChanged();
            checklog::documentChanged();
            return;
        }
        if (sci(h, SCI_GETLENGTH) > kAutoValidateMaxBytes && !g.manualBuffers.count(currentBuffer())) return;
        validateNow(h, g.autoValidate);
        markHandEdits(h);
    } catch (...) {
        // Never let a C++ exception unwind into the host.
    }
}

// Debounce: re-check once typing pauses.
static void schedule(double seconds) {
    int64_t mine = ++g.scheduleToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine == g.scheduleToken) runScheduled();
    });
}

// ── Commands: validation and lengths ────────────────────────────────────────

static void cmdFixLengths() {
    try {
        NppHandle h = currentScintilla();
        if (sci(h, SCI_GETREADONLY)) {
            showTip(h, sci(h, SCI_GETCURRENTPOS), "ADIF Lint: this document is read-only.");
            return;
        }
        g.manualBuffers.insert(currentBuffer());
        g.pending.active = false;
        adif::LintResult r = lintNow(h);  // a copy: the edits below change the document
        if (r.fixes.empty()) {
            validateNow(h);
            showTip(h, sci(h, SCI_GETCURRENTPOS), "ADIF Lint: no data lengths need fixing.");
            return;
        }
        size_t count = r.fixes.size();
        if (count > 2000) {
            // One replacement is much faster than thousands of small ones.
            std::string fixedText = adif::applyFixes(docText(h), r.fixes);
            intptr_t caret = sci(h, SCI_GETCURRENTPOS), firstLine = sci(h, SCI_GETFIRSTVISIBLELINE);
            g.ownEdit = true;
            sci(h, SCI_BEGINUNDOACTION);
            sci(h, SCI_TARGETWHOLEDOCUMENT);
            sci(h, SCI_REPLACETARGET, (uintptr_t)fixedText.size(), (intptr_t)fixedText.data());
            sci(h, SCI_ENDUNDOACTION);
            g.ownEdit = false;
            sci(h, SCI_GOTOPOS, (uintptr_t)std::min<intptr_t>(caret, (intptr_t)fixedText.size()));
            sci(h, SCI_SETFIRSTVISIBLELINE, (uintptr_t)firstLine);
        } else {
            std::vector<adif::TextEdit> edits;
            for (const adif::LengthFix &f : r.fixes) edits.push_back({f.start, f.end, f.digits});
            applyEdits(h, edits);
        }
        const adif::LintResult &after = validateNow(h);
        showTip(h, sci(h, SCI_GETCURRENTPOS),
                "Fixed " + std::to_string(count) + " data length" + (count == 1 ? "" : "s") + " (one undo step).\n" +
                    summary(after));
    } catch (...) {
    }
}

static void gotoProblem(bool forward) {
    try {
        NppHandle h = currentScintilla();
        g.manualBuffers.insert(currentBuffer());
        const adif::LintResult &r = validateNow(h);  // fresh positions
        intptr_t caret = sci(h, SCI_GETCURRENTPOS);
        if (r.diagnostics.empty()) {
            showTip(h, caret, "ADIF Lint: no problems found.");
            return;
        }
        const adif::Diagnostic *target = nullptr;
        if (forward) {
            for (const adif::Diagnostic &d : r.diagnostics)
                if ((intptr_t)d.start > caret) {
                    target = &d;
                    break;
                }
            if (!target) target = &r.diagnostics.front();  // wrap around
        } else {
            for (auto it = r.diagnostics.rbegin(); it != r.diagnostics.rend(); ++it)
                if ((intptr_t)it->start < caret) {
                    target = &*it;
                    break;
                }
            if (!target) target = &r.diagnostics.back();
        }
        intptr_t pos = (intptr_t)target->start;
        std::string text = wrap(severityLabel(target->severity) + target->message);
        sci(h, SCI_GOTOPOS, (uintptr_t)pos);
        sci(h, SCI_SCROLLCARET);
        showTip(h, pos, text);
    } catch (...) {
    }
}

static void cmdNextProblem() { gotoProblem(true); }
static void cmdPreviousProblem() { gotoProblem(false); }

// ── Commands: reformat ──────────────────────────────────────────────────────

static void reformatAs(adif::Layout layout) {
    try {
        NppHandle h = currentScintilla();
        if (sci(h, SCI_GETREADONLY)) {
            showTip(h, sci(h, SCI_GETCURRENTPOS), "ADIF Lint: this document is read-only.");
            return;
        }
        g.manualBuffers.insert(currentBuffer());
        g.pending.active = false;
        adif::LintResult r = lintNow(h);
        if (!adif::canReformat(r)) {
            validateNow(h);
            std::string why = "ADIF Lint: reformatting needs every data length right and every tag well formed, so "
                              "that no data is moved by mistake.";
            if (!r.fixes.empty()) why += " Run Fix Lengths first.";
            if (r.structuralErrors) why += " Then fix the remaining errors in red.";
            showTip(h, sci(h, SCI_GETCURRENTPOS), wrap(why));
            return;
        }
        std::string_view text = docText(h);
        std::string out = adif::reformat(text, r.model, layout, eolString(h));
        if (out == text) {
            showTip(h, sci(h, SCI_GETCURRENTPOS), "ADIF Lint: already in that layout.");
            return;
        }
        // Keep the caret on the same field.
        intptr_t caret = sci(h, SCI_GETCURRENTPOS);
        int field = adif::fieldAt(r.model, (size_t)caret);
        intptr_t offset = field >= 0 ? caret - (intptr_t)r.model.fields[(size_t)field].tagB : 0;
        sci(h, SCI_BEGINUNDOACTION);
        sci(h, SCI_TARGETWHOLEDOCUMENT);
        g.ownEdit = true;
        sci(h, SCI_REPLACETARGET, (uintptr_t)out.size(), (intptr_t)out.data());
        g.ownEdit = false;
        sci(h, SCI_ENDUNDOACTION);
        const adif::LintResult &after = validateNow(h);
        if (field >= 0 && (size_t)field < after.model.fields.size()) {
            sci(h, SCI_GOTOPOS, (uintptr_t)(after.model.fields[(size_t)field].tagB + offset));
            sci(h, SCI_SCROLLCARET);
        }
        showTip(h, sci(h, SCI_GETCURRENTPOS),
                layout == adif::Layout::RecordPerLine ? "Reformatted: one record per line (one undo step)."
                                                      : "Reformatted: one field per line (one undo step).");
    } catch (...) {
    }
}

static void cmdReformatRecords() { reformatAs(adif::Layout::RecordPerLine); }
static void cmdReformatFields() { reformatAs(adif::Layout::FieldPerLine); }

// ── Autocomplete ────────────────────────────────────────────────────────────

static bool isNameChar(int c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'; }

static void endList() {
    g.list.kind = ListKind::None;
    g.list.cancelPending = false;
}

static void showList(NppHandle h, ListKind kind, intptr_t start, const std::vector<std::string> &items, char sep) {
    if (items.empty()) return;
    std::string list;
    for (const std::string &s : items) {
        if (!list.empty()) list.push_back(sep);
        list += s;
    }
    g.list.kind = kind;
    g.list.start = start;
    g.list.list = std::move(list);
    g.list.separator = sep;
    g.list.cancelPending = false;
    intptr_t caret = sci(h, SCI_GETCURRENTPOS);
    sci(h, SCI_AUTOCSETSEPARATOR, (uintptr_t)sep);  // the host sets its own before each of its lists
    sci(h, SCI_AUTOCSETIGNORECASE, 1);              // the host's default too
    sci(h, SCI_AUTOCSHOW, (uintptr_t)std::max<intptr_t>(0, caret - start), (intptr_t)g.list.list.c_str());
}

// Re-show the current list after the host has handled a keystroke (its word
// completion may have replaced or cancelled ours).
static void reshowList() {
    if (g.list.kind == ListKind::None) return;
    NppHandle h = currentScintilla();
    intptr_t caret = sci(h, SCI_GETCURRENTPOS);
    if (caret < g.list.start) {
        endList();
        return;
    }
    sci(h, SCI_AUTOCSETSEPARATOR, (uintptr_t)g.list.separator);
    sci(h, SCI_AUTOCSETIGNORECASE, 1);
    sci(h, SCI_AUTOCSHOW, (uintptr_t)(caret - g.list.start), (intptr_t)g.list.list.c_str());
    g.list.cancelPending = false;
}

// Set the pending field's length from its data, now that the caret has left it.
// `dataEnd` is where the data stops (a typed '<' or line break), or -1 to use
// the validator's own fix for that field.
static void finishPendingField(intptr_t dataEnd) {
    if (!g.pending.active) return;
    g.pending.active = false;
    NppHandle h = currentScintilla();
    if (g.pending.buffer != currentBuffer()) return;
    const adif::LintResult &r = lintNow(h);
    for (const adif::ModelField &f : r.model.fields) {
        if ((intptr_t)f.tagB != g.pending.tagB) continue;
        std::string_view text = docText(h);
        if (dataEnd >= 0) {
            size_t e = std::min<size_t>((size_t)dataEnd, text.size());
            size_t b = f.gt + 1;
            if (e < b) return;
            while (e > b && (text[e - 1] == ' ' || text[e - 1] == '\t' || text[e - 1] == '\r' || text[e - 1] == '\n')) --e;
            std::string digits = std::to_string(adif::measureLength(text.substr(b, e - b), lengthUnit(), docUtf8(h)));
            if (text.substr(f.lenB, f.lenE - f.lenB) != digits) applyEdits(h, {{f.lenB, f.lenE, digits}});
        } else {
            for (const adif::LengthFix &fix : r.fixes)
                if (fix.start == f.lenB) applyEdits(h, {{fix.start, fix.end, fix.digits}});
        }
        return;
    }
}

static void startPendingField(intptr_t tagB, intptr_t lenB, intptr_t lenE) {
    g.pending = {true, currentBuffer(), tagB, lenB, lenE, lenE + 1};
}

// Values for the field whose tag ends just before `valueB`, if it has a list.
static std::vector<std::string> valuesAt(NppHandle h, intptr_t tagB, std::string *nameOut) {
    const adif::LintResult &r = lintNow(h);
    std::string_view text = docText(h);
    for (const adif::ModelField &f : r.model.fields) {
        if ((intptr_t)f.tagB != tagB) continue;
        int gi = adif::groupAt(r.model, f.tagB);
        const adif::ModelGroup *grp = gi >= 0 ? &r.model.groups[(size_t)gi] : nullptr;
        std::string name(adif::fieldName(text, f));
        if (nameOut) *nameOut = name;
        std::vector<std::string> v = adif::valueChoices(text, r.model, grp, name);
        // Scintilla's default order expects a sorted list (the host relies on that order setting).
        std::sort(v.begin(), v.end(), [](const std::string &a, const std::string &b) { return adif::compareNoCase(a, b) < 0; });
        return v;
    }
    return {};
}

// After '<': offer field names, unless the '<' was typed inside a field's data.
static void openNameList(intptr_t lt) {
    NppHandle h = currentScintilla();
    intptr_t caret = sci(h, SCI_GETCURRENTPOS);
    std::string_view text = docText(h);
    if (lt < 0 || (size_t)lt >= text.size() || text[(size_t)lt] != '<' || caret <= lt) return;
    for (intptr_t i = lt + 1; i < caret; ++i)
        if (!isNameChar((unsigned char)text[(size_t)i])) return;
    const adif::LintResult &r = lintNow(h);
    int fi = adif::fieldAt(r.model, (size_t)lt);
    if (fi >= 0) {
        const adif::ModelField &f = r.model.fields[(size_t)fi];
        if ((intptr_t)f.gt < lt && lt < (intptr_t)f.valueE) return;  // inside data
    }
    bool header = false;
    if (!r.model.groups.empty() && r.model.groups.front().header) {
        const adif::ModelGroup &hg = r.model.groups.front();
        header = hg.markerB == adif::kNoPos || lt <= (intptr_t)hg.markerB;
    } else if (r.model.groups.empty() || (r.model.firstTag != adif::kNoPos && lt <= (intptr_t)r.model.firstTag)) {
        header = !text.empty() && text[0] != '<' && text.find("<EOR>") == std::string_view::npos &&
                 text.find("<eor>") == std::string_view::npos;
    }
    showList(h, ListKind::Names, lt + 1, adif::fieldNameChoices(r.model, header), ' ');
}

// A field name was chosen: write "NAME:0>" (or "EOR>"), then offer values or a hint.
static void insertChosenName(intptr_t start, std::string name) {
    NppHandle h = currentScintilla();
    intptr_t caret = sci(h, SCI_GETCURRENTPOS);
    std::string_view text = docText(h);
    if (start <= 0 || caret < start || text[(size_t)start - 1] != '<') return;
    bool marker = name == "EOR" || name == "EOH";
    bool closed = (size_t)caret < text.size() && text[(size_t)caret] == '>';
    std::string insert = marker ? name + (closed ? "" : ">") : name + ":0>";
    applyEdits(h, {{(size_t)start, (size_t)caret, insert}}, true);
    intptr_t after = start + (intptr_t)insert.size() + (marker && closed ? 1 : 0);
    sci(h, SCI_GOTOPOS, (uintptr_t)after);
    if (marker) return;
    intptr_t lenB = start + (intptr_t)name.size() + 1;
    startPendingField(start - 1, lenB, lenB + 1);
    std::vector<std::string> values = valuesAt(h, start - 1, nullptr);
    if (!values.empty()) {
        showList(h, ListKind::Values, after, values, '\n');
    } else {
        showTip(h, after, wrap(adif::describeField(g.last.model, name) +
                               ". Type the data; its length is filled in when you move on."));
    }
}

// A value was chosen: write it and set the field's length to match.
static void insertChosenValue(intptr_t start, std::string value) {
    NppHandle h = currentScintilla();
    intptr_t caret = sci(h, SCI_GETCURRENTPOS);
    const adif::LintResult &r = lintNow(h);
    for (const adif::ModelField &f : r.model.fields) {
        if ((intptr_t)f.gt + 1 != start) continue;
        std::string digits = std::to_string(adif::measureLength(value, lengthUnit(), docUtf8(h)));
        applyEdits(h, {{f.lenB, f.lenE, digits}, {(size_t)start, (size_t)std::max(caret, start), value}}, true);
        intptr_t shift = (intptr_t)digits.size() - (intptr_t)(f.lenE - f.lenB);
        sci(h, SCI_GOTOPOS, (uintptr_t)(start + shift + (intptr_t)value.size()));
        g.pending.active = false;
        return;
    }
}

// After a typed '>': if it closed <NAME:N> of a field with a list, offer values.
static void maybeOpenValueList(intptr_t gtPos) {
    NppHandle h = currentScintilla();
    std::string_view text = docText(h);
    if (gtPos < 0 || (size_t)gtPos >= text.size() || text[(size_t)gtPos] != '>') return;
    size_t after = (size_t)gtPos + 1;
    if (after < text.size() && !(text[after] == ' ' || text[after] == '\t' || text[after] == '\r' || text[after] == '\n' ||
                                 text[after] == '<'))
        return;  // data already follows
    intptr_t lt = gtPos;
    while (lt > 0 && gtPos - lt < 128 && text[(size_t)lt] != '<' && text[(size_t)lt] != '\n') --lt;
    if (text[(size_t)lt] != '<') return;
    size_t colon = text.find(':', (size_t)lt);
    if (colon == std::string_view::npos || colon > (size_t)gtPos) return;
    size_t lenE = colon + 1;
    while (lenE < (size_t)gtPos && text[lenE] >= '0' && text[lenE] <= '9') ++lenE;
    if (lenE == colon + 1) return;
    std::vector<std::string> values = valuesAt(h, lt, nullptr);
    if (values.empty()) return;
    startPendingField(lt, (intptr_t)colon + 1, (intptr_t)lenE);
    showList(h, ListKind::Values, gtPos + 1, values, '\n');
}

static void onCharAdded(int ch) {
    if (!g.autocomplete || !isAdifBuffer(currentBuffer())) return;
    NppHandle h = currentScintilla();
    intptr_t caret = sci(h, SCI_GETCURRENTPOS);
    if (ch == '<') {
        endList();
        intptr_t lt = caret - 1;
        dispatch_async(dispatch_get_main_queue(), ^{
            try {
                bool hadPending = g.pending.active;
                intptr_t before = sci(currentScintilla(), SCI_GETCURRENTPOS);
                finishPendingField(lt);
                // Fixing the length may have shifted the '<'.
                intptr_t shift = sci(currentScintilla(), SCI_GETCURRENTPOS) - before;
                openNameList(lt + (hadPending ? shift : 0));
            } catch (...) {
            }
        });
        return;
    }
    if (ch == '\r' || ch == '\n') {
        endList();
        intptr_t lineBreak = caret - 1;
        if (ch == '\n' && lineBreak > 0) {
            std::string_view text = docText(h);
            if ((size_t)lineBreak - 1 < text.size() && text[(size_t)lineBreak - 1] == '\r') --lineBreak;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            try {
                finishPendingField(lineBreak);
            } catch (...) {
            }
        });
        return;
    }
    if (ch == '>' && g.list.kind == ListKind::None) {
        intptr_t gtPos = caret - 1;
        dispatch_async(dispatch_get_main_queue(), ^{
            try {
                maybeOpenValueList(gtPos);
            } catch (...) {
            }
        });
        return;
    }
    if (g.list.kind == ListKind::Names && isNameChar(ch)) {
        dispatch_async(dispatch_get_main_queue(), ^{ reshowList(); });
    } else if (g.list.kind == ListKind::Values && ch >= 32 && ch != '<' && ch != '>') {
        dispatch_async(dispatch_get_main_queue(), ^{ reshowList(); });
    } else if (g.list.kind != ListKind::None) {
        endList();
    }
}

static void onListSelection(const char *text, intptr_t position) {
    if (g.list.kind == ListKind::None || position != g.list.start || !text) return;  // not our list
    ListKind kind = g.list.kind;
    std::string chosen = text;
    NppHandle h = currentScintilla();
    sci(h, SCI_AUTOCCANCEL);  // stops Scintilla inserting the choice itself
    endList();
    dispatch_async(dispatch_get_main_queue(), ^{
        try {
            if (kind == ListKind::Names) insertChosenName(position, chosen);
            else insertChosenValue(position, chosen);
        } catch (...) {
        }
    });
}

// A cancel can come from the user (Escape, caret moved) or from the host's
// word completion reacting to a keystroke; in the second case reshowList()
// runs first and clears cancelPending.
static void onListCancelled() {
    if (g.list.kind == ListKind::None) return;
    g.list.cancelPending = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g.list.cancelPending) endList();
    });
}

// The caret moved: a pending field is finished once the caret leaves its data.
static void checkPendingLeft() {
    if (!g.pending.active) return;
    NppHandle h = currentScintilla();
    intptr_t caret = sci(h, SCI_GETCURRENTPOS);
    if (g.pending.buffer != currentBuffer()) {
        g.pending.active = false;
        return;
    }
    std::string_view text = docText(h);
    size_t end = (size_t)g.pending.valueB;
    while (end < text.size() && text[end] != '<' && text[end] != '\r' && text[end] != '\n') ++end;
    if (caret < g.pending.valueB || caret > (intptr_t)end) {
        dispatch_async(dispatch_get_main_queue(), ^{
            try {
                finishPendingField(-1);
            } catch (...) {
            }
        });
    }
}

// ── Record panel ────────────────────────────────────────────────────────────

static bool panelVisible() {
    if (!g.panel) return false;
    if (g.panelWindow) return g.panelWindow.visible;
    return g.panel.view.window != nil;
}

// The whole log in a line: its problems, the QSOs waiting for each upload service it
// uses, and today's POTA activation. Rebuilt only when the document changes.
static void logHealth(NppHandle h, const adif::LintResult &r, std::string *line, int *severity) {
    intptr_t length = sci(h, SCI_GETLENGTH);
    if (g.healthBuffer == currentBuffer() && g.healthEdit == g.editCount && g.healthLength == length) {
        *line = g.health;
        *severity = g.healthSeverity;
        return;
    }
    using adifhost::plural;
    std::string out;
    if (r.errors || r.warnings) out = plural(r.errors, "error") + ", " + plural(r.warnings, "warning");
    else out = r.infos ? plural(r.infos, "note") : std::string("No problems");
    int sev = r.errors ? 2 : r.warnings ? 1 : -1;
    std::string_view text = docText(h);
    if (r.structuralErrors == 0 && r.records) {
        // Uploads: only the services this log has been sent to.
        std::string waiting;
        for (adif::UploadService s : {adif::UploadService::QRZ, adif::UploadService::LoTW, adif::UploadService::ClubLog,
                                      adif::UploadService::EQSL}) {
            std::vector<adif::UploadItem> items = adif::uploadItems(text, r.model, s);
            // Used: something was sent (Y, or M after an edit). A downloaded log often says N
            // for services you never use (QRZ.com writes EQSL_QSL_SENT N).
            bool used = std::any_of(items.begin(), items.end(), [](const adif::UploadItem &i) {
                return adif::equalsNoCase(i.status, "Y") || adif::equalsNoCase(i.status, "M");
            });
            size_t n = (size_t)std::count_if(items.begin(), items.end(), [](const adif::UploadItem &i) { return adif::uploadWanted(i); });
            if (used && n) waiting += (waiting.empty() ? "" : ", ") + std::string(s == adif::UploadService::QRZ ? "QRZ" : adif::uploadServiceName(s)) + " " + std::to_string(n);
        }
        if (!waiting.empty()) out += "  ·  to upload: " + waiting;
        // Today's activation.
        std::string today = utcNow("%Y%m%d");
        for (const adif::Activation &a : adif::activations(text, r.model, adifhost::setting("stationCall"))) {
            if (a.date != today) continue;
            out += "  ·  " + a.park + " today: " + std::to_string(a.qsos) + (a.activated() ? " QSOs, activated" : " of " + std::to_string(a.needed));
            break;
        }
    }
    g.healthBuffer = currentBuffer();
    g.healthEdit = g.editCount;
    g.healthLength = length;
    g.health = out;
    g.healthSeverity = sev;
    *line = out;
    *severity = sev;
}

static ADIFPanelSnapshot buildSnapshot(NppHandle h) {
    ADIFPanelSnapshot s;
    g.panelGroupStart = -1;
    g.panelNames.clear();
    if (!isAdifBuffer(currentBuffer())) {
        s.title = "Not an ADIF document (.adi). Use Check Log to treat it as one.";
        return s;
    }
    const adif::LintResult &r = freshLint(h);
    const adif::DocModel &m = r.model;
    std::string_view text = docText(h);
    logHealth(h, r, &s.health, &s.healthSeverity);
    intptr_t caret = sci(h, SCI_GETCURRENTPOS);
    int gi = adif::groupAt(m, (size_t)caret);
    if (gi < 0 && !m.groups.empty()) gi = 0;
    if (gi < 0) {
        s.title = "No fields yet. Type '<' to add one.";
        return s;
    }
    const adif::ModelGroup &grp = m.groups[(size_t)gi];
    size_t start = adif::groupStart(m, grp);
    intptr_t line = sci(h, SCI_LINEFROMPOSITION, start) + 1;
    s.hasGroup = true;
    s.title = grp.header ? "Header" : "Record " + std::to_string(adif::recordNumber(m, gi)) + " of " +
                                          std::to_string(adif::recordCount(m));
    s.title += "  ·  line " + std::to_string(line);
    s.canPrevious = gi > 0;
    s.canNext = (size_t)gi + 1 < m.groups.size();
    g.panelGroupStart = (intptr_t)start;

    auto worst = [](int a, adif::Severity s) { return std::max(a, (int)s); };
    for (size_t i = 0; i < grp.fieldCount; ++i) {
        const adif::ModelField &f = m.fields[grp.firstField + i];
        ADIFPanelRow row;
        row.name = std::string(adif::fieldName(text, f));
        row.value = std::string(adif::fieldValue(text, f));
        row.choices = adif::valueChoices(text, m, &grp, row.name);
        if (!row.choices.empty() && std::find(row.choices.begin(), row.choices.end(), row.value) == row.choices.end() &&
            !row.value.empty())
            row.choices.insert(row.choices.begin(), row.value);
        std::string problems;
        for (const adif::Diagnostic &d : r.diagnostics) {
            if (d.start >= f.valueE || d.end <= f.tagB) continue;
            if (row.severity < (int)d.severity) {
                row.severity = worst(row.severity, d.severity);
                row.note = d.message;
            }
            problems += severityLabel(d.severity) + d.message + "\n";
            if (!d.fixes.empty()) row.repair += (row.repair.empty() ? "" : "; ") + d.fixLabel;
        }
        row.tooltip = problems + adif::describeField(m, row.name);
        if ((intptr_t)f.tagB <= caret && caret <= (intptr_t)f.valueE) s.selectedRow = (int)i;
        g.panelNames.push_back(row.name);
        s.rows.push_back(std::move(row));
    }
    // Problems on the record as a whole sit on its <EOR>/<EOH>.
    if (grp.markerB != adif::kNoPos) {
        for (const adif::Diagnostic &d : r.diagnostics) {
            if (d.start >= grp.markerE || d.end <= grp.markerB) continue;
            if (!s.footer.empty()) s.footer += "\n";
            s.footer += d.message;
            s.footerSeverity = std::max(s.footerSeverity, (int)d.severity);
            if (!d.fixes.empty()) s.footerRepair += (s.footerRepair.empty() ? "" : "; ") + d.fixLabel;
        }
    }
    for (const std::string &n : adif::fieldNameChoices(m, grp.header))
        if (n != "EOR" && n != "EOH") s.addableNames.push_back(n);
    return s;
}

static void refreshPanel() {
    if (!g.ready || !panelVisible()) return;
    try {
        [g.panel update:buildSnapshot(currentScintilla())];
    } catch (...) {
    }
}

static void schedulePanelRefresh() {
    if (!panelVisible()) return;
    int64_t mine = ++g.panelToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine == g.panelToken) refreshPanel();
    });
}

// The group the panel shows, re-found in a fresh lint; nullptr if the document
// changed so that the panel's rows no longer match.
static const adif::ModelGroup *panelGroup(NppHandle h, const adif::LintResult &r) {
    if (g.panelGroupStart < 0) return nullptr;
    int gi = adif::groupAt(r.model, (size_t)g.panelGroupStart);
    if (gi < 0) return nullptr;
    const adif::ModelGroup &grp = r.model.groups[(size_t)gi];
    if ((intptr_t)adif::groupStart(r.model, grp) != g.panelGroupStart || grp.fieldCount != g.panelNames.size()) return nullptr;
    std::string_view text = docText(h);
    for (size_t i = 0; i < grp.fieldCount; ++i)
        if (adif::fieldName(text, r.model.fields[grp.firstField + i]) != g.panelNames[i]) return nullptr;
    return &grp;
}

static void panelEdit(void (^make)(NppHandle h, const adif::LintResult &r, const adif::ModelGroup &grp,
                                   std::vector<adif::TextEdit> &edits)) {
    // Deferred: never change the table from inside its own delegate callback.
    dispatch_async(dispatch_get_main_queue(), ^{
        try {
            NppHandle h = currentScintilla();
            if (sci(h, SCI_GETREADONLY)) {
                NSBeep();
                return;
            }
            const adif::LintResult &r = lintNow(h);
            const adif::ModelGroup *grp = panelGroup(h, r);
            if (!grp) {
                NSBeep();
                refreshPanel();
                return;
            }
            std::vector<adif::TextEdit> edits;
            make(h, r, *grp, edits);
            std::string_view text = docText(h);
            edits.erase(std::remove_if(edits.begin(), edits.end(),
                                       [&](const adif::TextEdit &e) { return text.substr(e.start, e.end - e.start) == e.text; }),
                        edits.end());
            if (!edits.empty()) applyEdits(h, edits, true);
            validateNow(h, g.autoValidate);
        } catch (...) {
        }
    });
}

static void createPanel() {
    if (g.panel) return;
    g.panel = [[ADIFRecordPanel alloc] init];
    g.panel.onEditValue = ^(NSInteger row, NSString *value) {
        std::string v = [ADIFRecordPanel valueFromDisplay:value];
        panelEdit(^(NppHandle h, const adif::LintResult &r, const adif::ModelGroup &grp, std::vector<adif::TextEdit> &edits) {
            if (row < 0 || (size_t)row >= grp.fieldCount) return;
            edits.push_back(adif::setFieldValue(docText(h), r.model.fields[grp.firstField + (size_t)row], v, lengthUnit(),
                                                docUtf8(h)));
        });
    };
    g.panel.onAddField = ^(NSString *name, NSString *value) {
        std::string n = name.UTF8String ?: "", v = [ADIFRecordPanel valueFromDisplay:value];
        panelEdit(^(NppHandle h, const adif::LintResult &r, const adif::ModelGroup &grp, std::vector<adif::TextEdit> &edits) {
            edits.push_back(adif::insertField(docText(h), r.model, grp, n, v, lengthUnit(), docUtf8(h)));
        });
    };
    g.panel.onRemoveField = ^(NSInteger row) {
        panelEdit(^(NppHandle h, const adif::LintResult &r, const adif::ModelGroup &grp, std::vector<adif::TextEdit> &edits) {
            if (row < 0 || (size_t)row >= grp.fieldCount) return;
            edits.push_back(adif::removeField(docText(h), r.model, grp, (size_t)row));
        });
    };
    g.panel.onRepairRow = ^(NSInteger row) {
        panelEdit(^(NppHandle h, const adif::LintResult &r, const adif::ModelGroup &grp, std::vector<adif::TextEdit> &edits) {
            // The repairs of the problems on that field (row -1: on the record's <EOR>).
            size_t b, e;
            if (row >= 0 && (size_t)row < grp.fieldCount) {
                const adif::ModelField &f = r.model.fields[grp.firstField + (size_t)row];
                b = f.tagB, e = f.valueE;
            } else if (row < 0 && grp.markerB != adif::kNoPos) {
                b = grp.markerB, e = grp.markerE;
            } else {
                return;
            }
            std::vector<adif::Diagnostic> mine;
            for (const adif::Diagnostic &d : r.diagnostics)
                if (!d.fixes.empty() && d.start < e && d.end > b) mine.push_back(d);
            edits = adif::quickFixEdits(docText(h), r.model, mine, lengthUnit(), docUtf8(h));
        });
    };
    g.panel.onGoToRecord = ^(NSInteger delta) {
        try {
            NppHandle h = currentScintilla();
            const adif::LintResult &r = freshLint(h);
            int gi = adif::groupAt(r.model, (size_t)std::max<intptr_t>(0, g.panelGroupStart));
            int target = gi + (int)delta;
            if (target < 0 || (size_t)target >= r.model.groups.size()) return;
            sci(h, SCI_GOTOPOS, adif::groupStart(r.model, r.model.groups[(size_t)target]));
            sci(h, SCI_SCROLLCARET);
            refreshPanel();
        } catch (...) {
        }
    };
    g.panel.onRevealRow = ^(NSInteger row) {
        try {
            NppHandle h = currentScintilla();
            const adif::LintResult &r = freshLint(h);
            const adif::ModelGroup *grp = panelGroup(h, r);
            if (!grp || row < 0 || (size_t)row >= grp->fieldCount) return;
            const adif::ModelField &f = r.model.fields[grp->firstField + (size_t)row];
            sci(h, SCI_SETSEL, f.gt + 1, (intptr_t)f.valueE);
            sci(h, SCI_SCROLLCARET);
        } catch (...) {
        }
    };
    g.panel.valuesForField = ^NSArray<NSString *> *(NSString *name) {
        NSMutableArray *out = [NSMutableArray array];
        try {
            NppHandle h = currentScintilla();
            const adif::LintResult &r = freshLint(h);
            const adif::ModelGroup *grp = panelGroup(h, r);
            for (const std::string &v : adif::valueChoices(docText(h), r.model, grp, name.UTF8String ?: ""))
                [out addObject:@(v.c_str())];
        } catch (...) {
        }
        return out;
    };
    g.panel.onSortChanged = ^(NSString *column, BOOL ascending) {
        adifhost::setSetting("panelSort", std::string(column.UTF8String ?: "pos") + (ascending ? ":a" : ":d"));
    };
    {
        std::string sort = adifhost::setting("panelSort");  // "field:a"; empty: the record's own order
        size_t colon = sort.find(':');
        if (colon != std::string::npos)
            [g.panel setSortColumn:@(sort.substr(0, colon).c_str()) ascending:sort.substr(colon + 1) != "d"];
    }
    g.panelHandle = (uint64_t)app(NPPM_DMM_REGISTERPANEL, (uintptr_t)(__bridge void *)g.panel.view, (intptr_t)"ADIF Record");
    if (!g.panelHandle) {
        // Older host: a floating utility window instead of a docked panel.
        g.panelWindow = [[NSPanel alloc] initWithContentRect:NSMakeRect(200, 200, 360, 440)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
        g.panelWindow.title = @"ADIF Record";
        g.panelWindow.floatingPanel = YES;
        g.panelWindow.hidesOnDeactivate = YES;
        g.panelWindow.releasedWhenClosed = NO;
        g.panelWindow.contentView = g.panel.view;
    }
}

static void showPanel(bool show) {
    if (show) {
        createPanel();
        if (g.panelHandle) app(NPPM_DMM_SHOWPANEL, (uintptr_t)g.panelHandle);
        else [g.panelWindow orderFront:nil];
        refreshPanel();
    } else if (g.panel) {
        if (g.panelHandle) app(NPPM_DMM_HIDEPANEL, (uintptr_t)g.panelHandle);
        else [g.panelWindow orderOut:nil];
    }
}

static void cmdRecordPanel() {
    bool show = !panelVisible();  // the panel may have been closed from its own close button
    g.panelWanted = show;
    showPanel(show);
    setCheck(kCmdRecordPanel, show);
    saveSettings();
}

// ── New QSO ─────────────────────────────────────────────────────────────────

static std::string utcNow(const char *format) {
    std::time_t now = std::time(nullptr);
    std::tm utc{};
    gmtime_r(&now, &utc);
    char buf[32];
    std::strftime(buf, sizeof buf, format, &utc);
    return buf;
}

static std::string documentName() {
    std::string path = currentPath();
    size_t slash = path.find_last_of('/');
    return path.empty() ? "an untitled document" : path.substr(slash == std::string::npos ? 0 : slash + 1);
}

static bool isBlank(std::string_view text) {
    for (char c : text)
        if (c != ' ' && c != '\t' && c != '\r' && c != '\n') return false;
    return true;
}

static bool qsoVisible() { return g.qso && g.qso.window.visible; }

static bool isArrlSection(const std::string &v) {
    const adif::EnumDef *e = adif::findEnum("ARRL_Section");
    std::string t = v;
    while (!t.empty() && t.back() == ' ') t.pop_back();
    while (!t.empty() && t.front() == ' ') t.erase(t.begin());
    return e && !t.empty() && adif::findEnumValue(*e, t);
}

struct QsoCheck {
    bool ok = true;
    std::vector<std::pair<int, std::string>> rows;  // per row: severity, message
    std::string summary;
    int severity = -1;
    std::vector<std::pair<std::string, std::string>> fields;  // the values to log
};

// Check the window's values the way the validator would see them in this log,
// and look for the same contact already logged.
static QsoCheck checkQso(NppHandle h) {
    QsoCheck c;
    // Follow FREQ with BAND, and MODE with SUBMODE choices and default reports.
    std::string freq = [g.qso valueForField:"FREQ"], band = [g.qso valueForField:"BAND"];
    std::string fromFreq = adif::bandForFrequency(freq);
    if (!fromFreq.empty() && !adif::equalsNoCase(band, fromFreq)) [g.qso setValue:fromFreq forField:"BAND"];
    std::string mode = [g.qso valueForField:"MODE"];
    const adif::LintResult &doc = freshLint(h);
    if (!adif::equalsNoCase(mode, g.qsoMode)) {
        auto lookup = [&](std::string_view k) { return k == "MODE" ? mode : std::string(); };
        [g.qso setChoices:adif::valueChoicesWith(doc.model, "SUBMODE", lookup) forField:"SUBMODE"];
        for (const char *rst : {"RST_SENT", "RST_RCVD"})
            if ([g.qso valueForField:rst] == adif::defaultReport(g.qsoMode))
                [g.qso setValue:adif::defaultReport(mode) forField:rst];
        g.qsoMode = mode;
    }

    c.fields = [g.qso values];
    for (auto &f : c.fields) {
        if (f.first == "CALL" || f.first == "CLASS" || f.first == "ARRL_SECT")
            for (char &ch : f.second) ch = (char)std::toupper((unsigned char)ch);
        while (!f.second.empty() && (f.second.back() == ' ' || f.second.back() == '\t')) f.second.pop_back();
        while (!f.second.empty() && (f.second.front() == ' ' || f.second.front() == '\t')) f.second.erase(0, 1);
    }
    c.rows.assign(c.fields.size(), {-1, std::string()});
    auto get = [&](const char *name) {
        for (const auto &f : c.fields)
            if (f.first == name) return f.second;
        return std::string();
    };
    auto mark = [&](const char *name, int severity, const std::string &message) {
        for (size_t i = 0; i < c.fields.size(); ++i)
            if (c.fields[i].first == name && c.rows[i].first < severity) c.rows[i] = {severity, message};
    };
    for (const char *req : {"CALL", "QSO_DATE", "TIME_ON", "MODE"})
        if (get(req).empty()) mark(req, 2, "Required");
    if (get("BAND").empty() && get("FREQ").empty()) {
        mark("BAND", 2, "BAND or FREQ is required");
        mark("FREQ", 2, "BAND or FREQ is required");
    }

    // Lint the record after this log's header, so USERDEF fields are known.
    std::string_view text = docText(h);
    std::string header;
    if (!doc.model.groups.empty() && doc.model.groups.front().header && doc.model.groups.front().markerE != adif::kNoPos)
        header = std::string(text.substr(0, doc.model.groups.front().markerE)) + "\n";
    adif::ContestSetup contestNow = contest::setup();
    bool fieldDay = contestNow.preset == adif::ContestPreset::FieldDay || contestNow.preset == adif::ContestPreset::WinterFieldDay;
    adif::FieldList lintFields = c.fields;
    if (fieldDay)  // DX or MX: the exchange's word, not an ARRL section; it goes into SRX_STRING
        for (auto &f : lintFields)
            if (f.first == "ARRL_SECT" && !isArrlSection(f.second)) f.second.clear();
    adif::BuiltRecord br = adif::buildRecord(lintFields, adif::Layout::RecordPerLine, "\n", lengthUnit(), docUtf8(h));
    adif::LintOptions opt;
    opt.lengthUnit = lengthUnit();
    opt.utf8 = docUtf8(h);
    opt.today = adifhost::utcNow("%Y%m%d");
    adif::LintResult r = adif::lint(header + br.text, opt);
    std::vector<std::string> recordProblems;
    for (const adif::Diagnostic &d : r.diagnostics) {
        if (d.start < header.size()) continue;
        size_t at = d.start - header.size();
        bool placed = false;
        for (size_t i = 0; i < br.ranges.size(); ++i) {
            if (br.ranges[i].first == adif::kNoPos || at < br.ranges[i].first || at >= br.ranges[i].second) continue;
            if (c.rows[i].first < (int)d.severity) c.rows[i] = {(int)d.severity, d.message};
            placed = true;
            break;
        }
        if (!placed && d.code != "minimum-fields") recordProblems.push_back(d.message);
    }

    std::string call = get("CALL");
    if (fieldDay) {
        std::string pc = adif::classProblem(contestNow.preset, get("CLASS")), ps = adif::sectionProblem(contestNow.preset, get("ARRL_SECT"));
        if (!pc.empty()) mark("CLASS", 1, pc);
        if (!ps.empty()) mark("ARRL_SECT", 1, ps);
    }
    if (contestNow.preset != adif::ContestPreset::None && !call.empty()) {
        adif::Record qso;
        qso.fields = c.fields;
        std::vector<int> dup = adif::contestDupes(text, doc.model, adif::contestIdFor(contestNow), qso);
        std::string cat = adif::modeCategory(get("MODE"));
        if (!dup.empty()) {
            c.summary = call + " is already in the contest on " + adif::effectiveBand(qso) + " " +
                        (cat == "CW" ? "CW" : cat == "PH" ? "Phone" : "Digital") + " (record " + std::to_string(dup.back()) +
                        "): a station counts once per band and mode.";
            c.severity = 1;
        }
        std::string rule = adif::contestRuleProblem(contestNow.preset, qso);
        if (!rule.empty()) {
            c.summary += (c.summary.empty() ? "" : "\n") + rule;
            c.severity = std::max(c.severity, 1);
        }
    } else if (!call.empty()) {
        adif::Record qso;
        qso.fields = c.fields;
        std::vector<int> same = adif::sameContactAs(text, doc.model, qso);
        if (!same.empty()) {
            c.summary = call + " is already in this log on " + get("BAND") + " " + get("MODE") + " this UTC day (record " +
                        std::to_string(same.back()) + ").";
            c.severity = 1;
        } else if (size_t n = adif::timesWorkedAs(text, doc.model, call)) {
            c.summary = call + " is in this log " + std::to_string(n) + (n == 1 ? " time" : " times") + " on other bands, modes or days.";
            c.severity = 0;
        }
    }
    if (!call.empty()) {
        std::string before = logtools::workedBefore(call);
        if (!before.empty()) {
            c.summary += (c.summary.empty() ? "" : "\n") + before;
            c.severity = std::max(c.severity, 0);
        }
    }
    for (const std::string &p : recordProblems) {
        c.summary += (c.summary.empty() ? "" : "\n") + p;
        c.severity = std::max(c.severity, 1);
    }
    for (const auto &row : c.rows)
        if (row.first == 2) c.ok = false;
    return c;
}

static void showQsoCheck(const QsoCheck &c) {
    [g.qso setRowStatus:c.rows];
    [g.qso setSummary:c.summary severity:c.severity];
}

static void scheduleQsoCheck() {
    int64_t mine = ++g.qsoToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine != g.qsoToken || !qsoVisible()) return;
        try {
            showQsoCheck(checkQso(currentScintilla()));
        } catch (...) {
        }
    });
}

static void logQso() {
    ++g.qsoToken;  // a check scheduled before the click must not overwrite this result
    try {
        NppHandle h = currentScintilla();
        if (sci(h, SCI_GETREADONLY)) {
            [g.qso setSummary:"This document is read-only." severity:2];
            NSBeep();
            return;
        }
        QsoCheck c = checkQso(h);
        showQsoCheck(c);
        if (!c.ok) {
            [g.qso setSummary:"Fix the fields marked in red, then log." severity:2];
            NSBeep();
            return;
        }
        std::string_view text = docText(h);
        bool blank = isBlank(text);
        adif::LintResult r = lintNow(h);  // a copy: the edit below changes the document
        if (!blank && r.model.fields.empty() && r.model.groups.empty()) {
            [g.qso setSummary:"This document is not an ADIF log. Open an .adi file, or start a new empty document." severity:2];
            NSBeep();
            return;
        }
        if (!r.model.groups.empty() && !r.model.groups.back().header && r.model.groups.back().markerB == adif::kNoPos) {
            [g.qso setSummary:"The log's last record has no <EOR>, so a new record would run into it. Add <EOR> first."
                     severity:2];
            NSBeep();
            return;
        }
        // Station details the window does not show, copied from the log's last record.
        std::vector<std::string> shown;
        for (const auto &f : c.fields) shown.push_back(f.first);
        adif::FieldList hidden;
        if (g.qsoCarryHidden) hidden = adif::hiddenStationFields(text, r.model, shown);
        // The station profile and activation win over the last record, for the fields not shown.
        for (const auto &f : station::stationFields())
            if (std::find(shown.begin(), shown.end(), f.first) == shown.end()) hidden = adif::overlay(hidden, {f});
        for (auto &f : hidden) c.fields.push_back(std::move(f));
        // A running contest's fields: CONTEST_ID, the exchanges, the serial number (for the fields not shown).
        adif::ContestSetup contestNow = contest::setup();
        if (contestNow.preset != adif::ContestPreset::None) {
            int serial = contestNow.preset == adif::ContestPreset::Serial ? adif::nextSerial(text, r.model, adif::contestIdFor(contestNow)) : 0;
            adif::FieldList extra = adif::contestFields(contestNow, [g.qso values], serial);
            c.fields.erase(std::remove_if(c.fields.begin(), c.fields.end(),
                                          [](const auto &f) { return f.first == "ARRL_SECT" && !isArrlSection(f.second); }),
                           c.fields.end());
            c.fields = adif::overlay(c.fields, extra);  // the contest's own values win over carried ones
        }
        std::string eol = eolString(h);
        adif::BuiltRecord br = adif::buildRecord(c.fields, adif::recordLayout(text, r.model), eol, lengthUnit(), docUtf8(h));
        adif::TextEdit edit;
        size_t start = 0;
        if (blank) {
            std::string headerText = adif::newLogHeader(ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"), eol);
            edit = {0, text.size(), headerText + br.text};
            start = headerText.size();
        } else {
            edit = adif::appendRecord(text, r.model, br.text, eol, &start);
        }
        applyEdits(h, {edit});
        g.manualBuffers.insert(currentBuffer());
        const adif::LintResult &after = validateNow(h, g.autoValidate);
        sci(h, SCI_GOTOPOS, start);
        sci(h, SCI_SCROLLCARET);

        std::string call, mode;
        for (const auto &f : c.fields) {
            if (f.first == "CALL") call = f.second;
            if (f.first == "MODE") mode = f.second;
        }
        std::string done = "Logged " + call + " as record " + std::to_string(adif::recordCount(after.model)) + ".";
        if (c.severity == 1) done += " " + c.summary;
        // Ready for the next contact: carried fields keep their values.
        for (const adif::QsoField &q : g.qsoFields) {
            if (q.carry || q.name == "QSO_DATE" || q.name == "TIME_ON") continue;
            [g.qso setValue:(q.name == "RST_SENT" || q.name == "RST_RCVD") ? adif::defaultReport(mode) : std::string()
                   forField:q.name];
        }
        if (g.qso.useCurrentTime) [g.qso refreshTime];
        [g.qso setRowStatus:std::vector<std::pair<int, std::string>>(g.qsoFields.size(), {-1, std::string()})];
        [g.qso setSummary:done severity:c.severity == 1 ? 1 : -1];
        refreshQsoTarget();
        [g.qso focusField:"CALL"];
    } catch (...) {
    }
}

static void openQsoFields();
static void showQsoRows(NppHandle h, const adif::LintResult &r);
static void runLookup();
static void scheduleLookup();

// (Re)build the New QSO rows from the field list (or the log's own fields).
// With keepValues, what the user has typed into fields that remain is kept.
static void loadQsoRows(NppHandle h, const adif::LintResult &r, bool keepValues, bool keepStation) {
    std::string_view text = docText(h);
    std::map<std::string, std::string> typed;
    if (keepValues && g.qso)
        for (const auto &v : [g.qso values])
            if (!v.second.empty() && (keepStation || !adif::isStationField(v.first))) typed[v.first] = v.second;
    g.qsoFields = g.qsoFieldList.empty()
                      ? adif::newQsoTemplate(text, r.model, utcNow("%Y%m%d"), utcNow("%H%M%S"))
                      : adif::newQsoTemplateFor(text, r.model, utcNow("%Y%m%d"), utcNow("%H%M%S"), g.qsoFieldList);
    for (adif::QsoField &q : g.qsoFields) {
        auto it = typed.find(q.name);
        if (it != typed.end() && q.name != "QSO_DATE" && q.name != "TIME_ON") q.value = it->second;
    }
    // A log that doesn't name your station yet: the callsign and grid from Settings (Your Station).
    std::vector<std::pair<std::string, std::string>> carried = adif::hiddenStationFields(text, r.model, {});
    for (const auto &mine : {std::pair<std::string, std::string>{"STATION_CALLSIGN", adifhost::setting("stationCall")},
                             std::pair<std::string, std::string>{"MY_GRIDSQUARE", adifhost::setting("stationGrid")}}) {
        const std::string &name = mine.first, &value = mine.second;
        if (value.empty() || std::any_of(carried.begin(), carried.end(), [&](const auto &c) { return c.first == name; })) continue;
        auto row = std::find_if(g.qsoFields.begin(), g.qsoFields.end(), [&](const adif::QsoField &q) { return q.name == name; });
        if (row != g.qsoFields.end()) {
            if (row->value.empty()) row->value = value;
        } else if (g.qsoFieldList.empty()) {
            g.qsoFields.push_back(adif::QsoField{name, value, true});
        }
    }
    // The chosen station profile and the running activation fill their rows (the others are
    // written at logging, see logQso).
    for (const auto &f : station::stationFields())
        for (adif::QsoField &q : g.qsoFields)
            if (q.name == f.first) q.value = f.second;
    // A running contest fills its rows; a contest just stopped leaves them empty, not carried.
    adif::ContestSetup cs = contest::setup();
    adif::FieldList contestValues = adif::contestFields(cs, {}, 0);
    bool stopped = adifhost::setting("contestStopped") == "1";
    if (stopped) adifhost::setSetting("contestStopped", "");
    for (adif::QsoField &q : g.qsoFields) {
        for (const auto &f : contestValues)
            if (q.name == f.first) q.value = f.second;
        if (stopped && (q.name == "CONTEST_ID" || q.name == "STX_STRING" || q.name == "SRX_STRING" || q.name == "STX" || q.name == "SRX" ||
                        q.name == "CLASS" || q.name == "ARRL_SECT"))
            q.value.clear();
    }
    // A running contest asks for the other station's exchange.
    for (const std::string &name : adif::contestRows(cs.preset))
        if (std::none_of(g.qsoFields.begin(), g.qsoFields.end(), [&](const adif::QsoField &q) { return q.name == name; })) {
            auto it = typed.find(name);
            g.qsoFields.push_back(adif::QsoField{name, keepValues && it != typed.end() ? it->second : std::string(), false});
        }
    showQsoRows(h, r);
}

// Give the New QSO window one row per g.qsoFields entry.
static void showQsoRows(NppHandle h, const adif::LintResult &r) {
    std::string_view text = docText(h);
    std::string mode;
    for (const adif::QsoField &q : g.qsoFields)
        if (q.name == "MODE") mode = q.value;
    auto lookup = [&](std::string_view k) { return k == "MODE" ? mode : std::string(); };
    int timeDigits = 6;
    std::vector<ADIFQsoRow> rows;
    std::vector<std::string> shown;
    for (const adif::QsoField &q : g.qsoFields) {
        ADIFQsoRow row;
        row.name = q.name;
        row.value = q.value;
        row.description = adif::describeField(r.model, q.name);
        row.choices = adif::valueChoicesWith(r.model, q.name, lookup);
        row.required = adif::isRequiredQsoField(q.name);
        if (q.name == "TIME_ON") timeDigits = q.value.size() == 4 ? 4 : 6;
        shown.push_back(q.name);
        rows.push_back(std::move(row));
    }
    if (!g.qso) {
        g.qso = [[ADIFNewQsoPanel alloc] init];
        g.qso.onChange = ^{
            scheduleQsoCheck();
            scheduleLookup();
        };
        g.qso.onLookupChanged = ^(NSInteger source) {
            static const char *const kNames[] = {"off", "country", "qrz", "hamqth"};
            adifhost::setSetting("qsoLookup", kNames[std::clamp<NSInteger>(source, 0, 3)]);
            g.lookup.call.clear();  // look the current call up again
            runLookup();
        };
        {
            std::string s = adifhost::setting("qsoLookup");
            g.qso.lookupSource = s == "off" ? 0 : s == "qrz" ? 2 : s == "hamqth" ? 3 : 1;  // country data by default
        }
        g.qso.onLog = ^{ logQso(); };
        g.qso.onStationChosen = ^(NSInteger index) {
            if (index >= 0) {
                station::chooseProfile(index);
                return;
            }
            station::cmdStationProfiles();  // "Edit Profiles...": the popup goes back to the profile in use
            NSMutableArray *names = [NSMutableArray array];
            for (const adif::StationProfile &p : station::profiles()) [names addObject:@(p.name.c_str())];
            [g.qso setStations:names selected:station::chosenProfile()];
        };
        g.qso.onCustomize = ^{ openQsoFields(); };
        g.qso.onSpots = ^{ logtools::cmdPotaSpots(); };
        g.qso.onContest = ^{ contest::cmdContest(); };
    }
    g.qso.timeDigits = timeDigits;
    g.qsoMode = mode;
    [g.qso setRows:rows];
    // Say which station details will be written without being shown.
    std::string note, fromStation;
    adif::FieldList mine = station::stationFields();
    for (const auto &f : mine)
        if (std::find(shown.begin(), shown.end(), f.first) == shown.end())
            fromStation += (fromStation.empty() ? "" : ", ") + f.first + " " + f.second;
    if (g.qsoCarryHidden)
        for (const auto &f : adif::hiddenStationFields(text, r.model, shown))
            if (std::none_of(mine.begin(), mine.end(), [&](const auto &m) { return m.first == f.first; }))
                note += (note.empty() ? "Also written, from the last record: " : ", ") + f.first + " " + f.second;
    if (!fromStation.empty())
        note = "Also written, from the " + station::stationLabel() + ": " + fromStation + (note.empty() ? "" : ". " + note);
    [g.qso setNote:@(note.c_str())];
    std::vector<adif::StationProfile> profiles = station::profiles();
    NSMutableArray *names = [NSMutableArray array];
    for (const adif::StationProfile &p : profiles) [names addObject:@(p.name.c_str())];
    [g.qso setStations:names selected:station::chosenProfile()];
}

static void openQsoFields() {
    try {
        NppHandle h = currentScintilla();
        const adif::LintResult &r = freshLint(h);
        if (!g.qsoFieldsPanel) {
            g.qsoFieldsPanel = [[ADIFQsoFieldsPanel alloc] init];
            g.qsoFieldsPanel.onSave = ^(const std::vector<std::string> &fields, BOOL automatic, BOOL carryHidden) {
                g.qsoFieldList = automatic ? std::vector<std::string>() : fields;
                g.qsoCarryHidden = carryHidden;
                saveSettings();
                try {
                    NppHandle hh = currentScintilla();
                    loadQsoRows(hh, freshLint(hh), true);
                    scheduleQsoCheck();
                } catch (...) {
                }
            };
        }
        std::vector<std::string> current;
        for (const adif::QsoField &q : g.qsoFields) current.push_back(q.name);
        std::vector<ADIFFieldChoice> choices;
        std::set<std::string> listed;
        auto addChoice = [&](const std::string &n) {
            if (n == "EOR" || !listed.insert(n).second) return;
            adif::FieldInfo fi = adif::fieldInfo(r.model, n);
            choices.push_back({fi.name, fi.type, fi.brief, fi.details, fi.hasValues});
        };
        for (const std::string &n : adif::fieldNameChoices(r.model, false)) addChoice(n);
        for (const std::string &n : current) addChoice(n);  // e.g. a field already in the list
        [g.qsoFieldsPanel showFields:current carryHidden:g.qsoCarryHidden choices:choices];
    } catch (...) {
    }
}

static bool qsoHasField(const char *name) {
    for (const adif::QsoField &q : g.qsoFields)
        if (q.name == name) return true;
    return false;
}

// ── New QSO: call lookup, distance, hunting history ─────────────────────────

static std::string qsoValue(const char *name) {
    std::string v = [g.qso valueForField:name];
    while (!v.empty() && (v.back() == ' ' || v.back() == '\t')) v.pop_back();
    while (!v.empty() && (v.front() == ' ' || v.front() == '\t')) v.erase(0, 1);
    return v;
}

// Fill a shown, still empty field, remembering it so a new call can take it back.
static void lookupFill(const std::string &name, const std::string &value) {
    if (value.empty() || ![g.qso hasField:name] || !qsoValue(name.c_str()).empty()) return;
    [g.qso setValue:value forField:name];
    g.lookup.filled[name] = value;
}

static std::string myGrid() {
    std::string grid = qsoValue("MY_GRIDSQUARE");
    if (!grid.empty()) return grid;
    try {
        NppHandle h = currentScintilla();
        for (const auto &f : adif::hiddenStationFields(docText(h), freshLint(h).model, {}))
            if (f.first == "MY_GRIDSQUARE") return f.second;
    } catch (...) {
    }
    return adifhost::setting("stationGrid");  // Settings: Your Station
}

// The line under Look up: what was found, the distance, and what the logs say about the park.
static void showLookupInfo() {
    if (!g.qso) return;
    std::vector<std::string> parts;
    if (!g.lookup.found.empty()) parts.push_back(g.lookup.found);
    if (std::string lotw = ADIFLotwNote(qsoValue("CALL")); !lotw.empty()) parts.push_back(lotw);
    std::string theirGrid = qsoValue("GRIDSQUARE");
    if (theirGrid.empty() && g.lookup.callbook.count("GRIDSQUARE")) theirGrid = g.lookup.callbook["GRIDSQUARE"];
    std::string mine = myGrid(), km = adif::gridDistanceKm(mine, theirGrid);
    if (!km.empty()) {
        parts.push_back(adif::gridDistanceText(mine, theirGrid));
        if ([g.qso hasField:"DISTANCE"] && (qsoValue("DISTANCE").empty() || g.lookup.filled.count("DISTANCE"))) {
            [g.qso setValue:km forField:"DISTANCE"];
            g.lookup.filled["DISTANCE"] = km;
        }
    }
    for (const char *f : {"SIG_INFO", "POTA_REF", "WWFF_REF", "SOTA_REF"}) {
        std::string refs = qsoValue(f);
        size_t start = 0;
        while (start < refs.size()) {
            size_t comma = refs.find(',', start);
            std::string ref = refs.substr(start, comma == std::string::npos ? std::string::npos : comma - start);
            start = comma == std::string::npos ? refs.size() : comma + 1;
            if (adif::isPotaRef(ref) || adif::isAdifWwffRef(ref) || adif::isAdifSotaRef(ref)) {
                std::string line = logtools::referenceLine(ref);
                if (std::find(parts.begin(), parts.end(), line) == parts.end()) parts.push_back(line);
            }
        }
    }
    std::string text;
    for (const std::string &p : parts) text += (text.empty() ? "" : " \u00B7 ") + p;
    [g.qso setLookupInfo:@(text.c_str()) severity:-1];
}

static void runLookup() {
    if (!qsoVisible()) return;
    std::string call = qsoValue("CALL");
    for (char &c : call) c = (char)std::toupper((unsigned char)c);
    if (call == g.lookup.call) {
        showLookupInfo();
        return;
    }
    // A new call: take back what the last lookup filled, if you haven't changed it.
    for (const auto &f : g.lookup.filled)
        if (qsoValue(f.first.c_str()) == f.second) [g.qso setValue:"" forField:f.first];
    g.lookup.filled.clear();
    g.lookup.callbook.clear();
    g.lookup.found.clear();
    g.lookup.call = call;
    NSInteger source = g.qso.lookupSource;
    if (call.empty() || source == 0) {
        showLookupInfo();
        return;
    }
    adif::FieldMap country = adif::countryFields(ADIFCountries(), call);
    for (const char *f : {"DXCC", "COUNTRY", "CQZ", "ITUZ", "CONT"})
        if (country.count(f)) lookupFill(f, country[f]);
    if (country.count("COUNTRY"))
        g.lookup.found = country["COUNTRY"] + " (DXCC " + country["DXCC"] + ", CQ " + country["CQZ"] + ", ITU " + country["ITUZ"] + ")";
    showLookupInfo();
    scheduleQsoCheck();
    if (source < 2) return;
    ADIFSource src = source == 2 ? ADIFSourceQRZ : ADIFSourceHamQTH;
    if (!ADIFSavedAccount(src) || !ADIFHasSecret(src)) {
        g.lookup.found = std::string("No ") + ADIFSourceName(src).UTF8String + " account: add one in Settings";
        showLookupInfo();
        return;
    }
    if (!g.lookup.client || g.lookup.clientSource != source) {
        g.lookup.client = [[ADIFCallbookClient alloc] initWithSource:src agent:@"ADIFLint-" ADIFLINT_VERSION];
        g.lookup.clientSource = source;
    }
    std::string base = adif::lookupCall(call);
    [g.lookup.client lookup:@(base.c_str())
                 completion:^(BOOL found, const std::map<std::string, std::string> &raw, NSString *error, BOOL fatal) {
                     if (!qsoVisible() || g.lookup.call != call) return;
                     std::string name = ADIFSourceName(src).UTF8String;
                     if (!found) {
                         g.lookup.found = name + ": " + (error ? std::string(error.UTF8String) : base + " not found");
                         if (fatal) g.lookup.client = nil;  // sign in again next time
                         showLookupInfo();
                         return;
                     }
                     adif::FieldMap f = src == ADIFSourceQRZ ? adif::mapQrz(raw) : adif::mapHamQth(raw);
                     // A callbook gives the station's home: not where a portable or park station is.
                     bool away = adif::isPortableCall(call);
                     for (const char *ref : {"SIG_INFO", "POTA_REF", "SOTA_REF", "WWFF_REF"}) away |= !qsoValue(ref).empty();
                     for (const char *k : {"NAME", "QTH", "STATE", "CNTY", "GRIDSQUARE", "COUNTRY", "DXCC", "CQZ", "ITUZ", "CONT",
                                           "IOTA", "LAT", "LON"})
                         if (f.count(k) && !(away && adif::isLocationField(k))) lookupFill(k, f[k]);
                     if (away)
                         for (const char *k : {"GRIDSQUARE", "STATE", "CNTY", "QTH", "LAT", "LON"}) f.erase(k);
                     g.lookup.callbook = f;
                     std::string where = f["QTH"] + (f["STATE"].empty() ? "" : (f["QTH"].empty() ? "" : ", ") + f["STATE"]);
                     g.lookup.found = name + ": " + (f["NAME"].empty() ? base : f["NAME"]) + (where.empty() ? "" : ", " + where) +
                                      (f["GRIDSQUARE"].empty() ? "" : " (" + f["GRIDSQUARE"] + ")") +
                                      (away ? " (home address; away now)" : "");
                     showLookupInfo();
                     scheduleQsoCheck();
                 }];
}

static void scheduleLookup() {
    int64_t mine = ++g.lookup.token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine == g.lookup.token) runLookup();
    });
}

static void cmdNewQso();

// A spot picked in POTA Spots: fill New QSO, adding SIG and SIG_INFO rows when
// the window shows neither SIG_INFO nor POTA_REF, so the park is logged.
static void useSpot(const std::vector<std::pair<std::string, std::string>> &fields) {
    try {
        if (!qsoVisible()) cmdNewQso();
        if (!qsoVisible()) return;
        NppHandle h = currentScintilla();
        if (!qsoHasField("SIG_INFO") && !qsoHasField("POTA_REF") && !qsoHasField("WWFF_REF")) {
            std::map<std::string, std::string> typed;
            for (const auto &v : [g.qso values]) typed[v.first] = v.second;
            for (const char *name : {"SIG", "SIG_INFO"})
                if (!qsoHasField(name)) g.qsoFields.push_back({name, "", false});
            for (adif::QsoField &q : g.qsoFields)
                if (typed.count(q.name)) q.value = typed[q.name];
            showQsoRows(h, freshLint(h));
        }
        bool mode = false, submode = false;
        for (const auto &f : fields) {
            [g.qso setValue:f.second forField:f.first];
            mode |= f.first == "MODE";
            submode |= f.first == "SUBMODE";
        }
        if (mode && !submode) [g.qso setValue:"" forField:"SUBMODE"];  // a CW spot must not keep an earlier USB
        scheduleQsoCheck();
        scheduleLookup();  // the spot's call and park: country, distance and the park's history
        [g.qso show];
        [g.qso focusField:"RST_RCVD"];
    } catch (...) {
    }
}

// "Logging to: log.adi  ·  US-7929 today: 8 of 10".
static void refreshQsoTarget() {
    if (!g.qso) return;
    std::string line = documentName();
    try {
        NppHandle h = currentScintilla();
        std::string progress = station::activationProgress(docText(h), freshLint(h).model);
        if (!progress.empty()) line += "  ·  " + progress;
        adif::ContestSetup cs = contest::setup();
        if (cs.preset == adif::ContestPreset::Serial)
            line += "  ·  " + contest::label() + ": STX " + std::to_string(adif::nextSerial(docText(h), freshLint(h).model, adif::contestIdFor(cs))) + " next";
        else if (cs.preset != adif::ContestPreset::None)
            line += "  ·  " + contest::label();
    } catch (...) {
    }
    [g.qso setTarget:line];
}

static void cmdNewQso() {
    try {
        NppHandle h = currentScintilla();
        std::string_view text = docText(h);
        const adif::LintResult &r = lintNow(h);
        if (!isBlank(text) && r.model.fields.empty() && r.model.groups.empty()) {
            showTip(h, sci(h, SCI_GETCURRENTPOS),
                    "ADIF Lint: New QSO adds records to an ADIF log. Open an .adi file, or start a new empty document.");
            return;
        }
        g.manualBuffers.insert(currentBuffer());
        loadQsoRows(h, r, false);
        refreshQsoTarget();
        [g.qso setSummary:"" severity:-1];
        [g.qso show];
        [g.qso focusField:"CALL"];
        scheduleQsoCheck();
    } catch (...) {
    }
}

// ── Enrich Log ──────────────────────────────────────────────────────────────

static bool enrichVisible() { return g.enrich.panel && g.enrich.panel.window.visible; }

// Confirmation downloads and the country file describe each QSO; callbooks give a station's home.
static bool perQsoSource(ADIFSource s) { return s != ADIFSourceQRZ && s != ADIFSourceHamQTH; }

static void enrichUpdateAccount() {
    ADIFSource src = (ADIFSource)g.enrich.panel.source;
    if (src == ADIFSourceCountryData) {
        [g.enrich.panel setAccount:ADIFCountryDataStatus()];
        [g.enrich.panel setCredit:@"Country data by Jim Reisert AD1C (country-files.com)"];
        return;
    }
    NSString *account = ADIFSavedAccount(src);
    NSString *text = ADIFLookupFakeMode() ? @"Test data (no network)"
                     : account && ADIFHasSecret(src) ? [NSString stringWithFormat:@"%@ (saved in your Keychain)", account]
                                                     : @"None yet. Add one in Settings.";
    [g.enrich.panel setAccount:text];
    // HamQTH asks that its data be credited where users see it.
    [g.enrich.panel setCredit:src == ADIFSourceHamQTH ? @"Callbook data from HamQTH.com" : @""];
}

static void setAutoValidate(bool on);
static void setColour(bool on);
static void setAutocomplete(bool on);
static void setCountCharacters(bool on);
static void refreshSettingsOptions();

static void openSettings(NSInteger source) {
    if (!g.settings) {
        g.settings = [[ADIFSettingsPanel alloc] init];
        g.settings.onLotwUsersToggled = ^(BOOL on) {
            ADIFSetLotwUsersOn(on);
            [g.settings setLotwUsersOn:on status:ADIFLotwUsersStatus() ok:YES];
        };
        g.settings.onLotwUsersUpdate = ^{
            ADIFUpdateLotwUsers(^(BOOL ok, NSString *message) { [g.settings setLotwUsersOn:ADIFLotwUsersOn() status:message ok:ok]; });
        };
        g.settings.onPotaUpdate = ^{
            ADIFUpdatePotaParks(^(BOOL ok, NSString *message) {
                [g.settings setPotaStatus:message ok:ok];
                if (ok) worldmap::parkListChanged();
            });
        };
        g.settings.onIotaUpdate = ^{
            ADIFUpdateIotaGroups(^(BOOL ok, NSString *message) {
                [g.settings setIotaStatus:message ok:ok];
                if (ok) worldmap::iotaGroupsChanged();
            });
        };
        g.settings.onCountryUpdate = ^{
            ADIFUpdateCountryData(^(BOOL ok, NSString *message) { [g.settings setCountryStatus:message ok:ok]; });
        };
        g.settings.onChanged = ^(NSInteger changed) {
            // New credentials: sign in again on the next lookup.
            if (g.enrich.panel && g.enrich.panel.source == changed && !g.enrich.running) g.enrich.client = nil;
            if (g.enrich.panel) enrichUpdateAccount();
        };
        g.settings.onStationSave = ^(NSString *callText, NSString *gridText) {
            std::string call = upperAscii(trimmed(callText.UTF8String ?: "")), grid = trimmed(gridText.UTF8String ?: "");
            if (!grid.empty() && !adif::isAdifGridSquare(grid)) {
                [g.settings setStationStatus:@"The grid is a 4, 6 or 8 character Maidenhead locator, such as EN52 or EN52wa."
                                          ok:NO];
                return;
            }
            if (grid.size() >= 2) grid = upperAscii(grid.substr(0, 4)) + grid.substr(4);
            adifhost::setSetting("stationCall", call);
            adifhost::setSetting("stationGrid", grid);
            [g.settings setStationCall:ADIFString(call) grid:ADIFString(grid) logsFolder:ADIFString(adifhost::setting("logsFolder"))];
            [g.settings setStationStatus:@"Saved." ok:YES];
        };
        g.settings.onChooseLogsFolder = ^{
            NSOpenPanel *panel = [NSOpenPanel openPanel];
            panel.canChooseDirectories = YES;
            panel.canChooseFiles = NO;
            panel.message = @"Choose the folder of logs that Worked Before searches";
            std::string dir;
            if (const char *test = getenv("ADIFLINT_TEST_FOLDER")) dir = test;
            else if ([panel runModal] == NSModalResponseOK) dir = panel.URL.path.UTF8String ?: "";
            if (dir.empty()) return;
            adifhost::setSetting("logsFolder", dir);
            [g.settings setStationCall:ADIFString(adifhost::setting("stationCall")) grid:ADIFString(adifhost::setting("stationGrid"))
                            logsFolder:ADIFString(dir)];
        };
        g.settings.onStationProfiles = ^{ station::cmdStationProfiles(); };
        g.settings.onEditorOption = ^(NSInteger option, BOOL on) {
            switch (option) {
                case 0: setAutoValidate(on); break;
                case 1: setColour(on); break;
                case 2: setAutocomplete(on); break;
                case 3: setCountCharacters(on); break;
                default: break;
            }
        };
    }
    [g.settings setCountryStatus:ADIFCountryDataStatus() ok:YES];
    [g.settings setLotwUsersOn:ADIFLotwUsersOn() status:ADIFLotwUsersStatus() ok:YES];
    [g.settings setIotaStatus:ADIFIotaGroupsStatus() ok:YES];
    [g.settings setPotaStatus:ADIFPotaParksStatus() ok:YES];
    [g.settings setStationCall:ADIFString(adifhost::setting("stationCall")) grid:ADIFString(adifhost::setting("stationGrid"))
                    logsFolder:ADIFString(adifhost::setting("logsFolder"))];
    refreshSettingsOptions();
    [g.settings showSource:source];
}

static void refreshSettingsOptions() {
    [g.settings setEditorValidate:g.autoValidate colour:g.colour autocomplete:g.autocomplete characters:g.countCharacters];
}

static void cmdSettings() { openSettings(-1); }

// Non-header records with fields, optionally only those touching [selB, selE).
static std::vector<int> enrichScope(const adif::DocModel &m) {
    std::vector<int> out;
    for (size_t i = 0; i < m.groups.size(); ++i) {
        const adif::ModelGroup &grp = m.groups[i];
        if (grp.header || !grp.fieldCount) continue;
        if (g.enrich.selectionOnly &&
            !(adif::groupStart(m, grp) < g.enrich.selE && adif::groupEnd(m, grp) > g.enrich.selB))
            continue;
        out.push_back((int)i);
    }
    return out;
}

static void enrichFail(NSString *message) {
    g.enrich.running = false;
    [g.enrich.panel setBusy:NO];
    [g.enrich.panel setStatus:message severity:2];
}

// Lookups are done: propose changes against the log as it is now.
static void enrichFinish() {
    g.enrich.running = false;
    [g.enrich.panel setBusy:NO];
    try {
        if (g.enrich.buffer != currentBuffer()) {
            [g.enrich.panel setStatus:@"The log is no longer the active document. Switch back to it and press Find Data again: "
                                       @"the calls looked up are kept, so it takes moments."
                             severity:2];
            return;
        }
        NppHandle h = currentScintilla();
        const adif::LintResult &r = lintNow(h);
        std::string_view text = docText(h);
        adif::EnrichOptions opt;
        opt.fields = g.enrich.fields;
        opt.perQsoData = perQsoSource(g.enrich.source);
        opt.skipLocationAwayFromHome = g.enrich.skipAway;
        std::vector<adif::EnrichChange> changes, rejected;
        std::vector<int> scope = enrichScope(r.model);
        std::string note = ADIFSourceName(g.enrich.source).UTF8String;
        size_t matched = 0;
        if (g.enrich.source == ADIFSourceCountryData) {
            const adif::CountryTable &countries = ADIFCountries();
            for (int gi : scope) {
                adif::FieldMap f = adif::countryFields(countries, adif::groupValue(text, r.model, r.model.groups[(size_t)gi], "CALL"));
                if (f.empty()) continue;
                ++matched;
                adif::proposeChanges(text, r.model, gi, f, opt, "From the call's prefix (AD1C country file)", changes, &rejected);
            }
        } else {
            for (int gi : scope) {
                std::string call = adif::lookupCall(adif::groupValue(text, r.model, r.model.groups[(size_t)gi], "CALL"));
                auto it = g.enrich.found.find(call);
                if (it != g.enrich.found.end()) adif::proposeChanges(text, r.model, gi, it->second, opt, note, changes, &rejected);
            }
        }
        g.enrich.changes = changes;
        std::vector<ADIFEnrichRow> rows;
        std::set<int> records;
        for (const adif::EnrichChange &c : changes) {
            rows.push_back({c.accepted, c.record, c.call, c.field, c.current, c.value, c.replace, c.note});
            records.insert(c.group);
        }
        [g.enrich.panel setRows:rows];

        std::string status = g.enrich.cancelled ? "Stopped. " : "";
        if (g.enrich.source == ADIFSourceCountryData) {
            status += std::to_string(matched) + " of " + std::to_string(scope.size()) + " calls have a known prefix. ";
        } else {
            status += "Found " + std::to_string(g.enrich.found.size()) + " of " + std::to_string(g.enrich.calls.size()) + " calls";
            if (g.enrich.notFound) status += " (" + std::to_string(g.enrich.notFound) + " not found)";
            if (g.enrich.failed) status += "; " + std::to_string(g.enrich.failed) + " lookups failed: " + g.enrich.firstError;
            status += ". ";
            if (size_t n = g.enrich.recordsComplete)
                status += n == 1 ? std::string("1 record already had these fields, so its call was not looked up. ")
                                 : std::to_string(n) + " records already had these fields, so their calls were not looked up. ";
        }
        status += changes.empty() ? "Nothing to add: those records already have these fields."
                                  : std::to_string(changes.size()) + " changes for " + std::to_string(records.size()) +
                                        " records. Untick any you don't want, then Apply.";
        if (!rejected.empty()) {
            const adif::EnrichChange &x = rejected.front();
            status += " Left out " + std::to_string(rejected.size()) + (rejected.size() == 1 ? " value" : " values") +
                      " that ADIF Lint would report, such as " + x.call + " " + x.field + " " + x.value + ": " + x.note;
        }
        if (g.enrich.client.notice) status += std::string(" ") + g.enrich.client.notice.UTF8String;
        [g.enrich.panel setStatus:@(status.c_str()) severity:g.enrich.failed ? 1 : -1];
    } catch (...) {
        enrichFail(@"Something went wrong while comparing the data with the log.");
    }
}

// Lookups run a few at a time (each callbook request is one call; neither service
// has a batch lookup). After an error they go one at a time, with a pause.
static void enrichNextLookup() {
    auto &e = g.enrich;
    if (!e.running) return;
    if (e.cancelled || e.next >= e.calls.size()) {
        if (!e.inFlight) enrichFinish();
        return;
    }
    while (e.inFlight < e.parallel && e.next < e.calls.size() && !e.cancelled) {
        NSString *call = @(e.calls[e.next++].c_str());
        ++e.inFlight;
        ADIFSource src = e.source;
        unsigned run = e.run;  // answers from an earlier Find Data are ignored
        [e.client lookup:call
              completion:^(BOOL found, const std::map<std::string, std::string> &raw, NSString *error, BOOL fatal) {
                  auto &x = g.enrich;
                  if (!x.running || x.run != run) return;
                  --x.inFlight;
                  ++x.done;
                  if (fatal) {
                      enrichFail(error ?: @"The lookup failed.");
                      return;
                  }
                  if (found) x.found[call.UTF8String] = src == ADIFSourceQRZ ? adif::mapQrz(raw) : adif::mapHamQth(raw);
                  else if (error) {
                      if (!x.failed++) x.firstError = error.UTF8String;
                      x.parallel = 1;  // the service is struggling or refusing: slow down
                  } else ++x.notFound;
                  double total = (double)x.calls.size(), elapsed = CFAbsoluteTimeGetCurrent() - x.started;
                  [x.panel setProgress:(double)x.done / total];
                  std::string st = "Looked up " + std::to_string(x.done) + " of " + std::to_string(x.calls.size()) + " calls";
                  if (x.done >= 8 && x.done < x.calls.size()) {
                      long left = std::lround(elapsed / (double)x.done * (total - (double)x.done));
                      st += left < 90 ? ", about " + std::to_string(std::max(1L, left)) + " seconds left"
                                      : ", about " + std::to_string((left + 30) / 60) + " minutes left";
                  }
                  if (x.parallel == 1 && x.failed) st += " (one at a time after an error)";
                  [x.panel setStatus:@((st + "...").c_str()) severity:-1];
                  if (x.parallel == 1)
                      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                                     ^{ enrichNextLookup(); });
                  else
                      enrichNextLookup();
              }];
    }
}

static void enrichFind() {
    if (g.enrich.running) return;
    try {
        NppHandle h = currentScintilla();
        const adif::LintResult &r = lintNow(h);
        std::string_view text = docText(h);
        if (r.model.groups.empty()) {
            [g.enrich.panel setStatus:@"This document has no ADIF records." severity:2];
            return;
        }
        auto &e = g.enrich;
        e.source = (ADIFSource)e.panel.source;
        e.fields = [e.panel selectedFields];
        e.selectionOnly = e.panel.selectionOnly;
        e.skipAway = e.panel.skipAwayFromHome;
        e.selB = (size_t)sci(h, SCI_GETSELECTIONSTART);
        e.selE = (size_t)sci(h, SCI_GETSELECTIONEND);
        if (e.fields.empty()) {
            [e.panel setStatus:@"Tick at least one field to add." severity:2];
            return;
        }
        if (e.selectionOnly && e.selB == e.selE) {
            [e.panel setStatus:@"Select the records first, or untick \"Only the records in the selection\"." severity:2];
            return;
        }
        if (e.source == ADIFSourceCountryData && ADIFCountries().empty()) {
            [e.panel setStatus:@"No country data yet: open Settings and press Update under Country Data." severity:2];
            return;
        }
        if (e.source != ADIFSourceCountryData && (!ADIFSavedAccount(e.source) || !ADIFHasSecret(e.source))) {
            [e.panel setStatus:[NSString stringWithFormat:@"No %@ account yet. Add one in Settings, then press Find Data.",
                                                          ADIFSourceName(e.source)]
                      severity:2];
            return;
        }
        std::vector<int> scope = enrichScope(r.model);
        if (scope.empty()) {
            [e.panel setStatus:@"No records to enrich." severity:2];
            return;
        }
        e.buffer = currentBuffer();
        e.running = true;
        e.cancelled = false;
        e.next = e.notFound = e.failed = e.inFlight = e.done = e.recordsComplete = 0;
        e.parallel = 4;
        e.started = CFAbsoluteTimeGetCurrent();
        ++e.run;
        e.firstError.clear();
        e.found.clear();
        e.changes.clear();
        e.calls.clear();
        [e.panel setRows:std::vector<ADIFEnrichRow>()];
        [e.panel setBusy:YES];
        if (e.source == ADIFSourceCountryData) {  // offline: nothing to wait for
            enrichFinish();
            return;
        }
        // Only calls with a record that lacks one of the chosen fields (Enrich fills missing
        // fields): a log already enriched needs few or no lookups.
        std::set<std::string> unique;
        for (int gi : scope) {
            const adif::ModelGroup &grp = r.model.groups[(size_t)gi];
            bool away = e.skipAway && adif::awayFromHome(text, r.model, grp);
            bool needs = false;
            for (const std::string &f : e.fields)
                if (adif::groupValue(text, r.model, grp, f).empty() && !(away && adif::isLocationField(f))) needs = true;
            if (!needs) {
                ++e.recordsComplete;
                continue;
            }
            std::string call = adif::lookupCall(adif::groupValue(text, r.model, grp, "CALL"));
            if (!call.empty() && unique.insert(call).second) e.calls.push_back(call);
        }
        if (e.calls.empty()) {
            enrichFinish();
            return;
        }
        if (!e.client) e.client = [[ADIFCallbookClient alloc] initWithSource:e.source agent:@"ADIFLint-" ADIFLINT_VERSION];
        [e.panel setStatus:[NSString stringWithFormat:@"Looking up %zu calls, %zu at a time...", e.calls.size(), e.parallel] severity:-1];
        enrichNextLookup();
    } catch (...) {
        enrichFail(@"Something went wrong starting the lookups.");
    }
}

static void enrichApply() {
    auto &e = g.enrich;
    if (e.running) return;
    try {
        if (e.buffer != currentBuffer()) {
            [e.panel setStatus:@"Switch back to the log these changes are for, then Apply." severity:2];
            return;
        }
        NppHandle h = currentScintilla();
        if (sci(h, SCI_GETREADONLY)) {
            [e.panel setStatus:@"This document is read-only." severity:2];
            return;
        }
        std::vector<bool> accepted = [e.panel accepted];
        adif::LintResult r = lintNow(h);  // a copy: the edits below change the document
        std::string_view text = docText(h);
        std::vector<adif::EnrichChange> verified;
        size_t skipped = 0;
        for (size_t i = 0; i < e.changes.size() && i < accepted.size(); ++i) {
            if (!accepted[i]) continue;
            adif::EnrichChange c = e.changes[i];
            // The log may have been edited since Find Data: apply only where the record still matches.
            bool ok = c.group >= 0 && (size_t)c.group < r.model.groups.size() && !r.model.groups[(size_t)c.group].header &&
                      adif::equalsNoCase(adif::groupValue(text, r.model, r.model.groups[(size_t)c.group], "CALL"), c.call) &&
                      adif::groupValue(text, r.model, r.model.groups[(size_t)c.group], c.field) == c.current;
            if (ok) verified.push_back(c);
            else ++skipped;
        }
        std::set<int> records;
        for (const adif::EnrichChange &c : verified) records.insert(c.group);
        std::vector<adif::TextEdit> edits = adif::enrichmentEdits(text, r.model, verified, lengthUnit(), docUtf8(h));
        std::vector<int> changedData;  // records whose QSO data changed: an earlier upload is out of date
        for (const adif::EnrichChange &c : verified)
            if (!adif::isTrackingField(c.field)) changedData.push_back(c.group);
        edits = adif::mergeEdits(edits, adif::markModified(text, r.model, changedData, lengthUnit(), docUtf8(h)));
        if (!edits.empty()) applyEdits(h, edits);
        validateNow(h, g.autoValidate);
        std::string status = "Applied " + std::to_string(verified.size()) + " changes to " + std::to_string(records.size()) +
                             " records (one undo step).";
        if (skipped) status += " Skipped " + std::to_string(skipped) + " whose record changed since Find Data.";
        e.changes.clear();
        [e.panel setRows:std::vector<ADIFEnrichRow>()];
        [e.panel setStatus:@(status.c_str()) severity:skipped ? 1 : -1];
    } catch (...) {
        [e.panel setStatus:@"Something went wrong applying the changes." severity:2];
    }
}

static void openEnrich(ADIFSource source) {
    try {
        if (!g.enrich.panel) {
            g.enrich.panel = [[ADIFEnrichPanel alloc] init];
            g.enrich.panel.onOpenSettings = ^{
                openSettings(g.enrich.panel.source == ADIFSourceCountryData ? -3 : g.enrich.panel.source);
            };
            g.enrich.panel.onFind = ^{ enrichFind(); };
            g.enrich.panel.onCancel = ^{
                if (g.enrich.running) g.enrich.cancelled = true;
            };
            g.enrich.panel.onApply = ^{ enrichApply(); };
            g.enrich.panel.onChooseSource = ^(NSInteger chosen) { openEnrich((ADIFSource)chosen); };
        }
        if (g.enrich.running) {  // one lookup at a time
            [g.enrich.panel show];
            if (g.enrich.panel.source != source)
                [g.enrich.panel setStatus:@"Stop or finish the current lookup before switching source." severity:1];
            return;
        }
        adifhost::setSetting("enrichLast", std::to_string((long)source));
        if (g.enrich.panel.source != source || !g.enrich.panel.window.visible) {
            NSString *title = source == ADIFSourceQRZ          ? @"Enrich from QRZ.com"
                              : source == ADIFSourceHamQTH     ? @"Enrich from HamQTH"
                                                               : @"Enrich from Country Data";
            [g.enrich.panel setSource:source title:title];
            g.enrich.client = nil;
            g.enrich.changes.clear();
        }
        g.manualBuffers.insert(currentBuffer());
        [g.enrich.panel setTarget:documentName()];
        enrichUpdateAccount();
        [g.enrich.panel show];
    } catch (...) {
    }
}

// Enrich...: the source used last (QRZ.com at first); the window's popup switches.
static void cmdEnrich() {
    std::string last = adifhost::setting("enrichLast");
    long source = last.empty() ? ADIFSourceQRZ : std::atol(last.c_str());
    if (source != ADIFSourceQRZ && source != ADIFSourceHamQTH && source != ADIFSourceCountryData) source = ADIFSourceQRZ;
    openEnrich((ADIFSource)source);
}

// ── Commands: settings and about ────────────────────────────────────────────

static void setAutoValidate(bool on) {
    g.autoValidate = on;
    setCheck(kCmdAutoValidate, on);
    saveSettings();
    schedule(0.05);
    refreshSettingsOptions();
}

static void cmdToggleAutoValidate() { setAutoValidate(!g.autoValidate); }

static void setColour(bool on) {
    g.colour = on;
    saveSettings();
    try {
        NppHandle h = currentScintilla();
        if (!g.colour) clearColours(h);
        else if (isAdifBuffer(currentBuffer())) {
            freshLint(h);
            styleIndicators(h);
            paintColours(h);
        }
    } catch (...) {
    }
}

static void setAutocomplete(bool on) {
    g.autocomplete = on;
    saveSettings();
    endList();
    g.pending.active = false;
}

static void setCountCharacters(bool on) {
    g.countCharacters = on;
    saveSettings();
    if (isAdifBuffer(currentBuffer())) {
        try {
            validateNow(currentScintilla(), true);
        } catch (...) {
        }
    }
}

static void cmdAbout() {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"ADIF Lint %s", ADIFLINT_VERSION];
    alert.informativeText = [NSString
        stringWithFormat:
            @"Checks and edits ADIF %s (%s) .adi amateur-radio logs: problems marked as you type (red error, "
            @"orange warning, blue note; hover to read), Check Log with repairs, Fix Lengths, syntax colouring, Reformat, "
            @"autocomplete and "
            @"the Record Panel.\n\n"
            @"Logging and log tools: New QSO with callsign lookup and POTA/WWFF spots; a Log Table that edits like "
            @"a spreadsheet; Summary, Activation Tracker and export for POTA, WWFF and SOTA; Worked Before; Bulk Edit "
            @"and Time Shift; sorting, duplicates, merge, CSV and Cabrillo. Every change is one undo step.\n\n"
            @"Online services: import your QSOs and confirmations from LoTW, QRZ.com Logbook and eQSL; enrich from "
            @"QRZ.com, HamQTH or offline country data; upload to QRZ.com Logbook, LoTW (TQSL), Club Log and eQSL, sent "
            @"only when you press Upload. Accounts stay in your macOS Keychain.\n\n"
            @"Free software under the GNU GPL v3. Country data by Jim Reisert AD1C (MIT licence).",
            adif::kSpecVersion, adif::kSpecDate];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Project Page"];
    [alert addButtonWithTitle:@"ADIF Specification"];
    NSModalResponse r = [alert runModal];
    NSString *url = r == NSAlertSecondButtonReturn  ? @(kProjectUrl)
                    : r == NSAlertThirdButtonReturn ? @"https://www.adif.org/317/ADIF_317.htm"
                                                    : nil;
    if (url) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

// ── Hover ───────────────────────────────────────────────────────────────────

static void onDwellStart(intptr_t pos) {
    if (pos < 0 || g.lastBuffer != currentBuffer() || g.last.diagnostics.empty()) return;
    NppHandle h = currentScintilla();
    if (!lastIsFresh(h) || sci(h, SCI_AUTOCACTIVE)) return;
    std::string text;
    int shown = 0;
    for (const adif::Diagnostic &d : g.last.diagnostics) {
        if ((intptr_t)d.start > pos) break;  // sorted by start
        if (pos >= (intptr_t)d.end) continue;
        if (shown == 3) {
            text += "\n(more problems here)";
            break;
        }
        text += (text.empty() ? "" : "\n") + wrap(severityLabel(d.severity) + d.message);
        ++shown;
    }
    if (text.empty()) return;
    showTip(h, pos, text);
    g.tipFromDwell = true;
}

static void onDwellEnd() {
    if (!g.tipFromDwell) return;
    g.tipFromDwell = false;
    sci(currentScintilla(), SCI_CALLTIPCANCEL);
}

// ── Plugin exports ──────────────────────────────────────────────────────────

static void setItem(int i, const char *name, PFUNCPLUGINCMD fn, bool checked = false) {
    std::strncpy(funcItem[i]._itemName, name, NPP_MENU_ITEM_SIZE - 1);
    funcItem[i]._pFunc = fn;
    funcItem[i]._init2Check = checked;
    funcItem[i]._pShKey = nullptr;  // the host ignores plugin default shortcuts
}

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    std::memset(funcItem, 0, sizeof funcItem);
    loadSettings();
    setItem(kCmdNewQso, "New QSO...", cmdNewQso);
    setItem(kCmdSpots, "Spots (POTA, WWFF, More)...", logtools::cmdPotaSpots);
    setItem(kCmdStartActivation, "Start Activation...", station::cmdStartActivation);
    setItem(kSepLog, "", nullptr);
    setItem(kCmdLogTable, "Log Table...", logtools::cmdLogTable);
    setItem(kCmdCheckLog, "Check Log...", checklog::cmdCheckLog);
    setItem(kCmdFixLengths, "Fix Lengths", cmdFixLengths);
    setItem(kCmdNextProblem, "Next Problem", cmdNextProblem);
    setItem(kCmdPreviousProblem, "Previous Problem", cmdPreviousProblem);
    setItem(kSepEdit, "", nullptr);
    setItem(kCmdBulkEdit, "Bulk Edit...", logtools::cmdBulkEdit);
    setItem(kCmdTimeShift, "Time Shift...", logtools::cmdTimeShift);
    setItem(kCmdOrganize, "Sort and Organize...", logtools::cmdOrganize);
    setItem(kCmdDupes, "Remove Duplicates...", logtools::cmdRemoveDuplicates);
    setItem(kCmdMerge, "Compare and Merge Logs...", logtools::cmdCompareLogs);
    setItem(kSepReports, "", nullptr);
    setItem(kCmdSummary, "Log Summary...", logtools::cmdSummary);
    setItem(kCmdTracker, "Activation Tracker (POTA, WWFF, SOTA)...", logtools::cmdActivationTracker);
    setItem(kCmdWorkedBefore, "Worked Before...", logtools::cmdWorkedBefore);
    setItem(kCmdMap, "Map (Grids, DXCC, Parks)...", worldmap::cmdMap);
    setItem(kSepServices, "", nullptr);
    setItem(kCmdImport, "Import...", families::cmdImport);
    setItem(kCmdExport, "Export...", families::cmdExport);
    setItem(kCmdUpload, "QSL Sync (Upload, Confirmations)...", uploads::cmdQslSync);
    setItem(kCmdEnrich, "Enrich...", cmdEnrich);
    setItem(kCmdMonitor, "Monitor (WSJT-X, N1MM, Loggers)...", monitor::cmdMonitor);
    setItem(kSepView, "", nullptr);
    setItem(kCmdRecordPanel, "Record Panel", cmdRecordPanel, g.panelWanted);
    setItem(kCmdReformatRecords, "Reformat: One Record per Line", cmdReformatRecords);
    setItem(kCmdReformatFields, "Reformat: One Field per Line", cmdReformatFields);
    setItem(kCmdAutoValidate, "Check .adi Files While Typing", cmdToggleAutoValidate, g.autoValidate);
    setItem(kSepSettings, "", nullptr);
    setItem(kCmdSettings, "Settings...", cmdSettings);
    setItem(kCmdAbout, "About ADIF Lint...", cmdAbout);
}

extern "C" NPP_EXPORT const char *getName() { return kPluginName; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = kCmdCount;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    if (!n) return;
    try {
        switch (n->nmhdr.code) {
            case NPPN_READY: {
                int start = 0;
                if (app(NPPM_ALLOCATEINDICATOR, kIndCount, (intptr_t)&start)) g.indicatorBase = start;
                loadSettings();  // in case the config dir was not ready during setInfo
                setCheck(kCmdAutoValidate, g.autoValidate);
                setCheck(kCmdRecordPanel, g.panelWanted);
                for (NppHandle h : {nppData._scintillaMainHandle, nppData._scintillaSecondHandle}) {
                    sci(h, SCI_SETMOUSEDWELLTIME, kDwellMs);
                    styleIndicators(h);
                }
                g.ready = true;
                logtools::setIndexListener(^{
                    if (qsoVisible()) scheduleQsoCheck();
                });
                logtools::setSpotHandler(^(const std::vector<std::pair<std::string, std::string>> &fields) { useSpot(fields); });
                if (g.panelWanted) showPanel(true);
                schedule(0.1);
                dispatch_async(dispatch_get_main_queue(), ^{ monitor::startIfWanted(); });
                // First run: a welcome in Settings, asking for the station (never during the tests'
                // offline runs unless they ask for it).
                if (g.firstRun && (!ADIFLookupFakeMode() || getenv("ADIFLINT_TEST_WELCOME"))) {
                    g.firstRun = false;
                    adifhost::setSetting("firstRunDone", "1");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        openSettings(-1);
                        [g.settings showWelcome];
                    });
                }
                break;
            }
            case NPPN_TBMODIFICATION:
                // Toolbar buttons: <hint>.png and <hint>_dark.png in the plugin folder.
                app(NPPM_ADDTOOLBARICON_FORDARKMODE, (uintptr_t)funcItem[kCmdNewQso]._cmdID, (intptr_t) "toolbar-newqso.png");
                app(NPPM_ADDTOOLBARICON_FORDARKMODE, (uintptr_t)funcItem[kCmdLogTable]._cmdID, (intptr_t) "toolbar-table.png");
                app(NPPM_ADDTOOLBARICON_FORDARKMODE, (uintptr_t)funcItem[kCmdCheckLog]._cmdID, (intptr_t) "toolbar-check.png");
                app(NPPM_ADDTOOLBARICON_FORDARKMODE, (uintptr_t)funcItem[kCmdSpots]._cmdID, (intptr_t) "toolbar-spots.png");
                break;
            case NPPN_SHUTDOWN:
                g.ready = false;
                monitor::shutdown();
                if (g.panelHandle) app(NPPM_DMM_UNREGISTERPANEL, (uintptr_t)g.panelHandle);
                g.panelHandle = 0;
                break;
            case NPPN_BUFFERACTIVATED:
            case NPPN_FILESAVED:  // a document saved as .adi starts being checked
                endList();
                g.pending.active = false;
                schedule(0.05);
                if (qsoVisible()) {
                    refreshQsoTarget();
                    scheduleQsoCheck();
                }
                // A file opened for an activation: New QSO opens on it.
                if (!g.pendingOpen.empty() && currentPath() == g.pendingOpen) {
                    g.pendingOpen.clear();
                    cmdNewQso();
                }
                if (enrichVisible() && !g.enrich.running) [g.enrich.panel setTarget:documentName()];
                logtools::bufferActivated();
                uploads::documentChanged();
                imports::documentChanged();
                checklog::documentChanged();
                monitor::documentActivated();
                break;
            case NPPN_DARKMODECHANGED:
                for (NppHandle h : {nppData._scintillaMainHandle, nppData._scintillaSecondHandle}) styleIndicators(h);
                break;
            case SCN_MODIFIED:
                if (g.ready && (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) {
                    ++g.editCount;
                    noteEdit(n);
                    schedule(0.4);
                }
                break;
            case SCN_UPDATEUI:
                if (!g.ready) break;
                if (n->updated & SC_UPDATE_V_SCROLL) schedulePaint();
                if (n->updated & SC_UPDATE_SELECTION) {
                    schedulePanelRefresh();
                    checkPendingLeft();
                }
                break;
            case SCN_CHARADDED:
                if (g.ready) onCharAdded(n->ch);
                break;
            case SCN_AUTOCSELECTION:
                onListSelection(n->text, n->position);
                break;
            case SCN_AUTOCCANCELLED:
                onListCancelled();
                break;
            case SCN_DWELLSTART:
                onDwellStart(n->position);
                break;
            case SCN_DWELLEND:
                onDwellEnd();
                break;
            default:
                break;
        }
    } catch (...) {
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) { return TRUE; }
