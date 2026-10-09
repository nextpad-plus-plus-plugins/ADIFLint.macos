#include "adif_tools.h"

#include "adif_enrich.h"
#include "adif_geo.h"
#include "adif_spec.h"
#include "adif_upload.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <map>
#include <set>
#include <tuple>
#include <unordered_map>

namespace adif {
namespace {

const std::string kNone;

bool isBlankChar(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

bool isBlankText(std::string_view s) {
    for (char c : s)
        if (!isBlankChar(c)) return false;
    return true;
}

std::string upperAscii(std::string_view s) {
    std::string o(s);
    for (char &c : o)
        if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    return o;
}

std::string lowerAscii(std::string_view s) {
    std::string o(s);
    for (char &c : o)
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    return o;
}

std::string trim(std::string_view s) {
    size_t b = 0, e = s.size();
    while (b < e && isBlankChar(s[b])) ++b;
    while (e > b && isBlankChar(s[e - 1])) --e;
    return std::string(s.substr(b, e - b));
}

bool allDigits(std::string_view s) {
    if (s.empty()) return false;
    for (char c : s)
        if (c < '0' || c > '9') return false;
    return true;
}

int digitsValue(std::string_view s) {
    int v = 0;
    for (char c : s) v = v * 10 + (c - '0');
    return v;
}

// Days since 1970-01-01 for a proleptic Gregorian date, and back (H. Hinnant's algorithms).
long daysFromCivil(int y, unsigned m, unsigned d) {
    y -= m <= 2;
    const long era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (long)doe - 719468;
}

void civilFromDays(long z, int *y, unsigned *m, unsigned *d) {
    z += 719468;
    const long era = (z >= 0 ? z : z - 146096) / 146097;
    const unsigned doe = (unsigned)(z - era * 146097);
    const unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const long yy = (long)yoe + era * 400;
    const unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const unsigned mp = (5 * doy + 2) / 153;
    *d = doy - (153 * mp + 2) / 5 + 1;
    *m = mp < 10 ? mp + 3 : mp - 9;
    *y = (int)(yy + (*m <= 2));
}

long long floorDiv(long long a, long long b) { return a / b - ((a % b != 0) && ((a < 0) != (b < 0))); }

// Replace every ASCII case-insensitive occurrence of `find` (non-empty).
std::string replaceAllNoCase(std::string_view s, std::string_view find, std::string_view with) {
    std::string out;
    std::string hay = upperAscii(s), needle = upperAscii(find);
    size_t i = 0;
    while (i < s.size()) {
        size_t at = hay.find(needle, i);
        if (at == std::string::npos) break;
        out.append(s.substr(i, at - i));
        out.append(with);
        i = at + needle.size();
    }
    out.append(s.substr(std::min(i, s.size())));
    return out;
}

bool containsNoCase(std::string_view hay, std::string_view needle) {
    return upperAscii(hay).find(upperAscii(needle)) != std::string::npos;
}

std::vector<std::string> splitList(std::string_view s) {
    std::vector<std::string> out;
    size_t start = 0;
    while (start <= s.size()) {
        size_t comma = s.find(',', start);
        std::string part = trim(s.substr(start, comma == std::string_view::npos ? std::string_view::npos : comma - start));
        if (!part.empty()) out.push_back(upperAscii(part));
        if (comma == std::string_view::npos) break;
        start = comma + 1;
    }
    return out;
}

std::string joinList(const std::vector<std::string> &v, const char *sep = ",") {
    std::string out;
    for (size_t i = 0; i < v.size(); ++i) out += (i ? sep : "") + v[i];
    return out;
}

bool validFieldName(std::string_view n) {
    if (n.empty()) return false;
    for (char c : n)
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) return false;
    return !equalsNoCase(n, "EOR") && !equalsNoCase(n, "EOH");
}

// Indices into DocModel::fields of a group's fields with this name.
std::vector<size_t> fieldsNamed(std::string_view text, const DocModel &m, const ModelGroup &g, std::string_view name) {
    std::vector<size_t> out;
    for (size_t i = 0; i < g.fieldCount; ++i)
        if (equalsNoCase(fieldName(text, m.fields[g.firstField + i]), name)) out.push_back(g.firstField + i);
    return out;
}

// A field rebuilt from the model, keeping its name spelling and type indicator.
std::string specifierFrom(std::string_view text, const ModelField &f, std::string_view value, LengthUnit unit, bool utf8) {
    char indicator = f.typePos == kNoPos ? 0 : text[f.typePos];
    return makeSpecifier(fieldName(text, f), value, unit, utf8, indicator);
}

// Index of a band in the spec's table (frequency order), or a large number.
size_t bandOrder(std::string_view band) {
    size_t n = 0;
    const BandDef *t = bandTable(&n);
    for (size_t i = 0; i < n; ++i)
        if (equalsNoCase(t[i].name, band)) return i;
    return n + 1;
}

// Insert the (name, value) pairs at a record's end as one edit.
TextEdit insertFields(std::string_view text, const DocModel &m, const ModelGroup &g,
                      const std::vector<std::pair<std::string, std::string>> &fields, LengthUnit unit, bool utf8) {
    TextEdit e;
    for (size_t i = 0; i < fields.size(); ++i) {
        TextEdit one = insertField(text, m, g, fields[i].first, fields[i].second, unit, utf8);
        if (i == 0) e = one;
        else e.text += one.text;
    }
    return e;
}

void sortEdits(std::vector<TextEdit> &edits) {
    std::stable_sort(edits.begin(), edits.end(), [](const TextEdit &a, const TextEdit &b) {
        return a.start != b.start ? a.start < b.start : a.end < b.end;
    });
}

std::string padRight(std::string s, size_t w) {
    if (s.size() < w) s.append(w - s.size(), ' ');
    return s;
}

std::string padLeft(const std::string &s, size_t w) { return s.size() < w ? std::string(w - s.size(), ' ') + s : s; }

}  // namespace

// ── Records ─────────────────────────────────────────────────────────────────

const std::string &Record::get(std::string_view name) const {
    for (const auto &f : fields)
        if (equalsNoCase(f.first, name)) return f.second;
    return kNone;
}

bool Record::has(std::string_view name) const {
    for (const auto &f : fields)
        if (equalsNoCase(f.first, name)) return true;
    return false;
}

std::vector<Record> records(std::string_view text, const DocModel &m) {
    std::vector<Record> out;
    int number = 0;
    for (size_t gi = 0; gi < m.groups.size(); ++gi) {
        const ModelGroup &g = m.groups[gi];
        if (g.header) continue;
        Record r;
        r.group = (int)gi;
        r.number = ++number;
        for (size_t i = 0; i < g.fieldCount; ++i) {
            const ModelField &f = m.fields[g.firstField + i];
            r.fields.emplace_back(upperAscii(fieldName(text, f)), std::string(fieldValue(text, f)));
        }
        out.push_back(std::move(r));
    }
    return out;
}

std::vector<std::string> recordKeys(const std::vector<Record> &recs) {
    std::vector<std::string> out;
    std::map<std::string, int> seen;
    for (const Record &r : recs) {
        std::string k = upperAscii(trim(r.get("CALL"))) + "|" + r.get("QSO_DATE") + "|" + r.get("TIME_ON") + "|" +
                        effectiveBand(r) + "|" + effectiveMode(r);
        int n = ++seen[k];
        out.push_back(n == 1 ? k : k + "#" + std::to_string(n));
    }
    return out;
}

std::string applyTextEdits(std::string_view text, const std::vector<TextEdit> &edits) {
    std::string out;
    out.reserve(text.size());
    size_t at = 0;
    for (const TextEdit &e : edits) {
        if (e.start < at || e.end < e.start || e.end > text.size()) continue;  // not sorted or overlapping: skip
        out.append(text.substr(at, e.start - at));
        out.append(e.text);
        at = e.end;
    }
    out.append(text.substr(at));
    return out;
}

// ── Dates and times ─────────────────────────────────────────────────────────

bool parseAdifDate(std::string_view date, long *days) {
    if (date.size() != 8 || !allDigits(date)) return false;
    int y = digitsValue(date.substr(0, 4));
    unsigned mo = (unsigned)digitsValue(date.substr(4, 2)), d = (unsigned)digitsValue(date.substr(6, 2));
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return false;
    long v = daysFromCivil(y, mo, d);
    int yy;
    unsigned mm, dd;
    civilFromDays(v, &yy, &mm, &dd);
    if (yy != y || mm != mo || dd != d) return false;  // e.g. 20230230
    if (days) *days = v;
    return true;
}

bool parseAdifTime(std::string_view time, int *seconds) {
    if ((time.size() != 4 && time.size() != 6) || !allDigits(time)) return false;
    int h = digitsValue(time.substr(0, 2)), mi = digitsValue(time.substr(2, 2));
    int s = time.size() == 6 ? digitsValue(time.substr(4, 2)) : 0;
    if (h > 23 || mi > 59 || s > 59) return false;
    if (seconds) *seconds = h * 3600 + mi * 60 + s;
    return true;
}

std::string formatAdifDate(long days) {
    int y;
    unsigned m, d;
    civilFromDays(days, &y, &m, &d);
    char buf[16];
    std::snprintf(buf, sizeof buf, "%04d%02u%02u", y, m, d);
    return buf;
}

std::string formatAdifTime(int seconds, bool withSeconds) {
    seconds = ((seconds % 86400) + 86400) % 86400;
    char buf[16];
    if (withSeconds) std::snprintf(buf, sizeof buf, "%02d%02d%02d", seconds / 3600, seconds / 60 % 60, seconds % 60);
    else std::snprintf(buf, sizeof buf, "%02d%02d", seconds / 3600, seconds / 60 % 60);
    return buf;
}

std::string displayDate(std::string_view date) {
    if (!parseAdifDate(date, nullptr)) return std::string(date);
    return std::string(date.substr(0, 4)) + "-" + std::string(date.substr(4, 2)) + "-" + std::string(date.substr(6, 2));
}

std::string displayTime(std::string_view time) {
    if (!parseAdifTime(time, nullptr)) return std::string(time);
    std::string out = std::string(time.substr(0, 2)) + ":" + std::string(time.substr(2, 2));
    if (time.size() == 6) out += ":" + std::string(time.substr(4, 2));
    return out;
}

long long qsoStart(const Record &r) {
    long days;
    int secs;
    if (!parseAdifDate(r.get("QSO_DATE"), &days) || !parseAdifTime(r.get("TIME_ON"), &secs)) return -1;
    return (long long)days * 86400 + secs;
}

std::string effectiveMode(const Record &r) {
    const std::string &sub = r.get("SUBMODE");
    return upperAscii(trim(sub.empty() ? r.get("MODE") : sub));
}

std::string effectiveBand(const Record &r) {
    std::string band = trim(r.get("BAND"));
    if (band.empty()) band = bandForFrequency(trim(r.get("FREQ")));
    return lowerAscii(band);
}

// ── Table and summary ───────────────────────────────────────────────────────

std::vector<std::string> tableColumns(const std::vector<Record> &recs) {
    static const char *const kFirst[] = {"QSO_DATE", "TIME_ON",  "CALL",   "BAND",       "FREQ",  "MODE",
                                         "SUBMODE",  "RST_SENT", "RST_RCVD", "NAME",     "QTH",   "STATE",
                                         "GRIDSQUARE", "SIG",    "SIG_INFO", "POTA_REF", "COMMENT"};
    std::map<std::string, size_t> count, first;
    size_t order = 0;
    for (const Record &r : recs)
        for (const auto &f : r.fields) {
            if (f.second.empty()) continue;
            if (!count[f.first]++) first[f.first] = order++;
        }
    std::vector<std::string> out;
    for (const char *c : kFirst)
        if (count.count(c)) out.push_back(c);
    std::vector<std::string> rest;
    for (const auto &kv : count)
        if (std::find(out.begin(), out.end(), kv.first) == out.end()) rest.push_back(kv.first);
    // The contact's other fields by use, then the station's own (MY_*, STATION_CALLSIGN...).
    std::stable_sort(rest.begin(), rest.end(), [&](const std::string &a, const std::string &b) {
        bool sa = isStationField(a), sb = isStationField(b);
        if (sa != sb) return !sa;
        if (count[a] != count[b]) return count[a] > count[b];
        return first[a] < first[b];
    });
    out.insert(out.end(), rest.begin(), rest.end());
    return out;
}

std::string summaryReport(std::string_view text, const DocModel &m, std::string_view title) {
    std::vector<Record> recs = records(text, m);
    std::string out;
    auto line = [&](const std::string &label, const std::string &value) { out += padRight(label, 22) + value + "\n"; };
    auto heading = [&](const std::string &h) { out += "\n" + h + "\n" + std::string(h.size(), '-') + "\n"; };
    auto table = [&](const std::vector<std::pair<std::string, size_t>> &rows) {
        size_t w = 0;
        for (const auto &r : rows) w = std::max(w, r.first.size());
        for (const auto &r : rows) out += "  " + padRight(r.first, w + 2) + padLeft(std::to_string(r.second), 6) + "\n";
    };
    auto byCount = [](const std::map<std::string, size_t> &m) {
        std::vector<std::pair<std::string, size_t>> v(m.begin(), m.end());
        std::stable_sort(v.begin(), v.end(), [](const auto &a, const auto &b) { return a.second > b.second; });
        return v;
    };

    std::string t = "Summary of " + std::string(title);
    out += t + "\n" + std::string(t.size(), '=') + "\n\n";

    size_t withCall = 0;
    std::set<std::string> calls, days, grids, stations;
    std::map<std::string, size_t> bands, modes, perDay, entities, states, myParkCount;
    long long firstT = -1, lastT = -1;
    std::string firstS, lastS;
    std::set<std::string> hunted;
    size_t p2p = 0, lotwRcvd = 0, eqslRcvd = 0, cardRcvd = 0, qrzUp = 0, clublogUp = 0, lotwSent = 0, eqslSent = 0,
           undated = 0;
    auto yes = [](const std::string &v) { return equalsNoCase(v, "Y") || equalsNoCase(v, "V"); };
    for (const Record &r : recs) {
        const std::string &call = r.get("CALL");
        if (call.empty()) continue;
        ++withCall;
        calls.insert(lookupCall(call));
        std::string band = effectiveBand(r), mode = effectiveMode(r);
        ++bands[band.empty() ? "(none)" : band];
        ++modes[mode.empty() ? "(none)" : mode];
        const std::string &date = r.get("QSO_DATE");
        if (parseAdifDate(date, nullptr)) {
            days.insert(date);
            ++perDay[date];
        } else {
            ++undated;
        }
        long long t0 = qsoStart(r);
        std::string when = displayDate(date) + " " + displayTime(r.get("TIME_ON")) + " UTC";
        if (t0 >= 0 && (firstT < 0 || t0 < firstT)) firstT = t0, firstS = when;
        if (t0 >= 0 && t0 > lastT) lastT = t0, lastS = when;
        const std::string &dxcc = r.get("DXCC");
        const char *entity = dxcc.empty() ? nullptr : dxccEntityName(dxcc);
        if (entity) ++entities[entity];
        else if (!r.get("COUNTRY").empty()) ++entities[upperAscii(r.get("COUNTRY"))];
        if (!r.get("STATE").empty()) ++states[upperAscii(r.get("STATE"))];
        const std::string &grid = r.get("GRIDSQUARE");
        if (grid.size() >= 4) grids.insert(upperAscii(grid.substr(0, 4)));
        std::string st = stationCall(r);
        if (!st.empty()) stations.insert(st);
        for (const std::string &p : myParks(r)) ++myParkCount[p];
        if (!theirParks(r).empty()) ++p2p;
        for (const std::string &p : theirParks(r)) hunted.insert(p.substr(0, p.find('@')));
        lotwRcvd += yes(r.get("LOTW_QSL_RCVD"));
        eqslRcvd += yes(r.get("EQSL_QSL_RCVD"));
        cardRcvd += yes(r.get("QSL_RCVD"));
        qrzUp += equalsNoCase(r.get("QRZCOM_QSO_UPLOAD_STATUS"), "Y");
        clublogUp += equalsNoCase(r.get("CLUBLOG_QSO_UPLOAD_STATUS"), "Y");
        lotwSent += equalsNoCase(r.get("LOTW_QSL_SENT"), "Y");
        eqslSent += equalsNoCase(r.get("EQSL_QSL_SENT"), "Y");
    }

    line("Records", std::to_string(recs.size()));
    line("QSOs (with a CALL)", std::to_string(withCall));
    line("Callsigns worked", std::to_string(calls.size()));
    if (!firstS.empty()) line("First QSO", firstS);
    if (!lastS.empty()) line("Last QSO", lastS);
    line("UTC days", std::to_string(days.size()) + (undated ? " (" + std::to_string(undated) + " QSOs without a valid date)" : ""));
    if (!stations.empty()) {
        std::vector<std::string> v(stations.begin(), stations.end());
        line("Station callsigns", joinList(v, ", "));
    }
    if (!withCall) return out;

    std::vector<std::pair<std::string, size_t>> bandRows(bands.begin(), bands.end());
    std::stable_sort(bandRows.begin(), bandRows.end(),
                     [](const auto &a, const auto &b) { return bandOrder(a.first) < bandOrder(b.first); });
    heading("Bands");
    table(bandRows);
    heading("Modes (SUBMODE where given)");
    table(byCount(modes));
    heading("QSOs per UTC day");
    std::vector<std::pair<std::string, size_t>> dayRows;
    for (const auto &kv : perDay) dayRows.emplace_back(displayDate(kv.first), kv.second);
    table(dayRows);
    if (!entities.empty()) {
        heading("DXCC entities: " + std::to_string(entities.size()));
        table(byCount(entities));
    }
    if (!states.empty()) {
        heading("States and provinces (STATE): " + std::to_string(states.size()));
        table(std::vector<std::pair<std::string, size_t>>(states.begin(), states.end()));
    }
    if (!grids.empty()) {
        heading("Grid squares");
        line("  4-character grids", std::to_string(grids.size()));
    }
    if (!myParkCount.empty() || p2p) {
        heading("Parks on the Air");
        std::vector<Activation> acts = activations(text, m);
        size_t ok = 0;
        for (const Activation &a : acts) ok += a.activated();
        if (!acts.empty())
            line("  Activations", std::to_string(ok) + " of " + std::to_string(acts.size()) +
                                      " park-days reach 10 QSOs (see Activation Tracker)");
        for (const auto &kv : byCount(myParkCount)) line("  " + kv.first, std::to_string(kv.second) + " records");
        line("  Park-to-park QSOs", std::to_string(p2p));
        line("  Parks worked", std::to_string(hunted.size()) + " different (SIG_INFO or POTA_REF)");
    }
    heading("Confirmations and uploads");
    line("  LoTW confirmed", std::to_string(lotwRcvd));
    line("  eQSL confirmed", std::to_string(eqslRcvd));
    line("  QSL cards received", std::to_string(cardRcvd));
    line("  Uploaded to QRZ.com", std::to_string(qrzUp) + " of " + std::to_string(withCall));
    line("  Uploaded to Club Log", std::to_string(clublogUp) + " of " + std::to_string(withCall));
    line("  Sent to LoTW", std::to_string(lotwSent) + " of " + std::to_string(withCall));
    line("  Sent to eQSL", std::to_string(eqslSent) + " of " + std::to_string(withCall));
    return out;
}

// ── Bulk edits ──────────────────────────────────────────────────────────────

bool matchesFilter(const Record &r, const RecordFilter &f) {
    if (f.kind == RecordFilter::All || f.field.empty()) return true;
    const std::string &v = r.get(f.field);
    switch (f.kind) {
        case RecordFilter::Equals: return equalsNoCase(trim(v), trim(f.value));
        case RecordFilter::Contains: return !f.value.empty() && containsNoCase(v, f.value);
        case RecordFilter::Missing: return v.empty();
        case RecordFilter::Present: return !v.empty();
        default: return true;
    }
}

ChangePlan planBulkEdit(std::string_view text, const DocModel &m, const std::vector<int> &groups, const BulkEdit &op) {
    ChangePlan plan;
    std::string field = upperAscii(trim(op.field));
    if (!validFieldName(field)) {
        plan.skipReason = "Choose a field.";
        return plan;
    }
    std::string newName = upperAscii(trim(op.newName));
    if (op.action == BulkAction::Set && op.value.empty()) {
        plan.skipReason = "Enter a value (Remove deletes a field).";
        return plan;
    }
    if (op.action == BulkAction::Replace && op.find.empty()) {
        plan.skipReason = "Enter the text to find.";
        return plan;
    }
    if (op.action == BulkAction::Rename && (!validFieldName(newName) || newName == field)) {
        plan.skipReason = "Enter a new field name (letters, digits and _).";
        return plan;
    }
    for (int gi : groups) {
        if (gi < 0 || (size_t)gi >= m.groups.size() || m.groups[(size_t)gi].header) continue;
        const ModelGroup &g = m.groups[(size_t)gi];
        std::vector<size_t> occ = fieldsNamed(text, m, g, field);
        PlannedChange c;
        c.group = gi;
        c.record = recordNumber(m, gi);
        c.call = std::string(groupValue(text, m, g, "CALL"));
        c.field = field;
        size_t before = plan.changes.size();
        switch (op.action) {
            case BulkAction::Set: {
                if (occ.empty()) {
                    c.kind = PlannedChange::Add;
                    c.after = op.value;
                    plan.changes.push_back(c);
                    break;
                }
                std::string cur(fieldValue(text, m.fields[occ[0]]));
                if (op.onlyMissing && !cur.empty()) {
                    if (!plan.skipped++) plan.skipReason = "they already have a value";
                    break;
                }
                if (cur == op.value) break;
                c.kind = PlannedChange::Change;
                c.fieldIndex = occ[0];
                c.before = cur;
                c.after = op.value;
                plan.changes.push_back(c);
                break;
            }
            case BulkAction::Replace:
                for (size_t idx : occ) {
                    std::string cur(fieldValue(text, m.fields[idx]));
                    std::string next = replaceAllNoCase(cur, op.find, op.value);
                    if (next == cur) continue;
                    c.kind = PlannedChange::Change;
                    c.fieldIndex = idx;
                    c.before = cur;
                    c.after = next;
                    plan.changes.push_back(c);
                }
                break;
            case BulkAction::Remove:
                for (size_t idx : occ) {
                    c.kind = PlannedChange::Remove;
                    c.fieldIndex = idx;
                    c.before = std::string(fieldValue(text, m.fields[idx]));
                    plan.changes.push_back(c);
                }
                break;
            case BulkAction::Rename:
                if (occ.empty()) break;
                if (!fieldsNamed(text, m, g, newName).empty()) {
                    if (!plan.skipped++) plan.skipReason = "they already have " + newName;
                    break;
                }
                for (size_t idx : occ) {
                    c.kind = PlannedChange::Rename;
                    c.fieldIndex = idx;
                    c.before = std::string(fieldName(text, m.fields[idx]));
                    c.after = newName;
                    plan.changes.push_back(c);
                }
                break;
        }
        if (plan.changes.size() > before) ++plan.records;
    }
    return plan;
}

ChangePlan planTimeShift(std::string_view text, const DocModel &m, const std::vector<int> &groups, long long minutes) {
    if (!minutes) {
        ChangePlan plan;
        plan.skipReason = "Enter a shift.";
        return plan;
    }
    return planTimeShiftWith(text, m, groups, [minutes](long long, long long *seconds, std::string *) {
        *seconds = minutes * 60;
        return true;
    });
}

LocalTime localToUtc(long long wall, const std::function<long long(long long utc)> &offsetAt, long long *utc) {
    // The offsets in force half a day either side cover any one transition.
    std::vector<long long> found;
    for (long long probe : {wall - 43200, wall + 43200}) {
        long long u = wall - offsetAt(probe);
        if (u + offsetAt(u) == wall && std::find(found.begin(), found.end(), u) == found.end()) found.push_back(u);
    }
    if (found.empty()) return LocalTime::Skipped;
    std::sort(found.begin(), found.end());
    if (utc) *utc = found.front();
    return found.size() == 1 ? LocalTime::Unique : LocalTime::Repeated;
}

ChangePlan planTimeShiftWith(std::string_view text, const DocModel &m, const std::vector<int> &groups, const ShiftFor &shiftFor) {
    ChangePlan plan;
    std::vector<std::string> reasons;  // the first few, for the status line
    auto skip = [&](const std::string &why) {
        ++plan.skipped;
        if (reasons.size() < 3) reasons.push_back(why);
    };
    for (int gi : groups) {
        if (gi < 0 || (size_t)gi >= m.groups.size() || m.groups[(size_t)gi].header) continue;
        const ModelGroup &g = m.groups[(size_t)gi];
        auto first = [&](const char *name) {
            std::vector<size_t> v = fieldsNamed(text, m, g, name);
            return v.empty() ? kNoPos : v[0];
        };
        size_t fDate = first("QSO_DATE"), fTime = first("TIME_ON"), fDateOff = first("QSO_DATE_OFF"),
               fTimeOff = first("TIME_OFF");
        auto value = [&](size_t idx) { return idx == kNoPos ? std::string_view() : fieldValue(text, m.fields[idx]); };
        long days;
        int secs;
        std::string label = "record " + std::to_string(recordNumber(m, gi));
        if (std::string_view call = groupValue(text, m, g, "CALL"); !call.empty()) label += " (" + std::string(call) + ")";
        if (fDate == kNoPos || fTime == kNoPos || !parseAdifDate(value(fDate), &days) || !parseAdifTime(value(fTime), &secs)) {
            skip(label + " has no valid QSO_DATE and TIME_ON");
            continue;
        }
        long long delta = 0;
        std::string why;
        if (!shiftFor((long long)days * 86400 + secs, &delta, &why)) {
            skip(label + ": " + why);
            continue;
        }
        PlannedChange c;
        c.group = gi;
        c.record = recordNumber(m, gi);
        c.call = std::string(groupValue(text, m, g, "CALL"));
        c.kind = PlannedChange::Change;
        size_t before = plan.changes.size();
        auto change = [&](size_t idx, const std::string &next) {
            std::string cur(value(idx));
            if (cur == next) return;
            c.fieldIndex = idx;
            c.field = upperAscii(fieldName(text, m.fields[idx]));
            c.before = cur;
            c.after = next;
            plan.changes.push_back(c);
        };
        long long start = (long long)days * 86400 + secs + delta;
        long newDays = (long)floorDiv(start, 86400);
        change(fDate, formatAdifDate(newDays));
        change(fTime, formatAdifTime((int)(start - (long long)newDays * 86400), value(fTime).size() == 6));
        int secsOff;
        if (fTimeOff != kNoPos && parseAdifTime(value(fTimeOff), &secsOff)) {
            long daysOff;
            if (fDateOff != kNoPos && parseAdifDate(value(fDateOff), &daysOff)) {
                long long end = (long long)daysOff * 86400 + secsOff + delta;
                long endDays = (long)floorDiv(end, 86400);
                change(fDateOff, formatAdifDate(endDays));
                change(fTimeOff, formatAdifTime((int)(end - (long long)endDays * 86400), value(fTimeOff).size() == 6));
            } else {
                // No QSO_DATE_OFF: the end is on QSO_DATE, or the next day when TIME_OFF < TIME_ON.
                // Shifting start and end alike keeps that rule true.
                long long t = secsOff + delta;
                change(fTimeOff, formatAdifTime((int)(t - floorDiv(t, 86400) * 86400), value(fTimeOff).size() == 6));
            }
        } else if (long daysOff = 0; fDateOff != kNoPos && parseAdifDate(value(fDateOff), &daysOff)) {
            change(fDateOff, formatAdifDate(daysOff + (newDays - days)));  // QSO_DATE_OFF alone: move it by the same days
        }
        if (plan.changes.size() > before) ++plan.records;
    }
    for (size_t i = 0; i < reasons.size(); ++i) plan.skipReason += (i ? "; " : "") + reasons[i];
    if (plan.skipped > reasons.size()) plan.skipReason += "; and " + std::to_string(plan.skipped - reasons.size()) + " more";
    return plan;
}

ChangePlan planDistance(std::string_view text, const DocModel &m, const std::vector<int> &groups) {
    ChangePlan plan;
    size_t noGrid = 0, has = 0;
    for (int gi : groups) {
        if (gi < 0 || (size_t)gi >= m.groups.size() || m.groups[(size_t)gi].header) continue;
        const ModelGroup &g = m.groups[(size_t)gi];
        if (!groupValue(text, m, g, "DISTANCE").empty()) {
            ++has;
            continue;
        }
        std::string km = gridDistanceKm(groupValue(text, m, g, "MY_GRIDSQUARE"), groupValue(text, m, g, "GRIDSQUARE"));
        if (km.empty()) {
            ++noGrid;
            continue;
        }
        PlannedChange c;
        c.kind = PlannedChange::Add;
        c.group = gi;
        c.record = recordNumber(m, gi);
        c.call = std::string(groupValue(text, m, g, "CALL"));
        c.field = "DISTANCE";
        c.after = km;
        plan.changes.push_back(c);
        ++plan.records;
    }
    plan.skipped = noGrid + has;
    if (noGrid && has) plan.skipReason = std::to_string(noGrid) + " lack MY_GRIDSQUARE or GRIDSQUARE and " + std::to_string(has) +
                                         " already have DISTANCE";
    else if (noGrid) plan.skipReason = "they lack MY_GRIDSQUARE or GRIDSQUARE";
    else if (has) plan.skipReason = "they already have DISTANCE";
    return plan;
}

std::vector<TextEdit> planEdits(std::string_view text, const DocModel &m, const std::vector<PlannedChange> &changes,
                                LengthUnit unit, bool utf8) {
    std::vector<TextEdit> edits;
    std::map<int, std::vector<std::pair<std::string, std::string>>> adds;
    for (const PlannedChange &c : changes) {
        if (c.group < 0 || (size_t)c.group >= m.groups.size()) continue;
        const ModelGroup &g = m.groups[(size_t)c.group];
        bool inGroup = c.fieldIndex >= g.firstField && c.fieldIndex < g.firstField + g.fieldCount;
        switch (c.kind) {
            case PlannedChange::Add: adds[c.group].emplace_back(c.field, c.after); break;
            case PlannedChange::Change:
                if (inGroup) edits.push_back(setFieldValue(text, m.fields[c.fieldIndex], c.after, unit, utf8));
                break;
            case PlannedChange::Remove:
                if (inGroup) edits.push_back(removeField(text, m, g, c.fieldIndex - g.firstField));
                break;
            case PlannedChange::Rename:
                if (inGroup) {
                    const ModelField &f = m.fields[c.fieldIndex];
                    edits.push_back(TextEdit{f.tagB + 1, f.nameE, c.after});
                }
                break;
        }
    }
    for (const auto &kv : adds) edits.push_back(insertFields(text, m, m.groups[(size_t)kv.first], kv.second, unit, utf8));
    sortEdits(edits);
    return edits;
}

// ── Sorting ─────────────────────────────────────────────────────────────────

namespace {

// The records rearranged in the order `arrange` gives (indexes into the
// records): the comment before each record moves with it, and the blank runs
// between records become the log's usual separator.
std::string rearranged(std::string_view text, const DocModel &m, std::string_view eol, bool *changed,
                       const std::function<std::vector<size_t>(const std::vector<Record> &)> &arrange) {
    if (changed) *changed = false;
    std::vector<Record> recs = records(text, m);
    if (recs.size() < 2) return std::string(text);
    for (const Record &r : recs)
        if (m.groups[(size_t)r.group].markerB == kNoPos) return std::string(text);
    size_t n = recs.size();
    std::vector<size_t> b(n), e(n);
    for (size_t i = 0; i < n; ++i) {
        b[i] = groupStart(m, m.groups[(size_t)recs[i].group]);
        e[i] = groupEnd(m, m.groups[(size_t)recs[i].group]);
    }
    // The separator: the commonest blank run between records.
    std::map<std::string, size_t> seps;
    std::vector<std::string> comment(n);
    for (size_t i = 1; i < n; ++i) {
        std::string_view gap = text.substr(e[i - 1], b[i] - e[i - 1]);
        if (isBlankText(gap)) ++seps[std::string(gap)];
        else comment[i] = trim(gap);
    }
    std::string sep;
    size_t best = 0;
    for (const auto &kv : seps)
        if (kv.second > best) best = kv.second, sep = kv.first;
    if (sep.empty()) sep = recordLayout(text, m) == Layout::FieldPerLine ? std::string(eol) + std::string(eol) : std::string(eol);

    std::vector<size_t> order = arrange(recs);
    bool same = order.size() == n;
    for (size_t i = 0; same && i < n; ++i) same = order[i] == i;
    if (same || order.size() != n) return std::string(text);

    std::string out;
    out.reserve(text.size() + 64);
    out.append(text.substr(0, b[0]));
    for (size_t k = 0; k < n; ++k) {
        size_t i = order[k];
        if (k) out += sep;
        if (!comment[i].empty()) out += comment[i] + std::string(eol);
        out.append(text.substr(b[i], e[i] - b[i]));
    }
    out.append(text.substr(e[n - 1]));
    if (changed) *changed = true;
    return out;
}

bool isPlainNumber(std::string_view s) {
    size_t i = (!s.empty() && (s[0] == '+' || s[0] == '-')) ? 1 : 0;
    bool digit = false, dot = false;
    for (; i < s.size(); ++i) {
        if (s[i] >= '0' && s[i] <= '9') digit = true;
        else if (s[i] == '.' && !dot) dot = true;
        else return false;
    }
    return digit;
}

std::string digitsOnly(std::string_view s) {
    std::string out;
    for (char c : s)
        if (c >= '0' && c <= '9') out.push_back(c);
    return out;
}

}  // namespace

std::string sortedByTime(std::string_view text, const DocModel &m, std::string_view eol, bool *changed) {
    return rearranged(text, m, eol, changed, [](const std::vector<Record> &recs) {
        size_t n = recs.size();
        std::vector<long long> key(n);
        for (size_t i = 0; i < n; ++i) key[i] = qsoStart(recs[i]);
        std::vector<size_t> order(n);
        for (size_t i = 0; i < n; ++i) order[i] = i;
        std::stable_sort(order.begin(), order.end(), [&](size_t x, size_t y) {
            bool vx = key[x] >= 0, vy = key[y] >= 0;
            if (vx != vy) return vx;  // dated records first
            return vx && key[x] < key[y];
        });
        return order;
    });
}

int naturalCompare(std::string_view a, std::string_view b) {
    if (isPlainNumber(a) && isPlainNumber(b)) {
        double x = std::strtod(std::string(a).c_str(), nullptr), y = std::strtod(std::string(b).c_str(), nullptr);
        if (x != y) return x < y ? -1 : 1;
    }
    size_t i = 0, j = 0;
    while (i < a.size() && j < b.size()) {
        bool da = a[i] >= '0' && a[i] <= '9', db = b[j] >= '0' && b[j] <= '9';
        if (da && db) {
            size_t si = i, sj = j;
            while (si < a.size() && a[si] == '0') ++si;
            while (sj < b.size() && b[sj] == '0') ++sj;
            size_t ei = si, ej = sj;
            while (ei < a.size() && a[ei] >= '0' && a[ei] <= '9') ++ei;
            while (ej < b.size() && b[ej] >= '0' && b[ej] <= '9') ++ej;
            if (ei - si != ej - sj) return ei - si < ej - sj ? -1 : 1;
            int c = a.substr(si, ei - si).compare(b.substr(sj, ej - sj));
            if (c) return c < 0 ? -1 : 1;
            i = ei;
            j = ej;
            continue;
        }
        int ca = std::toupper((unsigned char)a[i]), cb = std::toupper((unsigned char)b[j]);
        if (ca != cb) return ca < cb ? -1 : 1;
        ++i;
        ++j;
    }
    return a.size() - i < b.size() - j ? -1 : (a.size() - i > b.size() - j ? 1 : 0);
}

int compareFieldValues(std::string_view field, std::string_view a, std::string_view b) {
    std::string x = trim(a), y = trim(b);
    const FieldDef *d = findField(field);
    if (d && d->enumeration && equalsNoCase(d->enumeration, "Band")) {
        const BandDef *bx = findBand(x), *by = findBand(y);
        if (bx && by) return bx->lowerMHz < by->lowerMHz ? -1 : bx->lowerMHz > by->lowerMHz ? 1 : 0;
        if (bx || by) return bx ? -1 : 1;  // known bands before anything else
    } else if (d && (d->type == DataType::Date || d->type == DataType::Time)) {
        std::string dx = digitsOnly(x), dy = digitsOnly(y);
        if (d->type == DataType::Time) {  // HHMM is HHMM00
            if (dx.size() == 4) dx += "00";
            if (dy.size() == 4) dy += "00";
        }
        if (!dx.empty() && !dy.empty() && dx != dy) return dx < dy ? -1 : 1;
        if (!dx.empty() && !dy.empty()) return 0;
    } else if (d && (d->type == DataType::Number || d->type == DataType::Integer || d->type == DataType::PositiveInteger)) {
        if (isPlainNumber(x) && isPlainNumber(y)) {
            double nx = std::strtod(x.c_str(), nullptr), ny = std::strtod(y.c_str(), nullptr);
            return nx < ny ? -1 : nx > ny ? 1 : 0;
        }
    }
    return naturalCompare(x, y);
}

std::string sortedBy(std::string_view text, const DocModel &m, const std::vector<SortKey> &keys, std::string_view eol,
                     bool *changed) {
    if (keys.empty()) {
        if (changed) *changed = false;
        return std::string(text);
    }
    return rearranged(text, m, eol, changed, [&](const std::vector<Record> &recs) {
        size_t n = recs.size();
        std::vector<size_t> order(n);
        for (size_t i = 0; i < n; ++i) order[i] = i;
        std::stable_sort(order.begin(), order.end(), [&](size_t x, size_t y) {
            for (const SortKey &k : keys) {
                std::string a = trim(recs[x].get(k.field)), b = trim(recs[y].get(k.field));
                if (a.empty() != b.empty()) return b.empty();  // a value before none, either direction
                if (a.empty()) continue;
                int c = compareFieldValues(k.field, a, b);
                if (c) return k.descending ? c > 0 : c < 0;
            }
            return false;
        });
        return order;
    });
}

std::vector<TextEdit> fieldOrderEdits(std::string_view text, const DocModel &m, const std::vector<std::string> &order,
                                      size_t *changedRecords, size_t *skipped) {
    std::vector<TextEdit> edits;
    if (changedRecords) *changedRecords = 0;
    if (skipped) *skipped = 0;
    std::map<std::string, size_t> rank;  // listed fields by position
    for (size_t i = 0; i < order.size(); ++i) rank.emplace(upperAscii(order[i]), i);
    for (const ModelGroup &g : m.groups) {
        if (g.header || g.fieldCount < 2) continue;
        const ModelField *f = &m.fields[g.firstField];
        bool clean = true;  // right lengths, and only whitespace between the fields
        for (size_t i = 0; i < g.fieldCount && clean; ++i) clean = f[i].lengthOk;
        for (size_t i = 1; i < g.fieldCount && clean; ++i) clean = isBlankText(text.substr(f[i - 1].valueE, f[i].tagB - f[i - 1].valueE));
        if (!clean) {
            if (skipped) ++*skipped;
            continue;
        }
        std::vector<size_t> idx(g.fieldCount);
        for (size_t i = 0; i < g.fieldCount; ++i) idx[i] = i;
        std::stable_sort(idx.begin(), idx.end(), [&](size_t x, size_t y) {
            auto rx = rank.find(upperAscii(fieldName(text, f[x]))), ry = rank.find(upperAscii(fieldName(text, f[y])));
            size_t px = rx == rank.end() ? order.size() : rx->second, py = ry == rank.end() ? order.size() : ry->second;
            return px < py;
        });
        bool same = true;
        for (size_t i = 0; i < idx.size() && same; ++i) same = idx[i] == i;
        if (same) continue;
        // The fields in their new order, each gap staying at its position.
        std::string out;
        for (size_t k = 0; k < idx.size(); ++k) {
            const ModelField &field = f[idx[k]];
            out.append(text.substr(field.tagB, field.valueE - field.tagB));
            if (k + 1 < idx.size()) out.append(text.substr(f[k].valueE, f[k + 1].tagB - f[k].valueE));
        }
        edits.push_back(TextEdit{f[0].tagB, f[g.fieldCount - 1].valueE, out});
        if (changedRecords) ++*changedRecords;
    }
    return edits;
}

// ── Duplicates ──────────────────────────────────────────────────────────────

namespace {

// Same CALL, band and mode (MODE, plus SUBMODE when both give one).
bool sameCallBandMode(const Record &a, const Record &b) {
    const std::string &ca = a.get("CALL");
    if (ca.empty() || !equalsNoCase(trim(ca), trim(b.get("CALL")))) return false;
    std::string ba = effectiveBand(a), bb = effectiveBand(b);
    if (ba.empty() || ba != bb) return false;
    const std::string &ma = a.get("MODE"), &mb = b.get("MODE");
    if (!ma.empty() && !mb.empty()) {
        if (!equalsNoCase(trim(ma), trim(mb))) return false;
        const std::string &sa = a.get("SUBMODE"), &sb = b.get("SUBMODE");
        return sa.empty() || sb.empty() || equalsNoCase(trim(sa), trim(sb));
    }
    return effectiveMode(a) == effectiveMode(b) && !effectiveMode(a).empty();
}

// No different station or program references (a park-to-park line per park is a separate contact).
bool sameReferences(const Record &a, const Record &b) {
    for (const char *f : {"STATION_CALLSIGN", "MY_SIG_INFO", "SIG_INFO", "MY_POTA_REF", "POTA_REF", "MY_SOTA_REF", "SOTA_REF",
                          "MY_WWFF_REF", "WWFF_REF"}) {
        const std::string &va = a.get(f), &vb = b.get(f);
        if (!va.empty() && !vb.empty() && !equalsNoCase(trim(va), trim(vb))) return false;
    }
    return true;
}

}  // namespace

bool sameQso(const Record &a, const Record &b, const DupeOptions &opt) {
    if (!sameCallBandMode(a, b)) return false;
    long long ta = qsoStart(a), tb = qsoStart(b);
    if (ta < 0 || tb < 0) return false;
    long long d = ta > tb ? ta - tb : tb - ta;
    if (d > (long long)opt.windowMinutes * 60) return false;
    return sameReferences(a, b);
}

std::vector<int> sameContactAs(std::string_view text, const DocModel &m, const Record &qso) {
    std::vector<int> out;
    const std::string &date = qso.get("QSO_DATE");
    for (const Record &r : records(text, m))
        if (r.get("QSO_DATE") == date && sameCallBandMode(r, qso) && sameReferences(r, qso)) out.push_back(r.number);
    return out;
}

size_t timesWorkedAs(std::string_view text, const DocModel &m, std::string_view call) {
    std::string base = lookupCall(call);
    size_t n = 0;
    if (base.empty()) return 0;
    for (const Record &r : records(text, m))
        if (!r.get("CALL").empty() && lookupCall(r.get("CALL")) == base) ++n;
    return n;
}

std::vector<DupeSet> findDuplicates(std::string_view text, const DocModel &m, const DupeOptions &opt) {
    std::vector<Record> recs = records(text, m);
    std::unordered_map<std::string, std::vector<size_t>> byCall;
    for (size_t i = 0; i < recs.size(); ++i)
        if (!recs[i].get("CALL").empty()) byCall[upperAscii(trim(recs[i].get("CALL")))].push_back(i);
    std::vector<DupeSet> out;
    std::vector<bool> used(recs.size(), false);
    for (size_t i = 0; i < recs.size(); ++i) {
        if (used[i] || recs[i].get("CALL").empty()) continue;
        std::vector<size_t> set{i};
        for (size_t j : byCall[upperAscii(trim(recs[i].get("CALL")))])
            if (j > i && !used[j] && sameQso(recs[i], recs[j], opt)) set.push_back(j);
        if (set.size() < 2) continue;
        for (size_t k : set) used[k] = true;
        auto filled = [&](size_t k) {
            size_t c = 0;
            for (const auto &f : recs[k].fields) c += !f.second.empty();
            return c;
        };
        size_t keep = set[0];
        for (size_t k : set)
            if (filled(k) > filled(keep)) keep = k;
        DupeSet d;
        d.keep = recs[keep].group;
        for (size_t k : set) {
            if (k == keep) continue;
            d.remove.push_back(recs[k].group);
            for (const auto &f : recs[k].fields) {
                if (f.second.empty() || recs[keep].has(f.first)) continue;
                bool already = false;
                for (const auto &x : d.fill) already |= x.first == f.first;
                if (!already) d.fill.push_back(f);
            }
        }
        out.push_back(std::move(d));
    }
    return out;
}

std::vector<TextEdit> duplicateEdits(std::string_view text, const DocModel &m, const std::vector<DupeSet> &sets, bool fill,
                                     LengthUnit unit, bool utf8) {
    std::vector<int> removed;
    std::vector<TextEdit> edits;
    for (const DupeSet &d : sets) {
        removed.insert(removed.end(), d.remove.begin(), d.remove.end());
        if (fill && !d.fill.empty() && d.keep >= 0 && (size_t)d.keep < m.groups.size())
            edits.push_back(insertFields(text, m, m.groups[(size_t)d.keep], d.fill, unit, utf8));
    }
    for (const TextEdit &e : removeRecordsEdits(text, m, removed)) edits.push_back(e);
    sortEdits(edits);
    return edits;
}

std::vector<TextEdit> removeRecordsEdits(std::string_view text, const DocModel &m, const std::vector<int> &groups) {
    std::vector<std::pair<size_t, size_t>> ranges;
    for (int gi : groups) {
        if (gi < 0 || (size_t)gi >= m.groups.size() || m.groups[(size_t)gi].header) continue;
        const ModelGroup &g = m.groups[(size_t)gi];
        size_t b = groupStart(m, g), e = groupEnd(m, g);
        size_t after = e;
        while (after < text.size() && isBlankChar(text[after])) ++after;
        if (after < text.size()) {
            e = after;  // the record and the blank run after it
        } else {
            while (b > 0 && isBlankChar(text[b - 1])) --b;  // last record: the blank run before it
        }
        ranges.emplace_back(b, e);
    }
    std::sort(ranges.begin(), ranges.end());
    std::vector<std::pair<size_t, size_t>> merged;
    for (const auto &r : ranges) {
        if (!merged.empty() && r.first <= merged.back().second) merged.back().second = std::max(merged.back().second, r.second);
        else merged.push_back(r);
    }
    std::vector<TextEdit> edits;
    for (auto &r : merged) {
        // Removing up to the last record: the blank run before goes too, the end of the file stays.
        if (isBlankText(text.substr(r.second)))
            while (r.first > 0 && isBlankChar(text[r.first - 1])) --r.first;
        edits.push_back(TextEdit{r.first, r.second, std::string()});
    }
    return edits;
}

// ── Spreadsheet editing ─────────────────────────────────────────────────────

std::string cellValue(std::string_view field, std::string_view shown) {
    std::string v = trim(shown);
    const FieldDef *d = findField(field);
    if (d && (d->type == DataType::Date || d->type == DataType::Time)) {
        std::string digits;
        bool other = false;
        for (char c : v) {
            if (c >= '0' && c <= '9') digits.push_back(c);
            else if (c != '-' && c != '/' && c != ':' && c != '.') other = true;
        }
        if (!other) return digits;  // 2026-10-06 -> 20261006, 22:30 -> 2230
    }
    return v;
}

std::vector<TextEdit> cellEdits(std::string_view text, const DocModel &m, const std::vector<CellChange> &changes,
                                LengthUnit unit, bool utf8) {
    // Per record, per field: the last change wins; fields in the order first changed.
    std::map<int, std::vector<std::pair<std::string, std::string>>> byGroup;
    for (const CellChange &c : changes) {
        if (c.group < 0 || (size_t)c.group >= m.groups.size() || m.groups[(size_t)c.group].header || c.field.empty()) continue;
        std::string field = upperAscii(c.field);
        auto &list = byGroup[c.group];
        auto it = std::find_if(list.begin(), list.end(), [&](const auto &kv) { return kv.first == field; });
        if (it != list.end()) it->second = c.value;
        else list.emplace_back(field, c.value);
    }
    std::vector<TextEdit> edits;
    for (const auto &kv : byGroup) {
        const ModelGroup &g = m.groups[(size_t)kv.first];
        std::vector<std::pair<std::string, std::string>> added;
        for (const auto &fv : kv.second) {
            int found = -1;
            for (size_t i = 0; i < g.fieldCount && found < 0; ++i)
                if (equalsNoCase(fieldName(text, m.fields[g.firstField + i]), fv.first)) found = (int)i;
            if (found >= 0 && fv.second.empty()) edits.push_back(removeField(text, m, g, (size_t)found));
            else if (found >= 0) {
                if (fieldValue(text, m.fields[g.firstField + (size_t)found]) != fv.second)
                    edits.push_back(setFieldValue(text, m.fields[g.firstField + (size_t)found], fv.second, unit, utf8));
            } else if (!fv.second.empty()) {
                added.push_back(fv);
            }
        }
        if (!added.empty()) edits.push_back(insertFields(text, m, g, added, unit, utf8));
    }
    sortEdits(edits);
    return edits;
}

std::string toTsv(const std::vector<std::vector<std::string>> &rows) {
    std::string out;
    for (const auto &row : rows) {
        for (size_t i = 0; i < row.size(); ++i) {
            if (i) out += '\t';
            const std::string &v = row[i];
            if (v.find_first_of("\t\"\r\n") != std::string::npos) {
                out += '"';
                for (char c : v) {
                    if (c == '"') out += '"';
                    out += c;
                }
                out += '"';
            } else {
                out += v;
            }
        }
        out += "\r\n";
    }
    return out;
}

std::vector<TextEdit> quickFixEdits(std::string_view text, const DocModel &m, const std::vector<Diagnostic> &diagnostics,
                                    LengthUnit unit, bool utf8, size_t *applied) {
    auto lengthsOk = [&](int g) {
        const ModelGroup &grp = m.groups[(size_t)g];
        for (size_t i = 0; i < grp.fieldCount; ++i)
            if (!m.fields[grp.firstField + i].lengthOk) return false;
        return true;
    };
    std::vector<CellChange> changes;
    std::vector<TextEdit> other;
    size_t used = 0;
    for (const Diagnostic &d : diagnostics) {
        if (d.fixes.empty()) continue;
        int g = groupAt(m, d.start);
        bool inRecord = g >= 0 && !m.groups[(size_t)g].header && d.start >= groupStart(m, m.groups[(size_t)g]) &&
                        lengthsOk(g);
        bool ok = true;
        std::vector<CellChange> mine;
        std::vector<TextEdit> edits;
        for (const FieldFix &fx : d.fixes) {
            switch (fx.kind) {
                case FixKind::SetValue:
                    if (!inRecord || fx.field.empty() || fx.value.empty()) ok = false;
                    else mine.push_back(CellChange{g, fx.field, fx.value});
                    break;
                case FixKind::RemoveField: {
                    int fi = fieldAt(m, d.start);
                    const ModelGroup &grp = m.groups[(size_t)std::max(g, 0)];
                    if (!inRecord || fi < 0 || (size_t)fi < grp.firstField || (size_t)fi >= grp.firstField + grp.fieldCount ||
                        !equalsNoCase(fieldName(text, m.fields[(size_t)fi]), fx.field))
                        ok = false;
                    else
                        edits.push_back(removeField(text, m, grp, (size_t)fi - grp.firstField));
                    break;
                }
                case FixKind::InsertText:
                    if (fx.at > text.size()) ok = false;
                    else edits.push_back(TextEdit{fx.at, fx.at, fx.value});
                    break;
                case FixKind::DeleteText:
                    if (d.end > text.size() || d.end <= d.start) ok = false;
                    else edits.push_back(TextEdit{d.start, d.end, std::string()});
                    break;
            }
        }
        if (!ok) continue;
        changes.insert(changes.end(), mine.begin(), mine.end());
        other.insert(other.end(), edits.begin(), edits.end());
        ++used;
    }
    std::vector<TextEdit> edits = mergeEdits(cellEdits(text, m, changes, unit, utf8), other);
    if (applied) *applied = used;
    return edits;
}

// ── Merging ─────────────────────────────────────────────────────────────────

MergePlan planMerge(std::string_view target, const DocModel &targetModel, std::string_view source,
                    const DocModel &sourceModel, const DupeOptions &opt, bool skipDuplicates) {
    MergePlan plan;
    std::vector<Record> have = records(target, targetModel), add = records(source, sourceModel);
    std::unordered_map<std::string, std::vector<size_t>> byCall;  // into `have`, then appended source records
    for (size_t i = 0; i < have.size(); ++i)
        if (!have[i].get("CALL").empty()) byCall[upperAscii(trim(have[i].get("CALL")))].push_back(i);
    std::vector<Record> added;
    for (const Record &r : add) {
        if (r.fields.empty()) {
            ++plan.emptyRecords;
            continue;
        }
        if (skipDuplicates && !r.get("CALL").empty()) {
            std::string key = upperAscii(trim(r.get("CALL")));
            int dupOf = -2;
            for (size_t i : byCall[key]) {
                const Record &other = i < have.size() ? have[i] : added[i - have.size()];
                if (sameQso(other, r, opt)) {
                    dupOf = i < have.size() ? other.group : -1;
                    break;
                }
            }
            if (dupOf != -2) {
                plan.duplicates.emplace_back(r.group, dupOf);
                continue;
            }
            byCall[key].push_back(have.size() + added.size());
        }
        added.push_back(r);
        plan.add.push_back(r.group);
    }
    for (const UserFieldInfo &u : sourceModel.userFields) {
        bool known = false;
        for (const UserFieldInfo &t : targetModel.userFields) known |= equalsNoCase(t.name, u.name);
        if (!known) plan.undefinedFields.push_back(upperAscii(u.name));
    }
    return plan;
}

std::string mergedRecords(std::string_view source, const DocModel &sourceModel, const std::vector<int> &groups,
                          Layout layout, std::string_view eol, LengthUnit unit, bool utf8) {
    std::string out;
    const std::string sep = layout == Layout::FieldPerLine ? std::string(eol) : std::string(" ");
    for (int gi : groups) {
        if (gi < 0 || (size_t)gi >= sourceModel.groups.size()) continue;
        const ModelGroup &g = sourceModel.groups[(size_t)gi];
        if (g.header || !g.fieldCount) continue;
        if (!out.empty() && layout == Layout::FieldPerLine) out += eol;  // a blank line between records
        for (size_t i = 0; i < g.fieldCount; ++i) {
            const ModelField &f = sourceModel.fields[g.firstField + i];
            out += specifierFrom(source, f, fieldValue(source, f), unit, utf8) + sep;
        }
        out += "<EOR>";
        out += eol;
    }
    return out;
}

// ── CSV ─────────────────────────────────────────────────────────────────────

std::string toCsv(const std::vector<Record> &recs, const std::vector<std::string> &columns) {
    auto plainNumber = [](std::string_view v) {
        size_t i = (!v.empty() && (v[0] == '+' || v[0] == '-')) ? 1 : 0;
        bool digit = false, dot = false;
        for (; i < v.size(); ++i) {
            if (v[i] >= '0' && v[i] <= '9') digit = true;
            else if (v[i] == '.' && !dot) dot = true;
            else return false;
        }
        return digit;
    };
    auto cell = [&](std::string v) {
        if (!v.empty() && (v[0] == '=' || v[0] == '+' || v[0] == '-' || v[0] == '@' || v[0] == '\t' || v[0] == '\r') &&
            !plainNumber(v))
            v = "'" + v;
        if (v.find_first_of(",\"\r\n") == std::string::npos) return v;
        std::string q = "\"";
        for (char c : v) {
            if (c == '"') q += '"';
            q += c;
        }
        return q + "\"";
    };
    std::string out;
    for (size_t i = 0; i < columns.size(); ++i) out += (i ? "," : "") + cell(columns[i]);
    out += "\r\n";
    for (const Record &r : recs) {
        for (size_t i = 0; i < columns.size(); ++i) out += (i ? "," : "") + cell(r.get(columns[i]));
        out += "\r\n";
    }
    return out;
}

// ── POTA ────────────────────────────────────────────────────────────────────

bool isPotaRef(std::string_view ref) {
    size_t at = ref.find('@');
    std::string_view park = ref.substr(0, at);
    size_t dash = park.find('-');
    if (dash == std::string_view::npos || dash < 1 || dash > 4) return false;
    for (size_t i = 0; i < dash; ++i) {
        char c = park[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) return false;
    }
    std::string_view num = park.substr(dash + 1);
    if ((num.size() != 4 && num.size() != 5) || !allDigits(num)) return false;
    if (at == std::string_view::npos) return true;
    std::string_view loc = ref.substr(at + 1);
    if (loc.size() < 4 || loc.size() > 6 || loc.find('-') != 2) return false;
    for (char c : loc)
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    return true;
}

namespace {

// A list without repeats, in its order ("US-1234,US-1234" is one park).
std::vector<std::string> distinct(std::vector<std::string> v) {
    std::vector<std::string> out;
    for (std::string &s : v)
        if (std::find(out.begin(), out.end(), s) == out.end()) out.push_back(std::move(s));
    return out;
}

std::vector<std::string> parks(const Record &r, const char *refField, const char *sigField, const char *infoField) {
    std::vector<std::string> list = distinct(splitList(r.get(refField)));
    if (!list.empty()) return list;
    const std::string &sig = r.get(sigField);
    std::vector<std::string> info = distinct(splitList(r.get(infoField)));
    if (info.empty()) return {};
    if (equalsNoCase(trim(sig), "POTA")) return info;
    if (!trim(sig).empty()) return {};
    for (const std::string &p : info)
        if (!isPotaRef(p)) return {};
    return info;
}

std::string parkBase(const std::string &park) { return park.substr(0, park.find('@')); }

std::string parkLocation(const std::string &park) {
    size_t at = park.find('@');
    return at == std::string::npos ? std::string() : park.substr(at + 1);
}

std::string fileCall(std::string call) {
    for (char &c : call)
        if (c == '/' || c == '\\' || c == ':' || c == ' ') c = '_';
    return call;
}

}  // namespace

std::vector<std::string> myParks(const Record &r) { return parks(r, "MY_POTA_REF", "MY_SIG", "MY_SIG_INFO"); }

const char *programName(Program p) { return p == Program::WWFF ? "WWFF" : p == Program::SOTA ? "SOTA" : "POTA"; }

std::vector<std::string> programRefs(const Record &r, Program p, bool mine) {
    if (p == Program::POTA) return mine ? myParks(r) : theirParks(r);
    const char *ref = p == Program::WWFF ? (mine ? "MY_WWFF_REF" : "WWFF_REF") : (mine ? "MY_SOTA_REF" : "SOTA_REF");
    std::vector<std::string> out = distinct(splitList(r.get(ref)));
    if (!out.empty()) return out;
    const std::string &sig = r.get(mine ? "MY_SIG" : "SIG");
    std::string info = upperAscii(trim(r.get(mine ? "MY_SIG_INFO" : "SIG_INFO")));
    bool valid = p == Program::WWFF ? isAdifWwffRef(info) : isAdifSotaRef(info);
    if (!info.empty() && equalsNoCase(trim(sig), programName(p)) && valid) out.push_back(info);
    return out;
}
std::vector<std::string> theirParks(const Record &r) { return parks(r, "POTA_REF", "SIG", "SIG_INFO"); }

std::string stationCall(const Record &r) {
    std::string s = upperAscii(trim(r.get("STATION_CALLSIGN")));
    return s.empty() ? upperAscii(trim(r.get("OPERATOR"))) : s;
}

std::vector<Activation> activations(std::string_view text, const DocModel &m, std::string_view defaultStation) {
    std::vector<Record> recs = records(text, m);
    // Records without a station callsign belong to the station the log is for.
    std::string fallback = upperAscii(trim(defaultStation));
    if (fallback.empty()) {
        std::map<std::string, size_t> count;
        size_t most = 0;
        for (const Record &r : recs)
            if (std::string s = stationCall(r); !s.empty() && ++count[s] > most) most = count[s], fallback = s;
    }
    std::map<std::tuple<std::string, std::string, std::string>, Activation> acts;  // (date, park, station)
    std::map<std::tuple<std::string, std::string, std::string>, std::set<std::string>> seen;
    for (const Record &r : recs) {
        std::vector<std::string> mine = myParks(r);
        const std::string &date = r.get("QSO_DATE");
        if (mine.empty() || !parseAdifDate(date, nullptr)) continue;
        std::string station = stationCall(r), call = upperAscii(trim(r.get("CALL")));
        bool noStation = station.empty();
        if (noStation) station = fallback;
        std::string band = lowerAscii(trim(r.get("BAND"))), mode = effectiveMode(r);
        std::string time = r.get("TIME_ON");
        bool valid = !call.empty() && parseAdifTime(time, nullptr) && !band.empty() && !mode.empty() &&
                     call != station && call != upperAscii(trim(r.get("OPERATOR")));
        std::string theirs = joinList(theirParks(r));
        for (const std::string &park : mine) {
            auto key = std::make_tuple(date, park, station);
            Activation &a = acts[key];
            if (a.groups.empty()) {
                a.station = station;
                a.park = park;
                a.date = a.lastDate = date;
            }
            a.groups.push_back(r.group);
            a.noStation += noStation;
            if (parseAdifTime(time, nullptr)) {
                std::string t = time.size() == 4 ? time + "00" : time;
                if (a.first.empty() || t < a.first) a.first = t;
                if (a.last.empty() || t > a.last) a.last = t;
            }
            if (!valid) {
                ++a.invalid;
                continue;
            }
            if (!seen[key].insert(call + "|" + band + "|" + mode + "|" + theirs).second) {
                ++a.duplicates;
                continue;
            }
            ++a.qsos;
            ++a.bands[band];
            ++a.modes[mode];
            if (!theirs.empty()) ++a.p2p;
        }
    }
    std::vector<Activation> out;
    for (auto &kv : acts) out.push_back(std::move(kv.second));
    return out;
}

std::vector<PotaFile> potaExport(std::string_view text, const DocModel &m, std::string_view defaultStation,
                                 std::string_view programVersion, std::string_view utcTimestamp, std::string_view eol,
                                 LengthUnit unit, bool utf8, std::string_view todayUtc) {
    std::vector<PotaFile> out;
    std::vector<Activation> acts = activations(text, m, defaultStation);
    for (const Activation &a : acts) {
        PotaFile f;
        f.station = a.station;
        f.park = a.park;
        f.date = a.date;
        std::string base = parkBase(a.park), loc = parkLocation(a.park);
        f.name = (f.station.empty() ? std::string("NOCALL") : fileCall(f.station)) + "@" + base + "-" + a.date +
                 (loc.empty() ? "" : "-" + loc) + ".adi";

        std::string h = "ADIF export for Parks on the Air: " + (f.station.empty() ? std::string("?") : f.station) + " at " +
                        a.park + " on " + displayDate(a.date) + " UTC";
        h += eol;
        h += makeSpecifier("ADIF_VER", kSpecVersion, LengthUnit::Bytes, false) + std::string(eol);
        h += makeSpecifier("PROGRAMID", "ADIF Lint", LengthUnit::Bytes, false) + std::string(eol);
        h += makeSpecifier("PROGRAMVERSION", programVersion, LengthUnit::Bytes, false) + std::string(eol);
        h += makeSpecifier("CREATED_TIMESTAMP", utcTimestamp, LengthUnit::Bytes, false) + std::string(eol);
        h += "<EOH>";
        h += eol;
        f.text = h;

        size_t addedStation = 0;
        for (int gi : a.groups) {
            const ModelGroup &g = m.groups[(size_t)gi];
            std::string rec;
            bool hasSig = false, hasInfo = false, hasStation = false;
            for (size_t i = 0; i < g.fieldCount; ++i) {
                const ModelField &fld = m.fields[g.firstField + i];
                std::string_view name = fieldName(text, fld);
                std::string value(fieldValue(text, fld));
                if (equalsNoCase(name, "MY_SIG")) value = "POTA", hasSig = true;
                else if (equalsNoCase(name, "MY_SIG_INFO")) value = base, hasInfo = true;
                else if (equalsNoCase(name, "MY_POTA_REF")) value = a.park;
                if (equalsNoCase(name, "STATION_CALLSIGN") || equalsNoCase(name, "OPERATOR"))
                    hasStation |= !trim(value).empty();
                rec += specifierFrom(text, fld, value, unit, utf8) + " ";
            }
            if (!hasSig) rec += makeSpecifier("MY_SIG", "POTA", unit, utf8) + " ";
            if (!hasInfo) rec += makeSpecifier("MY_SIG_INFO", base, unit, utf8) + " ";
            if (!hasStation && !f.station.empty()) {
                rec += makeSpecifier("STATION_CALLSIGN", f.station, unit, utf8) + " ";
                ++addedStation;
            }
            f.text += rec + "<EOR>" + std::string(eol);
            ++f.records;
        }
        f.qsos = a.qsos;
        if (!a.activated())
            f.notes.push_back(std::to_string(a.qsos) + (a.qsos == 1 ? " QSO: " : " QSOs: ") + std::to_string(10 - a.qsos) +
                              " short of the 10 for an activation");
        if (a.duplicates)
            f.notes.push_back(std::to_string(a.duplicates) + " duplicate" + (a.duplicates == 1 ? "" : "s") +
                              " (POTA drops them, no penalty)");
        if (a.invalid)
            f.notes.push_back(std::to_string(a.invalid) + " record" + (a.invalid == 1 ? "" : "s") +
                              " POTA would reject (missing CALL, TIME_ON, BAND or MODE, or your own call)");
        if (f.station.empty()) f.notes.push_back("no STATION_CALLSIGN or OPERATOR: enter your callsign");
        else if (addedStation)
            f.notes.push_back("STATION_CALLSIGN " + f.station + " added to " + std::to_string(addedStation) +
                              (addedStation == 1 ? " record" : " records"));
        if (!todayUtc.empty() && a.date > todayUtc) f.notes.push_back("dated in the future");
        out.push_back(std::move(f));
    }
    // Two files must never share a name (one would overwrite the other).
    std::set<std::string> names;
    for (PotaFile &f : out) {
        std::string stem = f.name.substr(0, f.name.size() - 4), name = f.name;
        for (int n = 2; !names.insert(name).second; ++n) name = stem + "-" + std::to_string(n) + ".adi";
        f.name = name;
    }
    return out;
}

std::string hzToMHz(std::string_view hz) {
    std::string d = trim(hz);
    size_t dot = d.find('.');
    bool roundUp = false;
    if (dot != std::string::npos) {  // "14074000.000000": a fraction of a hertz, rounded
        std::string frac = d.substr(dot + 1);
        for (char c : frac)
            if (c < '0' || c > '9') return "";
        roundUp = !frac.empty() && frac[0] >= '5';
        d.resize(dot);
    }
    if (d.empty() || d.size() > 15) return "";
    for (char c : d)
        if (c < '0' || c > '9') return "";
    unsigned long long v = std::strtoull(d.c_str(), nullptr, 10) + (roundUp ? 1 : 0);
    std::string whole = std::to_string(v / 1000000), frac = std::to_string(v % 1000000);
    frac = std::string(6 - frac.size(), '0') + frac;
    while (frac.size() > 3 && frac.back() == '0') frac.pop_back();
    return whole + "." + frac;
}

std::string khzToMHz(std::string_view kHz) {
    std::string k = trim(kHz);
    size_t dot = k.find('.');
    std::string whole = k.substr(0, dot), frac = dot == std::string::npos ? std::string() : k.substr(dot + 1);
    if (whole.empty() || whole.size() > 9 || !allDigits(whole) || (!frac.empty() && !allDigits(frac))) return "";
    if (dot != std::string::npos && frac.empty()) return "";
    frac.resize(3, '0');  // whole hertz; finer digits are dropped
    return hzToMHz(whole + frac);
}

std::vector<std::pair<std::string, std::string>> spotFields(std::string_view activator, std::string_view kHz,
                                                            std::string_view mode, std::string_view reference) {
    std::vector<std::pair<std::string, std::string>> out;
    std::string call = upperAscii(trim(activator));
    bool callOk = !call.empty() && call.size() <= 20;
    for (char c : call) callOk &= (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/';
    if (callOk) out.emplace_back("CALL", call);
    std::string mhz = khzToMHz(kHz), band = mhz.empty() ? std::string() : bandForFrequency(mhz);
    if (!mhz.empty()) out.emplace_back("FREQ", mhz);
    if (!band.empty()) out.emplace_back("BAND", band);

    std::string m = upperAscii(trim(mode)), adifMode, adifSub;
    double f = 0;
    if (m == "SSB") {
        adifMode = "SSB";
        if (parseAdifNumber(mhz, &f)) adifSub = (f < 10 && band != "60m") ? "LSB" : "USB";
    } else if (!m.empty() && m != "DATA") {
        const EnumDef *modes = findEnum("Mode"), *subs = findEnum("Submode");
        const EnumValue *v = modes ? findEnumValue(*modes, m) : nullptr;
        const EnumValue *sv = subs ? findEnumValue(*subs, m) : nullptr;
        if (v && !v->importOnly) adifMode = v->value;
        else if (sv && !sv->importOnly && sv->scope) adifMode = sv->scope, adifSub = sv->value;
    }
    if (!adifMode.empty()) out.emplace_back("MODE", adifMode);
    if (!adifSub.empty()) out.emplace_back("SUBMODE", adifSub);

    std::string ref = upperAscii(trim(reference));
    if (isPotaRef(ref)) {
        out.emplace_back("SIG", "POTA");
        out.emplace_back("SIG_INFO", ref);
        out.emplace_back("POTA_REF", ref);
    }
    return out;
}

// ── Worked before ───────────────────────────────────────────────────────────

std::vector<Contact> contacts(std::string_view text, const DocModel &m) {
    std::vector<Contact> out;
    for (const Record &r : records(text, m)) {
        std::string call = upperAscii(trim(r.get("CALL")));
        if (call.empty()) continue;
        Contact c;
        c.call = call;
        c.baseCall = lookupCall(call);
        c.date = r.get("QSO_DATE");
        c.time = r.get("TIME_ON");
        c.band = effectiveBand(r);
        c.mode = effectiveMode(r);
        c.myPark = joinList(myParks(r));
        c.theirPark = joinList(theirParks(r));
        for (Program p : {Program::POTA, Program::WWFF, Program::SOTA})
            for (std::string &ref : programRefs(r, p, false)) c.theirRefs.push_back(std::move(ref));
        c.record = r.number;
        out.push_back(std::move(c));
    }
    return out;
}

std::string workedSummary(std::string_view call, const std::vector<WorkedHit> &hits) {
    if (hits.empty()) return "";
    std::set<std::string> logs, modes;
    std::vector<std::string> bands;
    const WorkedHit *latest = nullptr;
    auto stamp = [](const Contact &c) { return c.date + (c.time.size() == 4 ? c.time + "00" : c.time); };
    for (const WorkedHit &h : hits) {
        logs.insert(h.log);
        if (!h.contact.mode.empty()) modes.insert(h.contact.mode);
        if (!h.contact.band.empty() && std::find(bands.begin(), bands.end(), h.contact.band) == bands.end())
            bands.push_back(h.contact.band);
        if (!latest || stamp(h.contact) > stamp(latest->contact)) latest = &h;
    }
    std::sort(bands.begin(), bands.end(), [](const std::string &a, const std::string &b) { return bandOrder(a) < bandOrder(b); });
    std::string s = upperAscii(call) + ": " + std::to_string(hits.size()) + (hits.size() == 1 ? " QSO" : " QSOs") + " in " +
                    std::to_string(logs.size()) + (logs.size() == 1 ? " other log" : " other logs") + "; last " +
                    displayDate(latest->contact.date) + " " + displayTime(latest->contact.time);
    std::string what = latest->contact.band + (latest->contact.mode.empty() ? "" : " " + latest->contact.mode);
    if (!what.empty() && what != " ") s += " on " + what;
    s += " (" + latest->log + ").";
    if (!bands.empty()) s += " Bands: " + joinList(bands, ", ") + ".";
    if (!modes.empty()) s += " Modes: " + joinList(std::vector<std::string>(modes.begin(), modes.end()), ", ") + ".";
    return s;
}

}  // namespace adif
