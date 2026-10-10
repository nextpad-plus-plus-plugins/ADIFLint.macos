#include "adif_import.h"

#include "adif_spec.h"

#include <algorithm>
#include <cstdlib>
#include <map>
#include <set>

namespace adif {
namespace {

std::string trimmedCopy(std::string_view s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) --e;
    return std::string(s.substr(b, e - b));
}

std::string upperCopy(std::string_view s) {
    std::string out = trimmedCopy(s);
    for (char &c : out)
        if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    return out;
}

// A record's band: BAND, else the band FREQ lies in.
std::string recordBand(std::string_view text, const DocModel &m, const ModelGroup &g) {
    std::string band = trimmedCopy(groupValue(text, m, g, "BAND"));
    if (band.empty()) band = bandForFrequency(trimmedCopy(groupValue(text, m, g, "FREQ")));
    return band;
}

using Fields = std::vector<std::pair<std::string, std::string>>;

// The record's fields in order (names upper case, values trimmed), without empty ones.
Fields groupFields(std::string_view text, const DocModel &m, const ModelGroup &g) {
    Fields out;
    for (size_t i = 0; i < g.fieldCount; ++i) {
        const ModelField &f = m.fields[g.firstField + i];
        std::string name = upperCopy(fieldName(text, f)), value = trimmedCopy(fieldValue(text, f));
        if (!name.empty() && !value.empty()) out.emplace_back(name, value);
    }
    return out;
}

std::string get(const Fields &f, std::string_view name) {
    for (const auto &kv : f)
        if (kv.first == name) return kv.second;
    return "";
}

void put(Fields &f, const std::string &name, const std::string &value) {
    if (value.empty()) return;
    for (auto &kv : f)
        if (kv.first == name) {
            kv.second = value;
            return;
        }
    f.emplace_back(name, value);
}

// "2026-10-07 18:22:11" or "20261007" -> "20261007"; "" when not a date.
std::string dateOf(std::string_view v) {
    std::string d;
    for (char c : v.substr(0, std::min<size_t>(v.size(), 10)))
        if (c >= '0' && c <= '9') d.push_back(c);
    return d.size() == 8 ? d : "";
}

// An ADIF MODE, or a SUBMODE named where a MODE belongs ("FT4" -> MFSK + FT4); "" when neither.
std::pair<std::string, std::string> adifMode(std::string_view mode, std::string_view submode) {
    std::string m = upperCopy(mode), sm = upperCopy(submode);
    if (m.empty()) return {"", ""};
    static const EnumDef *modes = findEnum("Mode"), *submodes = findEnum("Submode");
    if (modes && findEnumValue(*modes, m)) return {m, sm};
    if (submodes)
        if (const EnumValue *v = findEnumValue(*submodes, m); v && v->scope) return {upperCopy(v->scope), m};
    return {"", ""};
}

// The QSO's identity and whether a record can be built from it.
void finish(SiteQso &q, std::string_view today) {
    (void)today;
    q.call = get(q.fields, "CALL");
    q.date = get(q.fields, "QSO_DATE");
    q.time = get(q.fields, "TIME_ON");
    q.band = get(q.fields, "BAND");
    if (q.band.empty()) q.band = bandForFrequency(get(q.fields, "FREQ"));
    q.mode = get(q.fields, "MODE");
    if (q.call.empty()) q.problem = "no CALL";
    else if (qsoMinutes(q.date, q.time) < 0) q.problem = "no valid QSO_DATE and TIME_ON";
    else if (q.band.empty()) q.problem = "no BAND or FREQ";
    else if (q.mode.empty()) q.problem = "no MODE";
}

// The update's fields in record order: the other station's details, then each
// status before its date.
std::vector<std::string> updateOrder(const FieldMap &update) {
    static const char *const kOrder[] = {"GRIDSQUARE", "VUCC_GRIDS", "STATE", "CNTY", "DXCC", "COUNTRY", "CONT", "CQZ", "ITUZ",
                                         "IOTA", "CREDIT_SUBMITTED", "CREDIT_GRANTED", "LOTW_QSL_SENT", "LOTW_QSLSDATE",
                                         "LOTW_QSL_RCVD", "LOTW_QSLRDATE", "EQSL_QSL_RCVD", "EQSL_QSLRDATE",
                                         "QRZCOM_QSO_UPLOAD_STATUS", "QRZCOM_QSO_DOWNLOAD_STATUS", "QRZCOM_QSO_DOWNLOAD_DATE",
                                         "APP_QRZLOG_STATUS", "APP_QRZLOG_QSLDATE"};
    std::vector<std::string> out;
    for (const char *k : kOrder)
        if (update.count(k)) out.push_back(k);
    for (const auto &kv : update)
        if (std::find(out.begin(), out.end(), kv.first) == out.end()) out.push_back(kv.first);
    return out;
}

void addUpdate(SiteQso &q) {
    for (const std::string &k : updateOrder(q.update)) put(q.fields, k, q.update.at(k));
}

// QRZ.com writes '/' in calls as '_' (observed; Wavelog does the same).
std::string qrzCall(std::string v) {
    for (char &c : v)
        if (c == '_') c = '/';
    return v;
}

SiteQso fromLotw(std::string_view text, const DocModel &m, const ModelGroup &g, std::string_view today) {
    Fields f = groupFields(text, m, g);
    SiteQso q;
    q.group = (int)(&g - m.groups.data());
    std::pair<std::string, std::string> mode = adifMode(get(f, "MODE").empty() ? get(f, "APP_LOTW_MODE") : get(f, "MODE"), "");
    // A new record: the QSO as you uploaded it, your station's details, and the confirmation.
    for (const char *k : {"CALL", "QSO_DATE", "TIME_ON", "BAND", "FREQ", "BAND_RX", "FREQ_RX"}) put(q.fields, k, get(f, k));
    put(q.fields, "MODE", mode.first);
    put(q.fields, "SUBMODE", mode.second);
    for (const char *k : {"PROP_MODE", "SAT_NAME", "STATION_CALLSIGN", "MY_DXCC", "MY_COUNTRY", "MY_CQ_ZONE", "MY_ITU_ZONE",
                          "MY_IOTA", "MY_GRIDSQUARE", "MY_VUCC_GRIDS", "MY_STATE", "MY_CNTY"})
        put(q.fields, k, get(f, k));
    if (get(q.fields, "STATION_CALLSIGN").empty()) put(q.fields, "STATION_CALLSIGN", get(f, "APP_LOTW_OWNCALL"));
    // In LoTW: uploaded, on the day LoTW received it.
    q.update["LOTW_QSL_SENT"] = "Y";
    std::string sent = dateOf(get(f, "APP_LOTW_RXQSO"));
    if (!sent.empty()) q.update["LOTW_QSLSDATE"] = sent;
    q.confirmed = equalsNoCase(get(f, "QSL_RCVD"), "Y");
    if (q.confirmed) {
        q.update["LOTW_QSL_RCVD"] = "Y";
        std::string rcvd = dateOf(get(f, "QSLRDATE"));
        if (!rcvd.empty()) q.update["LOTW_QSLRDATE"] = rcvd;
        // The confirming station's details for this QSO.
        for (const char *k : {"DXCC", "COUNTRY", "CONT", "CQZ", "ITUZ", "IOTA", "GRIDSQUARE", "VUCC_GRIDS", "STATE", "CNTY"}) {
            std::string v = get(f, k);
            if (!v.empty()) q.update[k] = v;
        }
    }
    for (const char *k : {"CREDIT_GRANTED", "CREDIT_SUBMITTED"}) {
        std::string v = get(f, k);
        if (!v.empty()) q.update[k] = v;
    }
    addUpdate(q);
    finish(q, today);
    return q;
}

SiteQso fromQrz(std::string_view text, const DocModel &m, const ModelGroup &g, std::string_view today) {
    Fields f = groupFields(text, m, g);
    SiteQso q;
    q.group = (int)(&g - m.groups.data());
    // QRZ keeps the ADIF you uploaded ("lossless"): a new record is that, without QRZ's own APP_ fields.
    for (const auto &kv : f) {
        if (kv.first.rfind("APP_QRZLOG_", 0) == 0) continue;
        bool call = kv.first == "CALL" || kv.first == "STATION_CALLSIGN" || kv.first == "OPERATOR";
        put(q.fields, kv.first, call ? qrzCall(kv.second) : kv.second);
    }
    std::pair<std::string, std::string> mode = adifMode(get(q.fields, "MODE"), get(q.fields, "SUBMODE"));
    put(q.fields, "MODE", mode.first);
    if (get(q.fields, "SUBMODE").empty()) put(q.fields, "SUBMODE", mode.second);
    q.update["QRZCOM_QSO_UPLOAD_STATUS"] = "Y";  // it is in the logbook
    q.confirmed = equalsNoCase(get(f, "APP_QRZLOG_STATUS"), "C");
    if (q.confirmed) {
        q.update["APP_QRZLOG_STATUS"] = "C";
        std::string d = dateOf(get(f, "APP_QRZLOG_QSLDATE"));
        if (!d.empty()) q.update["APP_QRZLOG_QSLDATE"] = d;
        q.update["QRZCOM_QSO_DOWNLOAD_STATUS"] = "Y";
        if (dateOf(today).size() == 8) q.update["QRZCOM_QSO_DOWNLOAD_DATE"] = dateOf(today);
    }
    addUpdate(q);
    finish(q, today);
    return q;
}

SiteQso fromEqsl(std::string_view text, const DocModel &m, const ModelGroup &g, std::string_view today) {
    Fields f = groupFields(text, m, g);
    SiteQso q;
    q.group = (int)(&g - m.groups.data());
    // An InBox record is the eQSL another station sent you: their call is CALL,
    // and their RST_SENT is the report you received. It is their record, not
    // your log's, so it is offered to add but not ticked.
    std::pair<std::string, std::string> mode = adifMode(get(f, "MODE"), get(f, "SUBMODE"));
    for (const char *k : {"CALL", "QSO_DATE", "TIME_ON", "BAND", "FREQ"}) put(q.fields, k, get(f, k));
    put(q.fields, "MODE", mode.first);
    put(q.fields, "SUBMODE", mode.second);
    put(q.fields, "PROP_MODE", get(f, "PROP_MODE"));
    put(q.fields, "RST_RCVD", get(f, "RST_SENT"));
    q.confirmed = true;  // every InBox record is an eQSL received
    q.addByDefault = false;
    q.update["EQSL_QSL_RCVD"] = "Y";
    std::string d = dateOf(get(f, "EQSL_QSLRDATE"));
    if (!d.empty()) q.update["EQSL_QSLRDATE"] = d;
    std::string grid = get(f, "GRIDSQUARE");
    if (grid.size() >= 4) q.update["GRIDSQUARE"] = grid;
    addUpdate(q);
    finish(q, today);
    return q;
}

}  // namespace

const char *importSiteName(ImportSite s) {
    switch (s) {
        case ImportSite::LoTW: return "LoTW";
        case ImportSite::QRZLogbook: return "QRZ.com Logbook";
        case ImportSite::EQSL: return "eQSL";
    }
    return "";
}

std::vector<SiteQso> siteQsos(ImportSite site, std::string_view text, const DocModel &m, std::string_view today) {
    std::vector<SiteQso> out;
    for (const ModelGroup &g : m.groups) {
        if (g.header || !g.fieldCount) continue;
        SiteQso q = site == ImportSite::LoTW         ? fromLotw(text, m, g, today)
                    : site == ImportSite::QRZLogbook ? fromQrz(text, m, g, today)
                                                     : fromEqsl(text, m, g, today);
        // Values must be ASCII (ADI is ASCII only, §III.A); anything else is left out.
        SiteQso clean = q;
        clean.fields.clear();
        for (const auto &kv : q.fields) {
            bool ascii = true;
            for (unsigned char c : kv.second) ascii &= c >= 0x20 && c < 0x7f;
            if (ascii) clean.fields.push_back(kv);
        }
        for (auto it = clean.update.begin(); it != clean.update.end();) {
            bool ascii = true;
            for (unsigned char c : it->second) ascii &= c >= 0x20 && c < 0x7f;
            it = ascii ? std::next(it) : clean.update.erase(it);
        }
        out.push_back(std::move(clean));
    }
    return out;
}

std::vector<ImportItem> planImport(std::string_view logText, const DocModel &log, const std::vector<SiteQso> &qsos,
                                   ImportSite site) {
    std::vector<ImportItem> items(qsos.size());
    for (size_t i = 0; i < qsos.size(); ++i) items[i].qso = i;

    std::map<std::string, std::vector<int>> byCall;  // the log's records by CALL
    for (size_t gi = 0; gi < log.groups.size(); ++gi) {
        const ModelGroup &g = log.groups[gi];
        if (g.header || !g.fieldCount) continue;
        std::string call = upperCopy(groupValue(logText, log, g, "CALL"));
        if (!call.empty()) byCall[call].push_back((int)gi);
    }
    struct Candidate {
        size_t qso;
        int group;
        bool exact;
        long diff;
    };
    std::vector<Candidate> candidates;
    for (size_t qi = 0; qi < qsos.size(); ++qi) {
        const SiteQso &q = qsos[qi];
        long qm = qsoMinutes(q.date, q.time);
        auto it = byCall.find(upperCopy(q.call));
        if (qm < 0 || it == byCall.end()) continue;
        for (int gi : it->second) {
            const ModelGroup &g = log.groups[(size_t)gi];
            if (!equalsNoCase(recordBand(logText, log, g), q.band)) continue;
            long lm = qsoMinutes(trimmedCopy(groupValue(logText, log, g, "QSO_DATE")), trimmedCopy(groupValue(logText, log, g, "TIME_ON")));
            if (lm < 0) continue;
            long diff = std::labs(lm - qm);
            if (diff > 30) continue;
            std::string mode = trimmedCopy(groupValue(logText, log, g, "MODE"));
            bool exact = equalsNoCase(mode, q.mode);
            if (!exact && modeGroup(mode) != modeGroup(q.mode)) continue;
            candidates.push_back({qi, gi, exact, diff});
        }
    }
    // The best pairs first: the same mode, then the closest time, then the download's order.
    std::stable_sort(candidates.begin(), candidates.end(), [](const Candidate &a, const Candidate &b) {
        if (a.exact != b.exact) return a.exact;
        return a.diff < b.diff;
    });
    std::set<int> usedGroups;
    std::vector<bool> usedQsos(qsos.size(), false);
    for (const Candidate &c : candidates) {
        if (usedQsos[c.qso] || usedGroups.count(c.group)) continue;
        usedQsos[c.qso] = true;
        usedGroups.insert(c.group);
        ImportItem &item = items[c.qso];
        item.group = c.group;
        item.record = recordNumber(log, c.group);
        const SiteQso &q = qsos[c.qso];
        EnrichOptions opt;
        opt.fields = updateOrder(q.update);
        opt.perQsoData = true;  // the site's data describes this QSO
        std::string note = std::string(q.confirmed ? "Confirmed in " : "In ") + importSiteName(site);
        proposeChanges(logText, log, c.group, q.update, opt, note, item.changes);
        item.kind = item.changes.empty() ? ImportItem::Kind::InLog : ImportItem::Kind::Update;
    }
    return items;
}

std::string importedRecords(const std::vector<SiteQso> &qsos, const std::vector<size_t> &which, Layout layout,
                            std::string_view eol, LengthUnit unit, bool utf8) {
    std::string out;
    for (size_t i : which) {
        if (i >= qsos.size() || qsos[i].fields.empty()) continue;
        if (!out.empty() && layout == Layout::FieldPerLine) out += eol;  // a blank line between records
        out += buildRecord(qsos[i].fields, layout, eol, unit, utf8).text;
    }
    return out;
}

}  // namespace adif
