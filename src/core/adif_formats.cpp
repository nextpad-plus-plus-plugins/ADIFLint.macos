#include "adif_formats.h"

#include "adif_spec.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>

namespace adif {
namespace {

std::string trim(std::string_view s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) --e;
    return std::string(s.substr(b, e - b));
}

std::string up(std::string_view s) {
    std::string o(s);
    for (char &c : o)
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
    return o;
}

std::string low(std::string_view s) {
    std::string o(s);
    for (char &c : o)
        if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
    return o;
}

bool digits(std::string_view s) {
    if (s.empty()) return false;
    for (char c : s)
        if (c < '0' || c > '9') return false;
    return true;
}

// A header cell as a key: "RST Sent" -> "RST_SENT".
std::string key(std::string_view h) {
    std::string k = up(trim(h));
    if (k.size() >= 3 && (unsigned char)k[0] == 0xEF && (unsigned char)k[1] == 0xBB && (unsigned char)k[2] == 0xBF) k.erase(0, 3);
    std::string out;
    for (char c : k) {
        if (c == '(' || c == ')' || c == '[' || c == ']') continue;  // "Freq (kHz)" -> FREQ_KHZ
        out.push_back(c == ' ' || c == '-' || c == '.' || c == '/' ? '_' : c);
    }
    while (out.find("__") != std::string::npos) out.erase(out.find("__"), 1);
    while (!out.empty() && out.back() == '_') out.pop_back();
    return out;
}

std::string columnField(std::string_view header, bool *kHz) {
    std::string k = key(header);
    *kHz = k == "FREQ_KHZ" || k == "KHZ" || k == "FREQUENCY_KHZ";
    if (*kHz) return "FREQ";
    static const std::map<std::string, std::string> aliases = {
        {"CALLSIGN", "CALL"},       {"CALL_SIGN", "CALL"},       {"THEIR_CALL", "CALL"},      {"WORKED", "CALL"},
        {"DATE", "QSO_DATE"},       {"UTC_DATE", "QSO_DATE"},    {"QSODATE", "QSO_DATE"},     {"TIME", "TIME_ON"},
        {"UTC", "TIME_ON"},         {"UTC_TIME", "TIME_ON"},     {"TIME_UTC", "TIME_ON"},     {"START", "TIME_ON"},
        {"QSO_TIME", "TIME_ON"},    {"FREQUENCY", "FREQ"},       {"FREQ_MHZ", "FREQ"},        {"MHZ", "FREQ"},
        {"RST_S", "RST_SENT"},      {"RSTS", "RST_SENT"},        {"SENT", "RST_SENT"},        {"RST_TX", "RST_SENT"},
        {"RST_R", "RST_RCVD"},      {"RSTR", "RST_RCVD"},        {"RCVD", "RST_RCVD"},        {"RECEIVED", "RST_RCVD"},
        {"RST_RX", "RST_RCVD"},     {"GRID", "GRIDSQUARE"},      {"LOCATOR", "GRIDSQUARE"},   {"GRID_SQUARE", "GRIDSQUARE"},
        {"THEIR_GRID", "GRIDSQUARE"}, {"NOTES", "COMMENT"},      {"NOTE", "COMMENT"},         {"COMMENTS", "COMMENT"},
        {"REMARKS", "COMMENT"},     {"PARK", "POTA_REF"},        {"PARK_REF", "POTA_REF"},    {"THEIR_PARK", "POTA_REF"},
        {"MY_PARK", "MY_POTA_REF"}, {"MY_CALL", "STATION_CALLSIGN"}, {"COUNTY", "CNTY"},     {"POWER", "TX_PWR"},
        {"TX_POWER", "TX_PWR"},     {"PWR", "TX_PWR"},           {"MY_GRID", "MY_GRIDSQUARE"}, {"SUMMIT", "SOTA_REF"},
    };
    auto it = aliases.find(k);
    if (it != aliases.end()) return it->second;
    const FieldDef *f = findField(k);
    if (f && !f->header && !f->importOnly) return f->name;
    if (k.rfind("APP_", 0) == 0 && k.size() > 4) return k;
    return "";
}

std::string normalDate(const std::string &v) {
    std::string d;
    for (char c : v)
        if (c != '-' && c != '/') d.push_back(c);
    // Only year-first forms: "10/06/26" could be either month or day first.
    if (v.size() == 10 && (v[4] == '-' || v[4] == '/') && digits(d) && d.size() == 8) return d;
    if (v.size() == 8 && digits(v)) return v;
    return "";
}

std::string normalTime(const std::string &v) {
    std::string t;
    for (char c : v)
        if (c != ':') t.push_back(c);
    if (digits(t) && (t.size() == 4 || t.size() == 6)) return t;
    if (digits(t) && t.size() == 3) return "0" + t;  // "930"
    return "";
}

}  // namespace

std::vector<std::vector<std::string>> parseCsv(std::string_view csv) {
    if (csv.size() >= 3 && (unsigned char)csv[0] == 0xEF && (unsigned char)csv[1] == 0xBB && (unsigned char)csv[2] == 0xBF)
        csv.remove_prefix(3);  // UTF-8 byte order mark
    char delim = ',';
    {
        size_t nl = csv.find('\n');
        std::string_view first = csv.substr(0, nl);
        size_t c = 0, s = 0, t = 0;
        for (char ch : first) c += ch == ',', s += ch == ';', t += ch == '\t';
        if (s > c && s >= t) delim = ';';
        else if (t > c && t > s) delim = '\t';
    }
    std::vector<std::vector<std::string>> rows;
    std::vector<std::string> row;
    std::string cell;
    bool quoted = false, any = false;
    for (size_t i = 0; i < csv.size(); ++i) {
        char ch = csv[i];
        if (quoted) {
            if (ch == '"') {
                if (i + 1 < csv.size() && csv[i + 1] == '"') cell.push_back('"'), ++i;
                else quoted = false;
            } else {
                cell.push_back(ch);
            }
            continue;
        }
        if (ch == '"' && cell.empty()) quoted = true, any = true;
        else if (ch == delim) row.push_back(cell), cell.clear(), any = true;
        else if (ch == '\r') continue;
        else if (ch == '\n') {
            if (any || !cell.empty()) row.push_back(cell), rows.push_back(row);
            row.clear(), cell.clear(), any = false;
        } else {
            cell.push_back(ch), any = true;
        }
    }
    if (any || !cell.empty()) row.push_back(cell), rows.push_back(row);
    return rows;
}

CsvImport importCsv(std::string_view csv) {
    CsvImport out;
    std::vector<std::vector<std::string>> rows = parseCsv(csv);
    if (rows.empty()) return out;
    std::vector<std::string> fields;
    std::vector<bool> kHz;
    for (const std::string &h : rows[0]) {
        bool k = false;
        std::string f = columnField(h, &k);
        // A field named twice: the first column wins.
        for (const std::string &seen : fields)
            if (!f.empty() && seen == f) f.clear();
        fields.push_back(f);
        kHz.push_back(k);
        out.columns.emplace_back(trim(h), f);
    }
    for (size_t r = 1; r < rows.size(); ++r) {
        std::vector<std::pair<std::string, std::string>> rec;
        for (size_t c = 0; c < rows[r].size() && c < fields.size(); ++c) {
            if (fields[c].empty()) continue;
            std::string v = trim(rows[r][c]);
            if (v.size() > 1 && v[0] == '\'' && std::string("=+-@\t\r").find(v[1]) != std::string::npos) v.erase(0, 1);
            if (v.empty()) continue;
            const std::string &f = fields[c];
            std::string row = "row " + std::to_string(r + 1);
            if (f == "QSO_DATE" || f == "QSO_DATE_OFF") {
                std::string d = normalDate(v);
                if (d.empty()) out.notes.push_back(row + ": date \"" + v + "\" not understood (use YYYY-MM-DD)");
                else v = d;
            } else if (f == "TIME_ON" || f == "TIME_OFF") {
                std::string t = normalTime(v);
                if (t.empty()) out.notes.push_back(row + ": time \"" + v + "\" not understood (use HH:MM)");
                else v = t;
            } else if (f == "FREQ" || f == "FREQ_RX") {
                double x = std::atof(v.c_str());
                if (kHz[c] || x >= 1000) {
                    std::string mhz = khzToMHz(v);
                    if (!mhz.empty()) v = mhz;
                }
            } else if (f == "BAND" || f == "BAND_RX") {
                v = low(v);
            } else if (f == "CALL" || f == "MODE" || f == "SUBMODE" || f == "STATION_CALLSIGN" || f == "OPERATOR" ||
                       f == "GRIDSQUARE" || f == "POTA_REF" || f == "MY_POTA_REF" || f == "SOTA_REF" || f == "WWFF_REF") {
                v = up(v);
            }
            rec.emplace_back(f, v);
        }
        if (!rec.empty()) out.records.push_back(std::move(rec));
    }
    return out;
}

std::string cabrilloFreq(const Record &r) {
    std::string band = effectiveBand(r);
    static const std::map<std::string, std::string> vhf = {
        {"6m", "50"},     {"4m", "70"},      {"2m", "144"},    {"1.25m", "222"}, {"70cm", "432"},  {"33cm", "902"},
        {"23cm", "1.2G"}, {"13cm", "2.3G"},  {"9cm", "3.4G"},  {"6cm", "5.7G"},  {"3cm", "10G"},   {"1.25cm", "24G"},
        {"6mm", "47G"},   {"4mm", "75G"},    {"2.5mm", "122G"}, {"2mm", "134G"}, {"1mm", "241G"}};
    auto v = vhf.find(band);
    if (v != vhf.end()) return v->second;
    double mhz = 0;
    if (parseAdifNumber(r.get("FREQ"), &mhz) && mhz > 0) return std::to_string((long)std::lround(mhz * 1000));
    static const std::map<std::string, std::string> hf = {{"160m", "1800"}, {"80m", "3500"}, {"40m", "7000"},
                                                          {"20m", "14000"}, {"15m", "21000"}, {"10m", "28000"}};
    auto h = hf.find(band);
    if (h != hf.end()) return h->second;
    if (const BandDef *b = findBand(band)) return std::to_string((long)std::lround(b->lowerMHz * 1000));
    return "";
}

std::string cabrilloMode(const Record &r) {
    std::string m = up(r.get("MODE"));
    if (m.empty()) m = effectiveMode(r);
    if (m == "CW") return "CW";
    if (m == "SSB" || m == "AM" || m == "USB" || m == "LSB") return "PH";
    if (m == "FM") return "FM";
    if (m == "RTTY") return "RY";
    if (m.empty()) return "";
    return "DG";
}

CabrilloLog toCabrillo(const std::vector<Record> &recs, const CabrilloOptions &o) {
    CabrilloLog out;
    std::string t = "START-OF-LOG: 3.0\n";
    auto tag = [&](const char *name, const std::string &v) {
        if (!v.empty()) t += std::string(name) + ": " + v + "\n";
    };
    std::string contest;
    for (char c : up(o.contest))
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-') contest.push_back(c);
    if (contest.size() > 32) contest.resize(32);
    tag("CONTEST", contest);
    tag("CALLSIGN", up(o.callsign));
    tag("CATEGORY-OPERATOR", o.categoryOperator);
    tag("CATEGORY-POWER", o.categoryPower);
    tag("CATEGORY-STATION", o.categoryStation);
    tag("GRID-LOCATOR", o.grid);
    tag("LOCATION", o.location);
    tag("OPERATORS", up(o.operators));
    tag("CREATED-BY", o.createdBy);
    for (const Record &r : recs) {
        std::string call = up(trim(r.get("CALL"))), date = r.get("QSO_DATE"), time = r.get("TIME_ON");
        std::string freq = cabrilloFreq(r), mode = cabrilloMode(r);
        if (call.empty() || !parseAdifDate(date, nullptr) || !parseAdifTime(time, nullptr) || freq.empty() || mode.empty()) {
            ++out.skipped;
            continue;
        }
        std::string mine = stationCall(r);
        if (mine.empty()) mine = up(o.callsign);
        auto value = [](const std::string &a, const std::string &b) { return !a.empty() ? a : b; };
        // The Field Days: no reports; class and section as their own words (W1AW 2A CT K1ABC 3A EMA).
        std::string contest = up(trim(r.get("CONTEST_ID")));
        if (contest == "ARRL-FIELD-DAY" || contest == "WFD") {
            std::string sent = up(trim(r.get("STX_STRING")));
            std::string rcvd = up(trim(r.get("SRX_STRING")));
            if (rcvd.empty()) rcvd = up(trim(trim(r.get("CLASS")) + " " + trim(r.get("ARRL_SECT"))));
            bool missing = sent.empty() || rcvd.empty();
            out.incomplete += missing;
            std::string l = "QSO: " + std::string(5 - std::min<size_t>(5, freq.size()), ' ') + freq + " " + mode + (mode.size() < 2 ? " " : "") +
                            " " + date.substr(0, 4) + "-" + date.substr(4, 2) + "-" + date.substr(6, 2) + " " + time.substr(0, 4) + " " +
                            (mine.empty() ? "-" : mine) + " " + (sent.empty() ? "-" : sent) + " " + call + " " + (rcvd.empty() ? "-" : rcvd) + "\n";
            t += l;
            ++out.qsos;
            continue;
        }
        std::string rstS = trim(r.get("RST_SENT")), rstR = trim(r.get("RST_RCVD"));
        std::string exS = value(trim(r.get("STX_STRING")), trim(r.get("STX"))), exR = value(trim(r.get("SRX_STRING")), trim(r.get("SRX")));
        bool missing = false;
        for (std::string *f : {&rstS, &rstR, &exS, &exR}) {
            for (char &c : *f)
                if (c == ' ') c = '-';
            if (f->empty()) *f = "-", missing = true;
        }
        out.incomplete += missing;
        char line[256];
        std::snprintf(line, sizeof line, "QSO: %5s %-2s %s-%s-%s %s %-13s %3s %-6s %-13s %3s %-6s\n", freq.c_str(), mode.c_str(),
                      date.substr(0, 4).c_str(), date.substr(4, 2).c_str(), date.substr(6, 2).c_str(), time.substr(0, 4).c_str(),
                      mine.empty() ? "-" : mine.c_str(), rstS.c_str(), exS.c_str(), call.c_str(), rstR.c_str(), exR.c_str());
        std::string l = line;
        while (l.size() > 1 && l[l.size() - 2] == ' ') l.erase(l.size() - 2, 1);
        t += l;
        ++out.qsos;
    }
    t += "END-OF-LOG:\n";
    out.text = t;
    return out;
}

}  // namespace adif
