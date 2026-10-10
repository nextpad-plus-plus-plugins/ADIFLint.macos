#include "adif_qsl.h"

#include "adif_edit.h"
#include "adif_enrich.h"
#include "adif_spec.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>

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

std::string xmlText(std::string_view s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] != '&') {
            out.push_back(s[i]);
            continue;
        }
        size_t semi = s.find(';', i);
        if (semi == std::string_view::npos || semi - i > 10) {
            out.push_back('&');
            continue;
        }
        std::string_view ent = s.substr(i + 1, semi - i - 1);
        long code = -1;
        if (ent == "amp") code = '&';
        else if (ent == "lt") code = '<';
        else if (ent == "gt") code = '>';
        else if (ent == "quot") code = '"';
        else if (ent == "apos") code = '\'';
        else if (ent.size() > 1 && ent[0] == '#')
            code = ent[1] == 'x' ? std::strtol(std::string(ent.substr(2)).c_str(), nullptr, 16)
                                 : std::strtol(std::string(ent.substr(1)).c_str(), nullptr, 10);
        if (code <= 0 || code > 0x10FFFF) {
            out.push_back('&');
            continue;
        }
        if (code < 0x80) out.push_back((char)code);
        else if (code < 0x800) out += {(char)(0xC0 | (code >> 6)), (char)(0x80 | (code & 0x3F))};
        else if (code < 0x10000)
            out += {(char)(0xE0 | (code >> 12)), (char)(0x80 | ((code >> 6) & 0x3F)), (char)(0x80 | (code & 0x3F))};
        else
            out += {(char)(0xF0 | (code >> 18)), (char)(0x80 | ((code >> 12) & 0x3F)), (char)(0x80 | ((code >> 6) & 0x3F)),
                    (char)(0x80 | (code & 0x3F))};
        i = semi;
    }
    return out;
}

// name="value" (or 'value') in a start tag's text.
std::string attribute(std::string_view tag, std::string_view name) {
    size_t at = 0;
    while ((at = tag.find(name, at)) != std::string_view::npos) {
        bool start = at > 0 && (tag[at - 1] == ' ' || tag[at - 1] == '\t' || tag[at - 1] == '\n' || tag[at - 1] == '\r');
        size_t eq = tag.find_first_not_of(" \t\r\n", at + name.size());
        if (start && eq != std::string_view::npos && tag[eq] == '=') {
            size_t q = tag.find_first_not_of(" \t\r\n", eq + 1);
            if (q != std::string_view::npos && (tag[q] == '"' || tag[q] == '\'')) {
                size_t e = tag.find(tag[q], q + 1);
                if (e != std::string_view::npos) return xmlText(tag.substr(q + 1, e - q - 1));
            }
        }
        at += name.size();
    }
    return {};
}

// A number as TQSL compares zones: "05" is 5; anything else as it is.
std::string zone(const std::string &v) {
    char *end = nullptr;
    long n = std::strtol(v.c_str(), &end, 10);
    return !v.empty() && end && *end == '\0' ? std::to_string(n) : upper(v);
}

std::string sortedList(const std::string &grids) {
    std::vector<std::string> parts;
    size_t b = 0;
    while (b <= grids.size()) {
        size_t e = grids.find(',', b);
        if (e == std::string::npos) e = grids.size();
        parts.push_back(upper(trimmed(grids.substr(b, e - b))));
        b = e + 1;
    }
    std::sort(parts.begin(), parts.end());
    std::string out;
    for (const std::string &p : parts) out += p + ",";
    return out;
}

std::string mismatch(const char *field, const std::string &mine, const std::string &theirs) {
    return std::string(field) + " " + mine + " (the location: " + theirs + ")";
}

}  // namespace

std::string TqslLocation::get(std::string_view field) const {
    for (const auto &[n, v] : fields)
        if (n == field) return v;
    return {};
}

std::vector<TqslLocation> parseStationData(std::string_view xml) {
    std::vector<TqslLocation> out;
    size_t at = 0;
    while ((at = xml.find("<StationData", at)) != std::string_view::npos) {
        size_t gt = xml.find('>', at);
        if (gt == std::string_view::npos) break;
        char after = xml[at + 12];
        if (after != ' ' && after != '\t' && after != '\n' && after != '\r' && after != '>' && after != '/') {
            at += 12;  // <StationDataFile>
            continue;
        }
        TqslLocation loc;
        loc.name = attribute(xml.substr(at + 12, gt - at - 12), "name");
        bool empty = xml[gt - 1] == '/';
        size_t end = empty ? gt : xml.find("</StationData>", gt);
        if (end == std::string_view::npos) end = xml.size();
        for (size_t p = gt + 1; p < end;) {
            size_t lt = xml.find('<', p);
            if (lt == std::string_view::npos || lt >= end) break;
            size_t close = xml.find('>', lt);
            if (close == std::string_view::npos || close > end) break;
            std::string_view tag = xml.substr(lt + 1, close - lt - 1);
            if (tag.empty() || tag[0] == '/' || tag[0] == '!' || tag[0] == '?') {
                p = close + 1;
                continue;
            }
            size_t nameEnd = tag.find_first_of(" \t\r\n/");
            std::string name(tag.substr(0, nameEnd));
            if (tag.back() == '/') {  // <IOTA/>
                loc.fields.emplace_back(name, "");
                p = close + 1;
                continue;
            }
            std::string endTag = "</" + name + ">";
            size_t e = xml.find(endTag, close + 1);
            if (e == std::string_view::npos || e > end) break;
            loc.fields.emplace_back(name, trimmed(xmlText(xml.substr(close + 1, e - close - 1))));
            p = e + endTag.size();
        }
        if (!loc.name.empty()) out.push_back(std::move(loc));
        at = empty ? gt + 1 : end;
    }
    return out;
}

std::string lotwLocationProblem(const Record &qso, const TqslLocation &loc) {
    auto mine = [&](const char *f) { return trimmed(qso.get(f)); };
    // The call: STATION_CALLSIGN, else OPERATOR, against the certificate's.
    std::string call = upper(mine("STATION_CALLSIGN")), callField = "STATION_CALLSIGN";
    if (call.empty()) call = upper(mine("OPERATOR")), callField = "OPERATOR";
    std::string locCall = upper(trimmed(loc.get("CALL")));
    if (!call.empty() && !locCall.empty() && locCall != "NONE" && call != locCall) return mismatch(callField.c_str(), call, locCall);
    int dxcc = std::atoi(loc.get("DXCC").c_str()), myDxcc = std::atoi(mine("MY_DXCC").c_str());
    if (dxcc && myDxcc && dxcc != myDxcc) return mismatch("MY_DXCC", std::to_string(myDxcc), std::to_string(dxcc));
    std::string grid = mine("MY_GRIDSQUARE"), locGrid = trimmed(loc.get("GRIDSQUARE"));
    if (!grid.empty() && !locGrid.empty()) {
        bool same;
        if (grid.find(',') != std::string::npos || locGrid.find(',') != std::string::npos) {
            same = sortedList(grid) == sortedList(locGrid);
        } else {
            size_t n = locGrid.size() > 4 && grid.size() == 4 ? 4 : std::string::npos;
            same = equalsNoCase(grid.substr(0, n), locGrid.substr(0, n));
        }
        if (!same) return mismatch("MY_GRIDSQUARE", grid, locGrid);
    }
    // MY_STATE and MY_CNTY, against the entity's own fields.
    const char *stateField = nullptr, *countyField = nullptr;
    switch (dxcc) {
        case 291: case 6: case 110: stateField = "US_STATE", countyField = "US_COUNTY"; break;
        case 1: stateField = "CA_PROVINCE"; break;
        case 15: case 54: case 61: case 125: case 151: stateField = "RU_OBLAST"; break;
        case 318: stateField = "CN_PROVINCE"; break;
        case 150: stateField = "AU_STATE"; break;
        case 339: stateField = "JA_PREFECTURE", countyField = "JA_CITY_GUN_KU"; break;
        case 224: case 5: stateField = "FI_KUNTA"; break;
        default: break;
    }
    if (stateField) {
        std::string state = upper(mine("MY_STATE")), locState = upper(trimmed(loc.get(stateField)));
        if (dxcc == 1 && state == "QC") state = "PQ";  // TQSL's own codes for these
        if (dxcc == 1 && state == "NL") state = "NF";
        if (std::strcmp(stateField, "RU_OBLAST") == 0 && state == "YR") state = "JA";
        if (std::strcmp(stateField, "RU_OBLAST") == 0 && state == "YN") state = "JN";
        if (!state.empty() && !locState.empty() && state != locState) return mismatch("MY_STATE", mine("MY_STATE"), loc.get(stateField));
    }
    if (countyField) {
        std::string county = mine("MY_CNTY");
        size_t comma = county.find(',');
        if (comma != std::string::npos) county = trimmed(county.substr(comma + 1));
        std::string locCounty = trimmed(loc.get(countyField));
        if (!county.empty() && !locCounty.empty() && !equalsNoCase(county, locCounty))
            return mismatch("MY_CNTY", mine("MY_CNTY"), locCounty);
    }
    std::string itu = mine("MY_ITU_ZONE"), locItu = trimmed(loc.get("ITUZ"));
    if (!itu.empty() && !locItu.empty() && zone(itu) != zone(locItu)) return mismatch("MY_ITU_ZONE", itu, locItu);
    std::string cq = mine("MY_CQ_ZONE"), locCq = trimmed(loc.get("CQZ"));
    if (!cq.empty() && !locCq.empty() && zone(cq) != zone(locCq)) return mismatch("MY_CQ_ZONE", cq, locCq);
    return "";
}

size_t LotwUsers::load(std::string_view csv) {
    calls_.clear();
    size_t at = 0;
    while (at < csv.size()) {
        size_t end = csv.find('\n', at);
        if (end == std::string_view::npos) end = csv.size();
        std::string_view line = csv.substr(at, end - at);
        at = end + 1;
        size_t c1 = line.find(',');
        if (c1 == std::string_view::npos || c1 == 0 || c1 > 20) continue;
        std::string date = trimmed(line.substr(c1 + 1, 10));
        if (date.size() != 10 || date[4] != '-' || date[7] != '-') continue;
        calls_.emplace_back(upper(trimmed(line.substr(0, c1))), date);
    }
    std::sort(calls_.begin(), calls_.end());
    // A call listed twice keeps its latest upload: after sorting, the last of a run.
    std::vector<std::pair<std::string, std::string>> kept;
    for (auto &c : calls_) {
        if (!kept.empty() && kept.back().first == c.first) kept.back().second = std::max(kept.back().second, c.second);
        else kept.push_back(std::move(c));
    }
    calls_ = std::move(kept);
    return calls_.size();
}

std::string LotwUsers::lastUpload(std::string_view call) const {
    auto find = [&](const std::string &c) -> std::string {
        auto it = std::lower_bound(calls_.begin(), calls_.end(), c, [](const auto &e, const std::string &k) { return e.first < k; });
        return it != calls_.end() && it->first == c ? it->second : std::string();
    };
    std::string c = upper(trimmed(call));
    if (c.empty()) return "";
    std::string d = find(c);
    if (d.empty()) {
        std::string base = lookupCall(c);
        if (base != c) d = find(base);
    }
    return d;
}

ServiceSummary serviceSummary(std::string_view text, const DocModel &m, UploadService s) {
    ServiceSummary out;
    UploadFields f = uploadFields(s);
    for (const UploadItem &i : uploadItems(text, m, s)) {
        if (uploadWanted(i)) {
            ++out.toUpload;
            out.modified += equalsNoCase(i.status, "M");
        }
        out.uploaded += i.done;
        out.notToSend += i.skip;
        out.problems += !i.problem.empty() && !i.done && !i.skip;
    }
    for (const Record &r : records(text, m)) {
        std::string d = trimmed(r.get(f.date));
        if (d.size() == 8 && d > out.lastUpload) out.lastUpload = d;
        switch (s) {
            case UploadService::LoTW: {
                std::string v = trimmed(r.get("LOTW_QSL_RCVD"));
                out.confirmed += equalsNoCase(v, "Y") || equalsNoCase(v, "V");
                break;
            }
            case UploadService::EQSL: {
                std::string v = trimmed(r.get("EQSL_QSL_RCVD"));
                out.confirmed += equalsNoCase(v, "Y") || equalsNoCase(v, "V");
                break;
            }
            case UploadService::QRZ: out.confirmed += equalsNoCase(trimmed(r.get("APP_QRZLOG_STATUS")), "C"); break;
            case UploadService::ClubLog: break;
        }
    }
    return out;
}

}  // namespace adif
