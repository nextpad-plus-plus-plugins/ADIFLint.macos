#include "adif_labels.h"

#include "adif_edit.h"
#include "adif_spec.h"

#include <algorithm>
#include <map>

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

constexpr double kInch = 72, kMm = 72 / 25.4;

}  // namespace

std::vector<int> qslWanted(std::string_view text, const DocModel &m) {
    std::vector<int> out;
    for (const Record &r : records(text, m)) {
        std::string s = upper(trimmed(r.get("QSL_SENT")));
        if (s == "R" || s == "Q") out.push_back(r.group);
    }
    return out;
}

std::vector<QslLabel> qslLabels(std::string_view text, const DocModel &m, const std::vector<int> &groups, size_t perLabel) {
    if (perLabel == 0) perLabel = 1;
    std::map<int, const Record *> byGroup;
    std::vector<Record> recs = records(text, m);
    for (const Record &r : recs) byGroup[r.group] = &r;
    std::vector<std::pair<std::string, std::string>> order;  // (call, via) in first-seen order
    std::map<std::pair<std::string, std::string>, std::vector<const Record *>> qsos;
    for (int g : groups) {
        auto it = byGroup.find(g);
        if (it == byGroup.end()) continue;
        const Record &r = *it->second;
        std::string call = upper(trimmed(r.get("CALL")));
        if (call.empty()) continue;
        std::pair<std::string, std::string> key{call, upper(trimmed(r.get("QSL_VIA")))};
        if (!qsos.count(key)) order.push_back(key);
        qsos[key].push_back(&r);
    }
    std::vector<QslLabel> out;
    for (const auto &key : order) {
        std::vector<const Record *> list = qsos[key];
        std::stable_sort(list.begin(), list.end(), [](const Record *a, const Record *b) {
            return std::make_pair(a->get("QSO_DATE"), a->get("TIME_ON")) < std::make_pair(b->get("QSO_DATE"), b->get("TIME_ON"));
        });
        for (size_t i = 0; i < list.size(); i += perLabel) {
            QslLabel l;
            l.call = key.first;
            l.via = key.second;
            for (size_t k = i; k < list.size() && k < i + perLabel; ++k) {
                const Record &r = *list[k];
                LabelQso q;
                q.group = r.group;
                q.date = displayDate(trimmed(r.get("QSO_DATE")));
                q.time = trimmed(r.get("TIME_ON")).substr(0, 4);
                q.band = effectiveBand(r);
                std::string sub = trimmed(r.get("SUBMODE"));
                q.mode = sub.empty() ? trimmed(r.get("MODE")) : sub;
                q.rst = trimmed(r.get("RST_SENT"));
                l.qsos.push_back(std::move(q));
            }
            out.push_back(std::move(l));
        }
    }
    return out;
}

std::vector<std::string> labelLines(const QslLabel &label, std::string_view myCall, std::string_view closing) {
    std::vector<std::string> out;
    out.push_back("To: " + label.call + (label.via.empty() ? "" : " via " + label.via));
    for (const LabelQso &q : label.qsos)
        out.push_back(q.date + " " + q.time + "Z " + q.band + " " + q.mode + (q.rst.empty() ? "" : " " + q.rst));
    std::string close = trimmed(closing), me = upper(trimmed(myCall));
    if (!close.empty() || !me.empty()) out.push_back(close + (close.empty() || me.empty() ? "" : " de ") + me);
    return out;
}

const std::vector<LabelSheet> &labelSheets() {
    static const std::vector<LabelSheet> kSheets = {
        {"Avery 5160 (30 per sheet, Letter)", 8.5 * kInch, 11 * kInch, 3, 10, 2.625 * kInch, 1 * kInch, 0.5 * kInch, 0.1875 * kInch,
         2.75 * kInch, 1 * kInch, 3},
        {"Avery 5163 (10 per sheet, Letter)", 8.5 * kInch, 11 * kInch, 2, 5, 4 * kInch, 2 * kInch, 0.5 * kInch, 0.15625 * kInch,
         4.1875 * kInch, 2 * kInch, 8},
        {"Avery L7163 (14 per sheet, A4)", 210 * kMm, 297 * kMm, 2, 7, 99.1 * kMm, 38.1 * kMm, 15.15 * kMm, 4.65 * kMm, 101.6 * kMm,
         38.1 * kMm, 5},
    };
    return kSheets;
}

void labelPosition(const LabelSheet &s, size_t index, double *x, double *y) {
    size_t perPage = (size_t)std::max(1, s.columns * s.rows);
    size_t onPage = index % perPage;
    *x = s.left + (double)(onPage % (size_t)std::max(1, s.columns)) * s.across;
    *y = s.top + (double)(onPage / (size_t)std::max(1, s.columns)) * s.down;
}

std::vector<CellChange> qslSentChanges(const std::vector<int> &groups, std::string_view today) {
    std::vector<CellChange> out;
    for (int g : groups) {
        out.push_back({g, "QSL_SENT", "Y"});
        out.push_back({g, "QSLSDATE", std::string(today)});
    }
    return out;
}

}  // namespace adif
