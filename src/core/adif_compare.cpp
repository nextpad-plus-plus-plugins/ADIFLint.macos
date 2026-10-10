#include "adif_compare.h"

#include "adif_enrich.h"
#include "adif_spec.h"

#include <algorithm>
#include <cstdlib>
#include <map>
#include <set>

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

// The same value, as two logs might write it differently.
bool sameValue(const std::string &field, const std::string &a, const std::string &b) {
    std::string x = trimmed(a), y = trimmed(b);
    if (equalsNoCase(x, y)) return true;
    if (field == "TIME_ON" || field == "TIME_OFF") {
        if (x.size() == 4) x += "00";
        if (y.size() == 4) y += "00";
        return x == y;
    }
    const FieldDef *spec = findField(field);
    if (spec && spec->type == DataType::Number) {
        double p = 0, q = 0;
        return parseAdifNumber(x, &p) && parseAdifNumber(y, &q) && std::abs(p - q) < 1e-9;
    }
    return false;
}

long minutesOf(const Record &r) { return qsoMinutes(trimmed(r.get("QSO_DATE")), trimmed(r.get("TIME_ON"))); }

}  // namespace

std::vector<CompareRow> compareLogs(std::string_view here, const DocModel &hereModel, std::string_view there,
                                    const DocModel &thereModel, const DupeOptions &opt) {
    std::vector<Record> a = records(here, hereModel), b = records(there, thereModel);
    std::map<std::string, std::vector<size_t>> byCall;  // the other log's records by CALL
    for (size_t j = 0; j < b.size(); ++j)
        if (!trimmed(b[j].get("CALL")).empty()) byCall[upper(trimmed(b[j].get("CALL")))].push_back(j);
    struct Candidate {
        size_t i, j;
        long diff;
    };
    std::vector<Candidate> candidates;
    for (size_t i = 0; i < a.size(); ++i) {
        auto it = byCall.find(upper(trimmed(a[i].get("CALL"))));
        if (it == byCall.end()) continue;
        long am = minutesOf(a[i]);
        for (size_t j : it->second) {
            if (!sameQso(a[i], b[j], opt)) continue;
            long bm = minutesOf(b[j]);
            candidates.push_back({i, j, am < 0 || bm < 0 ? 0 : std::labs(am - bm)});
        }
    }
    std::stable_sort(candidates.begin(), candidates.end(), [](const Candidate &x, const Candidate &y) { return x.diff < y.diff; });
    std::vector<long> partner(a.size(), -1);
    std::vector<bool> taken(b.size(), false);
    for (const Candidate &c : candidates) {
        if (partner[c.i] >= 0 || taken[c.j]) continue;
        partner[c.i] = (long)c.j;
        taken[c.j] = true;
    }
    std::vector<CompareRow> out;
    for (size_t i = 0; i < a.size(); ++i) {
        if (a[i].fields.empty()) continue;
        CompareRow row;
        row.here = a[i].group;
        if (partner[i] < 0) {
            row.kind = CompareKind::OnlyHere;
            out.push_back(std::move(row));
            continue;
        }
        const Record &other = b[(size_t)partner[i]];
        row.there = other.group;
        std::vector<std::string> names;
        for (const auto &f : a[i].fields)
            if (std::find(names.begin(), names.end(), f.first) == names.end()) names.push_back(f.first);
        for (const auto &f : other.fields)
            if (std::find(names.begin(), names.end(), f.first) == names.end()) names.push_back(f.first);
        for (const std::string &n : names) {
            std::string x = trimmed(a[i].get(n)), y = trimmed(other.get(n));
            if (!sameValue(n, x, y)) row.diffs.push_back({n, x, y});
        }
        row.kind = row.diffs.empty() ? CompareKind::Same : CompareKind::Differ;
        out.push_back(std::move(row));
    }
    for (size_t j = 0; j < b.size(); ++j) {
        if (taken[j] || b[j].fields.empty()) continue;
        CompareRow row;
        row.kind = CompareKind::OnlyThere;
        row.there = b[j].group;
        out.push_back(std::move(row));
    }
    return out;
}

std::vector<CellChange> copyChanges(const CompareRow &row, bool replace) {
    std::vector<CellChange> out;
    if (row.kind != CompareKind::Differ || row.here < 0) return out;
    for (const FieldDiff &d : row.diffs)
        if (!d.there.empty() && (d.here.empty() || replace)) out.push_back({row.here, d.field, d.there});
    return out;
}

}  // namespace adif
