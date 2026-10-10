#include "adif_profiles.h"

#include "adif_edit.h"
#include "adif_lint.h"
#include "adif_spec.h"

#include <algorithm>

namespace adif {
namespace {

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

// "US-7929, US-1234" or "US-7929 US-1234": the items, trimmed.
std::vector<std::string> items(std::string_view s) {
    std::vector<std::string> out;
    std::string cur;
    for (size_t i = 0; i <= s.size(); ++i) {
        char c = i < s.size() ? s[i] : ',';
        if (c == ',' || c == ';' || c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            if (!cur.empty()) out.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(c);
        }
    }
    return out;
}

std::string dashed(std::string s) {
    for (char &c : s)
        if (c == '/' || c == '\\' || c == ':') c = '-';
    return s;
}

}  // namespace

std::string StationProfile::get(std::string_view field) const {
    for (const auto &[n, v] : fields)
        if (equalsNoCase(n, field)) return v;
    return {};
}

void StationProfile::set(std::string_view field, std::string value) {
    std::string name = upper(field);
    value = trimmed(value);
    auto it = std::find_if(fields.begin(), fields.end(), [&](const auto &f) { return f.first == name; });
    if (value.empty()) {
        if (it != fields.end()) fields.erase(it);
    } else if (it != fields.end()) {
        it->second = value;
    } else {
        fields.emplace_back(name, value);
    }
}

const std::vector<std::string> &profileFieldNames() {
    static const std::vector<std::string> kNames = {"STATION_CALLSIGN", "OPERATOR",   "MY_GRIDSQUARE", "MY_STATE",
                                                    "MY_CNTY",          "MY_COUNTRY", "MY_DXCC",       "MY_CQ_ZONE",
                                                    "MY_ITU_ZONE",      "MY_RIG",     "MY_ANTENNA",    "TX_PWR"};
    return kNames;
}

std::vector<StationProfile> parseProfiles(std::string_view text) {
    LintOptions opt;
    opt.buildModel = true;
    opt.maxDiagnostics = 0;
    LintResult r = lint(text, opt);
    std::vector<StationProfile> out;
    for (const Record &rec : records(text, r.model)) {
        StationProfile p;
        for (const auto &[name, value] : rec.fields) {
            std::string n = upper(name);
            if (n == "APP_ADIFLINT_PROFILE") p.name = trimmed(value);
            else if (n == "APP_ADIFLINT_TQSL") p.tqslLocation = trimmed(value);
            else if (!value.empty()) p.fields.emplace_back(n, value);
        }
        if (!p.name.empty()) out.push_back(std::move(p));
    }
    return out;
}

std::string profilesText(const std::vector<StationProfile> &profiles, std::string_view programVersion,
                         std::string_view utcTimestamp) {
    std::string out = "ADIF Lint station profiles: one record per profile, named by APP_ADIFLINT_PROFILE.\n";
    out += makeSpecifier("ADIF_VER", kSpecVersion, LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("PROGRAMID", "ADIF Lint", LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("PROGRAMVERSION", programVersion, LengthUnit::Bytes, false) + "\n";
    out += makeSpecifier("CREATED_TIMESTAMP", utcTimestamp, LengthUnit::Bytes, false) + "\n";
    out += "<EOH>\n";
    for (const StationProfile &p : profiles) {
        FieldList fields{{"APP_ADIFLINT_PROFILE", p.name}};
        fields.insert(fields.end(), p.fields.begin(), p.fields.end());
        if (!p.tqslLocation.empty()) fields.emplace_back("APP_ADIFLINT_TQSL", p.tqslLocation);
        out += buildRecord(fields, Layout::RecordPerLine, "\n", LengthUnit::Characters, true).text;
    }
    return out;
}

std::vector<std::string> parseReferences(Program p, std::string_view typed, std::vector<std::string> *bad, std::string *why) {
    std::vector<std::string> refs;
    for (const std::string &item : items(typed)) {
        std::string ref = upper(trimmed(item));
        if (ref.empty() || std::find(refs.begin(), refs.end(), ref) != refs.end()) continue;
        bool ok = p == Program::POTA ? isPotaRef(ref) : p == Program::WWFF ? isAdifWwffRef(ref) : isAdifSotaRef(ref);
        if (ok) refs.push_back(ref);
        else if (bad) bad->push_back(ref);
    }
    if (why) {
        why->clear();
        if (bad && !bad->empty())
            *why = std::string("Not a ") + programName(p) + " reference: " + bad->front() +
                   (p == Program::POTA ? " (e.g. US-7929)" : p == Program::WWFF ? " (e.g. KFF-1234)" : " (e.g. W7A/AE-001)");
        else if (p != Program::POTA && refs.size() > 1)
            *why = std::string(programName(p)) + " takes one reference per log (" +
                   (p == Program::WWFF ? "MY_WWFF_REF" : "MY_SOTA_REF") + " holds one).";
        else if (refs.empty())
            *why = "Type the reference you're activating.";
    }
    return refs;
}

FieldList activationFields(Program p, const std::vector<std::string> &refs) {
    if (refs.empty()) return {};
    std::string list;
    for (const std::string &r : refs) list += (list.empty() ? "" : ",") + r;
    switch (p) {
        case Program::POTA: return {{"MY_SIG", "POTA"}, {"MY_SIG_INFO", list}, {"MY_POTA_REF", list}};
        case Program::WWFF: return {{"MY_SIG", "WWFF"}, {"MY_SIG_INFO", refs.front()}, {"MY_WWFF_REF", refs.front()}};
        case Program::SOTA: return {{"MY_SOTA_REF", refs.front()}};
    }
    return {};
}

std::string activationFileName(Program p, std::string_view call, const std::vector<std::string> &refs, std::string_view date) {
    std::string c = call.empty() ? std::string("NOCALL") : dashed(upper(call));
    std::string joined;
    for (const std::string &r : refs) joined += (joined.empty() ? "" : "+") + dashed(r);
    switch (p) {
        case Program::POTA: return c + "@" + joined + "-" + std::string(date) + ".adi";
        case Program::WWFF: return c + " @ " + joined + " " + std::string(date) + ".adi";
        case Program::SOTA: return c + "_" + joined + "_" + std::string(date) + ".adi";
    }
    return c + "_" + std::string(date) + ".adi";
}

FieldList overlay(const FieldList &base, const FieldList &over) {
    FieldList out = base;
    for (const auto &field : over) {
        auto it = std::find_if(out.begin(), out.end(), [&](const auto &f) { return equalsNoCase(f.first, field.first); });
        if (it != out.end()) it->second = field.second;
        else out.push_back(field);
    }
    return out;
}

}  // namespace adif
