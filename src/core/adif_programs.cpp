#include "adif_programs.h"

#include "adif_enrich.h"
#include "adif_lint.h"
#include "adif_spec.h"

#include <algorithm>
#include <map>
#include <set>
#include <tuple>

namespace adif {
namespace {

std::string up(std::string_view s) {
    std::string o;
    for (char c : s)
        if (c != ' ' && c != '\t' && c != '\r' && c != '\n') o.push_back((c >= 'a' && c <= 'z') ? (char)(c - 32) : c);
    return o;
}

std::string low(std::string_view s) {
    std::string o;
    for (char c : s)
        if (c != ' ' && c != '\t' && c != '\r' && c != '\n') o.push_back((c >= 'A' && c <= 'Z') ? (char)(c + 32) : c);
    return o;
}

std::string usualStation(const std::vector<Record> &recs) {
    std::map<std::string, size_t> n;
    std::string best;
    size_t most = 0;
    for (const Record &r : recs)
        if (std::string s = stationCall(r); !s.empty() && ++n[s] > most) most = n[s], best = s;
    return best;
}

// WWFF and SOTA. perDay: one per UTC date (always so for SOTA; WWFF export files).
std::vector<Activation> collect(std::string_view text, const DocModel &m, Program p, std::string_view defaultStation,
                                bool perDay) {
    std::vector<Record> recs = records(text, m);
    std::string fallback = up(defaultStation);
    if (fallback.empty()) fallback = usualStation(recs);
    using Key = std::tuple<std::string, std::string, std::string>;  // (date or "", reference, station)
    std::map<Key, Activation> acts;
    std::map<Key, std::set<std::string>> seen;
    bool daily = perDay || p == Program::SOTA;
    for (const Record &r : recs) {
        std::vector<std::string> mine = programRefs(r, p, true);
        const std::string &date = r.get("QSO_DATE");
        if (mine.empty() || !parseAdifDate(date, nullptr)) continue;
        std::string station = stationCall(r), call = up(r.get("CALL"));
        bool noStation = station.empty();
        if (noStation) station = fallback;
        std::string band = low(r.get("BAND")), mode = effectiveMode(r), time = r.get("TIME_ON");
        bool valid = !call.empty() && parseAdifTime(time, nullptr) && !band.empty() && !mode.empty() && call != station &&
                     call != up(r.get("OPERATOR"));
        bool toRef = !programRefs(r, p, false).empty();
        for (const std::string &ref : mine) {
            Key key{daily ? date : std::string(), ref, station};
            Activation &a = acts[key];
            if (a.groups.empty()) {
                a.program = p;
                a.needed = p == Program::WWFF ? 44 : 4;
                a.station = station;
                a.park = ref;
                a.date = a.lastDate = date;
            }
            a.date = std::min(a.date, date);
            a.lastDate = std::max(a.lastDate, date);
            a.groups.push_back(r.group);
            a.noStation += noStation;
            if (parseAdifTime(time, nullptr) && daily) {
                std::string t = time.size() == 4 ? time + "00" : time;
                if (a.first.empty() || t < a.first) a.first = t;
                if (a.last.empty() || t > a.last) a.last = t;
            }
            if (!valid) {
                ++a.invalid;
                continue;
            }
            // WWFF: the same call counts again on another band, mode or date. SOTA: different stations.
            std::string once = p == Program::WWFF ? call + "|" + band + "|" + mode + "|" + date : call;
            if (!seen[key].insert(once).second) {
                ++a.duplicates;
                continue;
            }
            ++a.qsos;
            ++a.bands[band];
            ++a.modes[mode];
            if (toRef) ++a.p2p;
        }
    }
    std::vector<Activation> out;
    for (auto &kv : acts) out.push_back(std::move(kv.second));
    std::stable_sort(out.begin(), out.end(), [](const Activation &x, const Activation &y) {
        return std::tie(x.date, x.park, x.station) < std::tie(y.date, y.park, y.station);
    });
    return out;
}

std::string fileSafe(std::string s, char slash) {
    for (char &c : s)
        if (c == '/' || c == '\\' || c == ':') c = slash;
    return s;
}

}  // namespace

std::vector<Activation> programActivations(std::string_view text, const DocModel &m, Program p, std::string_view defaultStation) {
    if (p == Program::POTA) return activations(text, m, defaultStation);
    return collect(text, m, p, defaultStation, false);
}

std::vector<PotaFile> programExport(Program p, std::string_view text, const DocModel &m, std::string_view defaultStation,
                                    std::string_view programVersion, std::string_view utcTimestamp, std::string_view eol,
                                    LengthUnit unit, bool utf8, std::string_view todayUtc) {
    if (p == Program::POTA)
        return potaExport(text, m, defaultStation, programVersion, utcTimestamp, eol, unit, utf8, todayUtc);
    std::vector<PotaFile> out;
    const char *refField = p == Program::WWFF ? "MY_WWFF_REF" : "MY_SOTA_REF";
    std::vector<Activation> acts = collect(text, m, p, defaultStation, true);
    if (p == Program::WWFF) {
        // A multi-date activation is one log, named for its first day (wwff.co "Confirming and
        // sending log", checked 2026-10-09): join a reference's consecutive UTC days. Each day
        // counts its own QSOs, as collect() did.
        std::stable_sort(acts.begin(), acts.end(), [](const Activation &x, const Activation &y) {
            return std::tie(x.park, x.station, x.date) < std::tie(y.park, y.station, y.date);
        });
        std::vector<Activation> joined;
        for (Activation &a : acts) {
            Activation *prev = joined.empty() ? nullptr : &joined.back();
            if (prev && prev->park == a.park && prev->station == a.station &&
                qsoMinutes(a.date, "0000") - qsoMinutes(prev->lastDate, "0000") == 24 * 60) {
                prev->lastDate = a.lastDate;
                prev->groups.insert(prev->groups.end(), a.groups.begin(), a.groups.end());
                prev->qsos += a.qsos, prev->duplicates += a.duplicates, prev->invalid += a.invalid;
                prev->noStation += a.noStation, prev->p2p += a.p2p;
                for (const auto &[k, n] : a.bands) prev->bands[k] += n;
                for (const auto &[k, n] : a.modes) prev->modes[k] += n;
                prev->last = a.last;
            } else {
                joined.push_back(std::move(a));
            }
        }
        for (Activation &a : joined) std::sort(a.groups.begin(), a.groups.end());
        std::stable_sort(joined.begin(), joined.end(), [](const Activation &x, const Activation &y) {
            return std::tie(x.date, x.park, x.station) < std::tie(y.date, y.park, y.station);
        });
        acts = std::move(joined);
    }
    for (const Activation &a : acts) {
        PotaFile f;
        f.station = a.station;
        f.park = a.park;
        f.date = a.date;
        // WWFF: "{callsign} @ {reference} {date}", '/' in the call as '-' (wwff.co, checked
        // 2026-10-09; the Logsearch upload form asks for "callsign @ reference YYYYMMDD").
        std::string call = f.station.empty() ? std::string("NOCALL") : fileSafe(f.station, p == Program::WWFF ? '-' : '_');
        f.name = p == Program::WWFF ? call + " @ " + fileSafe(a.park, '-') + " " + a.date + ".adi"
                                    : call + "_" + fileSafe(a.park, '-') + "_" + a.date + ".adi";
        std::string h = std::string("ADIF export for ") + (p == Program::WWFF ? "World Wide Flora & Fauna" : "Summits on the Air") +
                        ": " + (f.station.empty() ? std::string("?") : f.station) + " at " + a.park + " on " +
                        displayDate(a.date) + (a.lastDate != a.date ? " to " + displayDate(a.lastDate) : std::string()) +
                        " UTC";
        h += eol;
        h += makeSpecifier("ADIF_VER", kSpecVersion, LengthUnit::Bytes, false) + std::string(eol);
        h += makeSpecifier("PROGRAMID", "ADIF Lint", LengthUnit::Bytes, false) + std::string(eol);
        h += makeSpecifier("PROGRAMVERSION", programVersion, LengthUnit::Bytes, false) + std::string(eol);
        h += makeSpecifier("CREATED_TIMESTAMP", utcTimestamp, LengthUnit::Bytes, false) + std::string(eol);
        h += "<EOH>";
        h += eol;
        f.text = h;
        size_t added = 0;
        for (int gi : a.groups) {
            const ModelGroup &g = m.groups[(size_t)gi];
            std::string rec;
            bool hasRef = false, hasStation = false;
            for (size_t i = 0; i < g.fieldCount; ++i) {
                const ModelField &fld = m.fields[g.firstField + i];
                std::string_view name = fieldName(text, fld);
                std::string value(fieldValue(text, fld));
                if (equalsNoCase(name, refField)) value = a.park, hasRef = true;
                if (equalsNoCase(name, "STATION_CALLSIGN") || equalsNoCase(name, "OPERATOR")) hasStation |= !value.empty();
                char ind = fld.typePos == kNoPos ? 0 : text[fld.typePos];
                rec += makeSpecifier(name, value, unit, utf8, ind) + " ";
            }
            if (!hasRef) rec += makeSpecifier(refField, a.park, unit, utf8) + " ";
            if (!hasStation && !f.station.empty()) {
                rec += makeSpecifier("STATION_CALLSIGN", f.station, unit, utf8) + " ";
                ++added;
            }
            f.text += rec + "<EOR>" + std::string(eol);
            ++f.records;
        }
        f.qsos = a.qsos;
        if (p == Program::SOTA && !a.activated())
            f.notes.push_back(std::to_string(a.qsos) + (a.qsos == 1 ? " station: " : " stations: ") +
                              std::to_string(4 - a.qsos) + " more for the summit's points");
        if (p == Program::WWFF) f.notes.push_back("WWFF counts 44 QSOs per reference, over any number of days");
        if (a.duplicates) f.notes.push_back(std::to_string(a.duplicates) + " repeated");
        if (a.invalid)
            f.notes.push_back(std::to_string(a.invalid) + (a.invalid == 1 ? " record" : " records") +
                              " missing CALL, TIME_ON, BAND or MODE, or working your own call");
        if (f.station.empty()) f.notes.push_back("no STATION_CALLSIGN or OPERATOR: enter your callsign");
        else if (added) f.notes.push_back("STATION_CALLSIGN " + f.station + " added to " + std::to_string(added) +
                                          (added == 1 ? " record" : " records"));
        if (!todayUtc.empty() && a.lastDate > todayUtc) f.notes.push_back("dated in the future");
        out.push_back(std::move(f));
    }
    std::set<std::string> names;
    for (PotaFile &f : out) {
        std::string stem = f.name.substr(0, f.name.size() - 4), name = f.name;
        for (int n = 2; !names.insert(name).second; ++n) name = stem + "-" + std::to_string(n) + ".adi";
        f.name = name;
    }
    return out;
}

std::vector<std::pair<std::string, std::string>> programSpotFields(Program p, std::string_view activator, std::string_view kHz,
                                                                   std::string_view mode, std::string_view reference) {
    if (p == Program::POTA) return spotFields(activator, kHz, mode, reference);
    auto out = spotFields(activator, kHz, mode, "");
    std::string ref = up(reference);
    bool ok = p == Program::WWFF ? isAdifWwffRef(ref) : isAdifSotaRef(ref);
    if (ok) {
        out.emplace_back("SIG", programName(p));
        out.emplace_back("SIG_INFO", ref);
        out.emplace_back(p == Program::WWFF ? "WWFF_REF" : "SOTA_REF", ref);
    }
    return out;
}

ReferenceHistory referenceHistory(std::string_view ref, const std::vector<WorkedHit> &hits) {
    ReferenceHistory h;
    std::string want = up(ref.substr(0, ref.find('@')));
    if (want.empty()) return h;
    for (const WorkedHit &hit : hits) {
        bool match = false;
        for (const std::string &r : hit.contact.theirRefs) match |= up(std::string_view(r).substr(0, r.find('@'))) == want;
        if (!match) continue;
        ++h.qsos;
        if (hit.contact.date >= h.lastDate) h.lastDate = hit.contact.date, h.lastLog = hit.log;
    }
    return h;
}

std::string referenceSummary(std::string_view ref, const ReferenceHistory &h) {
    std::string r = up(ref.substr(0, ref.find('@')));
    // WWFF first: KFF-1234 also has the shape of a POTA park.
    std::string kind = isAdifWwffRef(r) ? "reference" : isPotaRef(r) ? "park" : isAdifSotaRef(r) ? "summit" : "reference";
    if (!h.qsos) return r + ": a new " + kind + "!";
    return r + ": worked " + std::to_string(h.qsos) + (h.qsos == 1 ? " time" : " times") + " before, last " +
           displayDate(h.lastDate) + (h.lastLog.empty() ? "" : " (" + h.lastLog + ")");
}

}  // namespace adif
