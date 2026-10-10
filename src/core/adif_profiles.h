// Station profiles and activations.
//
// A profile is a named set of the logging station's own fields (STATION_CALLSIGN,
// OPERATOR, MY_GRIDSQUARE, MY_STATE, MY_RIG, TX_PWR...), kept as ADIF records in
// the plugin's config folder, one record per profile, named by APP_ADIFLINT_PROFILE.
// An activation adds the program's own fields (MY_SIG, MY_POTA_REF...) for one or
// more references.
#pragma once

#include "adif_tools.h"

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

using FieldList = std::vector<std::pair<std::string, std::string>>;

struct StationProfile {
    std::string name;
    FieldList fields;          // upper-case names, in the order given
    std::string tqslLocation;  // the TQSL Station Location its LoTW uploads use, or empty
    std::string get(std::string_view field) const;
    void set(std::string_view field, std::string value);  // an empty value removes the field
};

// Profiles from the profiles file (ADIF records with APP_ADIFLINT_PROFILE); records
// without a name are skipped.
std::vector<StationProfile> parseProfiles(std::string_view text);
// The profiles file: a header, then one record per profile.
std::string profilesText(const std::vector<StationProfile> &profiles, std::string_view programVersion,
                         std::string_view utcTimestamp);

// References typed for an activation ("us-7929, US-1234"): upper case, de-duplicated.
// *bad gets the ones that aren't references of the program. WWFF and SOTA allow one
// reference (MY_WWFF_REF and MY_SOTA_REF hold one each); POTA several (a two-fer).
std::vector<std::string> parseReferences(Program p, std::string_view typed, std::vector<std::string> *bad, std::string *why);

// The fields an activation writes in every record: POTA MY_SIG POTA, MY_SIG_INFO and
// MY_POTA_REF (the parks, comma separated); WWFF MY_SIG WWFF, MY_SIG_INFO, MY_WWFF_REF;
// SOTA MY_SOTA_REF.
FieldList activationFields(Program p, const std::vector<std::string> &refs);

// The working log's file name, as each program names a log: POTA call@park-YYYYMMDD.adi
// (parks joined by '+'), WWFF "call @ ref YYYYMMDD.adi", SOTA call_summit_YYYYMMDD.adi;
// '/' in the call becomes '-' (and in a summit too).
std::string activationFileName(Program p, std::string_view call, const std::vector<std::string> &refs, std::string_view date);

// `base` with `over` laid on top: a field in both takes over's value; over's other
// fields follow base's in their order.
FieldList overlay(const FieldList &base, const FieldList &over);

}  // namespace adif
