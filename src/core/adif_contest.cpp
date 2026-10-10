#include "adif_contest.h"

#include "adif_enrich.h"
#include "adif_spec.h"

#include <algorithm>
#include <cstdlib>
#include <iterator>

namespace adif {
namespace {

std::string trimmed(std::string_view s) {
    size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
    return b == std::string_view::npos ? std::string() : std::string(s.substr(b, e - b + 1));
}

std::string upper(std::string_view s) {
    std::string o(s);
    for (char &c : o)
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
    return o;
}

bool isSection(std::string_view s) {
    const EnumDef *e = findEnum("ARRL_Section");
    return e && findEnumValue(*e, s);
}

// "1D IL" -> ("1D", "IL"); extra spaces allowed.
std::pair<std::string, std::string> splitExchange(std::string_view sent) {
    std::string s = upper(trimmed(sent));
    size_t sp = s.find_first_of(" \t");
    if (sp == std::string::npos) return {s, ""};
    return {s.substr(0, sp), trimmed(s.substr(sp))};
}

std::string get(const std::vector<std::pair<std::string, std::string>> &f, const char *name) {
    for (const auto &kv : f)
        if (kv.first == name) return trimmed(kv.second);
    return {};
}

}  // namespace

const char *contestPresetName(ContestPreset p) {
    switch (p) {
        case ContestPreset::FieldDay: return "ARRL Field Day";
        case ContestPreset::WinterFieldDay: return "Winter Field Day";
        case ContestPreset::Serial: return "Serial numbers";
        case ContestPreset::None: break;
    }
    return "";
}

std::vector<std::string> contestRows(ContestPreset p) {
    switch (p) {
        case ContestPreset::FieldDay:
        case ContestPreset::WinterFieldDay: return {"CLASS", "ARRL_SECT"};
        case ContestPreset::Serial: return {"SRX"};
        case ContestPreset::None: break;
    }
    return {};
}

std::string contestIdFor(const ContestSetup &s) {
    switch (s.preset) {
        case ContestPreset::FieldDay: return "ARRL-FIELD-DAY";
        case ContestPreset::WinterFieldDay: return "WFD";
        case ContestPreset::Serial: return upper(trimmed(s.contestId));
        case ContestPreset::None: break;
    }
    return "";
}

std::string classProblem(ContestPreset p, std::string_view cls) {
    std::string c = upper(trimmed(cls));
    if (c.empty() || (p != ContestPreset::FieldDay && p != ContestPreset::WinterFieldDay)) return "";
    size_t digits = 0;
    while (digits < c.size() && c[digits] >= '0' && c[digits] <= '9') ++digits;
    std::string letters = c.substr(digits);
    bool ok = digits >= 1 && digits <= 2 && c[0] != '0';
    if (p == ContestPreset::WinterFieldDay) {
        ok = ok && letters.size() == 1 && std::string("HIOM").find(letters[0]) != std::string::npos;
        return ok ? "" : "Winter Field Day sends the number of transmitters and a category, H, I, O or M, such as 2O.";
    }
    ok = ok && !letters.empty() && letters.size() <= 2 && std::all_of(letters.begin(), letters.end(), [](char ch) { return ch >= 'A' && ch <= 'F'; });
    return ok ? "" : "A Field Day class is the number of transmitters and a letter A to F, such as 3A.";
}

std::string sectionProblem(ContestPreset p, std::string_view section) {
    std::string s = upper(trimmed(section));
    if (s.empty() || (p != ContestPreset::FieldDay && p != ContestPreset::WinterFieldDay)) return "";
    if (isSection(s) || s == "DX" || (p == ContestPreset::WinterFieldDay && s == "MX")) return "";
    return p == ContestPreset::WinterFieldDay ? "Not an ARRL or RAC section (or MX, DX): " + s
                                              : "Not an ARRL or RAC section (or DX): " + s;
}

std::string sentProblem(const ContestSetup &s) {
    if (s.preset != ContestPreset::FieldDay && s.preset != ContestPreset::WinterFieldDay) return "";
    auto [cls, sect] = splitExchange(s.sent);
    if (cls.empty() || sect.empty())
        return s.preset == ContestPreset::FieldDay ? "Type your class and section, such as 1D IL." : "Type your class, category and section, such as 2O IL.";
    std::string p = classProblem(s.preset, cls);
    if (p.empty()) p = sectionProblem(s.preset, sect);
    return p;
}

std::vector<std::pair<std::string, std::string>> contestFields(const ContestSetup &s,
                                                               const std::vector<std::pair<std::string, std::string>> &qso,
                                                               int serial) {
    std::vector<std::pair<std::string, std::string>> out;
    if (s.preset == ContestPreset::None) return out;
    std::string id = contestIdFor(s);
    if (!id.empty()) out.emplace_back("CONTEST_ID", id);
    if (s.preset == ContestPreset::Serial) {
        if (serial > 0) out.emplace_back("STX", std::to_string(serial));
        return out;
    }
    auto [cls, sect] = splitExchange(s.sent);
    if (!cls.empty()) out.emplace_back("STX_STRING", cls + (sect.empty() ? "" : " " + sect));
    if (isSection(sect)) out.emplace_back("MY_ARRL_SECT", sect);
    std::string theirClass = upper(get(qso, "CLASS")), theirSect = upper(get(qso, "ARRL_SECT"));
    if (!theirClass.empty() || !theirSect.empty())
        out.emplace_back("SRX_STRING", theirClass + (theirClass.empty() || theirSect.empty() ? "" : " ") + theirSect);
    return out;
}

int nextSerial(std::string_view text, const DocModel &m, std::string_view contestId) {
    long most = 0;
    for (const Record &r : records(text, m)) {
        if (!contestId.empty() && !equalsNoCase(trimmed(r.get("CONTEST_ID")), contestId)) continue;
        std::string stx = trimmed(r.get("STX"));
        char *end = nullptr;
        long n = std::strtol(stx.c_str(), &end, 10);
        if (!stx.empty() && end && *end == '\0' && n > most) most = n;
    }
    return (int)most + 1;
}

std::string modeCategory(std::string_view mode) {
    std::string m = upper(trimmed(mode));
    if (m == "CW") return "CW";
    if (m == "SSB" || m == "AM" || m == "FM" || m == "DIGITALVOICE" || m == "USB" || m == "LSB") return "PH";
    return "DG";
}

std::string contestRuleProblem(ContestPreset p, const Record &qso) {
    if (p != ContestPreset::FieldDay && p != ContestPreset::WinterFieldDay) return "";
    std::string band = effectiveBand(qso), prop = upper(trimmed(qso.get("PROP_MODE")));
    if (p == ContestPreset::FieldDay) {
        static const char *const hf[] = {"160m", "80m", "40m", "20m", "15m", "10m"};
        const BandDef *b = findBand(band);
        bool counted = !b || b->lowerMHz >= 50 || std::find(std::begin(hf), std::end(hf), band) != std::end(hf);
        if (!counted) return "ARRL Field Day counts 160, 80, 40, 20, 15 and 10 m and 6 m and up, not " + band + ".";
        if (prop == "RPT") return "ARRL Field Day doesn't count repeater contacts.";
        return "";
    }
    if (band == "12m" || band == "17m" || band == "30m" || band == "60m")
        return "Winter Field Day doesn't use 12, 17, 30 or 60 m.";
    static const char *const wsjt[] = {"FT2", "FST4", "FT4", "FT8", "JT4", "JT9", "JT65", "Q65", "MSK144", "WSPR", "FST4W", "ECHO"};
    for (const char *m : {"MODE", "SUBMODE"}) {
        std::string v = upper(trimmed(qso.get(m)));
        if (std::find(std::begin(wsjt), std::end(wsjt), v) != std::end(wsjt))
            return "Winter Field Day doesn't count WSJT modes such as " + v + ".";
    }
    if (prop == "RPT" || prop == "SAT" || prop == "ECH" || prop == "INTERNET" || prop == "IRL")
        return "Winter Field Day counts only direct simplex contacts, not through a repeater, satellite or the internet.";
    return "";
}

std::vector<int> contestDupes(std::string_view text, const DocModel &m, std::string_view contestId, const Record &qso) {
    std::vector<int> out;
    std::string call = lookupCall(upper(trimmed(qso.get("CALL"))));
    std::string band = upper(effectiveBand(qso)), cat = modeCategory(qso.get("MODE"));
    if (call.empty() || band.empty()) return out;
    for (const Record &r : records(text, m)) {
        if (!contestId.empty() && !equalsNoCase(trimmed(r.get("CONTEST_ID")), contestId)) continue;
        if (lookupCall(upper(trimmed(r.get("CALL")))) != call || upper(effectiveBand(r)) != band) continue;
        if (modeCategory(r.get("MODE")) != cat) continue;
        out.push_back(r.number);
    }
    return out;
}

}  // namespace adif
