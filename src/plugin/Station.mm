#import "Station.h"

#import "CheckLog.h"
#import "LogTools.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#include "adif_lint.h"
#include "adif_programs.h"

#include <sys/stat.h>

using namespace adifhost;

namespace station {
namespace {

// ── Profiles file ──

std::string profilesPath() {
    std::string dir = configDir();
    return dir.empty() ? std::string() : dir + "/ADIFLint-profiles.adi";
}

struct Cache {
    std::vector<adif::StationProfile> list;
    time_t mtime = -1;
    off_t size = -1;
} cache;

void save(const std::vector<adif::StationProfile> &list) {
    std::string path = profilesPath();
    if (path.empty()) return;
    std::string text = adif::profilesText(list, ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"));
    NSData *data = [NSData dataWithBytes:text.data() length:text.size()];
    [data writeToFile:ADIFString(path) options:NSDataWritingAtomic error:nil];
    cache.list = list;
    struct stat st{};
    if (stat(path.c_str(), &st) == 0) cache.mtime = st.st_mtime, cache.size = st.st_size;
}

// ── Activation (kept in ADIFLint.ini so it survives a restart) ──

struct Activation {
    bool active = false;
    adif::Program program = adif::Program::POTA;
    std::vector<std::string> refs;
};

Activation activation() {
    Activation a;
    a.active = setting("activationActive") == "1";
    std::string p = setting("activationProgram");
    a.program = p == "WWFF" ? adif::Program::WWFF : p == "SOTA" ? adif::Program::SOTA : adif::Program::POTA;
    std::vector<std::string> bad;
    std::string why;
    a.refs = adif::parseReferences(a.program, setting("activationRefs"), &bad, &why);
    if (a.refs.empty()) a.active = false;
    return a;
}

std::string joined(const std::vector<std::string> &v, const char *sep) {
    std::string out;
    for (const std::string &s : v) out += (out.empty() ? "" : sep) + s;
    return out;
}

// ── The Station Profiles editor ──

const char *kProfileColumns[] = {"STATION_CALLSIGN", "OPERATOR", "MY_GRIDSQUARE", "MY_STATE", "MY_CNTY",
                                 "MY_RIG",           "MY_ANTENNA", "TX_PWR"};

struct Editor {
    ADIFToolWindow *w = nil;
    std::vector<adif::StationProfile> list;
} ed;

void editorShow() {
    if (!ed.w) return;
    [ed.w setTarget:[@"Kept in " stringByAppendingString:ADIFString(profilesPath()).stringByAbbreviatingWithTildeInPath]];
    ed.list = profiles();
    std::vector<std::vector<std::string>> rows;
    std::vector<std::string> keys;
    for (const adif::StationProfile &p : ed.list) {
        std::vector<std::string> row{p.name};
        for (const char *f : kProfileColumns) row.push_back(p.get(f));
        row.push_back(p.tqslLocation);
        rows.push_back(row);
        keys.push_back(p.name);
    }
    [ed.w setRows:rows severities:std::vector<int>() keys:keys ticks:std::vector<bool>() keepTicks:NO];
}

// A cell typed in the editor: checked, then saved at once.
void editorEdit(NSInteger row, size_t column, NSString *typed) {
    if (row < 0 || (size_t)row >= ed.list.size()) return;
    adif::StationProfile &p = ed.list[(size_t)row];
    std::string v = ADIFStd(typed);
    while (!v.empty() && (v.back() == ' ' || v.back() == '\t')) v.pop_back();
    while (!v.empty() && (v.front() == ' ' || v.front() == '\t')) v.erase(v.begin());
    std::string problem;
    if (column == 0) {
        if (v.empty()) problem = "A profile needs a name.";
        for (const adif::StationProfile &o : ed.list)
            if (&o != &p && o.name == v) problem = "Another profile is called " + v + ".";
        if (problem.empty()) p.name = v;
    } else if (column == 9) {
        p.tqslLocation = v;
    } else {
        std::string field = kProfileColumns[column - 1];
        if (field == "STATION_CALLSIGN" || field == "OPERATOR" || field == "MY_STATE")
            for (char &c : v) c = (char)std::toupper((unsigned char)c);
        double watts = 0;
        if (field == "MY_GRIDSQUARE" && !v.empty() && !adif::isAdifGridSquare(v))
            problem = "A grid is a 4, 6 or 8 character Maidenhead locator, such as EN52 or EN52wa.";
        else if (field == "TX_PWR" && !v.empty() && !adif::parseAdifNumber(v, &watts))
            problem = "Power is a number of watts, such as 5 or 100.";
        if (field == "MY_GRIDSQUARE" && v.size() >= 4) {
            for (size_t i = 0; i < 2; ++i) v[i] = (char)std::toupper((unsigned char)v[i]);
            for (size_t i = 4; i < v.size() && i < 6; ++i) v[i] = (char)std::tolower((unsigned char)v[i]);
        }
        if (problem.empty()) p.set(field, v);
    }
    if (!problem.empty()) {
        [ed.w setStatus:ADIFString(problem) severity:2];
        editorShow();
        return;
    }
    std::string name = p.name;  // editorShow() reloads the list
    save(ed.list);
    editorShow();
    [ed.w setStatus:ADIFString("Saved " + name + ".") severity:-1];
    stationChanged();
}

}  // namespace

std::vector<adif::StationProfile> profiles() {
    std::string path = profilesPath();
    struct stat st{};
    if (path.empty() || stat(path.c_str(), &st) != 0) {
        cache = Cache{};
        return {};
    }
    if (st.st_mtime != cache.mtime || st.st_size != cache.size) {
        NSData *data = [NSData dataWithContentsOfFile:ADIFString(path)];
        std::string text = data ? std::string((const char *)data.bytes, data.length) : std::string();
        cache.list = adif::parseProfiles(text);
        cache.mtime = st.st_mtime;
        cache.size = st.st_size;
    }
    return cache.list;
}

void cmdStationProfiles() {
    if (!ed.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Station Profiles" size:NSMakeSize(980, 420) headline:NO];
        ed.w = w;
        std::vector<ADIFToolColumn> cols{{"name", "Profile", 120}};
        const char *titles[] = {"Callsign", "Operator", "Grid", "State", "County", "Rig", "Antenna", "Power (W)"};
        for (size_t i = 0; i < 8; ++i) cols.push_back({kProfileColumns[i], titles[i], i >= 5 && i <= 6 ? 110.0 : 80.0});
        cols.push_back({"tqsl", "TQSL Location", 120});
        [w setColumns:cols checkboxes:NO sortable:NO];
        std::vector<size_t> editable;
        for (size_t i = 0; i < cols.size(); ++i) editable.push_back(i);
        [w setEditableColumns:editable];
        w.onEditCell = ^(NSInteger row, size_t column, NSString *text) { editorEdit(row, column, text); };
        [w addButton:@"Add" trailing:NO action:^{
            ed.list = profiles();
            adif::StationProfile p;
            int n = (int)ed.list.size() + 1;
            for (bool taken = true; taken; ++n) {
                p.name = "Profile " + std::to_string(n);
                taken = std::any_of(ed.list.begin(), ed.list.end(), [&](const adif::StationProfile &o) { return o.name == p.name; });
            }
            p.set("STATION_CALLSIGN", setting("stationCall"));
            p.set("MY_GRIDSQUARE", setting("stationGrid"));
            ed.list.push_back(p);
            save(ed.list);
            editorShow();
            [ed.w selectRow:(NSInteger)ed.list.size() - 1];
            [ed.w beginEditingRow:(NSInteger)ed.list.size() - 1 column:0];
            [ed.w setStatus:@"Added a profile with Your Station's callsign and grid: name it, then fill in the rest." severity:-1];
            stationChanged();
        }];
        [w addButton:@"Duplicate" trailing:NO action:^{
            std::vector<NSInteger> sel = [ed.w selectedRows];
            if (sel.size() != 1) {
                [ed.w setStatus:@"Select the profile to copy." severity:1];
                return;
            }
            adif::StationProfile p = ed.list[(size_t)sel[0]];
            p.name += " copy";
            ed.list.push_back(p);
            save(ed.list);
            editorShow();
            stationChanged();
        }];
        [w addButton:@"Remove" trailing:NO action:^{
            std::vector<NSInteger> sel = [ed.w selectedRows];
            if (sel.empty()) {
                [ed.w setStatus:@"Select the profiles to remove." severity:1];
                return;
            }
            std::sort(sel.rbegin(), sel.rend());
            for (NSInteger r : sel)
                if ((size_t)r < ed.list.size()) ed.list.erase(ed.list.begin() + r);
            save(ed.list);
            editorShow();
            [ed.w setStatus:ADIFString("Removed " + std::to_string(sel.size()) + (sel.size() == 1 ? " profile." : " profiles."))
                    severity:-1];
            stationChanged();
        }];
        [w setStatus:@"Your station's fields for different places or rigs: home, portable, a club station. New QSO's Station "
                     @"popup and Start Activation write them into each QSO. Double-click a cell to edit it."
              severity:-1];
    }
    editorShow();
    [ed.w show];
}

// ── New QSO's station ──

NSInteger chosenProfile() {
    std::string name = setting("qsoProfile");
    if (name.empty()) return 0;
    std::vector<adif::StationProfile> list = profiles();
    for (size_t i = 0; i < list.size(); ++i)
        if (list[i].name == name) return (NSInteger)i + 1;
    return 0;
}

void chooseProfile(NSInteger index) {
    std::vector<adif::StationProfile> list = profiles();
    setSetting("qsoProfile", index >= 1 && (size_t)index <= list.size() ? list[(size_t)index - 1].name : std::string());
    stationChanged();
}

adif::FieldList stationFields() {
    adif::FieldList out;
    NSInteger i = chosenProfile();
    std::vector<adif::StationProfile> list = profiles();
    if (i >= 1 && (size_t)i <= list.size()) out = list[(size_t)i - 1].fields;
    Activation a = activation();
    if (a.active) out = adif::overlay(out, adif::activationFields(a.program, a.refs));
    return out;
}

std::string stationLabel() {
    std::string out;
    NSInteger i = chosenProfile();
    std::vector<adif::StationProfile> list = profiles();
    if (i >= 1 && (size_t)i <= list.size()) out = "profile " + list[(size_t)i - 1].name;
    Activation a = activation();
    if (a.active) out += (out.empty() ? "" : ", ") + std::string("activating ") + joined(a.refs, ", ");
    return out;
}

std::string activationProgress(std::string_view text, const adif::DocModel &m) {
    Activation a = activation();
    if (!a.active) return "";
    std::string today = utcNow("%Y%m%d"), out;
    for (const adif::Activation &act : adif::programActivations(text, m, a.program, setting("stationCall"))) {
        if (std::find(a.refs.begin(), a.refs.end(), act.park) == a.refs.end()) continue;
        if (a.program != adif::Program::WWFF && act.date != today) continue;
        std::string what = a.program == adif::Program::SOTA ? " stations" : "";
        std::string line = act.park + (a.program == adif::Program::POTA ? " today: " : ": ") + std::to_string(act.qsos) +
                           (act.activated() ? what + ", activated" : " of " + std::to_string(act.needed) + what);
        out += (out.empty() ? "" : "  ·  ") + line;
    }
    if (out.empty()) out = joined(a.refs, ", ") + ": no QSOs yet";
    return out;
}

// ── Start Activation ──

namespace {

struct Starter {
    ADIFToolWindow *w = nil;
    NSPopUpButton *program = nil, *profile = nil, *target = nil;
    NSTextField *refs = nil, *folder = nil, *file = nil;
    NSButton *start = nil, *finish = nil, *pota = nil;
} st;

adif::Program chosenProgram() {
    NSInteger i = st.program.indexOfSelectedItem;
    return i == 1 ? adif::Program::WWFF : i == 2 ? adif::Program::SOTA : adif::Program::POTA;
}

std::string activationFolder() {
    std::string f = setting("activationFolder");
    if (f.empty()) f = setting("logsFolder");
    if (f.empty()) f = ADIFStd(NSHomeDirectory()) + "/Documents";
    return f;
}

std::string callFor(NSInteger profileIndex) {
    std::vector<adif::StationProfile> list = profiles();
    if (profileIndex >= 1 && (size_t)profileIndex <= list.size()) {
        std::string c = list[(size_t)profileIndex - 1].get("STATION_CALLSIGN");
        if (!c.empty()) return c;
    }
    return setting("stationCall");
}

// Refresh the window: what was typed, the file it would start, and the references' history.
void starterShow() {
    if (!st.w) return;
    [st.w setTarget:[@"Open log: " stringByAppendingString:ADIFString(documentName())]];
    std::vector<adif::StationProfile> list = profiles();
    NSInteger keep = st.profile.indexOfSelectedItem;
    [st.profile removeAllItems];
    [st.profile addItemWithTitle:@"Your Station (Settings)"];
    for (const adif::StationProfile &p : list) [st.profile addItemWithTitle:ADIFString(p.name)];
    [st.profile selectItemAtIndex:keep >= 0 && keep < st.profile.numberOfItems ? keep : 0];

    adif::Program p = chosenProgram();
    std::vector<std::string> bad;
    std::string why;
    std::vector<std::string> refs = adif::parseReferences(p, ADIFStd(st.refs.stringValue), &bad, &why);
    bool newFile = st.target.indexOfSelectedItem == 0;
    std::string call = callFor(st.profile.indexOfSelectedItem);
    std::string name = adif::activationFileName(p, call, refs, utcNow("%Y%m%d"));
    st.folder.stringValue = ADIFString(activationFolder()).stringByAbbreviatingWithTildeInPath;
    st.file.stringValue = newFile ? (refs.empty() ? @"" : ADIFString(name)) : ADIFString("into " + documentName());
    std::vector<std::vector<std::string>> rows;
    for (const std::string &r : refs) rows.push_back({r, logtools::referenceLine(r)});
    [st.w setRows:rows severities:std::vector<int>()];
    st.start.enabled = !refs.empty() && why.empty();
    Activation a = activation();
    st.finish.enabled = a.active;
    st.pota.hidden = !(a.active && a.program == adif::Program::POTA);
    std::string status;
    int severity = -1;
    if (!why.empty() && !ADIFStd(st.refs.stringValue).empty()) status = why, severity = 2;
    else if (a.active) status = "Activating " + joined(a.refs, ", ") + ". New QSO writes " + programName(a.program) +
                                " fields in every QSO; Finish checks the log and opens the export.";
    else status = "Choose the program and the references, then Start: New QSO opens with your station and the "
                  "activation's fields filled in.";
    if (call.empty() && newFile && severity < 0)
        status += " No callsign yet: add it in Settings (Your Station) or a profile.", severity = 1;
    [st.w setStatus:ADIFString(status) severity:severity];
}

void startActivation() {
    adif::Program p = chosenProgram();
    std::vector<std::string> bad;
    std::string why;
    std::vector<std::string> refs = adif::parseReferences(p, ADIFStd(st.refs.stringValue), &bad, &why);
    if (!why.empty() || refs.empty()) {
        [st.w setStatus:ADIFString(why.empty() ? std::string("Type a reference.") : why) severity:2];
        return;
    }
    NSInteger profile = st.profile.indexOfSelectedItem;
    setSetting("activationProgram", adif::programName(p));
    setSetting("activationRefs", joined(refs, ","));
    setSetting("activationActive", "1");
    std::vector<adif::StationProfile> list = profiles();
    setSetting("qsoProfile", profile >= 1 && (size_t)profile <= list.size() ? list[(size_t)profile - 1].name : std::string());
    if (st.target.indexOfSelectedItem == 0) {
        std::string dir = activationFolder();
        std::string path = dir + "/" + adif::activationFileName(p, callFor(profile), refs, utcNow("%Y%m%d"));
        [[NSFileManager defaultManager] createDirectoryAtPath:ADIFString(dir) withIntermediateDirectories:YES attributes:nil error:nil];
        bool existed = [[NSFileManager defaultManager] fileExistsAtPath:ADIFString(path)];
        if (!existed) {
            std::string header = adif::newLogHeader(ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"), "\n");
            NSData *data = [NSData dataWithBytes:header.data() length:header.size()];
            NSError *error = nil;
            if (![data writeToFile:ADIFString(path) options:NSDataWritingAtomic error:&error]) {
                [st.w setStatus:[@"Could not create the log: " stringByAppendingString:error.localizedDescription ?: @"?"]
                        severity:2];
                return;
            }
        }
        setSetting("activationLog", path);
        if (!openFile(path, true)) {
            [st.w setStatus:@"Nextpad++ did not open the new log. Open it from the folder, then New QSO." severity:2];
            return;
        }
        [st.w setStatus:ADIFString(std::string(existed ? "Opened " : "Started ") + ADIFStd(ADIFString(path).lastPathComponent) +
                                   "; New QSO opens on it.")
                severity:3];
    } else {
        setSetting("activationLog", path());
        openNewQso();
    }
    stationChanged();
    starterShow();
}

void finishActivation() {
    Activation a = activation();
    if (!a.active) return;
    std::string log = setting("activationLog");
    if (!log.empty() && log != path()) {
        [st.w setStatus:ADIFString("Switch to the activation's log (" + ADIFStd(ADIFString(log).lastPathComponent) +
                                   ") first, then Finish.")
                severity:2];
        return;
    }
    setSetting("activationActive", "0");
    stationChanged();
    checklog::cmdCheckLog();
    logtools::openActivationExport(a.program);
    std::string next = a.program == adif::Program::POTA ? "upload each park's file on pota.app (My Log Uploads)"
                       : a.program == adif::Program::WWFF ? "send the file to your national WWFF log manager"
                                                          : "upload the file to the SOTA database";
    [st.w setStatus:ADIFString("Finished " + joined(a.refs, ", ") + ". Repair anything Check Log lists, save the files in "
                               "Export, then " + next + ". Upload... sends the QSOs to QRZ.com, LoTW, Club Log or eQSL.")
            severity:3];
    starterShow();
    st.pota.hidden = a.program != adif::Program::POTA;
}

}  // namespace

void cmdStartActivation() {
    if (!st.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Start Activation" size:NSMakeSize(760, 460) headline:NO];
        st.w = w;
        st.program = ADIFPopup(@[ @"POTA", @"WWFF", @"SOTA" ]);
        std::string last = setting("activationProgram");
        [st.program selectItemAtIndex:last == "WWFF" ? 1 : last == "SOTA" ? 2 : 0];
        st.refs = ADIFTextField(@"e.g. US-7929, US-1234 for a two-fer", 260);
        st.refs.stringValue = ADIFString(joined(activation().refs, ", "));
        [w addOptionRow:@[ ADIFLabel(@"Program:"), st.program, ADIFLabel(@"References:"), st.refs ]];
        st.profile = ADIFPopup(@[ @"Your Station (Settings)" ]);
        NSButton *edit = [NSButton buttonWithTitle:@"Profiles..." target:nil action:nil];
        ADIFOnAction(edit, ^{ cmdStationProfiles(); });
        [w addOptionRow:@[ ADIFLabel(@"Station:"), st.profile, edit ]];
        st.target = ADIFPopup(@[ @"A new log file", @"The log that's open" ]);
        st.folder = ADIFLabel(@"");
        st.folder.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [st.folder.widthAnchor constraintLessThanOrEqualToConstant:300].active = YES;
        NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
        ADIFOnAction(choose, ^{
            NSOpenPanel *panel = [NSOpenPanel openPanel];
            panel.canChooseDirectories = YES;
            panel.canChooseFiles = NO;
            panel.canCreateDirectories = YES;
            panel.message = @"Choose the folder for activation logs";
            std::string dir;
            if (const char *test = getenv("ADIFLINT_TEST_FOLDER")) dir = test;
            else if ([panel runModal] == NSModalResponseOK) dir = ADIFStd(panel.URL.path);
            if (dir.empty()) return;
            setSetting("activationFolder", dir);
            starterShow();
        });
        [w addOptionRow:@[ ADIFLabel(@"Log to:"), st.target, ADIFLabel(@"in"), st.folder, choose ]];
        st.file = ADIFLabel(@"");
        st.file.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [w addOptionRow:@[ ADIFLabel(@"File:"), st.file ]];
        for (NSControl *c in @[ st.program, st.profile, st.target ]) ADIFOnAction(c, ^{ starterShow(); });
        [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                          object:st.refs
                                                           queue:nil
                                                      usingBlock:^(NSNotification *n) { starterShow(); }];
        [w setColumns:std::vector<ADIFToolColumn>{{"ref", "Reference", 110}, {"history", "Your logs", 560}} checkboxes:NO sortable:NO];
        st.finish = [w addButton:@"Finish..." trailing:NO action:^{ finishActivation(); }];
        st.pota = [w addButton:@"Open pota.app Uploads" trailing:NO action:^{
            // docs.pota.app "Submitting logs" (checked 2026-10-09) links this page.
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://pota.app/#/user/logs"]];
        }];
        st.start = [w addButton:@"Start" trailing:YES action:^{ startActivation(); }];
        [w setDefaultButton:st.start];
    }
    NSInteger chosen = chosenProfile();
    starterShow();
    [st.profile selectItemAtIndex:chosen < st.profile.numberOfItems ? chosen : 0];
    starterShow();
    [st.w show];
}

}  // namespace station
