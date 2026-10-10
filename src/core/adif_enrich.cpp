#include "adif_enrich.h"

#include "adif_spec.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace adif {
namespace {

std::string trimmed(std::string_view s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) --e;
    // Collapse internal runs of whitespace.
    std::string out;
    bool space = false;
    for (size_t i = b; i < e; ++i) {
        char c = s[i];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
            space = true;
            continue;
        }
        if (space && !out.empty()) out.push_back(' ');
        space = false;
        out.push_back(c);
    }
    return out;
}

// ADI fields are ASCII 32-126 (§III.A): drop anything else rather than corrupt the log.
bool printableAscii(std::string_view s) {
    for (unsigned char c : s)
        if (c < 32 || c > 126) return false;
    return true;
}

std::string get(const std::map<std::string, std::string> &raw, const char *key) {
    for (const auto &kv : raw)
        if (equalsNoCase(kv.first, key)) return trimmed(kv.second);
    return {};
}

std::string upper(std::string_view s) {
    std::string o(s);
    for (char &c : o)
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
    return o;
}

bool allDigits(std::string_view s) {
    if (s.empty()) return false;
    for (char c : s)
        if (c < '0' || c > '9') return false;
    return true;
}

std::string stripZeros(std::string s) {
    while (s.size() > 1 && s[0] == '0') s.erase(0, 1);
    return s;
}

// US entities whose counties use the "ST,County" form (ADIF Secondary_Administrative_Subdivision).
bool usEntity(const std::string &dxcc) { return dxcc == "291" || dxcc == "6" || dxcc == "110"; }

void put(FieldMap &out, const char *field, const std::string &value) {
    if (!value.empty() && printableAscii(value)) out[field] = value;
}

void putZone(FieldMap &out, const char *field, const std::string &v, int max) {
    if (!allDigits(v)) return;
    int n = std::stoi(v.size() > 3 ? "0" : v);
    if (n >= 1 && n <= max) out[field] = std::to_string(n);
}

void putEntity(FieldMap &out, const std::string &dxcc) {
    std::string code = stripZeros(dxcc);
    if (!allDigits(code) || code == "0") return;
    if (const char *name = dxccEntityName(code)) {
        out["DXCC"] = code;
        out["COUNTRY"] = name;
    }
}

// STATE only when ADIF lists that code for the entity (Primary_Administrative_Subdivision[DXCC]).
void putState(FieldMap &out, const std::string &state, const std::string &dxcc) {
    const EnumDef *e = findEnum("Primary_Administrative_Subdivision");
    if (state.empty() || !e) return;
    std::string code = stripZeros(dxcc);
    if (!code.empty() && enumHasScope(*e, code) && findEnumValue(*e, state, code)) out["STATE"] = upper(state);
}

void putLocation(FieldMap &out, const std::string &lat, const std::string &lon) {
    double a = 0, b = 0;
    if (lat.empty() || lon.empty()) return;
    // Callbooks write plain decimals; accept a leading '+' they sometimes use.
    std::string la = lat[0] == '+' ? lat.substr(1) : lat, lo = lon[0] == '+' ? lon.substr(1) : lon;
    if (!parseAdifNumber(la, &a) || !parseAdifNumber(lo, &b) || std::fabs(a) > 90 || std::fabs(b) > 180) return;
    out["LAT"] = adifLocation(a, true);
    out["LON"] = adifLocation(b, false);
}

// Days since 1970-01-01 for a civil date (proleptic Gregorian).
long daysFromCivil(int y, int m, int d) {
    y -= m <= 2;
    const long era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (unsigned)(m + (m > 2 ? -3 : 9)) + 2) / 5 + (unsigned)d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (long)doe - 719468;
}

}  // namespace

// QSO_DATE + TIME_ON -> minutes since 1970, or -1 when malformed.
long qsoMinutes(std::string_view date, std::string_view time) {
    if (date.size() != 8 || !allDigits(date) || (time.size() != 4 && time.size() != 6) || !allDigits(time)) return -1;
    int y = std::stoi(std::string(date.substr(0, 4))), mo = std::stoi(std::string(date.substr(4, 2))),
        d = std::stoi(std::string(date.substr(6, 2)));
    int h = std::stoi(std::string(time.substr(0, 2))), mi = std::stoi(std::string(time.substr(2, 2)));
    return daysFromCivil(y, mo, d) * 1440 + h * 60 + mi;
}

// LoTW mode groups: CW, phone, and everything else as data.
int modeGroup(std::string_view mode) {
    if (equalsNoCase(mode, "CW")) return 0;
    for (const char *p : {"SSB", "AM", "FM", "DIGITALVOICE"})
        if (equalsNoCase(mode, p)) return 1;
    return 2;
}


// ── Mapping callbook data to ADIF fields ────────────────────────────────────

FieldMap mapQrz(const std::map<std::string, std::string> &raw) {
    FieldMap out;
    std::string fname = get(raw, "fname"), name = get(raw, "name");
    put(out, "NAME", trimmed(fname + " " + name));
    put(out, "QTH", get(raw, "addr2"));
    std::string dxcc = get(raw, "dxcc");
    putEntity(out, dxcc);
    std::string state = get(raw, "state"), county = get(raw, "county");
    putState(out, state, dxcc);
    if (usEntity(stripZeros(dxcc)) && out.count("STATE") && !county.empty())
        put(out, "CNTY", out["STATE"] + "," + county);
    // QRZ's geoloc says where its coordinates came from; "dxcc", "state" and
    // "none" are too coarse to be a station's grid or position.
    std::string geoloc = get(raw, "geoloc");
    bool precise = !(equalsNoCase(geoloc, "dxcc") || equalsNoCase(geoloc, "state") || equalsNoCase(geoloc, "none"));
    std::string grid = get(raw, "grid");
    if (precise && isAdifGridSquare(grid)) out["GRIDSQUARE"] = grid;
    if (precise) putLocation(out, get(raw, "lat"), get(raw, "lon"));
    putZone(out, "CQZ", get(raw, "cqzone"), 40);
    putZone(out, "ITUZ", get(raw, "ituzone"), 90);
    put(out, "IOTA", upper(get(raw, "iota")));
    return out;
}

FieldMap mapHamQth(const std::map<std::string, std::string> &raw) {
    FieldMap out;
    std::string name = get(raw, "adr_name");
    put(out, "NAME", name.empty() ? get(raw, "nick") : name);
    std::string qth = get(raw, "qth");
    put(out, "QTH", qth.empty() ? get(raw, "adr_city") : qth);
    std::string dxcc = get(raw, "adif");
    putEntity(out, dxcc);
    std::string state = get(raw, "us_state"), county = get(raw, "us_county");
    putState(out, state, dxcc);
    if (usEntity(stripZeros(dxcc)) && out.count("STATE") && !county.empty())
        put(out, "CNTY", out["STATE"] + "," + county);
    std::string grid = get(raw, "grid");
    if (isAdifGridSquare(grid)) out["GRIDSQUARE"] = grid;
    putLocation(out, get(raw, "latitude"), get(raw, "longitude"));
    putZone(out, "CQZ", get(raw, "cq"), 40);
    putZone(out, "ITUZ", get(raw, "itu"), 90);
    put(out, "IOTA", upper(get(raw, "iota")));
    std::string cont = upper(get(raw, "continent"));
    const EnumDef *ce = findEnum("Continent");
    if (ce && findEnumValue(*ce, cont)) out["CONT"] = cont;
    return out;
}

// ── Calls and locations ─────────────────────────────────────────────────────

std::string lookupCall(std::string_view call) {
    std::string c = upper(trimmed(call));
    if (c.find('/') == std::string::npos) return c;
    // Of the '/'-separated parts, the base call is the longest one with both a
    // letter and a digit that is not a usual suffix.
    static const char *const kSuffixes[] = {"P", "M", "MM", "AM", "QRP", "A", "B", "LH", "R", "J", "E"};
    std::string best;
    size_t start = 0;
    while (start <= c.size()) {
        size_t slash = c.find('/', start);
        std::string part = c.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
        bool letter = false, digit = false;
        for (char ch : part) {
            letter |= ch >= 'A' && ch <= 'Z';
            digit |= ch >= '0' && ch <= '9';
        }
        bool suffix = false;
        for (const char *s : kSuffixes) suffix |= part == s;
        if (letter && digit && !suffix && part.size() > best.size()) best = part;
        if (slash == std::string::npos) break;
        start = slash + 1;
    }
    return best.empty() ? c : best;
}

bool isPortableCall(std::string_view call) { return call.find('/') != std::string_view::npos; }

bool isLocationField(std::string_view f) {
    for (const char *l : {"GRIDSQUARE", "GRIDSQUARE_EXT", "STATE", "CNTY", "QTH", "LAT", "LON", "DXCC", "COUNTRY", "CQZ",
                          "ITUZ", "IOTA", "CONT"})
        if (equalsNoCase(f, l)) return true;
    return false;
}

std::string adifLocation(double degrees, bool latitude) {
    char hemi = latitude ? (degrees < 0 ? 'S' : 'N') : (degrees < 0 ? 'W' : 'E');
    double a = std::fabs(degrees);
    int deg = (int)a;
    // Round to thousandths of a minute, carrying 60.000 into the degrees.
    long milli = std::lround((a - deg) * 60.0 * 1000.0);
    if (milli >= 60000) {
        milli -= 60000;
        ++deg;
    }
    char buf[24];
    snprintf(buf, sizeof buf, "%c%03d %02ld.%03ld", hemi, deg, milli / 1000, milli % 1000);
    return buf;
}

bool awayFromHome(std::string_view text, const DocModel &m, const ModelGroup &g) {
    if (isPortableCall(groupValue(text, m, g, "CALL"))) return true;
    for (const char *f : {"SIG_INFO", "POTA_REF", "SOTA_REF", "WWFF_REF"})
        if (!groupValue(text, m, g, f).empty()) return true;
    return false;
}

// ── Proposals ───────────────────────────────────────────────────────────────

// A confirmation or download replaces a status that says it hasn't happened:
// LOTW_QSL_RCVD and EQSL_QSL_RCVD N, R, Q or I become Y (V, verified, stays);
// QRZCOM_QSO_DOWNLOAD_STATUS N or I becomes Y; APP_QRZLOG_STATUS becomes C.
static bool upgradesStatus(const std::string &field, std::string_view current, std::string_view value) {
    if (field == "LOTW_QSL_RCVD" || field == "EQSL_QSL_RCVD")
        return equalsNoCase(value, "Y") && !equalsNoCase(current, "Y") && !equalsNoCase(current, "V");
    if (field == "QRZCOM_QSO_DOWNLOAD_STATUS") return equalsNoCase(value, "Y") && !equalsNoCase(current, "Y");
    if (field == "APP_QRZLOG_STATUS") return equalsNoCase(value, "C") && !equalsNoCase(current, "C");
    return false;
}

void proposeChanges(std::string_view text, const DocModel &m, int group, const FieldMap &data, const EnrichOptions &opt,
                    const std::string &note, std::vector<EnrichChange> &out) {
    if (group < 0 || (size_t)group >= m.groups.size()) return;
    const ModelGroup &g = m.groups[(size_t)group];
    if (g.header) return;
    bool away = !opt.perQsoData && opt.skipLocationAwayFromHome && awayFromHome(text, m, g);
    std::string call(groupValue(text, m, g, "CALL"));
    int record = recordNumber(m, group);
    for (const std::string &field : opt.fields) {
        auto it = data.find(field);
        if (it == data.end() || it->second.empty()) continue;
        if (away && isLocationField(field)) continue;
        std::string current(groupValue(text, m, g, field));
        EnrichChange c{group, record, call, field, current, it->second, false, true, note};
        if (current.empty()) {
            out.push_back(std::move(c));
        } else if (equalsNoCase(current, it->second)) {
            continue;
        } else if (upgradesStatus(field, current, it->second)) {
            c.replace = true;  // a confirmation upgrades N/R/Q/I: always worth offering
            out.push_back(std::move(c));
        } else if (opt.proposeReplacements) {
            c.replace = true;
            c.accepted = false;
            out.push_back(std::move(c));
        }
    }
}

// ── Edits ───────────────────────────────────────────────────────────────────

std::vector<TextEdit> enrichmentEdits(std::string_view text, const DocModel &m, const std::vector<EnrichChange> &changes,
                                      LengthUnit unit, bool utf8) {
    std::vector<TextEdit> edits;
    std::map<int, TextEdit> inserts;  // one per record
    for (const EnrichChange &c : changes) {
        if (!c.accepted || c.group < 0 || (size_t)c.group >= m.groups.size()) continue;
        const ModelGroup &g = m.groups[(size_t)c.group];
        if (c.replace) {
            for (size_t i = 0; i < g.fieldCount; ++i) {
                const ModelField &f = m.fields[g.firstField + i];
                if (equalsNoCase(fieldName(text, f), c.field)) {
                    edits.push_back(setFieldValue(text, f, c.value, unit, utf8));
                    break;
                }
            }
            continue;
        }
        TextEdit e = insertField(text, m, g, c.field, c.value, unit, utf8);
        auto it = inserts.find(c.group);
        if (it == inserts.end()) inserts.emplace(c.group, e);
        else it->second.text += e.text;  // same position; each piece carries its own separator
    }
    for (auto &kv : inserts) edits.push_back(std::move(kv.second));
    std::sort(edits.begin(), edits.end(), [](const TextEdit &a, const TextEdit &b) {
        return a.start != b.start ? a.start < b.start : a.end < b.end;
    });
    return edits;
}

}  // namespace adif
