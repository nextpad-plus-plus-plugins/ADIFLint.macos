#include "adif_capture.h"

#include "adif_edit.h"
#include "adif_lint.h"
#include "adif_spec.h"
#include "adif_tools.h"

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace adif {
namespace {

constexpr uint32_t kWsjtxMagic = 0xadbccbda;
constexpr size_t kMaxText = 1 << 16;  // a datagram's worth; longer strings are refused

std::string upper(std::string_view s) {
    std::string o(s);
    for (char &c : o)
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
    return o;
}

std::string trimmed(std::string_view s) {
    size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
    return b == std::string_view::npos ? std::string() : std::string(s.substr(b, e - b + 1));
}

// Big-endian QDataStream reader; any overrun makes ok false and every read after it empty.
struct Reader {
    std::string_view b;
    size_t p = 0;
    bool ok = true;
    bool need(size_t n) {
        if (!ok || b.size() - p < n || p > b.size()) ok = false;
        return ok;
    }
    uint64_t un(size_t n) {
        if (!need(n)) return 0;
        uint64_t v = 0;
        for (size_t i = 0; i < n; ++i) v = (v << 8) | (unsigned char)b[p + i];
        p += n;
        return v;
    }
    uint32_t u32() { return (uint32_t)un(4); }
    uint8_t u8() { return (uint8_t)un(1); }
    int64_t i64() { return (int64_t)un(8); }
    std::string utf8() {
        uint32_t n = u32();
        if (!ok || n == 0xffffffffu) return {};  // null
        if (n > kMaxText || !need(n)) return {};
        std::string s(b.substr(p, n));
        p += n;
        return s;
    }
    // QDateTime as UTC "YYYYMMDD" and "HHMMSS"; false when it can't be read (a time zone).
    bool dateTime(std::string *date, std::string *time) {
        int64_t jd = i64();
        uint32_t ms = u32();
        uint8_t spec = u8();
        int64_t offset = spec == 2 ? (int32_t)u32() : 0;
        if (!ok || spec == 3) return ok = false;
        if (jd <= 0 || ms == 0xffffffffu) return false;  // a null date or time
        int64_t secs = (int64_t)(ms / 1000) - offset;     // offset from UTC, in seconds: back to UTC
        while (secs < 0) secs += 86400, --jd;
        while (secs >= 86400) secs -= 86400, ++jd;
        // Julian day to the Gregorian calendar (Fliegel and Van Flandern, as Qt's QDate).
        int64_t a = jd + 32044, b4 = (4 * a + 3) / 146097, c = a - 146097 * b4 / 4, d = (4 * c + 3) / 1461;
        int64_t e = c - 1461 * d / 4, m = (5 * e + 2) / 153;
        int day = (int)(e - (153 * m + 2) / 5 + 1), month = (int)(m + 3 - 12 * (m / 10));
        int64_t year = 100 * b4 + d - 4800 + m / 10;
        if (year < 1900 || year > 9999) return false;
        char buf[16];
        snprintf(buf, sizeof buf, "%04d%02d%02d", (int)year, month, day);
        *date = buf;
        snprintf(buf, sizeof buf, "%02d%02d%02d", (int)(secs / 3600), (int)(secs / 60 % 60), (int)(secs % 60));
        *time = buf;
        return true;
    }
};

void put(FieldList &f, const char *name, std::string value) {
    value = trimmed(value);
    if (!value.empty()) f.emplace_back(name, std::move(value));
}

std::string xmlUnescape(std::string_view s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] != '&') {
            out.push_back(s[i]);
            continue;
        }
        static const struct { const char *ent; char ch; } kEnts[] = {{"&amp;", '&'}, {"&lt;", '<'}, {"&gt;", '>'}, {"&quot;", '"'}, {"&apos;", '\''}};
        bool done = false;
        for (const auto &x : kEnts)
            if (s.substr(i, std::strlen(x.ent)) == x.ent) {
                out.push_back(x.ch);
                i += std::strlen(x.ent) - 1;
                done = true;
                break;
            }
        if (!done) out.push_back('&');
    }
    return out;
}

// The text of <tag>...</tag> inside `xml` (case-insensitive tag), or "".
std::string xmlValue(std::string_view xml, const char *tag) {
    std::string open = std::string("<") + tag + ">", close = std::string("</") + tag + ">";
    std::string lower(xml.substr(0, std::min<size_t>(xml.size(), kMaxText)));
    for (char &c : lower) c = (char)std::tolower((unsigned char)c);
    std::string lo = open, lc = close;
    for (char &c : lo) c = (char)std::tolower((unsigned char)c);
    for (char &c : lc) c = (char)std::tolower((unsigned char)c);
    size_t b = lower.find(lo);
    if (b == std::string::npos) return {};
    b += lo.size();
    size_t e = lower.find(lc, b);
    size_t lt = lower.find('<', b);  // a missing close tag ends at the next tag
    if (e == std::string::npos || (lt != std::string::npos && lt < e)) e = lt == std::string::npos ? lower.size() : lt;
    return xmlUnescape(xml.substr(b, e - b));
}

// "352519" (10 Hz units) -> "3.52519".
std::string tensOfHzToMHz(std::string_view v) {
    double x = 0;
    if (!parseAdifNumber(trimmed(v), &x) || x <= 0) return {};
    char buf[32];
    snprintf(buf, sizeof buf, "%.5f", x / 100000.0);
    std::string s = buf;
    while (!s.empty() && s.back() == '0') s.pop_back();
    if (!s.empty() && s.back() == '.') s.pop_back();
    return s;
}

std::string hzToMHzText(uint64_t hz) {
    char buf[32];
    snprintf(buf, sizeof buf, "%llu.%06llu", (unsigned long long)(hz / 1000000), (unsigned long long)(hz % 1000000));
    std::string s = buf;
    while (!s.empty() && s.back() == '0') s.pop_back();
    if (!s.empty() && s.back() == '.') s.pop_back();
    return s;
}

// Digits with no decimal point, as HRD's "db add" FREQ (GridTracker drops the point): Hz,
// kHz or MHz, whichever falls in a band.
std::string freqFromDigits(std::string_view v) {
    double x = 0;
    if (!parseAdifNumber(trimmed(v), &x) || x <= 0) return std::string(v);
    for (double div : {1e6, 1e3, 1.0}) {
        char buf[32];
        snprintf(buf, sizeof buf, "%.6f", x / div);
        std::string s = buf;
        while (!s.empty() && s.back() == '0') s.pop_back();
        if (!s.empty() && s.back() == '.') s.pop_back();
        if (!bandForFrequency(s).empty()) return s;
    }
    return std::string(v);
}

bool isNumber(std::string_view v) {
    double x = 0;
    return parseAdifNumber(trimmed(v), &x);
}

// A JSON string starting at j[at] == '"': its decoded text (UTF-8) and where it ends.
bool jsonString(std::string_view j, size_t at, std::string *out, size_t *end) {
    out->clear();
    for (size_t i = at + 1; i < j.size(); ++i) {
        char c = j[i];
        if (c == '"') {
            *end = i + 1;
            return true;
        }
        if (out->size() > kMaxText) return false;
        if (c != '\\') {
            out->push_back(c);
            continue;
        }
        if (++i >= j.size()) return false;
        switch (j[i]) {
            case '"': case '\\': case '/': out->push_back(j[i]); break;
            case 'b': out->push_back('\b'); break;
            case 'f': out->push_back('\f'); break;
            case 'n': out->push_back('\n'); break;
            case 'r': out->push_back('\r'); break;
            case 't': out->push_back('\t'); break;
            case 'u': {
                auto hex4 = [&](size_t p, uint32_t *v) {
                    if (p + 4 > j.size()) return false;
                    *v = 0;
                    for (size_t k = p; k < p + 4; ++k) {
                        char h = j[k];
                        int d = h >= '0' && h <= '9' ? h - '0' : h >= 'a' && h <= 'f' ? h - 'a' + 10 : h >= 'A' && h <= 'F' ? h - 'A' + 10 : -1;
                        if (d < 0) return false;
                        *v = *v * 16 + (uint32_t)d;
                    }
                    return true;
                };
                uint32_t cp = 0, lo = 0;
                if (!hex4(i + 1, &cp)) return false;
                i += 4;
                if (cp >= 0xD800 && cp < 0xDC00 && i + 6 < j.size() && j[i + 1] == '\\' && j[i + 2] == 'u' && hex4(i + 3, &lo) &&
                    lo >= 0xDC00 && lo < 0xE000) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    i += 6;
                }
                if (cp < 0x80) out->push_back((char)cp);
                else if (cp < 0x800) out->push_back((char)(0xC0 | (cp >> 6))), out->push_back((char)(0x80 | (cp & 0x3F)));
                else if (cp < 0x10000)
                    out->push_back((char)(0xE0 | (cp >> 12))), out->push_back((char)(0x80 | ((cp >> 6) & 0x3F))),
                        out->push_back((char)(0x80 | (cp & 0x3F)));
                else
                    out->push_back((char)(0xF0 | (cp >> 18))), out->push_back((char)(0x80 | ((cp >> 12) & 0x3F))),
                        out->push_back((char)(0x80 | ((cp >> 6) & 0x3F))), out->push_back((char)(0x80 | (cp & 0x3F)));
                break;
            }
            default: return false;
        }
    }
    return false;
}

// A string member of the top-level JSON object, or false.
bool jsonMember(std::string_view j, std::string_view key, std::string *out) {
    size_t i = j.find_first_not_of(" \t\r\n");
    if (i == std::string_view::npos || j[i] != '{') return false;
    int depth = 0;
    std::string s;
    while (i < j.size()) {
        char c = j[i];
        if (c == '"') {
            size_t end = 0;
            if (!jsonString(j, i, &s, &end)) return false;
            size_t colon = j.find_first_not_of(" \t\r\n", end);
            if (depth == 1 && colon != std::string_view::npos && j[colon] == ':' && s == key) {
                size_t v = j.find_first_not_of(" \t\r\n", colon + 1);
                return v != std::string_view::npos && j[v] == '"' && jsonString(j, v, out, &end);
            }
            i = end;
            continue;
        }
        if (c == '{' || c == '[') ++depth;
        else if (c == '}' || c == ']') --depth;
        ++i;
    }
    return false;
}

CapturedQso finish(CapturedQso q) {
    normalizeCaptured(q.fields, &q.problem);
    return q;
}

}  // namespace

void normalizeCaptured(FieldList &fields, std::string *problem) {
    FieldList out;
    for (auto &[name, value] : fields) {
        std::string n = upper(trimmed(name)), v = trimmed(value);
        if (n.empty() || v.empty()) continue;
        if (n == "CALL" || n == "STATION_CALLSIGN" || n == "OPERATOR") v = upper(v);
        if ((n == "QSO_DATE" || n == "QSO_DATE_OFF") && v.size() == 10 && (v[4] == '-' || v[4] == '/'))
            v = v.substr(0, 4) + v.substr(5, 2) + v.substr(8, 2);
        if ((n == "TIME_ON" || n == "TIME_OFF") && v.find(':') != std::string::npos) {
            std::string digits;
            for (char c : v)
                if (c >= '0' && c <= '9') digits += c;
            v = digits;
        }
        bool seen = false;  // the first value of a field wins
        for (const auto &o : out) seen |= o.first == n;
        if (!seen) out.emplace_back(n, v);
    }
    auto get = [&](const char *n) -> std::string {
        for (const auto &f : out)
            if (f.first == n) return f.second;
        return {};
    };
    auto set = [&](const char *n, const std::string &v) {
        for (auto &f : out)
            if (f.first == n) {
                f.second = v;
                return;
            }
        out.emplace_back(n, v);
    };
    // A MODE that is a submode (FT4, JS8, USB): its mode, and the SUBMODE.
    std::string mode = get("MODE");
    const EnumDef *modes = findEnum("Mode"), *subs = findEnum("Submode");
    if (!mode.empty() && modes && subs) {
        const EnumValue *m = findEnumValue(*modes, mode);
        const EnumValue *s = findEnumValue(*subs, mode);
        if ((!m || m->importOnly) && s && s->scope && get("SUBMODE").empty()) {
            set("MODE", s->scope);
            set("SUBMODE", s->value);
        }
    }
    if (get("BAND").empty() && !get("FREQ").empty()) {
        std::string band = bandForFrequency(get("FREQ"));
        if (!band.empty()) set("BAND", band);
    }
    if (problem) {
        problem->clear();
        std::string missing;
        for (const char *n : {"CALL", "QSO_DATE", "TIME_ON", "MODE"})
            if (get(n).empty()) missing += (missing.empty() ? "" : ", ") + std::string(n);
        if (get("BAND").empty() && get("FREQ").empty()) missing += (missing.empty() ? "" : ", ") + std::string("BAND or FREQ");
        if (!missing.empty()) *problem = "no " + missing;
    }
    fields = std::move(out);
}

std::vector<CapturedQso> parseWsjtxMessage(std::string_view bytes, bool *isWsjtx) {
    Reader r{bytes};
    bool magic = r.u32() == kWsjtxMagic;
    if (isWsjtx) *isWsjtx = magic && r.ok;
    if (!magic) return {};
    r.u32();  // schema: newer schemas only add fields at the end
    uint32_t type = r.u32();
    std::string id = r.utf8();
    if (!r.ok) return {};
    if (type == 12) {
        std::string adif = r.utf8();
        if (!r.ok) return {};
        std::vector<CapturedQso> out = parseAdifPayload(adif, id.empty() ? std::string("WSJT-X") : id);
        for (CapturedQso &q : out) q.wsjtxType = 12, q.client = id;
        return out;
    }
    if (type != 5) return {};
    CapturedQso q;
    q.source = id.empty() ? std::string("WSJT-X") : id;
    q.client = id;
    q.wsjtxType = 5;
    std::string offDate, offTime, onDate, onTime;
    bool hasOff = r.dateTime(&offDate, &offTime);
    std::string call = r.utf8(), grid = r.utf8();
    uint64_t hz = r.un(8);
    std::string mode = r.utf8(), sent = r.utf8(), rcvd = r.utf8(), power = r.utf8(), comments = r.utf8(), name = r.utf8();
    bool hasOn = r.dateTime(&onDate, &onTime);
    std::string op = r.utf8(), mine = r.utf8(), myGrid = r.utf8(), xSent = r.utf8(), xRcvd = r.utf8(), prop = r.utf8();
    // Fields after "Date & Time On" came with later versions: read what is there.
    FieldList &f = q.fields;
    put(f, "CALL", call);
    if (hasOn) put(f, "QSO_DATE", onDate), put(f, "TIME_ON", onTime);
    else if (hasOff) put(f, "QSO_DATE", offDate), put(f, "TIME_ON", offTime);
    if (hasOff) put(f, "QSO_DATE_OFF", offDate), put(f, "TIME_OFF", offTime);
    if (hz) put(f, "FREQ", hzToMHzText(hz));
    put(f, "MODE", mode);
    put(f, "RST_SENT", sent);
    put(f, "RST_RCVD", rcvd);
    put(f, "GRIDSQUARE", grid);
    put(f, "NAME", name);
    put(f, "TX_PWR", power);
    put(f, "COMMENT", comments);
    put(f, "OPERATOR", op);
    put(f, "STATION_CALLSIGN", mine);
    put(f, "MY_GRIDSQUARE", myGrid);
    put(f, "STX_STRING", xSent);
    put(f, "SRX_STRING", xRcvd);
    put(f, "PROP_MODE", prop);
    if (call.empty()) return {};
    return {finish(std::move(q))};
}

std::vector<CapturedQso> parseAdifPayload(std::string_view text, std::string_view source) {
    // Records only: after a header's <EOH>, else from the first '<' ("ADD <call:4>...").
    std::string lower(text.substr(0, std::min<size_t>(text.size(), kMaxText)));
    for (char &c : lower) c = (char)std::tolower((unsigned char)c);
    size_t eoh = lower.find("<eoh>"), eor = lower.find("<eor>");
    if (eoh != std::string::npos && (eor == std::string::npos || eoh < eor)) text = text.substr(eoh + 5);
    size_t lt = text.find('<');
    if (lt == std::string_view::npos) return {};
    text = text.substr(lt);
    if (text.size() > (8u << 20)) return {};  // a QSO or a few, not a log
    LintOptions opt;
    opt.buildModel = true;
    opt.maxDiagnostics = 0;
    std::string owned(text);
    LintResult r = lint(owned, opt);
    std::vector<CapturedQso> out;
    for (const Record &rec : records(owned, r.model)) {
        if (rec.fields.empty()) continue;
        CapturedQso q;
        q.source = std::string(source);
        q.fields = rec.fields;
        out.push_back(finish(std::move(q)));
    }
    return out;
}

std::vector<CapturedQso> parseN1mmXml(std::string_view text) {
    std::string lower(text.substr(0, std::min<size_t>(text.size(), kMaxText)));
    for (char &c : lower) c = (char)std::tolower((unsigned char)c);
    CapturedQso q;
    q.source = "N1MM Logger+";
    if (lower.find("<contactinfo>") != std::string::npos) q.kind = CapturedQso::Kind::Add;
    else if (lower.find("<contactreplace>") != std::string::npos) q.kind = CapturedQso::Kind::Replace;
    else if (lower.find("<contactdelete>") != std::string::npos) q.kind = CapturedQso::Kind::Delete;
    else return {};
    q.id = trimmed(xmlValue(text, "ID"));
    std::string stamp = trimmed(xmlValue(text, "timestamp"));  // "2020-01-17 16:43:38"
    FieldList &f = q.fields;
    put(f, "CALL", xmlValue(text, "call"));
    if (stamp.size() >= 19) {
        put(f, "QSO_DATE", stamp.substr(0, 10));
        put(f, "TIME_ON", stamp.substr(11, 8));
    }
    std::string tx = tensOfHzToMHz(xmlValue(text, "txfreq")), rx = tensOfHzToMHz(xmlValue(text, "rxfreq"));
    put(f, "FREQ", tx.empty() ? rx : tx);
    if (!rx.empty() && rx != tx) put(f, "FREQ_RX", rx);
    put(f, "MODE", xmlValue(text, "mode"));
    put(f, "RST_SENT", xmlValue(text, "snt"));
    put(f, "RST_RCVD", xmlValue(text, "rcv"));
    std::string sntnr = trimmed(xmlValue(text, "sntnr")), rcvnr = trimmed(xmlValue(text, "rcvnr"));
    if (!sntnr.empty() && sntnr != "0") put(f, "STX", sntnr);
    if (!rcvnr.empty() && rcvnr != "0") put(f, "SRX", rcvnr);
    put(f, "STX_STRING", xmlValue(text, "SentExchange"));
    std::string exchange = xmlValue(text, "exchange1");
    if (trimmed(exchange).empty()) exchange = xmlValue(text, "exchangel");  // the documentation's spelling
    put(f, "SRX_STRING", exchange);
    put(f, "GRIDSQUARE", xmlValue(text, "gridsquare"));
    put(f, "ARRL_SECT", xmlValue(text, "section"));
    put(f, "NAME", xmlValue(text, "name"));
    put(f, "QTH", xmlValue(text, "qth"));
    put(f, "COMMENT", xmlValue(text, "comment"));
    std::string power = xmlValue(text, "power");  // the worked station's power, per N1MM; "KW" stays in the exchange
    if (isNumber(power)) put(f, "RX_PWR", power);
    std::string zone = trimmed(xmlValue(text, "zone"));
    if (!zone.empty() && zone != "0") put(f, "CQZ", zone);
    // N1MM's own contest names ("DXPEDITION", "CWOPS"): CONTEST_ID only when ADIF lists it.
    std::string contest = upper(trimmed(xmlValue(text, "contestname")));
    const EnumDef *contests = findEnum("Contest_ID");
    if (contests && findEnumValue(*contests, contest)) put(f, "CONTEST_ID", findEnumValue(*contests, contest)->value);
    else put(f, "APP_N1MM_CONTESTNAME", contest);
    put(f, "STATION_CALLSIGN", xmlValue(text, "mycall"));
    put(f, "OPERATOR", xmlValue(text, "operator"));
    if (!q.id.empty()) put(f, "APP_N1MM_ID", q.id);
    if (q.kind == CapturedQso::Kind::Delete) return {q};
    return {finish(std::move(q))};
}

std::vector<CapturedQso> parseJs8Json(std::string_view text) {
    if (text.size() > kMaxText) return {};
    std::string type, value;
    if (!jsonMember(text, "type", &type) || type != "LOG.QSO" || !jsonMember(text, "value", &value)) return {};
    return parseAdifPayload(value, "JS8Call");
}

std::vector<CapturedQso> parseLoggerCommand(std::string_view text) {
    std::string lower(text.substr(0, std::min<size_t>(text.size(), kMaxText)));
    for (char &c : lower) c = (char)std::tolower((unsigned char)c);
    // DXKeeper: <command:3>log<parameters:N>ADIF
    size_t pc = lower.find("<parameters:");
    if (lower.find("<command:") != std::string::npos && pc != std::string::npos) {
        size_t colon = pc + 12, gt = lower.find('>', colon);
        if (gt == std::string::npos) return {};
        long n = std::strtol(lower.substr(colon, gt - colon).c_str(), nullptr, 10);
        if (n <= 0 || (size_t)n > text.size() - gt - 1) n = (long)(text.size() - gt - 1);
        if (lower.find("<command:3>log") == std::string::npos) return {};
        return parseAdifPayload(text.substr(gt + 1, (size_t)n), "DXKeeper command");
    }
    // HRD Logbook: db add {CALL="W1AW" BAND="20m" ...}
    size_t add = lower.find("db add");
    if (add != std::string::npos) {
        size_t open = text.find('{', add), close = open == std::string_view::npos ? open : text.find('}', open);
        if (open == std::string_view::npos || close == std::string_view::npos) return {};
        CapturedQso q;
        q.source = "HRD command";
        std::string_view body = text.substr(open + 1, close - open - 1);
        size_t i = 0;
        while (i < body.size()) {
            size_t eq = body.find('=', i);
            if (eq == std::string_view::npos) break;
            std::string name = upper(trimmed(body.substr(i, eq - i)));
            if (name.rfind("COL_", 0) == 0) name = name.substr(4);
            size_t q1 = body.find('"', eq), q2 = q1 == std::string_view::npos ? q1 : body.find('"', q1 + 1);
            if (q1 == std::string_view::npos || q2 == std::string_view::npos) break;
            std::string value(body.substr(q1 + 1, q2 - q1 - 1));
            if (name == "FREQ" && value.find('.') == std::string::npos) value = freqFromDigits(value);
            if (!name.empty()) q.fields.emplace_back(name, value);
            i = q2 + 1;
        }
        if (q.fields.empty()) return {};
        return {finish(std::move(q))};
    }
    return parseAdifPayload(text, "ADIF over TCP");
}

std::vector<CapturedQso> parseCapture(std::string_view bytes, std::string_view sourceHint) {
    bool wsjtx = false;
    std::vector<CapturedQso> out = parseWsjtxMessage(bytes, &wsjtx);
    if (wsjtx) return out;
    std::string head = trimmed(bytes.substr(0, 400));
    for (char &c : head) c = (char)std::tolower((unsigned char)c);
    if (!head.empty() && head[0] == '{') return parseJs8Json(bytes);
    if (head.rfind("<?xml", 0) == 0 || head.find("<contactinfo>") != std::string::npos ||
        head.find("<contactreplace>") != std::string::npos || head.find("<contactdelete>") != std::string::npos)
        return parseN1mmXml(bytes);
    if (head.find("<command:") != std::string::npos || head.find("db add") != std::string::npos) return parseLoggerCommand(bytes);
    return parseAdifPayload(bytes, sourceHint);
}

std::string captureRefusal(std::string_view text, const LintResult &r) {
    if (text.find_first_not_of(" \t\r\n") == std::string_view::npos) return "";
    if (!canReformat(r)) return "The log has structural problems (wrong lengths or broken tags): run Fix Lengths on it.";
    bool records = false, header = false;
    for (const ModelGroup &g : r.model.groups) {
        if (g.header) {
            header = g.markerB != kNoPos;
            continue;
        }
        records = true;
        if (g.markerB == kNoPos) return "A record in the log has no <EOR>.";
    }
    if (!records && !header) return "It isn't an ADIF log.";
    return "";
}

bool applyCaptured(std::string &text, const std::vector<CapturedQso> &qsos, const CaptureFormat &fmt,
                   std::vector<CaptureOutcome> *outcomes, std::string *why) {
    LintOptions opt;
    opt.buildModel = true;
    opt.maxDiagnostics = 0;
    opt.lengthUnit = fmt.unit;
    std::string work = text;
    LintResult r = lint(work, opt);
    std::string problem = captureRefusal(work, r);
    if (!problem.empty()) {
        if (why) *why = problem;
        return false;
    }
    if (work.find_first_not_of(" \t\r\n") == std::string::npos) {
        work = newLogHeader(fmt.programVersion, fmt.timestamp, fmt.eol);
        r = lint(work, opt);
    }
    std::vector<Record> recs = records(work, r.model);
    Layout layout = recordLayout(work, r.model);
    std::string pending;  // records built, not yet appended
    auto relint = [&] {
        r = lint(work, opt);
        recs = records(work, r.model);
    };
    auto flush = [&] {
        if (pending.empty()) return;
        TextEdit e = appendRecord(work, r.model, pending, fmt.eol, nullptr);
        work.replace(e.start, e.end - e.start, e.text);
        pending.clear();
        relint();
    };
    auto built = [&](const FieldList &fields) {
        std::string t = buildRecord(fields, layout, fmt.eol, fmt.unit, fmt.utf8).text;
        return t;
    };
    DupeOptions dupe;
    std::vector<CaptureOutcome> out;
    for (const CapturedQso &q : qsos) {
        CaptureOutcome o;
        bool add = q.kind == CapturedQso::Kind::Add;
        if (!add) {
            flush();
            int found = -1;
            for (size_t i = 0; i < recs.size() && !q.id.empty(); ++i)
                if (equalsNoCase(recs[i].get("APP_N1MM_ID"), q.id)) found = (int)i;
            if (found < 0) {
                add = q.kind == CapturedQso::Kind::Replace;
                if (!add) o.result = CaptureResult::NotFound;
            } else {
                const Record &rec = recs[(size_t)found];
                const ModelGroup &g = r.model.groups[(size_t)rec.group];
                size_t b = groupStart(r.model, g), e = groupEnd(r.model, g);
                o.record = rec.number;
                if (q.kind == CapturedQso::Kind::Replace) {
                    std::string t = built(overlay(rec.fields, q.fields));
                    while (!t.empty() && (t.back() == '\n' || t.back() == '\r')) t.pop_back();
                    work.replace(b, e - b, t);
                    o.result = CaptureResult::Replaced;
                } else {
                    while (e < work.size() && (work[e] == ' ' || work[e] == '\t' || work[e] == '\r' || work[e] == '\n')) ++e;
                    work.erase(b, e - b);
                    o.result = CaptureResult::Deleted;
                }
                relint();
            }
        }
        if (add) {
            Record cand;
            cand.fields = q.fields;
            for (const Record &rec : recs)
                if (sameQso(rec, cand, dupe)) {
                    o.result = CaptureResult::Duplicate;
                    o.record = rec.number;
                    break;
                }
            if (o.result != CaptureResult::Duplicate) {
                pending += built(q.fields);
                cand.number = (int)recs.size() + 1;
                recs.push_back(cand);
                o.result = CaptureResult::Added;
                o.record = cand.number;
            }
        }
        out.push_back(o);
    }
    flush();
    text = std::move(work);
    if (outcomes) *outcomes = std::move(out);
    return true;
}

TextEdit minimalEdit(std::string_view before, std::string_view after) {
    size_t n = std::min(before.size(), after.size()), p = 0, s = 0;
    while (p < n && before[p] == after[p]) ++p;
    while (s < n - p && before[before.size() - 1 - s] == after[after.size() - 1 - s]) ++s;
    // Whole UTF-8 characters on both sides of the edit.
    while (p > 0 && p < before.size() && ((unsigned char)before[p] & 0xC0) == 0x80) --p;
    while (s > 0 && ((unsigned char)before[before.size() - s] & 0xC0) == 0x80) --s;
    return TextEdit{p, before.size() - s, std::string(after.substr(p, after.size() - s - p))};
}

std::string queueText(const std::vector<CapturedQso> &qsos, std::string_view programVersion, std::string_view timestamp) {
    std::string out = "ADIF Lint Monitor: QSOs waiting to be added to their log.\n";
    out += makeSpecifier("ADIF_VER", kSpecVersion, LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("PROGRAMID", "ADIF Lint", LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("PROGRAMVERSION", programVersion, LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("CREATED_TIMESTAMP", timestamp, LengthUnit::Bytes, false) + "\n";
    out += "<EOH>\n";
    for (const CapturedQso &q : qsos) {
        FieldList fields = q.fields;
        if (q.kind != CapturedQso::Kind::Add) {
            fields.emplace_back("APP_ADIFLINT_ACTION", q.kind == CapturedQso::Kind::Replace ? "REPLACE" : "DELETE");
            bool hasId = false;
            for (const auto &f : fields) hasId |= f.first == "APP_N1MM_ID";
            if (!hasId && !q.id.empty()) fields.emplace_back("APP_N1MM_ID", q.id);
        }
        if (!q.source.empty()) fields.emplace_back("APP_ADIFLINT_SOURCE", q.source);
        out += buildRecord(fields, Layout::RecordPerLine, "\n", LengthUnit::Characters, true).text;
    }
    return out;
}

std::vector<CapturedQso> parseQueue(std::string_view text) {
    LintOptions opt;
    opt.buildModel = true;
    opt.maxDiagnostics = 0;
    opt.lengthUnit = LengthUnit::Characters;
    LintResult r = lint(text, opt);
    std::vector<CapturedQso> out;
    for (const Record &rec : records(text, r.model)) {
        CapturedQso q;
        for (const auto &[name, value] : rec.fields) {
            if (name == "APP_ADIFLINT_ACTION")
                q.kind = equalsNoCase(value, "DELETE") ? CapturedQso::Kind::Delete
                         : equalsNoCase(value, "REPLACE") ? CapturedQso::Kind::Replace
                                                          : CapturedQso::Kind::Add;
            else if (name == "APP_ADIFLINT_SOURCE") q.source = value;
            else q.fields.emplace_back(name, value);
            if (name == "APP_N1MM_ID") q.id = value;
        }
        if (!q.fields.empty()) out.push_back(std::move(q));
    }
    return out;
}

std::string wsjtxString(std::string_view s) {
    std::string out;
    uint32_t n = (uint32_t)s.size();
    for (int i = 3; i >= 0; --i) out.push_back((char)((n >> (8 * i)) & 0xff));
    out.append(s);
    return out;
}

namespace {

void be(std::string &out, uint64_t v, int bytes) {
    for (int i = bytes - 1; i >= 0; --i) out.push_back((char)((v >> (8 * i)) & 0xff));
}

void header(std::string &out, uint32_t type, std::string_view id) {
    be(out, kWsjtxMagic, 4);
    be(out, 3, 4);  // schema 3
    be(out, type, 4);
    out += wsjtxString(id);
}

void dateTime(std::string &out, std::string_view date, std::string_view time) {
    int y = 0, m = 0, d = 0, hh = 0, mm = 0, ss = 0;
    std::sscanf(std::string(date).c_str(), "%4d%2d%2d", &y, &m, &d);
    std::sscanf(std::string(time).c_str(), "%2d%2d%2d", &hh, &mm, &ss);
    int a = (14 - m) / 12;
    int64_t yy = y + 4800 - a, mo = m + 12 * a - 3;
    int64_t jd = d + (153 * mo + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045;
    be(out, (uint64_t)jd, 8);
    be(out, (uint64_t)((hh * 3600 + mm * 60 + ss) * 1000), 4);
    be(out, 1, 1);  // UTC
}

}  // namespace

std::string wsjtxLoggedAdif(std::string_view id, std::string_view adif) {
    std::string out;
    header(out, 12, id);
    out += wsjtxString(adif);
    return out;
}

std::string wsjtxQsoLogged(std::string_view id, const FieldList &qso) {
    auto get = [&](const char *n) -> std::string {
        for (const auto &f : qso)
            if (equalsNoCase(f.first, n)) return f.second;
        return {};
    };
    std::string out;
    header(out, 5, id);
    std::string offDate = get("QSO_DATE_OFF").empty() ? get("QSO_DATE") : get("QSO_DATE_OFF");
    std::string offTime = get("TIME_OFF").empty() ? get("TIME_ON") : get("TIME_OFF");
    dateTime(out, offDate, offTime);
    out += wsjtxString(get("CALL")) + wsjtxString(get("GRIDSQUARE"));
    double mhz = 0;
    parseAdifNumber(get("FREQ"), &mhz);
    be(out, (uint64_t)(mhz * 1e6 + 0.5), 8);
    for (const char *n : {"MODE", "RST_SENT", "RST_RCVD", "TX_PWR", "COMMENT", "NAME"}) out += wsjtxString(get(n));
    dateTime(out, get("QSO_DATE"), get("TIME_ON"));
    for (const char *n : {"OPERATOR", "STATION_CALLSIGN", "MY_GRIDSQUARE", "STX_STRING", "SRX_STRING", "PROP_MODE"})
        out += wsjtxString(get(n));
    return out;
}

}  // namespace adif
