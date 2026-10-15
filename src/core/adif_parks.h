// POTA's park list, for the Map's POTA overlay: every park's name and place. From
// https://pota.app/all_parks_ext.csv (read 2026-10-14: 96,625 parks in 239 programs, 92,313
// active, rebuilt daily), whose columns are reference, name, active, entityId, locationDesc,
// latitude, longitude and grid. No POTA terms cover the file; like other loggers, ADIF Lint
// downloads it when the user asks (Settings -> POTA Parks) and never ships it.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace adif {

struct PotaPark {
    std::string ref, name;  // "US-1234", the park's name (UTF-8)
    std::string location;   // "US-CO", or several for a park across them ("US-DC,US-MD,US-WV")
    int entity = 0;         // its DXCC entity
    double lat = 0, lon = 0;
    bool active = true;
    bool placed = false;  // lat and lon say where it is (the list has none for some parks, or 0, 0)
};

class PotaParks {
public:
    // Replaces what was loaded with the list's parks; 0 when the text isn't the list (its
    // header names the columns above, in any order). Rows whose reference isn't one are skipped.
    size_t load(std::string_view csv);
    const std::vector<PotaPark> &parks() const { return parks_; }  // by reference
    size_t size() const { return parks_.size(); }
    size_t active() const { return active_; }
    // The park a log names: "us-1234@US-WI" is US-1234. A reference from before POTA's 2024
    // renaming of programs that kept their numbers (K- to US-, G- to GB-...) is found under its
    // new name. nullptr when not listed.
    const PotaPark *find(std::string_view ref) const;
    size_t indexOf(const PotaPark *p) const { return p ? (size_t)(p - parks_.data()) : (size_t)-1; }

private:
    std::vector<PotaPark> parks_;
    size_t active_ = 0;
};

// A park reference as the list writes it, from how a log writes one: upper case, without its
// "@location" (ADIF POTARef: program-number[@ISO 3166-2]). "" when it isn't one.
std::string potaListRef(std::string_view ref);

}  // namespace adif
