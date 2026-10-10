#include "adif_edit.h"

#include "adif_spec.h"

#include <algorithm>
#include <set>

namespace adif {
namespace {

bool isBlank(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

std::string upperAscii(std::string_view s) {
    std::string out(s);
    for (char &c : out)
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
    return out;
}

bool lessNoCase(const std::string &a, const std::string &b) { return compareNoCase(a, b) < 0; }

void sortUnique(std::vector<std::string> &v) {
    std::sort(v.begin(), v.end(), lessNoCase);
    v.erase(std::unique(v.begin(), v.end(), [](const std::string &a, const std::string &b) { return equalsNoCase(a, b); }),
            v.end());
}

const UserFieldInfo *findUserField(const DocModel &m, std::string_view name) {
    for (const UserFieldInfo &u : m.userFields)
        if (equalsNoCase(u.name, name)) return &u;
    return nullptr;
}

}  // namespace

// ── Reformat ────────────────────────────────────────────────────────────────

bool canReformat(const LintResult &r) { return r.structuralErrors == 0 && r.fixes.empty(); }

std::string reformat(std::string_view text, const DocModel &m, Layout layout, std::string_view eol) {
    // Everything to emit, in document order.
    enum class Kind { Text, Field, Marker };
    struct Item {
        size_t pos;
        Kind kind;
        size_t b, e;      // bytes to copy
        bool header;      // field or marker belongs to the header
    };
    std::vector<Item> items;
    for (const ModelGroup &g : m.groups) {
        for (size_t i = 0; i < g.fieldCount; ++i) {
            const ModelField &f = m.fields[g.firstField + i];
            items.push_back({f.tagB, Kind::Field, f.tagB, f.valueE, g.header});
        }
        if (g.markerB != kNoPos) items.push_back({g.markerB, Kind::Marker, g.markerB, g.markerE, g.header});
    }
    for (const auto &t : m.otherText) items.push_back({t.first, Kind::Text, t.first, t.second, false});
    std::stable_sort(items.begin(), items.end(), [](const Item &a, const Item &b) { return a.pos < b.pos; });

    std::string out;
    out.reserve(text.size() + text.size() / 8);
    if (m.hasBom) out.append(text.substr(0, 3));
    bool atLineStart = true;
    auto newline = [&] {
        if (!atLineStart) out.append(eol);
        atLineStart = true;
    };
    if (m.headerTextE > m.headerTextB) {
        out.append(text.substr(m.headerTextB, m.headerTextE - m.headerTextB));
        out.append(eol);
    } else if (!m.groups.empty() && m.groups.front().header && m.firstTag != kNoPos) {
        // A header with no text still needs the file not to start with '<'
        // (§IV.A.3), so keep the original leading whitespace (often one space).
        size_t b = m.hasBom ? 3 : 0;
        if (m.firstTag > b) out.append(text.substr(b, m.firstTag - b));
    }
    for (const Item &it : items) {
        std::string_view bytes = text.substr(it.b, it.e - it.b);
        switch (it.kind) {
            case Kind::Text:
                newline();
                out.append(bytes);
                out.append(eol);
                break;
            case Kind::Field:
                if (it.header || layout == Layout::FieldPerLine) {
                    newline();
                    out.append(bytes);
                    out.append(eol);
                } else {
                    if (!atLineStart) out.push_back(' ');
                    out.append(bytes);
                    atLineStart = false;
                }
                break;
            case Kind::Marker:
                if (it.header) {  // <EOH>, then a blank line before the records
                    newline();
                    out.append(bytes);
                    out.append(eol);
                    out.append(eol);
                } else if (layout == Layout::RecordPerLine) {
                    if (!atLineStart) out.push_back(' ');
                    out.append(bytes);
                    out.append(eol);
                } else {  // one field per line: <EOR> on its own line, blank line between records
                    newline();
                    out.append(bytes);
                    out.append(eol);
                    out.append(eol);
                }
                atLineStart = true;
                break;
        }
    }
    newline();
    // No run of blank lines at the end.
    while (out.size() >= 2 * eol.size() && std::string_view(out).substr(out.size() - 2 * eol.size()) ==
                                               std::string(eol) + std::string(eol))
        out.resize(out.size() - eol.size());
    return out;
}

// ── Lookups ─────────────────────────────────────────────────────────────────

size_t groupStart(const DocModel &m, const ModelGroup &g) {
    if (g.fieldCount) return m.fields[g.firstField].tagB;
    return g.markerB == kNoPos ? 0 : g.markerB;
}

size_t groupEnd(const DocModel &m, const ModelGroup &g) {
    if (g.markerE != kNoPos) return g.markerE;
    return g.fieldCount ? m.fields[g.firstField + g.fieldCount - 1].valueE : 0;
}

int groupAt(const DocModel &m, size_t pos) {
    int found = -1;
    // Groups are in document order; binary search on their start.
    size_t lo = 0, hi = m.groups.size();
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (groupStart(m, m.groups[mid]) <= pos) {
            found = (int)mid;
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return found;
}

int fieldAt(const DocModel &m, size_t pos) {
    int g = groupAt(m, pos);
    if (g < 0) return -1;
    const ModelGroup &grp = m.groups[(size_t)g];
    for (size_t i = 0; i < grp.fieldCount; ++i) {
        const ModelField &f = m.fields[grp.firstField + i];
        if (f.tagB <= pos && pos <= f.valueE) return (int)(grp.firstField + i);
    }
    return -1;
}

int recordNumber(const DocModel &m, int group) {
    if (group < 0 || (size_t)group >= m.groups.size() || m.groups[(size_t)group].header) return 0;
    int n = 0;
    for (int i = 0; i <= group; ++i) n += !m.groups[(size_t)i].header;
    return n;
}

size_t recordCount(const DocModel &m) {
    size_t n = 0;
    for (const ModelGroup &g : m.groups) n += !g.header;
    return n;
}

std::string_view fieldName(std::string_view text, const ModelField &f) {
    return text.substr(f.tagB + 1, f.nameE - f.tagB - 1);
}

std::string_view fieldValue(std::string_view text, const ModelField &f) {
    return text.substr(f.gt + 1, f.valueE - f.gt - 1);
}

std::string_view groupValue(std::string_view text, const DocModel &m, const ModelGroup &g, std::string_view name) {
    for (size_t i = 0; i < g.fieldCount; ++i) {
        const ModelField &f = m.fields[g.firstField + i];
        if (equalsNoCase(fieldName(text, f), name)) return fieldValue(text, f);
    }
    return {};
}

// ── Edits ───────────────────────────────────────────────────────────────────

std::string makeSpecifier(std::string_view name, std::string_view value, LengthUnit unit, bool utf8, char indicator) {
    std::string s = "<";
    s.append(name);
    s.push_back(':');
    s += std::to_string(measureLength(value, unit, utf8));
    if (indicator) {
        s.push_back(':');
        s.push_back(indicator);
    }
    s.push_back('>');
    s.append(value);
    return s;
}

TextEdit setFieldValue(std::string_view text, const ModelField &f, std::string_view value, LengthUnit unit, bool utf8) {
    char indicator = f.typePos == kNoPos ? 0 : text[f.typePos];
    return TextEdit{f.tagB, f.valueE, makeSpecifier(fieldName(text, f), value, unit, utf8, indicator)};
}

TextEdit insertField(std::string_view text, const DocModel &m, const ModelGroup &g, std::string_view name,
                     std::string_view value, LengthUnit unit, bool utf8) {
    std::string spec = makeSpecifier(name, value, unit, utf8);
    if (g.markerB == kNoPos) {  // unterminated record at the end of the file
        size_t at = g.fieldCount ? m.fields[g.firstField + g.fieldCount - 1].valueE : text.size();
        return TextEdit{at, at, " " + spec};
    }
    // Reuse the separator that precedes the marker: " " or a line break.
    size_t sepB = g.markerB;
    size_t floor = g.fieldCount ? m.fields[g.firstField + g.fieldCount - 1].valueE : 0;
    while (sepB > floor && isBlank(text[sepB - 1])) --sepB;
    std::string sep(text.substr(sepB, g.markerB - sepB));
    size_t nl = sep.find('\n');
    if (nl != std::string::npos) sep = (nl > 0 && sep[nl - 1] == '\r') ? "\r\n" : "\n";
    else sep = " ";
    return TextEdit{g.markerB, g.markerB, spec + sep};
}

TextEdit removeField(std::string_view text, const DocModel &m, const ModelGroup &g, size_t index) {
    const ModelField &f = m.fields[g.firstField + index];
    size_t next = index + 1 < g.fieldCount ? m.fields[g.firstField + index + 1].tagB
                  : g.markerB != kNoPos     ? g.markerB
                                            : text.size();
    size_t end = f.valueE;
    size_t e = end;
    while (e < next && isBlank(text[e])) ++e;
    if (e == next) end = next;  // only whitespace up to the next item: take the separator too
    return TextEdit{f.tagB, end, std::string()};
}

// ── Choices ─────────────────────────────────────────────────────────────────

std::vector<std::string> fieldNameChoices(const DocModel &m, bool header) {
    std::vector<std::string> out;
    size_t n = 0;
    const FieldDef *t = fieldTable(&n);
    if (header) {
        for (size_t i = 0; i < n; ++i)
            if (t[i].header) out.emplace_back(t[i].name);
        out.push_back("USERDEF" + std::to_string(m.userFields.size() + 1));
        out.push_back("EOH");
    } else {
        for (size_t i = 0; i < n; ++i) {
            if (t[i].header || t[i].importOnly) continue;
            if (t[i].type == DataType::IntlString || t[i].type == DataType::IntlMultilineString) continue;
            out.emplace_back(t[i].name);
        }
        for (const UserFieldInfo &u : m.userFields)
            if (u.name.find(' ') == std::string::npos) out.push_back(upperAscii(u.name));
        for (const auto &a : m.appFields) out.push_back(a.first);
        out.push_back("EOR");
    }
    sortUnique(out);
    return out;
}

std::vector<std::string> valueChoices(std::string_view text, const DocModel &m, const ModelGroup *g,
                                      std::string_view name) {
    return valueChoicesWith(m, name, [&](std::string_view key) {
        return g ? std::string(groupValue(text, m, *g, key)) : std::string();
    });
}

std::vector<std::string> valueChoicesWith(const DocModel &m, std::string_view name,
                                          const std::function<std::string(std::string_view)> &lookup) {
    std::vector<std::string> out;
    if (const UserFieldInfo *u = findUserField(m, name)) {
        if (u->indicator == 'B') return {"N", "Y"};
        return u->values;
    }
    const FieldDef *fd = findField(name);
    if (!fd) return out;
    if (fd->type == DataType::Boolean) return {"N", "Y"};
    if (!fd->enumeration) return out;
    const EnumDef *e = findEnum(fd->enumeration);
    if (!e) return out;
    if (equalsNoCase(e->name, "Band")) {  // spec order (by frequency) reads better than alphabetical
        size_t nb = 0;
        const BandDef *b = bandTable(&nb);
        for (size_t i = 0; i < nb; ++i) out.emplace_back(b[i].name);
        return out;
    }
    if (equalsNoCase(e->name, "DXCC_Entity_Code") || equalsNoCase(e->name, "Credit") ||
        equalsNoCase(e->name, "Sponsored_Award") || equalsNoCase(e->name, "Secondary_Administrative_Subdivision_Alt"))
        return out;  // bare codes or lists: a menu of them does not help
    std::string scope;
    if (fd->enumKey) {
        scope = lookup(fd->enumKey);
        while (scope.size() > 1 && scope[0] == '0') scope.erase(0, 1);  // DXCC "0291" -> "291"
        bool submode = equalsNoCase(e->name, "Submode");
        if (scope.empty() || !enumHasScope(*e, scope)) {
            if (!submode) return out;  // subdivisions need a known DXCC entity
            scope.clear();             // all submodes when MODE is missing or has none listed
        }
    }
    for (size_t i = 0; i < e->count; ++i) {
        const EnumValue &v = e->values[i];
        if (v.importOnly) continue;
        if (!scope.empty() && !(v.scope && equalsNoCase(v.scope, scope))) continue;
        out.emplace_back(v.value);
    }
    sortUnique(out);
    return out;
}

std::string describeField(const DocModel &m, std::string_view name) {
    std::string n = upperAscii(name);
    if (const FieldDef *fd = findField(name)) {
        std::string s = n + " (" + typeName(fd->type) + ")";
        if (fd->description) s += std::string(": ") + fd->description;
        if (fd->importOnly) s += " [import-only]";
        return s;
    }
    if (const UserFieldInfo *u = findUserField(m, name)) {
        std::string s = n + " (user-defined";
        if (u->indicator) s += std::string(", ") + typeName(typeFromIndicator(u->indicator));
        return s + ")";
    }
    for (const auto &a : m.appFields)
        if (a.first == n)
            return n + " (application-defined" +
                   (a.second ? std::string(", ") + typeName(typeFromIndicator(a.second)) : std::string()) + ")";
    if (n == "EOR") return "EOR: end of record";
    if (n == "EOH") return "EOH: end of header";
    return n;
}

FieldInfo fieldInfo(const DocModel &m, std::string_view name) {
    FieldInfo fi;
    fi.name = upperAscii(name);
    fi.hasValues = !valueChoicesWith(m, name, [](std::string_view) { return std::string(); }).empty();
    if (const FieldDef *fd = findField(name)) {
        fi.type = typeName(fd->type);
        fi.brief = fd->description ? fd->description : "";
        fi.details = fd->details ? fd->details : fi.brief;
        if (fd->importOnly) fi.brief += " (import-only)";
    } else if (const UserFieldInfo *u = findUserField(m, name)) {
        fi.type = u->indicator ? typeName(typeFromIndicator(u->indicator)) : "";
        fi.brief = "User-defined field, from this log's header";
        fi.details = fi.brief;
    } else if (fi.name.rfind("APP_", 0) == 0) {
        for (const auto &a : m.appFields)
            if (a.first == fi.name && a.second) fi.type = typeName(typeFromIndicator(a.second));
        fi.brief = "Application-defined field, used in this log";
        fi.details = fi.brief;
    }
    return fi;
}

// ── New QSO ─────────────────────────────────────────────────────────────────

bool isCarriedField(std::string_view name) {
    static const char *const kCarried[] = {"BAND",      "BAND_RX",   "FREQ",       "FREQ_RX",  "MODE",
                                           "SUBMODE",   "STATION_CALLSIGN", "OPERATOR", "OWNER_CALLSIGN",
                                           "TX_PWR",    "PROP_MODE", "SAT_NAME",   "SAT_MODE", "CONTEST_ID"};
    if (name.size() > 3 && equalsNoCase(name.substr(0, 3), "MY_")) return true;
    for (const char *c : kCarried)
        if (equalsNoCase(name, c)) return true;
    return false;
}

std::string defaultReport(std::string_view mode) {
    if (equalsNoCase(mode, "SSB") || equalsNoCase(mode, "AM") || equalsNoCase(mode, "FM") ||
        equalsNoCase(mode, "DIGITALVOICE"))
        return "59";
    if (equalsNoCase(mode, "CW") || equalsNoCase(mode, "RTTY")) return "599";
    return "";
}

std::string bandForFrequency(std::string_view mhz) {
    double f = 0;
    if (!parseAdifNumber(mhz, &f)) return "";
    size_t n = 0;
    const BandDef *b = bandTable(&n);
    const double kTol = 1e-9;  // edges are inclusive; absorb binary rounding of decimal MHz
    for (size_t i = 0; i < n; ++i)
        if (f >= b[i].lowerMHz - kTol && f <= b[i].upperMHz + kTol) return b[i].name;
    return "";
}

bool isRequiredQsoField(std::string_view name) {
    for (const char *r : {"CALL", "QSO_DATE", "TIME_ON", "MODE"})
        if (equalsNoCase(name, r)) return true;
    return false;
}

bool isStationField(std::string_view name) {
    for (const char *perQso : {"BAND", "BAND_RX", "FREQ", "FREQ_RX", "MODE", "SUBMODE"})
        if (equalsNoCase(name, perQso)) return false;
    return isCarriedField(name);
}

namespace {

// The last record with fields, as (upper-case name, value) in its order.
std::vector<std::pair<std::string, std::string>> lastRecordFields(std::string_view text, const DocModel &m) {
    std::vector<std::pair<std::string, std::string>> out;
    for (auto it = m.groups.rbegin(); it != m.groups.rend(); ++it) {
        if (it->header || !it->fieldCount) continue;
        for (size_t i = 0; i < it->fieldCount; ++i) {
            const ModelField &f = m.fields[it->firstField + i];
            out.emplace_back(upperAscii(fieldName(text, f)), std::string(fieldValue(text, f)));
        }
        break;
    }
    return out;
}

// Rows for `names` (upper case, no duplicates): carried values from the last
// record, the UTC date and time in the log's format, default reports.
std::vector<QsoField> fillTemplate(const std::vector<std::string> &names,
                                   const std::vector<std::pair<std::string, std::string>> &last, std::string_view utcDate,
                                   std::string_view utcTime) {
    bool shortTime = false;
    for (const auto &f : last)
        if (f.first == "TIME_ON") shortTime = f.second.size() == 4;
    std::vector<QsoField> out;
    for (const std::string &name : names) {
        bool carry = isCarriedField(name);
        std::string value;
        if (carry)
            for (const auto &f : last)
                if (f.first == name) {
                    value = f.second;
                    break;
                }
        out.push_back({name, value, carry});
    }
    std::string mode;
    for (const QsoField &q : out)
        if (q.name == "MODE") mode = q.value;
    for (QsoField &q : out) {
        if (q.name == "QSO_DATE") q.value = std::string(utcDate);
        else if (q.name == "TIME_ON") q.value = std::string(utcTime.substr(0, shortTime ? 4 : 6));
        else if (q.name == "RST_SENT" || q.name == "RST_RCVD") q.value = defaultReport(mode);
    }
    return out;
}

void addName(std::vector<std::string> &names, std::string name) {
    if (std::find(names.begin(), names.end(), name) == names.end()) names.push_back(std::move(name));
}

}  // namespace

std::vector<QsoField> newQsoTemplate(std::string_view text, const DocModel &m, std::string_view utcDate,
                                     std::string_view utcTime) {
    auto last = lastRecordFields(text, m);
    std::vector<std::string> names;
    for (const auto &f : last) addName(names, f.first);
    for (const char *c : {"CALL", "QSO_DATE", "TIME_ON", "BAND", "FREQ", "MODE", "SUBMODE", "RST_SENT", "RST_RCVD"})
        addName(names, c);
    return fillTemplate(names, last, utcDate, utcTime);
}

std::vector<QsoField> newQsoTemplateFor(std::string_view text, const DocModel &m, std::string_view utcDate,
                                        std::string_view utcTime, const std::vector<std::string> &fields) {
    std::vector<std::string> names;
    for (const std::string &f : fields)
        if (!f.empty()) addName(names, upperAscii(f));
    // Required fields the list lacks go first, in the usual order.
    std::vector<std::string> missing;
    for (const char *r : {"CALL", "QSO_DATE", "TIME_ON", "MODE"})
        if (std::find(names.begin(), names.end(), r) == names.end()) missing.push_back(r);
    if (std::find(names.begin(), names.end(), "BAND") == names.end() &&
        std::find(names.begin(), names.end(), "FREQ") == names.end())
        missing.push_back("BAND");
    names.insert(names.begin(), missing.begin(), missing.end());
    return fillTemplate(names, lastRecordFields(text, m), utcDate, utcTime);
}

std::vector<std::pair<std::string, std::string>> hiddenStationFields(std::string_view text, const DocModel &m,
                                                                     const std::vector<std::string> &shown) {
    std::vector<std::pair<std::string, std::string>> out;
    for (const auto &f : lastRecordFields(text, m)) {
        if (f.second.empty() || !isStationField(f.first)) continue;
        bool isShown = false;
        for (const std::string &s : shown) isShown |= equalsNoCase(s, f.first);
        if (!isShown) out.push_back(f);
    }
    return out;
}

Layout recordLayout(std::string_view text, const DocModel &m) {
    for (auto it = m.groups.rbegin(); it != m.groups.rend(); ++it) {
        if (it->header || it->fieldCount < 2) continue;
        for (size_t i = 0; i + 1 < it->fieldCount; ++i) {
            const ModelField &a = m.fields[it->firstField + i], &b = m.fields[it->firstField + i + 1];
            if (text.substr(a.valueE, b.tagB - a.valueE).find('\n') != std::string_view::npos) return Layout::FieldPerLine;
        }
        return Layout::RecordPerLine;
    }
    return Layout::RecordPerLine;
}

BuiltRecord buildRecord(const std::vector<std::pair<std::string, std::string>> &fields, Layout layout, std::string_view eol,
                        LengthUnit unit, bool utf8) {
    BuiltRecord r;
    const std::string sep = layout == Layout::FieldPerLine ? std::string(eol) : std::string(" ");
    for (const auto &f : fields) {
        if (f.second.empty()) {
            r.ranges.emplace_back(kNoPos, kNoPos);
            continue;
        }
        if (!r.text.empty()) r.text += sep;
        size_t b = r.text.size();
        r.text += makeSpecifier(f.first, f.second, unit, utf8);
        r.ranges.emplace_back(b, r.text.size());
    }
    if (!r.text.empty()) r.text += sep;
    r.text += "<EOR>";
    r.text += eol;
    return r;
}

TextEdit appendRecord(std::string_view text, const DocModel &m, std::string_view record, std::string_view eol,
                      size_t *recordStart) {
    // Line breaks already at the end of the document.
    size_t breaks = 0, i = text.size();
    while (i > 0 && (text[i - 1] == '\n' || text[i - 1] == '\r' || text[i - 1] == ' ' || text[i - 1] == '\t')) {
        if (text[i - 1] == '\n' || (text[i - 1] == '\r' && (i == text.size() || text[i] != '\n'))) ++breaks;
        --i;
    }
    size_t want = i == 0 ? 0 : (recordLayout(text, m) == Layout::FieldPerLine ? 2 : 1);
    std::string prefix;
    for (size_t k = breaks; k < want; ++k) prefix += eol;
    if (recordStart) *recordStart = text.size() + prefix.size();
    return TextEdit{text.size(), text.size(), prefix + std::string(record)};
}

std::string newLogHeader(std::string_view programVersion, std::string_view utcTimestamp, std::string_view eol) {
    std::string h = "ADIF log created with ADIF Lint";
    h += eol;
    h += makeSpecifier("ADIF_VER", kSpecVersion, LengthUnit::Bytes, false) + std::string(eol);
    h += makeSpecifier("PROGRAMID", "ADIF Lint", LengthUnit::Bytes, false) + std::string(eol);
    h += makeSpecifier("PROGRAMVERSION", programVersion, LengthUnit::Bytes, false) + std::string(eol);
    h += makeSpecifier("CREATED_TIMESTAMP", utcTimestamp, LengthUnit::Bytes, false) + std::string(eol);
    h += "<EOH>";
    h += eol;
    h += eol;
    return h;
}

}  // namespace adif
