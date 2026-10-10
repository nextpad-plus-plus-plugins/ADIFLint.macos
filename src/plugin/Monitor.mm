#import "Monitor.h"

#import "PluginHost.h"
#import "ToolWindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "adif_capture.h"
#include "adif_tools.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <ctime>
#include <deque>
#include <memory>

using namespace adifhost;

namespace monitor {
namespace {

constexpr size_t kMaxMessage = 64 * 1024;  // a datagram, or what one TCP connection may send
constexpr size_t kMaxTcpClients = 4;
constexpr double kTcpIdleSeconds = 30;
constexpr int kMaxPerSecond = 20;          // messages per source; more are dropped
constexpr double kWsjtxPairSeconds = 1.5;  // QSO Logged waits this long for its Logged ADIF
constexpr size_t kMaxRows = 500;
constexpr double kPollSeconds = 2;
constexpr off_t kMaxFileRead = 8 << 20;

enum Source { kWsjtx, kAdif, kN1mm, kTcp, kSourceCount };
struct SourceDef {
    const char *name, *enableKey, *portKey;
    int port;
    bool on;
};
// WSJT-X's UDP Server port (2237), the usual ADIF broadcast port (2333), N1MM Logger+'s
// contact broadcast (12060), and DXKeeper's log-command port (52001: GridTracker sends
// to its DXKeeper port + 1).
const SourceDef kSources[kSourceCount] = {
    {"WSJT-X", "monitorWsjtx", "monitorWsjtxPort", 2237, true},
    {"ADIF", "monitorAdif", "monitorAdifPort", 2333, true},
    {"N1MM", "monitorN1mm", "monitorN1mmPort", 12060, false},
    {"TCP", "monitorTcp", "monitorTcpPort", 52001, false},
};

// ── Settings ──

bool enabled(Source s) {
    std::string v = setting(kSources[s].enableKey);
    return v.empty() ? kSources[s].on : v == "1";
}
int defaultPort(Source s) {
    if (const char *base = getenv("ADIFLINT_TEST_PORTS")) return std::atoi(base) + (int)s;  // the tests' own ports
    return kSources[s].port;
}
int port(Source s) {
    int p = std::atoi(setting(kSources[s].portKey).c_str());
    return p > 0 && p < 65536 ? p : defaultPort(s);
}
bool remoteAllowed() { return setting("monitorRemote") == "1"; }
std::string target() { return setting("monitorTarget"); }
std::string baseName(const std::string &p) {
    size_t slash = p.find_last_of('/');
    return slash == std::string::npos ? p : p.substr(slash + 1);
}
std::vector<std::string> split(const std::string &s, char sep) {
    std::vector<std::string> out;
    size_t b = 0;
    while (b <= s.size()) {
        size_t e = s.find(sep, b);
        if (e == std::string::npos) e = s.size();
        if (e > b) out.push_back(s.substr(b, e - b));
        b = e + 1;
    }
    return out;
}
std::string join(const std::vector<std::string> &v, const char *sep) {
    std::string out;
    for (const std::string &s : v) out += (out.empty() ? "" : sep) + s;
    return out;
}
std::vector<std::string> watchedFiles() { return split(setting("monitorFiles"), '|'); }
std::string plural(size_t n, const char *what) { return std::to_string(n) + " " + what + (n == 1 ? "" : "s"); }

// ── State ──

struct Listener {
    int fd = -1;
    dispatch_source_t source = nil;
    std::string status;
    int severity = -1;
    size_t messages = 0;
    double windowStart = 0;
    int windowCount = 0;
};
struct TcpClient {
    int fd = -1;
    dispatch_source_t read = nil, idle = nil;
    std::string buffer;
    double last = 0;
};
struct Watch {
    std::string path;
    dispatch_source_t vnode = nil;
    ino_t inode = 0;
    off_t offset = 0;
    bool seen = false;  // the file existed when last looked at
    std::string status;
};
struct Row {
    std::string when, source, call, date, time, band, mode, result;
    int severity = -1;
    adif::CapturedQso qso;
    bool queued = false;
    std::string log;  // where it went
    int record = 0;
};
struct Pending {
    uint64_t id = 0;
    adif::CapturedQso qso;
};

struct State {
    bool running = false;
    Listener listeners[kSourceCount];
    std::vector<std::shared_ptr<TcpClient>> clients;
    std::vector<std::shared_ptr<Watch>> watches;
    dispatch_source_t poll = nil;
    std::vector<in_addr_t> local;  // this Mac's addresses
    std::deque<Row> rows;          // newest first
    std::vector<Pending> pending;  // WSJT-X QSO Logged, waiting for its Logged ADIF
    uint64_t nextId = 1;
    std::deque<std::pair<std::string, double>> logged12;  // client|CALL of Logged ADIF messages, with when
    std::vector<adif::CapturedQso> memoryQueue;            // when the host has no config folder
    std::string note;  // the last thing that happened, for the status line
    int noteSeverity = -1;
    int closing = 0;  // listening sockets still closing: a restart waits for their ports
    bool startWhenClosed = false;

    ADIFToolWindow *w = nil;
    NSTextField *targetLabel = nil, *filesLabel = nil, *multicast = nil;
    NSButton *checks[kSourceCount] = {};
    NSTextField *ports[kSourceCount] = {};
    NSButton *remote = nil, *autoStart = nil, *startStop = nil, *flush = nil;
} m;

double now() { return CFAbsoluteTimeGetCurrent(); }

std::string localTime() {
    time_t t = time(nullptr);
    struct tm tm{};
    localtime_r(&t, &tm);
    char buf[16];
    strftime(buf, sizeof buf, "%H:%M:%S", &tm);
    return buf;
}

std::string field(const adif::CapturedQso &q, const char *name) {
    for (const auto &f : q.fields)
        if (f.first == name) return f.second;
    return {};
}

std::vector<in_addr_t> localAddresses() {
    std::vector<in_addr_t> out;
    struct ifaddrs *list = nullptr;
    if (getifaddrs(&list) != 0) return out;
    for (struct ifaddrs *i = list; i; i = i->ifa_next)
        if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET) out.push_back(((sockaddr_in *)i->ifa_addr)->sin_addr.s_addr);
    freeifaddrs(list);
    return out;
}

bool isLocal(const sockaddr_in &a) {
    if ((ntohl(a.sin_addr.s_addr) >> 24) == 127) return true;
    return std::find(m.local.begin(), m.local.end(), a.sin_addr.s_addr) != m.local.end();
}

void refresh();
void route(std::vector<adif::CapturedQso> qsos, bool quietDuplicates);
void startAll();

// A listening socket's source was cancelled and its socket closed.
void listenerClosed() {
    if (--m.closing == 0 && m.startWhenClosed) {
        m.startWhenClosed = false;
        startAll();
    }
}

// ── The queue: QSOs waiting for their log, kept in a file so nothing is lost ──

std::string queuePath() {
    std::string dir = configDir();
    return dir.empty() ? std::string() : dir + "/ADIFLint-queue.adi";
}

std::vector<adif::CapturedQso> loadQueue() {
    std::string p = queuePath();
    if (p.empty()) return m.memoryQueue;
    NSData *d = [NSData dataWithContentsOfFile:ADIFString(p)];
    if (!d.length) return {};
    return adif::parseQueue(std::string((const char *)d.bytes, d.length));
}

void saveQueue(const std::vector<adif::CapturedQso> &q) {
    std::string p = queuePath();
    if (p.empty()) {
        m.memoryQueue = q;
        return;
    }
    if (q.empty()) {
        [[NSFileManager defaultManager] removeItemAtPath:ADIFString(p) error:nil];
        return;
    }
    std::string text = adif::queueText(q, ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"));
    [[NSData dataWithBytes:text.data() length:text.size()] writeToFile:ADIFString(p) options:NSDataWritingAtomic error:nil];
}

size_t queuedCount() {
    std::string p = queuePath();
    if (p.empty()) return m.memoryQueue.size();
    if (![[NSFileManager defaultManager] fileExistsAtPath:ADIFString(p)]) return 0;
    return loadQueue().size();
}

// ── Writing to the chosen log ──

enum class Where { Active, Disk, Queue };

Where whereTo(std::string *why) {
    std::string t = target();
    if (t.empty()) {
        *why = "no log chosen";
        return Where::Queue;
    }
    if (path() == t) return Where::Active;
    bool known = false;
    std::vector<std::string> open = openFiles(&known);
    if (!known) {
        *why = baseName(t) + " may be open in Nextpad++; switch to it";
        return Where::Queue;
    }
    if (std::find(open.begin(), open.end(), t) != open.end()) {
        *why = baseName(t) + " is open in another tab; switch to it";
        return Where::Queue;
    }
    return Where::Disk;
}

adif::CaptureFormat format(const std::string &eol, bool utf8) {
    adif::CaptureFormat f;
    f.eol = eol;
    f.unit = lengthUnit();
    f.utf8 = utf8;
    f.programVersion = ADIFLINT_VERSION;
    f.timestamp = utcNow("%Y%m%d %H%M%S");
    return f;
}

bool writeActive(const std::vector<adif::CapturedQso> &qsos, std::vector<adif::CaptureOutcome> *outs, std::string *why) {
    NppHandle h = scintilla();
    if (readOnly(h)) {
        *why = "the log is read-only";
        return false;
    }
    std::string before(text(h)), after = before;
    if (!adif::applyCaptured(after, qsos, format(eol(h), utf8(h)), outs, why)) return false;
    if (after != before) apply(h, {adif::minimalEdit(before, after)});
    return true;
}

bool writeDisk(const std::vector<adif::CapturedQso> &qsos, std::vector<adif::CaptureOutcome> *outs, std::string *why) {
    NSString *file = ADIFString(target());
    std::string before;
    if ([[NSFileManager defaultManager] fileExistsAtPath:file]) {
        NSData *d = [NSData dataWithContentsOfFile:file];
        if (!d) {
            *why = "can't read " + baseName(target());
            return false;
        }
        before.assign((const char *)d.bytes, d.length);
    }
    std::string after = before;
    if (!adif::applyCaptured(after, qsos, format(before.find("\r\n") != std::string::npos ? "\r\n" : "\n", true), outs, why))
        return false;
    if (after == before) return true;
    NSError *error = nil;
    if (![[NSData dataWithBytes:after.data() length:after.size()] writeToFile:file options:NSDataWritingAtomic error:&error]) {
        *why = "can't write " + baseName(target()) + ": " + ADIFStd(error.localizedDescription ?: @"?");
        return false;
    }
    return true;
}

void addRow(const adif::CapturedQso &q, const std::string &result, int severity, bool queued = false, int record = 0) {
    Row r;
    r.when = localTime();
    r.source = q.source;
    r.call = field(q, "CALL");
    r.date = field(q, "QSO_DATE");
    r.time = field(q, "TIME_ON").substr(0, 4);
    r.band = field(q, "BAND");
    std::string sub = field(q, "SUBMODE");
    r.mode = sub.empty() ? field(q, "MODE") : sub;
    r.result = result;
    r.severity = severity;
    r.qso = q;
    r.queued = queued;
    r.log = target();
    r.record = record;
    m.rows.push_front(std::move(r));
    while (m.rows.size() > kMaxRows) m.rows.pop_back();
}

std::string outcomeText(const adif::CaptureOutcome &o, bool disk, int *severity) {
    std::string where = disk ? " (in the file)" : "";
    *severity = 3;
    switch (o.result) {
        case adif::CaptureResult::Added: return "Added as record " + std::to_string(o.record) + where;
        case adif::CaptureResult::Replaced: return "Replaced record " + std::to_string(o.record) + where;
        case adif::CaptureResult::Deleted: return "Deleted record " + std::to_string(o.record) + where;
        case adif::CaptureResult::Duplicate: *severity = 0; return "Already in the log (record " + std::to_string(o.record) + ")";
        case adif::CaptureResult::NotFound: *severity = 1; return "Not in the log, nothing to change";
    }
    return "";
}

// Queued rows got written: say where.
void markQueuedRows(const std::vector<adif::CaptureOutcome> &outs, size_t count, bool disk) {
    // The queue is in arrival order; rows are newest first.
    std::vector<Row *> queued;
    for (auto it = m.rows.rbegin(); it != m.rows.rend(); ++it)
        if (it->queued) queued.push_back(&*it);
    for (size_t i = 0; i < queued.size(); ++i) {
        queued[i]->queued = false;
        size_t k = i + (count > queued.size() ? count - queued.size() : 0);
        if (k < outs.size() && k < count) {
            queued[i]->result = outcomeText(outs[k], disk, &queued[i]->severity) + ", from the queue";
            queued[i]->record = outs[k].record;
        } else {
            queued[i]->result = "Added from the queue";
            queued[i]->severity = 3;
        }
        queued[i]->log = target();
    }
}

// Add to the queue: not the same QSO as one already waiting, nor one the log's file has.
void enqueue(const std::vector<adif::CapturedQso> &qsos, const std::string &why, int severity, bool quietDuplicates) {
    std::vector<adif::CapturedQso> queue = loadQueue();
    std::vector<adif::Record> known;
    for (const adif::CapturedQso &q : queue) {
        adif::Record r;
        r.fields = q.fields;
        known.push_back(r);
    }
    if (!target().empty())
        if (NSData *d = [NSData dataWithContentsOfFile:ADIFString(target())]) {
            std::string t((const char *)d.bytes, d.length);
            adif::LintOptions opt;
            opt.buildModel = true;
            opt.maxDiagnostics = 0;
            adif::LintResult r = adif::lint(t, opt);
            for (adif::Record &rec : adif::records(t, r.model)) known.push_back(std::move(rec));
        }
    adif::DupeOptions dupe;
    for (const adif::CapturedQso &q : qsos) {
        adif::Record cand;
        cand.fields = q.fields;
        bool dup = false;
        if (q.kind == adif::CapturedQso::Kind::Add)
            for (const adif::Record &k : known) dup = dup || adif::sameQso(k, cand, dupe);
        if (dup) {
            if (!quietDuplicates) addRow(q, "Already waiting or in the log", 0);
            continue;
        }
        queue.push_back(q);
        known.push_back(cand);
        addRow(q, "Queued: " + why, severity, true);
    }
    saveQueue(queue);
}

// Write the queue and these QSOs to the log, or queue them all with the reason.
void deliver(const std::vector<adif::CapturedQso> &qsos, bool quietDuplicates) {
    if (qsos.empty() && !queuedCount()) return;
    std::string why;
    Where where = whereTo(&why);
    if (where == Where::Queue) {
        if (!qsos.empty()) enqueue(qsos, why, 1, quietDuplicates);
        m.note = plural(queuedCount(), "QSO") + " waiting: " + why + ".";
        m.noteSeverity = 1;
        return;
    }
    std::vector<adif::CapturedQso> all = loadQueue();
    size_t fromQueue = all.size();
    all.insert(all.end(), qsos.begin(), qsos.end());
    if (all.empty()) return;
    std::vector<adif::CaptureOutcome> outs;
    bool ok = where == Where::Active ? writeActive(all, &outs, &why) : writeDisk(all, &outs, &why);
    if (!ok) {
        if (!qsos.empty()) enqueue(qsos, why, 2, quietDuplicates);
        m.note = "Can't add to " + baseName(target()) + ": " + why;
        m.noteSeverity = 2;
        return;
    }
    bool disk = where == Where::Disk;
    if (fromQueue) {
        saveQueue({});
        markQueuedRows(outs, fromQueue, disk);
    }
    for (size_t i = 0; i < qsos.size() && fromQueue + i < outs.size(); ++i) {
        const adif::CaptureOutcome &o = outs[fromQueue + i];
        if (o.result == adif::CaptureResult::Duplicate && quietDuplicates) continue;
        int severity = -1;
        std::string text = outcomeText(o, disk, &severity);
        addRow(qsos[i], text, severity, false, o.record);
    }
    size_t total = 0;
    for (const adif::CaptureOutcome &o : outs) total += o.result == adif::CaptureResult::Added;
    if (total) {
        m.note = "Added " + plural(total, "QSO") + " to " + baseName(target()) + (disk ? " (written to the file)." : ".");
        m.noteSeverity = 3;
    }
}

void route(std::vector<adif::CapturedQso> qsos, bool quietDuplicates) {
    std::vector<adif::CapturedQso> good;
    for (adif::CapturedQso &q : qsos) {
        if (q.kind != adif::CapturedQso::Kind::Delete && !q.problem.empty()) {
            addRow(q, "Not logged: " + q.problem, 2);
            continue;
        }
        // The same QSO from two sources at once (WSJT-X's UDP message and its log file).
        bool twice = false;
        if (q.kind == adif::CapturedQso::Kind::Add) {
            adif::Record cand;
            cand.fields = q.fields;
            adif::DupeOptions dupe;
            size_t looked = 0;
            for (const Row &r : m.rows) {
                if (++looked > 200) break;
                if (r.severity == 2 || r.qso.kind != adif::CapturedQso::Kind::Add) continue;
                adif::Record seen;
                seen.fields = r.qso.fields;
                if (adif::sameQso(seen, cand, dupe) && r.source != q.source) {
                    twice = true;
                    break;
                }
            }
        }
        if (twice) {
            if (!quietDuplicates) addRow(q, "Same QSO as from another source just now", 0);
            continue;
        }
        good.push_back(std::move(q));
    }
    if (!good.empty()) deliver(good, quietDuplicates);
    refresh();
}

// ── WSJT-X: QSO Logged (5) and Logged ADIF (12) come together; the ADIF one is kept ──

void receivedWsjtx(std::vector<adif::CapturedQso> qsos) {
    double t = now();
    while (!m.logged12.empty() && t - m.logged12.front().second > 10) m.logged12.pop_front();
    for (adif::CapturedQso &q : qsos) {
        std::string key = q.client + "|" + field(q, "CALL");
        if (q.wsjtxType == 12) {
            m.pending.erase(std::remove_if(m.pending.begin(), m.pending.end(),
                                           [&](const Pending &p) { return p.qso.client + "|" + field(p.qso, "CALL") == key; }),
                            m.pending.end());
            m.logged12.emplace_back(key, t);
            route({q}, false);
            continue;
        }
        bool logged = std::any_of(m.logged12.begin(), m.logged12.end(), [&](const auto &k) { return k.first == key; });
        if (logged) continue;
        uint64_t id = m.nextId++;
        m.pending.push_back({id, q});
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWsjtxPairSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            auto it = std::find_if(m.pending.begin(), m.pending.end(), [&](const Pending &p) { return p.id == id; });
            if (it == m.pending.end()) return;
            adif::CapturedQso held = it->qso;
            m.pending.erase(it);
            route({held}, false);
        });
    }
}

bool allow(Listener &l) {
    double t = now();
    if (t - l.windowStart >= 1) l.windowStart = t, l.windowCount = 0;
    return ++l.windowCount <= kMaxPerSecond;
}

// A message arrived. Most carry no QSO (WSJT-X sends a datagram per decode, JS8Call its
// activity): those are dropped quietly; only messages with QSOs count toward the limit.
void received(Source s, const std::string &bytes) {
    Listener &l = m.listeners[s];
    const char *hint = s == kTcp ? "Logger over TCP" : s == kN1mm ? "N1MM Logger+" : s == kWsjtx ? "WSJT-X" : "ADIF over UDP";
    std::vector<adif::CapturedQso> qsos = adif::parseCapture(bytes, hint);
    if (qsos.empty()) return;
    if (!allow(l)) {
        m.note = std::string(kSources[s].name) + ": more than " + std::to_string(kMaxPerSecond) + " QSOs a second; the rest dropped.";
        m.noteSeverity = 1;
        refresh();
        return;
    }
    ++l.messages;
    bool wsjtx = std::any_of(qsos.begin(), qsos.end(), [](const adif::CapturedQso &q) { return q.wsjtxType != 0; });
    if (wsjtx) receivedWsjtx(std::move(qsos));
    else route(std::move(qsos), false);
}

// ── UDP ──

void setNonBlocking(int fd) {
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
}

int openUdp(Source s, int p, std::string *problem) {
    std::string group = s == kWsjtx ? setting("monitorMulticast") : std::string();
    in_addr groupAddr{};
    bool multicast = !group.empty();
    if (multicast && (inet_pton(AF_INET, group.c_str(), &groupAddr) != 1 || !IN_MULTICAST(ntohl(groupAddr.s_addr)))) {
        *problem = group + " is not a multicast group (224.0.0.0 to 239.255.255.255)";
        return -1;
    }
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        *problem = std::strerror(errno);
        return -1;
    }
    int on = 1;
    // Sharing the port is right for a multicast group (every listener gets each datagram);
    // for one address it would take datagrams away from the program already listening.
    if (multicast) {
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof on);
    }
    setNonBlocking(fd);
    sockaddr_in a{};
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)p);
    a.sin_addr.s_addr = htonl(multicast || remoteAllowed() ? INADDR_ANY : INADDR_LOOPBACK);
    if (bind(fd, (sockaddr *)&a, sizeof a) != 0) {
        int e = errno;
        close(fd);
        if (e == EADDRINUSE)
            *problem = "port " + std::to_string(p) + " is in use by another program" +
                       (s == kWsjtx && !multicast ? " (GridTracker or JTAlert?); use a multicast group in WSJT-X and here" : "");
        else
            *problem = "can't listen on port " + std::to_string(p) + ": " + std::strerror(e);
        return -1;
    }
    if (multicast) {
        bool joined = false;
        for (in_addr_t iface : {htonl(INADDR_LOOPBACK), htonl(INADDR_ANY)}) {
            ip_mreq mr{};
            mr.imr_multiaddr = groupAddr;
            mr.imr_interface.s_addr = iface;
            joined |= setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mr, sizeof mr) == 0;
        }
        if (!joined) {
            *problem = "can't join " + group + ": " + std::strerror(errno);
            close(fd);
            return -1;
        }
    }
    return fd;
}

void readUdp(Source s) {
    Listener &l = m.listeners[s];
    static std::vector<char> buf(kMaxMessage + 1);
    for (int i = 0; i < 64 && l.fd >= 0; ++i) {
        sockaddr_in from{};
        socklen_t len = sizeof from;
        ssize_t n = recvfrom(l.fd, buf.data(), buf.size(), 0, (sockaddr *)&from, &len);
        if (n < 0) break;
        if ((size_t)n > kMaxMessage) continue;  // more than a QSO
        if (!remoteAllowed() && !isLocal(from)) continue;
        received(s, std::string(buf.data(), (size_t)n));
    }
}

std::string listenText(Source s, int p) {
    std::string group = s == kWsjtx ? setting("monitorMulticast") : std::string();
    return std::string(kSources[s].name) + " " + (group.empty() ? "" : group + ":") + std::to_string(p);
}

void startUdp(Source s) {
    Listener &l = m.listeners[s];
    std::string problem;
    int p = port(s);
    int fd = openUdp(s, p, &problem);
    if (fd < 0) {
        l.status = std::string(kSources[s].name) + ": " + problem;
        l.severity = 2;
        return;
    }
    l.fd = fd;
    l.messages = 0;
    l.status = listenText(s, p);
    l.severity = -1;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{ readUdp(s); });
    dispatch_source_set_cancel_handler(src, ^{
        close(fd);
        listenerClosed();
    });
    dispatch_resume(src);
    l.source = src;
}

// ── TCP: a command to a logger, or ADIF, per connection ──

// Where the complete messages in a TCP buffer end: after the last <EOR>, or the "}" of HRD's "db add {...}".
size_t completeEnd(const std::string &buf) {
    std::string lower(buf);
    for (char &c : lower) c = (char)std::tolower((unsigned char)c);
    size_t end = 0, eor = lower.rfind("<eor>"), add = lower.rfind("db add");
    if (eor != std::string::npos) end = eor + 5;
    if (add != std::string::npos) {
        size_t close = lower.find('}', add);
        if (close != std::string::npos) end = std::max(end, close + 1);
    }
    return end;
}

void closeClient(const std::shared_ptr<TcpClient> &c, bool parseRest) {
    std::string rest;
    if (parseRest && c->buffer.find_first_not_of(" \t\r\n") != std::string::npos) rest.swap(c->buffer);
    c->buffer.clear();
    if (c->read) dispatch_source_cancel(c->read), c->read = nil;
    if (c->idle) dispatch_source_cancel(c->idle), c->idle = nil;
    m.clients.erase(std::remove(m.clients.begin(), m.clients.end(), c), m.clients.end());
    if (!rest.empty()) received(kTcp, rest);
}

void readTcp(const std::shared_ptr<TcpClient> &c) {
    char buf[16384];
    for (;;) {
        ssize_t n = recv(c->fd, buf, sizeof buf, 0);
        if (n > 0) {
            c->buffer.append(buf, (size_t)n);
            c->last = now();
            if (c->buffer.size() > kMaxMessage) {
                m.note = "TCP: a connection sent more than 64 KB; closed.";
                m.noteSeverity = 1;
                closeClient(c, false);
                refresh();
                return;
            }
            continue;
        }
        if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) {
            closeClient(c, true);  // the sender finished
            return;
        }
        break;
    }
    size_t end = completeEnd(c->buffer);
    if (end) {
        std::string msg = c->buffer.substr(0, end);
        c->buffer.erase(0, end);
        received(kTcp, msg);
    }
}

void acceptTcp() {
    Listener &l = m.listeners[kTcp];
    for (;;) {
        sockaddr_in from{};
        socklen_t len = sizeof from;
        int fd = accept(l.fd, (sockaddr *)&from, &len);
        if (fd < 0) break;
        if ((!remoteAllowed() && !isLocal(from)) || m.clients.size() >= kMaxTcpClients) {
            close(fd);
            continue;
        }
        setNonBlocking(fd);
        auto c = std::make_shared<TcpClient>();
        c->fd = fd;
        c->last = now();
        std::weak_ptr<TcpClient> weak = c;
        c->read = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(c->read, ^{
            if (auto me = weak.lock()) readTcp(me);
        });
        dispatch_source_set_cancel_handler(c->read, ^{ close(fd); });
        c->idle = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(c->idle, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(c->idle, ^{
            auto me = weak.lock();
            if (me && now() - me->last > kTcpIdleSeconds) closeClient(me, true);
        });
        m.clients.push_back(c);
        dispatch_resume(c->read);
        dispatch_resume(c->idle);
    }
}

void startTcp() {
    Listener &l = m.listeners[kTcp];
    int p = port(kTcp);
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);  // listen again at once after a restart
    setNonBlocking(fd);
    sockaddr_in a{};
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)p);
    a.sin_addr.s_addr = htonl(remoteAllowed() ? INADDR_ANY : INADDR_LOOPBACK);
    if (fd < 0 || bind(fd, (sockaddr *)&a, sizeof a) != 0 || listen(fd, (int)kMaxTcpClients) != 0) {
        int e = errno;
        if (fd >= 0) close(fd);
        l.status = "TCP: " + (e == EADDRINUSE ? "port " + std::to_string(p) + " is in use by another program"
                                              : "can't listen on port " + std::to_string(p) + ": " + std::strerror(e));
        l.severity = 2;
        return;
    }
    l.fd = fd;
    l.messages = 0;
    l.status = listenText(kTcp, p);
    l.severity = -1;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{ acceptTcp(); });
    dispatch_source_set_cancel_handler(src, ^{
        close(fd);
        listenerClosed();
    });
    dispatch_resume(src);
    l.source = src;
}

// ── Files another program appends to ──

void saveOffsets() {
    std::vector<std::string> parts;
    for (const auto &w : m.watches) parts.push_back(std::to_string((unsigned long long)w->inode) + ":" + std::to_string((long long)w->offset));
    setSetting("monitorFileOffsets", join(parts, "|"));
}

void readWatch(const std::shared_ptr<Watch> &w);

void openVnode(const std::shared_ptr<Watch> &w) {
    int fd = open(w->path.c_str(), O_EVTONLY);
    if (fd < 0) return;
    std::weak_ptr<Watch> weak = w;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
                                                   DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_DELETE |
                                                       DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
                                                   dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        auto me = weak.lock();
        if (!me) return;
        unsigned long flags = dispatch_source_get_data(src);
        if (flags & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE)) {
            dispatch_source_cancel(src);
            if (me->vnode == src) me->vnode = nil;
        }
        readWatch(me);
    });
    dispatch_source_set_cancel_handler(src, ^{ close(fd); });
    dispatch_resume(src);
    w->vnode = src;
}

void readWatch(const std::shared_ptr<Watch> &w) {
    struct stat st{};
    if (stat(w->path.c_str(), &st) != 0) {
        w->status = baseName(w->path) + ": waiting for the file";
        w->seen = false;
        return;
    }
    bool quiet = false;
    if (st.st_ino != w->inode || st.st_size < w->offset) {
        // A new file, or one cut short: read it from the start. A file rewritten in place
        // (by a program that saves the whole log) repeats QSOs the log has: not listed.
        quiet = w->seen && w->inode != 0;
        w->inode = st.st_ino;
        w->offset = 0;
        if (w->vnode) dispatch_source_cancel(w->vnode), w->vnode = nil;
    }
    w->seen = true;
    if (!w->vnode) openVnode(w);
    w->status = baseName(w->path);
    if (st.st_size == w->offset) return;
    off_t want = std::min<off_t>(st.st_size - w->offset, kMaxFileRead);
    int fd = open(w->path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    std::string chunk((size_t)want, '\0');
    ssize_t n = pread(fd, chunk.data(), (size_t)want, w->offset);
    close(fd);
    if (n <= 0) return;
    chunk.resize((size_t)n);
    std::string lower(chunk);
    for (char &c : lower) c = (char)std::tolower((unsigned char)c);
    size_t eor = lower.rfind("<eor>");
    if (eor == std::string::npos) {
        if (chunk.size() > (1u << 20)) {  // a megabyte without a record: not an ADIF log
            w->offset = st.st_size;
            w->status = baseName(w->path) + ": no ADIF records";
            saveOffsets();
        }
        return;
    }
    size_t end = eor + 5;
    w->offset += (off_t)end;
    saveOffsets();
    std::vector<adif::CapturedQso> qsos = adif::parseAdifPayload(chunk.substr(0, end), baseName(w->path));
    if (!qsos.empty()) route(std::move(qsos), quiet);
    if (w->offset < st.st_size && (off_t)n == want && want == kMaxFileRead) readWatch(w);  // more than one read's worth
}

void startWatches() {
    std::vector<std::string> files = watchedFiles();
    std::vector<std::string> saved = split(setting("monitorFileOffsets"), '|');
    for (size_t i = 0; i < files.size(); ++i) {
        auto w = std::make_shared<Watch>();
        w->path = files[i];
        struct stat st{};
        if (stat(w->path.c_str(), &st) == 0) {
            w->seen = true;
            w->inode = st.st_ino;
            w->offset = st.st_size;  // from now on
            // Where the last run stopped, when it's the same file: QSOs logged while Nextpad++ was closed.
            if (i < saved.size()) {
                unsigned long long ino = 0;
                long long off = -1;
                if (std::sscanf(saved[i].c_str(), "%llu:%lld", &ino, &off) == 2 && ino == (unsigned long long)st.st_ino && off >= 0 &&
                    off <= st.st_size)
                    w->offset = (off_t)off;
            }
        }
        m.watches.push_back(w);
        openVnode(w);
        readWatch(w);
    }
    saveOffsets();
}

// ── Start and stop ──

void stopAll(bool queuePending) {
    for (Listener &l : m.listeners) {
        if (l.source) ++m.closing, dispatch_source_cancel(l.source);
        l.source = nil;
        l.fd = -1;
        l.status.clear();
    }
    for (auto c : std::vector<std::shared_ptr<TcpClient>>(m.clients)) closeClient(c, false);
    for (auto &w : m.watches)
        if (w->vnode) dispatch_source_cancel(w->vnode), w->vnode = nil;
    m.watches.clear();
    if (m.poll) dispatch_source_cancel(m.poll), m.poll = nil;
    std::vector<adif::CapturedQso> held;
    for (Pending &p : m.pending) held.push_back(p.qso);
    m.pending.clear();
    if (!held.empty()) {
        if (queuePending) {
            std::vector<adif::CapturedQso> q = loadQueue();
            q.insert(q.end(), held.begin(), held.end());
            saveQueue(q);
        } else {
            route(held, false);
        }
    }
    m.running = false;
}

void startAll() {
    stopAll(false);
    if (m.closing > 0) {  // the old sockets close on the next turn of the run loop; then their ports are free
        m.startWhenClosed = true;
        return;
    }
    m.local = localAddresses();
    for (Source s : {kWsjtx, kAdif, kN1mm})
        if (enabled(s)) startUdp(s);
    if (enabled(kTcp)) startTcp();
    startWatches();
    m.poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(m.poll, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollSeconds * NSEC_PER_SEC)),
                              (uint64_t)(kPollSeconds * NSEC_PER_SEC), NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(m.poll, ^{
        for (auto w : std::vector<std::shared_ptr<Watch>>(m.watches)) readWatch(w);
    });
    dispatch_resume(m.poll);
    m.running = true;
    m.note.clear();
    m.noteSeverity = -1;
    deliver({}, false);  // anything waiting from before
    refresh();
}

void restartIfRunning() {
    if (m.running) startAll();
    else refresh();
}

// ── The window ──

std::string chooseFile(const char *testVariable, NSString *message) {
    if (const char *test = getenv(testVariable)) return test;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = message;
    p.canChooseFiles = YES;
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *ext in @[ @"adi", @"adif" ])
        if (UTType *t = [UTType typeWithFilenameExtension:ext]) [types addObject:t];
    p.allowedContentTypes = types;
    if ([p runModal] != NSModalResponseOK || !p.URL) return "";
    return ADIFStd(p.URL.path);
}

void setTarget(const std::string &p) {
    if (p.empty()) return;
    std::vector<std::string> files = watchedFiles();
    if (std::find(files.begin(), files.end(), p) != files.end()) {
        m.note = baseName(p) + " is a watched file: QSOs added to it would come straight back. Choose another log.";
        m.noteSeverity = 2;
        refresh();
        return;
    }
    setSetting("monitorTarget", p);
    m.note = "Captured QSOs go into " + baseName(p) + ".";
    m.noteSeverity = -1;
    deliver({}, false);
    refresh();
}

void addWatch(const std::string &p) {
    if (p.empty()) return;
    if (p == target()) {
        m.note = baseName(p) + " is the log QSOs go into; it can't also be watched.";
        m.noteSeverity = 2;
        refresh();
        return;
    }
    std::vector<std::string> files = watchedFiles();
    if (std::find(files.begin(), files.end(), p) == files.end()) files.push_back(p);
    setSetting("monitorFiles", join(files, "|"));
    m.note = "Watching " + baseName(p) + ": QSOs added to it from now on are captured.";
    m.noteSeverity = -1;
    restartIfRunning();
}

void copyRows() {
    std::string out;
    for (NSInteger r : [m.w selectedRows])
        if (r >= 0 && (size_t)r < m.rows.size() && m.rows[(size_t)r].qso.kind == adif::CapturedQso::Kind::Add)
            out += adif::buildRecord(m.rows[(size_t)r].qso.fields, adif::Layout::RecordPerLine, "\n", lengthUnit(), true).text;
    if (out.empty()) {
        m.note = "Select the QSOs to copy.";
        m.noteSeverity = 1;
    } else {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:ADIFString(out) forType:NSPasteboardTypeString];
        m.note = "Copied as ADIF records.";
        m.noteSeverity = -1;
    }
    refresh();
}

void goToRow(NSInteger row) {
    if (row < 0 || (size_t)row >= m.rows.size()) return;
    const Row &r = m.rows[(size_t)row];
    if (!r.record || r.log.empty()) return;
    if (path() != r.log) {
        m.note = "Open " + baseName(r.log) + " to see record " + std::to_string(r.record) + ".";
        m.noteSeverity = -1;
        refresh();
        return;
    }
    NppHandle h = scintilla();
    const adif::LintResult &lr = lint(h);
    int n = 0;
    for (const adif::ModelGroup &g : lr.model.groups) {
        if (g.header) continue;
        if (++n == r.record) {
            goTo(h, adif::groupStart(lr.model, g), true);
            return;
        }
    }
}

void refresh() {
    if (!m.w) return;
    std::string t = target();
    m.targetLabel.stringValue = t.empty() ? @"(none chosen)" : ADIFString(t).stringByAbbreviatingWithTildeInPath;
    [m.w setTarget:ADIFString(t.empty() ? std::string("Log: none chosen") : "Log: " + baseName(t) + (path() == t ? " (open)" : ""))];
    std::vector<std::string> files;
    for (const std::string &f : watchedFiles()) files.push_back(baseName(f));
    m.filesLabel.stringValue = files.empty() ? @"none" : ADIFString(join(files, ", "));
    m.startStop.title = m.running ? @"Stop" : @"Start";
    size_t queued = queuedCount();
    m.flush.enabled = queued > 0;
    m.flush.title = queued ? ADIFString("Add " + plural(queued, "Queued QSO")) : @"Add Queued QSOs";

    std::vector<std::string> on, problems;
    for (const Listener &l : m.listeners)
        if (!l.status.empty()) (l.severity == 2 ? problems : on).push_back(l.status);
    for (const auto &w : m.watches) on.push_back("file " + w->status);
    if (m.running && on.empty() && problems.empty()) problems.push_back("nothing to listen to: tick a source or watch a file");
    if (m.running) [m.w setHeadline:ADIFString(on.empty() ? std::string("Not listening") : "Listening: " + join(on, " · ")) severity:on.empty() ? 2 : 3];
    else [m.w setHeadline:@"Stopped" severity:-1];
    std::string status = join(problems, "; ");
    int severity = problems.empty() ? m.noteSeverity : 2;
    if (!m.note.empty()) status += (status.empty() ? "" : ". ") + m.note;
    else if (problems.empty()) severity = -1;
    if (status.empty())
        status = m.running ? "Waiting for QSOs. Log one in WSJT-X (or the program you set up) and it appears here."
                           : "Choose the log captured QSOs go into, tick the programs to listen to, then Start. It only "
                             "listens on this Mac unless you allow other computers; it never sends anything.";
    [m.w setStatus:ADIFString(status) severity:severity];

    std::vector<std::vector<std::string>> rows;
    std::vector<int> severities;
    std::vector<std::string> keys;
    size_t i = 0;
    for (const Row &r : m.rows) {
        rows.push_back({r.when, r.source, r.call, r.date, r.time, r.band, r.mode, r.result});
        severities.push_back(r.severity);
        keys.push_back(std::to_string(m.rows.size() - i++) + r.when);
    }
    [m.w setRows:rows severities:severities keys:keys ticks:std::vector<bool>() keepTicks:NO];
}

}  // namespace

std::string wsjtxLogPath() {
    if (const char *test = getenv("ADIFLINT_TEST_WSJTX_LOG")) return test;
    // WSJT-X User Guide v3.2.0-rc1, p.120 (log directory on macOS) and p.45 (wsjtx_log.adi).
    return ADIFStd(NSHomeDirectory()) + "/Library/Application Support/WSJT-X/wsjtx_log.adi";
}

void cmdMonitor() {
    if (!m.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Monitor" size:NSMakeSize(900, 560) headline:YES];
        m.w = w;
        m.targetLabel = ADIFLabel(@"");
        m.targetLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [m.targetLabel.widthAnchor constraintLessThanOrEqualToConstant:380].active = YES;
        NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
        ADIFOnAction(choose, ^{ setTarget(chooseFile("ADIFLINT_TEST_TARGET", @"Choose the log captured QSOs go into")); });
        NSButton *useOpen = [NSButton buttonWithTitle:@"Use the Open Log" target:nil action:nil];
        ADIFOnAction(useOpen, ^{
            if (path().empty()) {
                m.note = "Save this document as an .adi file first.";
                m.noteSeverity = 2;
                refresh();
                return;
            }
            setTarget(path());
        });
        [w addOptionRow:@[ ADIFLabel(@"Add QSOs to:"), m.targetLabel, choose, useOpen ]];

        auto sourceRow = [&](Source s, NSString *title) {
            m.checks[s] = ADIFCheckbox(title, enabled(s));
            m.ports[s] = ADIFTextField(@"", 60);
            m.ports[s].stringValue = [NSString stringWithFormat:@"%d", port(s)];
            m.ports[s].cell.sendsActionOnEndEditing = YES;
            ADIFOnAction(m.checks[s], ^{
                setSetting(kSources[s].enableKey, m.checks[s].state == NSControlStateValueOn ? "1" : "0");
                restartIfRunning();
            });
            ADIFOnAction(m.ports[s], ^{
                int p = (int)m.ports[s].integerValue;
                if (p <= 0 || p > 65535) {
                    m.ports[s].stringValue = [NSString stringWithFormat:@"%d", port(s)];
                    return;
                }
                if (p == port(s)) return;
                setSetting(kSources[s].portKey, std::to_string(p));
                restartIfRunning();
            });
        };
        sourceRow(kWsjtx, @"WSJT-X, JTDX, JS8Call (UDP Server) port");
        m.multicast = ADIFTextField(@"none", 110);
        m.multicast.stringValue = ADIFString(setting("monitorMulticast"));
        m.multicast.cell.sendsActionOnEndEditing = YES;
        ADIFOnAction(m.multicast, ^{
            std::string g = ADIFStd(m.multicast.stringValue);
            while (!g.empty() && g.back() == ' ') g.pop_back();
            while (!g.empty() && g.front() == ' ') g.erase(g.begin());
            if (g == setting("monitorMulticast")) return;
            setSetting("monitorMulticast", g);
            restartIfRunning();
        });
        [w addOptionRow:@[ m.checks[kWsjtx], m.ports[kWsjtx], ADIFLabel(@"multicast group:"), m.multicast ]];
        sourceRow(kAdif, @"ADIF over UDP port");
        sourceRow(kN1mm, @"N1MM Logger+ contacts (XML) port");
        [w addOptionRow:@[ m.checks[kAdif], m.ports[kAdif], m.checks[kN1mm], m.ports[kN1mm] ]];
        sourceRow(kTcp, @"Logger commands over TCP (DXKeeper, HRD form) port");
        [w addOptionRow:@[ m.checks[kTcp], m.ports[kTcp] ]];

        m.filesLabel = ADIFLabel(@"");
        m.filesLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [m.filesLabel.widthAnchor constraintLessThanOrEqualToConstant:300].active = YES;
        NSButton *wsjtx = [NSButton buttonWithTitle:@"Watch WSJT-X's Log" target:nil action:nil];
        ADIFOnAction(wsjtx, ^{
            std::string p = wsjtxLogPath();
            if (![[NSFileManager defaultManager] fileExistsAtPath:ADIFString(p)]) {
                m.note = "WSJT-X's log isn't at " + ADIFStd(ADIFString(p).stringByAbbreviatingWithTildeInPath) +
                         " yet (it appears with the first QSO WSJT-X logs). Watching it anyway.";
                m.noteSeverity = 1;
            }
            addWatch(p);
        });
        NSButton *addFile = [NSButton buttonWithTitle:@"Add File..." target:nil action:nil];
        ADIFOnAction(addFile, ^{ addWatch(chooseFile("ADIFLINT_TEST_WATCH", @"Choose a log file another program adds QSOs to")); });
        NSButton *clearFiles = [NSButton buttonWithTitle:@"Stop Watching" target:nil action:nil];
        ADIFOnAction(clearFiles, ^{
            setSetting("monitorFiles", "");
            setSetting("monitorFileOffsets", "");
            m.note = "No files watched.";
            m.noteSeverity = -1;
            restartIfRunning();
        });
        [w addOptionRow:@[ ADIFLabel(@"Watch files:"), m.filesLabel, wsjtx, addFile, clearFiles ]];

        m.remote = ADIFCheckbox(@"Accept from other computers", remoteAllowed());
        ADIFOnAction(m.remote, ^{
            setSetting("monitorRemote", m.remote.state == NSControlStateValueOn ? "1" : "0");
            restartIfRunning();
        });
        m.autoStart = ADIFCheckbox(@"Start when Nextpad++ starts", setting("monitorAutoStart") == "1");
        ADIFOnAction(m.autoStart, ^{ setSetting("monitorAutoStart", m.autoStart.state == NSControlStateValueOn ? "1" : "0"); });
        [w addOptionRow:@[ m.remote, m.autoStart ]];

        [w setColumns:std::vector<ADIFToolColumn>{{"when", "Arrived", 64}, {"from", "From", 96}, {"call", "Call", 76},
                                                  {"date", "Date", 72}, {"time", "UTC", 44}, {"band", "Band", 44},
                                                  {"mode", "Mode", 52}, {"result", "Result", 380}}
            checkboxes:NO
              sortable:NO];
        w.onActivateRow = ^(NSInteger row) { goToRow(row); };
        m.flush = [w addButton:@"Add Queued QSOs" trailing:NO action:^{
            m.note.clear();
            deliver({}, false);
            refresh();
        }];
        [w addButton:@"Copy as ADIF" trailing:NO action:^{ copyRows(); }];
        [w addButton:@"Clear List" trailing:NO action:^{
            m.rows.clear();
            m.note.clear();
            refresh();
        }];
        m.startStop = [w addButton:@"Start" trailing:YES action:^{
            if (m.running) {
                stopAll(false);
                m.note = "Stopped.";
                m.noteSeverity = -1;
                refresh();
            } else {
                startAll();
            }
        }];
        [w setDefaultButton:m.startStop];
    }
    refresh();
    [m.w show];
}

void startIfWanted() {
    if (setting("monitorAutoStart") == "1" && !m.running) startAll();
}

void documentActivated() {
    if (m.w) refresh();
    std::string t = target();
    if (t.empty() || path() != t || !queuedCount()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (path() == target()) {
            deliver({}, false);
            refresh();
        }
    });
}

void shutdown() { stopAll(true); }

}  // namespace monitor
