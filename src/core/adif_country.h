// Country (DXCC entity) from a callsign's prefix, offline, using Jim Reisert
// AD1C's country files (cty.csv from Big CTY, www.country-files.com, MIT
// licence; format checked 2026-10-07 against bigcty-20260915): each line is
//   prefix,name,DXCC,continent,CQ,ITU,lat,lon(+W),UTC offset,aliases;
// aliases are space-separated prefixes, "=CALL" for an exact callsign, each
// optionally followed by (CQ) [ITU] <lat/lon> {continent} ~offset~ overrides.
// A leading '*' marks a WAE/CQ-only entity; its DXCC number is the ARRL entity.
#pragma once

#include "adif_enrich.h"

#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace adif {

struct CountryInfo {
    int dxcc = 0;           // ADIF DXCC entity code
    std::string name;       // AD1C's name ("United States")
    std::string continent;  // AF AN AS EU NA OC SA
    int cq = 0, itu = 0;
    double lat = 0, lon = 0;  // degrees, north and east positive
};

class CountryTable {
public:
    // Parse cty.csv; false (with the reason) when nothing usable was found.
    bool load(std::string_view ctyCsv, std::string *error = nullptr);
    bool empty() const { return entities_.empty(); }
    size_t entities() const { return entities_.size(); }
    // Every entity in the file, the WAE and CQ-only ones too (Sicily, Shetland... under their
    // ARRL entity's number), each with where the file puts it.
    const std::vector<CountryInfo> &all() const { return entities_; }
    // The entity for a callsign: an exact "=CALL" entry first, else the longest
    // matching prefix. In a portable call the location prefix decides
    // (VE3/K1ABC is Canada); /P, /M, /QRP... are ignored; /MM and /AM are no entity.
    bool lookup(std::string_view call, CountryInfo *out) const;

private:
    struct Alias {
        size_t entity = 0;
        int cq = -1, itu = -1;
        std::string continent;
        bool hasLatLon = false;
        double lat = 0, lon = 0;
    };
    bool resolve(const Alias &a, CountryInfo *out) const;
    std::vector<CountryInfo> entities_;
    std::unordered_map<std::string, Alias> exact_, prefix_;
    size_t longest_ = 0;
};

// ADIF fields for a contact with `call`: DXCC, COUNTRY (ADIF's own entity name,
// as LoTW uses), CQZ, ITUZ, CONT. Empty when the call matches no entity.
FieldMap countryFields(const CountryTable &table, std::string_view call);

}  // namespace adif
