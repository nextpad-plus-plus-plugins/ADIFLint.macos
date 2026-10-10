// Station profiles (named sets of your station's fields) and activations (Start
// Activation: a program's references, a profile, a new log; Finish: Check Log and
// the export). New QSO asks this module which station fields to write.
#pragma once

#import <Cocoa/Cocoa.h>

#include "adif_profiles.h"

#include <string>
#include <vector>

namespace station {

std::vector<adif::StationProfile> profiles();  // from ADIFLint-profiles.adi in the config folder
void cmdStationProfiles();                     // the editor
void cmdStartActivation();                     // the Start Activation window

// New QSO's Station popup: 0 the log's own fields, 1... the profiles.
NSInteger chosenProfile();
void chooseProfile(NSInteger index);

// The fields New QSO writes for your station: the chosen profile, then the running
// activation's (MY_SIG, MY_POTA_REF...). Empty when the log's own carry over.
adif::FieldList stationFields();
std::string stationLabel();  // "profile Portable, activating US-7929" or ""

// The running activation's progress in this log: "US-7929 today: 8 of 10", or "".
std::string activationProgress(std::string_view text, const adif::DocModel &m);

}  // namespace station
