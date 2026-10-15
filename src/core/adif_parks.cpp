#include "adif_parks.h"

#include "adif_formats.h"
#include "adif_lint.h"
#include "adif_tools.h"

#include <algorithm>
#include <cmath>

namespace adif {
namespace {

std::string trimmed(std::string_view s) {
    size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
    return b == std::string_view::npos ? std::string() : std::string(s.substr(b, e - b + 1));
}

std::string upper(std::string s) {
    for (char &c : s)
        if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    return s;
}

}  // namespace

std::string potaListRef(std::string_view ref) {
    std::string v = upper(trimmed(ref));
    if (!isPotaRef(v)) return "";
    return v.substr(0, v.find('@'));
}

size_t PotaParks::load(std::string_view csv) {
    parks_.clear(), active_ = 0;
    std::vector<std::vector<std::string>> rows = parseCsv(csv);
    if (rows.empty()) return 0;
    const char *const kColumns[] = {"reference", "name", "active", "entityId", "locationDesc", "latitude", "longitude"};
    size_t col[7];
    for (size_t k = 0; k < 7; ++k) {
        auto it = std::find_if(rows[0].begin(), rows[0].end(), [&](const std::string &h) { return trimmed(h) == kColumns[k]; });
        if (it == rows[0].end()) return 0;
        col[k] = (size_t)(it - rows[0].begin());
    }
    size_t need = *std::max_element(std::begin(col), std::end(col));
    for (size_t i = 1; i < rows.size(); ++i) {
        const std::vector<std::string> &r = rows[i];
        if (r.size() <= need) continue;
        PotaPark p;
        p.ref = upper(trimmed(r[col[0]]));
        if (!isPotaRef(p.ref) || p.ref.find('@') != std::string::npos) continue;
        p.name = trimmed(r[col[1]]);
        p.active = trimmed(r[col[2]]) != "0";
        double n = 0;
        if (parseAdifNumber(trimmed(r[col[3]]), &n) && n >= 0 && n < 10000) p.entity = (int)n;
        p.location = upper(trimmed(r[col[4]]));
        double lat = 0, lon = 0;
        if (parseAdifNumber(trimmed(r[col[5]]), &lat) && parseAdifNumber(trimmed(r[col[6]]), &lon) && std::fabs(lat) <= 90 &&
            std::fabs(lon) <= 180 && (lat != 0 || lon != 0))
            p.lat = lat, p.lon = lon, p.placed = true;
        parks_.push_back(std::move(p));
    }
    std::stable_sort(parks_.begin(), parks_.end(), [](const PotaPark &a, const PotaPark &b) { return a.ref < b.ref; });
    // One row per reference: a repeat (never seen in the list) keeps the first.
    parks_.erase(std::unique(parks_.begin(), parks_.end(), [](const PotaPark &a, const PotaPark &b) { return a.ref == b.ref; }), parks_.end());
    active_ = (size_t)std::count_if(parks_.begin(), parks_.end(), [](const PotaPark &p) { return p.active; });
    return parks_.size();
}

const PotaPark *PotaParks::find(std::string_view ref) const {
    std::string key = potaListRef(ref);
    if (key.empty()) return nullptr;
    auto look = [&](const std::string &k) -> const PotaPark * {
        auto it = std::lower_bound(parks_.begin(), parks_.end(), k, [](const PotaPark &p, const std::string &x) { return p.ref < x; });
        return it != parks_.end() && it->ref == k ? &*it : nullptr;
    };
    if (const PotaPark *p = look(key)) return p;
    // Programs POTA renamed in 2024 to ISO codes, keeping the parks' numbers
    // (docs.pota.app/docs/changes: united-states, modified 2024-03-20; great-britain, 2024-03-24;
    // 2024-03-14; read 2026-10-14). Only these: the US territories and GI, GM and GW were
    // renumbered, and an old Canadian VE- is now Venezuela's prefix.
    static const char *const kRenamed[][2] = {{"K", "US"}, {"G", "GB"}, {"OA", "PE"}, {"TG", "GT"}, {"T7", "SM"}, {"TA", "TR"}};
    std::string program = key.substr(0, key.find('-')), number = key.substr(key.find('-'));
    for (const auto &r : kRenamed)
        if (program == r[0]) return look(r[1] + number);
    return nullptr;
}

}  // namespace adif
