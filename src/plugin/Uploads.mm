#import "Uploads.h"

#import "Families.h"
#import "Lookup.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#include "Scintilla.h"
#include "adif_spec.h"
#include "adif_tools.h"
#include "adif_upload.h"

#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cstdlib>
#include <map>
#include <memory>
#include <set>

using namespace adifhost;

namespace {

const size_t kServices = 4;
// How long TQSL may take to sign and upload (ADIFLINT_TEST_TQSL_SECONDS overrides it for tests).
double tqslSeconds() {
    const char *t = getenv("ADIFLINT_TEST_TQSL_SECONDS");
    return t ? std::atof(t) : 600;
}
enum { kColRecord, kColCall, kColDate, kColTime, kColBand, kColMode, kColStatus, kColResult };

std::string plural(size_t n, const char *word) { return std::to_string(n) + " " + word + (n == 1 ? "" : "s"); }

NSString *agent() { return [NSString stringWithFormat:@"ADIFLint/%s", ADIFLINT_VERSION]; }

struct Upload {
    adif::UploadService service = adif::UploadService::QRZ;
    ADIFToolWindow *w = nil;
    NSTextField *account = nil, *callsign = nil, *nickname = nil, *tqsl = nil;
    NSComboBox *location = nil;
    NSButton *includeDone = nil, *selectionOnly = nil, *upload = nil, *stop = nil;
    intptr_t buffer = 0;
    std::vector<adif::UploadItem> items;  // model rows
    bool running = false, cancelled = false, results = false;
    // The run: what was sent, and what came back.
    struct Sent {
        size_t row;
        int group;
        std::string call, date, time, adi;
        bool ok = false;
    };
    std::vector<Sent> sent;
    size_t next = 0;
    std::string fatal;
    NSTask *task = nil;
};
Upload ups[kServices];

Upload &up(adif::UploadService s) { return ups[(size_t)s]; }

// ── TQSL ────────────────────────────────────────────────────────────────────

// TQSL installs to /Applications/TrustedQSL/tqsl.app (older versions to /Applications/tqsl.app).
std::string tqslPath() {
    std::string p = setting("tqslPath");
    if (!p.empty()) return p;
    for (const char *c : {"/Applications/TrustedQSL/tqsl.app/Contents/MacOS/tqsl", "/Applications/tqsl.app/Contents/MacOS/tqsl"})
        if (access(c, X_OK) == 0) return c;
    return "";
}

// Station Location names TQSL has saved, if its station_data file is where TQSL
// keeps it on macOS; only used as suggestions.
NSArray<NSString *> *tqslLocations() {
    NSMutableArray *out = [NSMutableArray array];
    NSString *file = [@"~/Library/Application Support/TrustedQSL/station_data" stringByExpandingTildeInPath];
    NSData *d = [NSData dataWithContentsOfFile:file];
    if (!d) return out;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:d options:NSXMLNodeLoadExternalEntitiesNever error:nil];
    for (NSXMLElement *e in [doc nodesForXPath:@"//StationData" error:nil])
        if (NSString *name = [e attributeForName:@"name"].stringValue) [out addObject:name];
    return out;
}

void runTqsl(const std::string &path, NSArray<NSString *> *args, Upload *u, void (^done)(int code, NSString *output)) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@(path.c_str())];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        done(-1, [@"Could not start TQSL: " stringByAppendingString:err.localizedDescription ?: @"unknown error"]);
        return;
    }
    u->task = task;
    // TQSL can stop to ask something (a certificate password, a dialog); don't wait forever.
    auto timedOut = std::make_shared<std::atomic<bool>>(false);
    double limit = tqslSeconds();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (task.running) {
            *timedOut = true;
            [task terminate];
        }
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *out = [pipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        int code = task.terminationStatus;
        NSString *text = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            u->task = nil;
            if (*timedOut)
                done(-1, [NSString stringWithFormat:@"TQSL did not finish within %@, so it was stopped. It may have been "
                                                    @"waiting for a dialog, such as a certificate password: run TQSL once "
                                                    @"by itself to check",
                                                    limit >= 120 ? [NSString stringWithFormat:@"%d minutes", (int)(limit / 60)]
                                                                 : [NSString stringWithFormat:@"%d seconds", (int)limit]]);
            else done(code, text);
        });
    });
}

// ── The window ──────────────────────────────────────────────────────────────

NSString *accountLine(adif::UploadService s) {
    auto saved = [](ADIFSource src) { return ADIFSavedAccount(src) && ADIFHasSecret(src); };
    switch (s) {
        case adif::UploadService::QRZ:
            return saved(ADIFSourceQRZLogbook) ? @"QRZ.com Logbook API key saved in your Keychain"
                                               : @"No QRZ.com Logbook API key yet: add it in Settings.";
        case adif::UploadService::ClubLog:
            if (!saved(ADIFSourceClubLog)) return @"No Club Log account yet: add it in Settings.";
            if (!saved(ADIFSourceClubLogKey)) return @"No Club Log API key yet: add it in Settings.";
            return [NSString stringWithFormat:@"%@ (Application Password and API key in your Keychain)",
                                              ADIFSavedAccount(ADIFSourceClubLog)];
        case adif::UploadService::EQSL:
            return saved(ADIFSourceEQSL) ? [NSString stringWithFormat:@"%@ (saved in your Keychain)", ADIFSavedAccount(ADIFSourceEQSL)]
                                         : @"No eQSL account yet: add it in Settings.";
        case adif::UploadService::LoTW: return @"";
    }
    return @"";
}

// "Upload N QSOs" for the ticked rows that can be sent; returns N.
size_t updateUploadButton(Upload &u) {
    std::vector<bool> ticks = [u.w ticked];
    size_t n = 0;
    for (size_t i = 0; i < ticks.size() && i < u.items.size(); ++i) n += ticks[i] && u.items[i].problem.empty();
    u.upload.title = [NSString stringWithFormat:@"Upload %zu QSO%@", n, n == 1 ? @"" : @"s"];
    u.upload.enabled = n > 0 && !u.running && !u.results;
    return n;
}

void setRunning(Upload &u, bool running) {
    u.running = running;
    u.upload.enabled = !running;
    u.stop.enabled = running;
    for (NSControl *c in @[ u.includeDone, u.selectionOnly ]) c.enabled = !running;
}

// Fill the table with what would be sent.
// keepTicks: the list is being refreshed after an edit, so QSOs you unticked stay unticked.
void plan(Upload &u, bool keepTicks = false) {
    if (!u.w || u.running) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        u.buffer = buffer();
        u.results = false;
        [u.w setTarget:[@"Log: " stringByAppendingString:ADIFString(documentName())]];
        if (u.account) u.account.stringValue = accountLine(u.service);
        if (u.tqsl) {
            std::string p = tqslPath();
            u.tqsl.stringValue = p.empty() ? @"not found: choose it" : [ADIFString(p) stringByAbbreviatingWithTildeInPath];
        }
        bool includeDone = u.includeDone.state == NSControlStateValueOn;
        std::set<int> sel;
        if (u.selectionOnly.state == NSControlStateValueOn) {
            size_t b = (size_t)sci(h, SCI_GETSELECTIONSTART), e = (size_t)sci(h, SCI_GETSELECTIONEND);
            for (size_t i = 0; i < r.model.groups.size(); ++i) {
                const adif::ModelGroup &g = r.model.groups[i];
                size_t gb = adif::groupStart(r.model, g), ge = adif::groupEnd(r.model, g);
                if (!g.header && (b == e ? (gb <= b && b <= ge) : (gb < e && ge > b))) sel.insert((int)i);
            }
        }
        adif::UploadFields f = adif::uploadFields(u.service);
        u.items.clear();
        std::vector<std::vector<std::string>> rows;
        std::vector<int> sev;
        std::vector<bool> ticks;
        size_t wanted = 0, problems = 0, done = 0;
        for (adif::UploadItem &i : adif::uploadItems(text, r.model, u.service)) {
            if (u.selectionOnly.state == NSControlStateValueOn && !sel.count(i.group)) continue;
            if (i.done) ++done;
            if ((i.done || i.skip) && !includeDone) continue;
            std::string status = !i.problem.empty() ? "can't send: " + i.problem
                                 : i.done            ? std::string("sent ") + adif::displayDate(std::string(adif::groupValue(
                                                                   text, r.model, r.model.groups[(size_t)i.group], f.date)))
                                 : i.skip            ? std::string(f.status) + " " + i.status + ": not to be sent"
                                 : i.replace         ? "changed since upload"
                                                     : "";
            rows.push_back({std::to_string(i.record), i.call, adif::displayDate(i.date), adif::displayTime(i.time), i.band, i.mode,
                            status, ""});
            sev.push_back(!i.problem.empty() ? 2 : i.done || i.skip ? 0 : i.replace ? 1 : -1);
            bool want = adif::uploadWanted(i) || (includeDone && i.done && i.problem.empty());
            ticks.push_back(want);
            wanted += want;
            problems += !i.problem.empty();
            u.items.push_back(i);
        }
        std::vector<adif::Record> recs = adif::records(text, r.model);
        std::map<int, std::string> keyOf;
        std::vector<std::string> allKeys = adif::recordKeys(recs);
        for (size_t k = 0; k < recs.size(); ++k) keyOf[recs[k].group] = allKeys[k];
        std::vector<std::string> keys;
        for (const adif::UploadItem &i : u.items) keys.push_back(keyOf[i.group]);
        [u.w setRows:rows severities:sev keys:keys ticks:ticks keepTicks:keepTicks];
        wanted = updateUploadButton(u);
        std::string st;
        if (!adif::recordCount(r.model)) st = "This document has no ADIF records.";
        else if (!wanted)
            st = "Nothing to send: " + plural(done, "QSO") + " already sent to " + adif::uploadServiceName(u.service) +
                 (problems ? ", " + plural(problems, "record") + " missing what it needs" : "") + ".";
        else
            st = plural(wanted, "QSO") + " ticked to send to " + adif::uploadServiceName(u.service) +
                 (done && !includeDone ? " (" + std::to_string(done) + " already sent are not listed)" : "") +
                 ". Nothing is sent until you press Upload; afterwards each one sent gets " + f.status + " Y and " + f.date +
                 ".";
        [u.w setStatus:ADIFString(st) severity:r.structuralErrors ? 1 : -1];
        if (r.structuralErrors)
            [u.w setStatus:@"The log has structural problems, so records may be read wrongly. Run Fix Lengths first." severity:2];
    } catch (...) {
    }
}

// The run is over: mark the records that the service accepted, in one undo step.
void finish(Upload &u, const std::string &summary, int severity) {
    setRunning(u, false);
    u.results = true;
    u.upload.enabled = NO;  // Refresh lists what is left, so nothing is sent twice by accident
    u.upload.title = @"Upload";
    std::vector<int> groups;
    size_t ok = 0, moved = 0;
    try {
        NppHandle h = scintilla();
        if (buffer() == u.buffer && !readOnly(h)) {
            adif::LintResult r = lint(h);  // a copy: the edit changes the document
            std::string_view text = adifhost::text(h);
            for (const Upload::Sent &s : u.sent) {
                if (!s.ok) continue;
                ++ok;
                bool same = s.group >= 0 && (size_t)s.group < r.model.groups.size() &&
                            adif::equalsNoCase(adif::groupValue(text, r.model, r.model.groups[(size_t)s.group], "CALL"), s.call) &&
                            adif::groupValue(text, r.model, r.model.groups[(size_t)s.group], "QSO_DATE") == s.date &&
                            adif::groupValue(text, r.model, r.model.groups[(size_t)s.group], "TIME_ON") == s.time;
                if (same) groups.push_back(s.group);
                else ++moved;
            }
            if (!groups.empty())
                adifhost::apply(h, adif::markUploaded(text, r.model, groups, u.service, utcNow("%Y%m%d"), lengthUnit(), utf8(h)));
        } else {
            for (const Upload::Sent &s : u.sent) ok += s.ok;
            moved = ok;
        }
    } catch (...) {
    }
    adif::UploadFields f = adif::uploadFields(u.service);
    std::string st = summary;
    if (!groups.empty()) st += " Marked " + plural(groups.size(), "record") + " " + f.status + " Y (one undo step).";
    if (moved) st += " " + plural(moved, "record") + " changed or were in another document, so their status was not set.";
    [u.w setStatus:ADIFString(st) severity:severity];
}

void sendNext(Upload &u);

void recordResult(Upload &u, size_t i, bool ok, const std::string &text, int severity) {
    u.sent[i].ok = ok;
    [u.w setCell:text row:(NSInteger)u.sent[i].row column:kColResult];
    [u.w setRowSeverity:severity row:(NSInteger)u.sent[i].row];
}

// QRZ and eQSL take one QSO per request: send them one after another.
void sendNext(Upload &u) {
    if (u.cancelled || !u.fatal.empty() || u.next >= u.sent.size()) {
        size_t ok = 0;
        for (const Upload::Sent &s : u.sent) ok += s.ok;
        std::string summary = u.fatal.empty() ? (u.cancelled ? "Stopped. " : "") + std::string("Sent ") + std::to_string(ok) +
                                                     " of " + std::to_string(u.sent.size()) + " to " +
                                                     adif::uploadServiceName(u.service) + "."
                                              : u.fatal + " Sent " + std::to_string(ok) + " before that.";
        finish(u, summary, !u.fatal.empty() ? 2 : ok == u.sent.size() ? 3 : 1);
        return;
    }
    size_t i = u.next++;
    [u.w setStatus:ADIFString("Sending " + std::to_string(i + 1) + " of " + std::to_string(u.sent.size()) + ": " + u.sent[i].call +
                              "...")
             severity:-1];
    Upload *pu = &u;
    auto later = ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sendNext(*pu); });
    };
    if (u.service == adif::UploadService::QRZ) {
        // M (changed since upload), or sending again one already uploaded: replace QRZ's copy.
        bool replace = u.items[u.sent[i].row].replace || u.items[u.sent[i].row].done;
        ADIFQrzLogbookInsert(agent(), ADIFString(u.sent[i].adi), replace, ^(NSString *reply, NSString *error) {
            if (error) {
                recordResult(*pu, i, false, "not sent: " + ADIFStd(error), 2);
                pu->fatal = "Stopped: " + ADIFStd(error) + ".";
            } else {
                adif::QrzReply q = adif::parseQrzReply(ADIFStd(reply));
                if (q.ok()) recordResult(*pu, i, true, q.result == "REPLACE" ? "replaced (LOGID " + q.logid + ")" : "uploaded (LOGID " + q.logid + ")", 3);
                else if (q.duplicate()) recordResult(*pu, i, true, "already in the logbook", 3);
                else if (q.result == "AUTH" || q.result.empty()) {
                    recordResult(*pu, i, false, "refused", 2);
                    pu->fatal = "QRZ.com refused the upload" + (q.reason.empty() ? std::string(".") : ": " + q.reason + ".") +
                                " Check the API key in Settings.";
                } else {
                    recordResult(*pu, i, false, "rejected: " + q.reason, 2);
                }
            }
            later();
        });
    } else {
        std::string file = u.sent[i].adi;
        ADIFEqslUpload(agent(), ADIFString(file), @"adiflint.adi", ^(NSString *reply, NSString *error) {
            if (error) {
                recordResult(*pu, i, false, "not sent: " + ADIFStd(error), 2);
                pu->fatal = "Stopped: " + ADIFStd(error) + ".";
            } else {
                adif::EqslReply e = adif::parseEqslReply(ADIFStd(reply));
                if (!e.errors.empty()) {
                    recordResult(*pu, i, false, "error: " + e.errors.front(), 2);
                    pu->fatal = "eQSL: " + e.errors.front() + ".";  // sign-in or service errors stop the run
                } else if (e.added == 1) {
                    recordResult(*pu, i, true, "uploaded", 3);
                } else if (e.duplicate) {
                    recordResult(*pu, i, true, "already on eQSL", 3);
                } else {
                    recordResult(*pu, i, false, "rejected: " + (e.warnings.empty() ? std::string("no result") : e.warnings.front()), 2);
                }
            }
            later();
        });
    }
}

void startUpload(Upload &u) {
    if (u.running) return;
    try {
        NppHandle h = scintilla();
        if (buffer() != u.buffer) {
            plan(u);
            [u.w setStatus:@"The log changed; check the list, then Upload again." severity:1];
            return;
        }
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        std::vector<bool> ticks = [u.w ticked];
        u.sent.clear();
        u.next = 0;
        u.fatal.clear();
        u.cancelled = false;
        std::string nick = u.nickname ? ADIFStd(u.nickname.stringValue) : std::string();
        if (u.nickname) setSetting("eqslNickname", nick);
        std::string header = adif::uploadFile(text, r.model, {}, ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"));
        for (size_t row = 0; row < u.items.size() && row < ticks.size(); ++row) {
            const adif::UploadItem &i = u.items[row];
            if (!ticks[row] || !i.problem.empty()) continue;
            if (i.group < 0 || (size_t)i.group >= r.model.groups.size() ||
                !adif::equalsNoCase(adif::groupValue(text, r.model, r.model.groups[(size_t)i.group], "CALL"), i.call)) {
                plan(u);
                [u.w setStatus:@"The log changed; check the list, then Upload again." severity:1];
                return;
            }
            Upload::Sent s;
            s.row = row;
            s.group = i.group;
            s.call = i.call;
            s.date = i.date;
            s.time = i.time;
            s.adi = adif::recordAdi(text, r.model, i.group);
            if (u.service == adif::UploadService::EQSL) {
                if (!nick.empty())
                    s.adi.insert(s.adi.size() - 5, adif::makeSpecifier("APP_EQSL_QTH_NICKNAME", nick, adif::LengthUnit::Bytes, true) + " ");
                s.adi = header + s.adi + "\n";
            }
            u.sent.push_back(s);
            [u.w setCell:"" row:(NSInteger)row column:kColResult];
        }
        if (u.sent.empty()) {
            [u.w setStatus:@"Nothing is ticked." severity:1];
            return;
        }
        setRunning(u, true);
        Upload *pu = &u;
        std::vector<int> groups;
        for (const Upload::Sent &s : u.sent) groups.push_back(s.group);
        switch (u.service) {
            case adif::UploadService::QRZ:
            case adif::UploadService::EQSL: sendNext(u); break;
            case adif::UploadService::ClubLog: {
                std::string call = ADIFStd(u.callsign.stringValue);
                for (char &c : call) c = (char)std::toupper((unsigned char)c);
                if (call.empty()) {
                    setRunning(u, false);
                    [u.w setStatus:@"Enter the Club Log callsign to upload into." severity:2];
                    return;
                }
                setSetting("clublogCall", call);
                std::string file = adif::uploadFile(text, r.model, groups, ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"));
                [u.w setStatus:ADIFString("Sending " + plural(groups.size(), "QSO") + " to Club Log...") severity:-1];
                ADIFClubLogUpload(agent(), ADIFString(call), ADIFString(file), @"adiflint.adi",
                                  ^(NSInteger status, NSString *message, NSString *error) {
                                      bool ok = !error && status == 200;
                                      std::string msg = ADIFStd(message);
                                      for (size_t i = 0; i < pu->sent.size(); ++i)
                                          recordResult(*pu, i, ok, ok ? "queued at Club Log" : "not sent", ok ? 3 : 2);
                                      if (ok)
                                          finish(*pu, "Club Log accepted " + plural(pu->sent.size(), "QSO") +
                                                          "; it processes uploads within a minute or so.",
                                                 3);
                                      else
                                          finish(*pu, error ? "Club Log: " + ADIFStd(error) + "."
                                                            : "Club Log refused the upload (HTTP " + std::to_string(status) + ")" +
                                                                  (msg.empty() ? "." : ": " + msg) +
                                                                  (status == 403 ? " Check the email, Application Password and API "
                                                                                   "key in Settings before trying again."
                                                                                 : ""),
                                                 2);
                                  });
                break;
            }
            case adif::UploadService::LoTW: {
                std::string tq = tqslPath();
                std::string loc = ADIFStd(u.location.stringValue);
                if (tq.empty() || access(tq.c_str(), X_OK) != 0) {
                    setRunning(u, false);
                    [u.w setStatus:@"TQSL was not found. Install it from lotw.arrl.org, or choose where it is." severity:2];
                    return;
                }
                if (loc.empty()) {
                    setRunning(u, false);
                    [u.w setStatus:@"Enter the TQSL Station Location to sign with (as named in TQSL)." severity:2];
                    return;
                }
                setSetting("tqslLocation", loc);
                std::string file = adif::uploadFile(text, r.model, groups, ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"));
                NSString *tmp = [NSTemporaryDirectory()
                    stringByAppendingPathComponent:[NSString stringWithFormat:@"adiflint-lotw-%@.adi", [NSUUID UUID].UUIDString]];
                if (![[NSData dataWithBytes:file.data() length:file.size()] writeToFile:tmp atomically:YES]) {
                    setRunning(u, false);
                    [u.w setStatus:@"Could not write the file for TQSL." severity:2];
                    return;
                }
                chmod(tmp.fileSystemRepresentation, 0600);
                [u.w setStatus:ADIFString("TQSL is signing and uploading " + plural(groups.size(), "QSO") + "...") severity:-1];
                // -x batch, -d no date dialog, -u upload, -a compliant: sign valid QSOs, skip duplicates and out-of-range ones.
                NSMutableArray *args = [@[ @"-x", @"-d", @"-u", @"-a", @"compliant", @"-l", ADIFString(loc) ] mutableCopy];
                if (NSString *pw = ADIFTqslPassword()) [args addObjectsFromArray:@[ @"-p", pw ]];  // TQSL's documented -p
                [args addObject:tmp];
                runTqsl(tq, args, &u,
                        ^(int code, NSString *output) {
                            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
                            std::string out = ADIFStd([output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
                            if (out.size() > 600) out = "..." + out.substr(out.size() - 600);
                            bool ok = code == 0;
                            for (size_t i = 0; i < pu->sent.size(); ++i)
                                recordResult(*pu, i, ok, ok ? "uploaded" : "see below", ok ? 3 : code == 9 || code == 8 ? 1 : 2);
                            std::string meaning = code < 0 ? ADIFStd(output) : adif::tqslExitMeaning(code);
                            std::string summary = "TQSL: " + meaning + "." +
                                                  (!ok && code >= 0 && !out.empty() ? " Its report: " + out : "") +
                                                  (code == 8 || code == 9
                                                       ? " Records were not marked, since TQSL does not say which QSOs it "
                                                         "skipped."
                                                       : "");
                            finish(*pu, summary, ok ? 3 : code == 9 ? 1 : 2);
                        });
                break;
            }
        }
    } catch (...) {
        setRunning(u, false);
        [u.w setStatus:@"Something went wrong preparing the upload." severity:2];
    }
}

void openUpload(adif::UploadService s) {
    Upload &u = up(s);
    u.service = s;
    if (!u.w) {
        NSString *title = [NSString stringWithFormat:@"Upload to %s", adif::uploadServiceName(s)];
        if (s == adif::UploadService::LoTW) title = @"Upload to LoTW (TQSL)";
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:title size:NSMakeSize(860, 560) headline:NO];
        u.w = w;
        Upload *pu = &u;
        [w addOptionRow:@[ ADIFLabel(@"Upload to:"), families::popup(families::kUpload, (NSInteger)s) ]];
        if (s != adif::UploadService::LoTW) {
            u.account = ADIFLabel(@"");
            u.account.lineBreakMode = NSLineBreakByTruncatingTail;
            NSButton *settings = [NSButton buttonWithTitle:@"Settings..." target:nil action:nil];
            ADIFOnAction(settings, ^{
                openSettings(s == adif::UploadService::QRZ ? ADIFSourceQRZLogbook
                             : s == adif::UploadService::ClubLog ? ADIFSourceClubLog
                                                                 : ADIFSourceEQSL);
            });
            [w addOptionRow:@[ ADIFLabel(@"Account:"), u.account, settings ]];
        }
        if (s == adif::UploadService::ClubLog) {
            u.callsign = ADIFTextField(@"e.g. K1ABC", 120);
            [w addOptionRow:@[ ADIFLabel(@"Upload into the Club Log log for callsign:"), u.callsign ]];
        }
        if (s == adif::UploadService::EQSL) {
            u.nickname = ADIFTextField(@"optional", 160);
            u.nickname.stringValue = ADIFString(setting("eqslNickname"));
            u.nickname.toolTip = @"Only when you have several eQSL accounts with the same callsign: the QTH Nickname of the "
                                 @"one to upload into (sent as APP_EQSL_QTH_NICKNAME).";
            [w addOptionRow:@[ ADIFLabel(@"QTH Nickname:"), u.nickname ]];
        }
        if (s == adif::UploadService::LoTW) {
            u.tqsl = ADIFLabel(@"");
            u.tqsl.lineBreakMode = NSLineBreakByTruncatingMiddle;
            [u.tqsl.widthAnchor constraintLessThanOrEqualToConstant:460].active = YES;
            NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
            ADIFOnAction(choose, ^{
                std::string p;
                if (const char *env = getenv("ADIFLINT_TEST_OPEN_FILE")) p = env;
                else {
                    NSOpenPanel *op = [NSOpenPanel openPanel];
                    op.message = @"Choose TQSL (tqsl.app)";
                    op.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
                    op.treatsFilePackagesAsDirectories = NO;
                    if ([op runModal] != NSModalResponseOK || !op.URL) return;
                    p = ADIFStd(op.URL.path);
                }
                if (p.size() > 4 && p.substr(p.size() - 4) == ".app") p += "/Contents/MacOS/tqsl";
                setSetting("tqslPath", p);
                plan(*pu);
            });
            [w addOptionRow:@[ ADIFLabel(@"TQSL:"), u.tqsl, choose ]];
            u.location = ADIFComboBox(tqslLocations(), 220);
            u.location.stringValue = ADIFString(setting("tqslLocation"));
            u.location.placeholderString = @"as named in TQSL";
            [w addOptionRow:@[ ADIFLabel(@"Station Location:"), u.location,
                               ADIFLabel(@"(TQSL signs with this location's callsign certificate)") ]];
        }
        u.includeDone = ADIFCheckbox(@"Also list QSOs already sent", NO);
        u.selectionOnly = ADIFCheckbox(@"Only the records in the editor selection", NO);
        ADIFOnAction(u.includeDone, ^{ plan(*pu); });
        ADIFOnAction(u.selectionOnly, ^{ plan(*pu); });
        [w addOptionRow:@[ u.includeDone, u.selectionOnly ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"record", "Record", 56}, {"call", "Call", 84}, {"date", "Date", 80},
                                                  {"time", "Time", 56}, {"band", "Band", 50}, {"mode", "Mode", 60},
                                                  {"status", "Status", 140}, {"result", "Result", 250}}
            checkboxes:YES
              sortable:NO];
        [w addButton:@"Refresh" trailing:NO action:^{ plan(*pu); }];
        [w addButton:@"Tick All" trailing:NO action:^{ [pu->w setAllTicked:YES]; }];
        [w addButton:@"Untick All" trailing:NO action:^{ [pu->w setAllTicked:NO]; }];
        [w addButton:@"Copy ADIF" trailing:NO action:^{
            try {
                NppHandle h = scintilla();
                const adif::LintResult &r = lint(h);
                std::vector<bool> ticks = [pu->w ticked];
                std::vector<int> groups;
                for (size_t i = 0; i < pu->items.size() && i < ticks.size(); ++i)
                    if (ticks[i] && pu->items[i].problem.empty()) groups.push_back(pu->items[i].group);
                std::string file = adif::uploadFile(adifhost::text(h), r.model, groups, ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"));
                [NSPasteboard.generalPasteboard clearContents];
                [NSPasteboard.generalPasteboard setString:ADIFString(file) forType:NSPasteboardTypeString];
                [pu->w setStatus:ADIFString("Copied the ADIF of the " + plural(groups.size(), "ticked QSO") +
                                            ", as it would be sent (without passwords or keys).")
                         severity:-1];
            } catch (...) {
            }
        }];
        u.stop = [w addButton:@"Stop" trailing:YES action:^{
            pu->cancelled = true;
            if (pu->task.running) [pu->task terminate];
        }];
        u.upload = [w addButton:@"Upload" trailing:YES action:^{ startUpload(*pu); }];
        [w setDefaultButton:u.upload];
        w.onTicksChanged = ^{ updateUploadButton(*pu); };
        w.onClose = ^{
            pu->cancelled = true;  // a QRZ or eQSL run stops after the current QSO
        };
        setRunning(u, false);
    }
    if (u.callsign && !u.callsign.stringValue.length) {
        std::string call = setting("clublogCall");
        if (call.empty()) {
            try {
                NppHandle h = scintilla();
                for (const adif::Record &r : adif::records(adifhost::text(h), lint(h).model))
                    if (!(call = adif::stationCall(r)).empty()) break;
            } catch (...) {
            }
        }
        u.callsign.stringValue = ADIFString(call);
    }
    if (!u.running) plan(u);
    [u.w show];
}

}  // namespace

namespace uploads {

void cmdUploadQrz() { openUpload(adif::UploadService::QRZ); }
void cmdUploadLotw() { openUpload(adif::UploadService::LoTW); }
void cmdUploadClubLog() { openUpload(adif::UploadService::ClubLog); }
void cmdUploadEqsl() { openUpload(adif::UploadService::EQSL); }

void documentChanged() {
    static int64_t token = 0;
    int64_t mine = ++token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine != token) return;
        for (Upload &u : ups)
            if (u.w && u.w.window.visible && !u.running && !u.results) plan(u, true);
    });
}

}  // namespace uploads
