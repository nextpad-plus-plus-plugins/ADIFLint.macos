// Contests and Field Days in New QSO: the exchange each asks for, the fields
// written with every QSO, the next serial number and the duplicate rule.
//
// ARRL Field Day (www.arrl.org/field-day-rules, revised 2026-03-01): the
// exchange is the operating class and the ARRL/RAC section (DX stations send
// their class and "DX"); a station can be worked once per band per mode, the
// modes being Phone, CW and Digital.
// Winter Field Day (winterfieldday.org 2025 rules): the exchange is a category
// number, a class letter (H home, I indoor, O outdoor, M mobile) and a location
// (the ARRL/RAC section, MX for Mexico, DX elsewhere), such as 2O IL; a station
// can be worked once per band per mode (CW, Phone, Digital); FT4 and FT8 don't
// count as Digital.
// ADIF 3.1.7: CONTEST_ID ARRL-FIELD-DAY and WFD; CLASS "contest class (e.g. for
// ARRL Field Day)"; ARRL_SECT and MY_ARRL_SECT from the ARRL_Section
// enumeration; STX/SRX serial numbers; STX_STRING/SRX_STRING the exchange sent
// and received.
#pragma once

#include "adif_lint.h"
#include "adif_tools.h"

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

enum class ContestPreset { None, FieldDay, WinterFieldDay, Serial };

struct ContestSetup {
    ContestPreset preset = ContestPreset::None;
    std::string sent;       // Field Days: your exchange ("1D IL", "2O IL")
    std::string contestId;  // Serial: the CONTEST_ID to write (may be empty)
};

const char *contestPresetName(ContestPreset p);  // "ARRL Field Day", "Winter Field Day", "Serial numbers", ""

// The rows New QSO asks for the other station's exchange: CLASS and ARRL_SECT for
// the Field Days, SRX for serial numbers.
std::vector<std::string> contestRows(ContestPreset p);

// The CONTEST_ID written: ARRL-FIELD-DAY, WFD, or the one set for serials.
std::string contestIdFor(const ContestSetup &s);

// What's wrong with your exchange for this preset ("" when fine).
std::string sentProblem(const ContestSetup &s);
// What's wrong with a received class or section ("" when fine; either may be empty).
std::string classProblem(ContestPreset p, std::string_view cls);
std::string sectionProblem(ContestPreset p, std::string_view section);

// The fields written with each QSO besides the ones New QSO shows: CONTEST_ID,
// STX_STRING and MY_ARRL_SECT from your exchange, SRX_STRING from the received
// CLASS and ARRL_SECT, STX (`serial`, when > 0). `qso` holds the shown fields;
// ARRL_SECT that isn't an ARRL section (DX, MX) is left out of the record and kept
// in SRX_STRING.
std::vector<std::pair<std::string, std::string>> contestFields(const ContestSetup &s,
                                                               const std::vector<std::pair<std::string, std::string>> &qso,
                                                               int serial);

// 1 + the highest STX among records with this CONTEST_ID (any, when empty).
int nextSerial(std::string_view text, const DocModel &m, std::string_view contestId);

// The mode as the Field Days count it: "CW", "PH" (SSB, AM, FM, DIGITALVOICE) or "DG".
std::string modeCategory(std::string_view mode);

// Records (numbers) that are the same contact under a Field Day's rule: the same
// call, band and mode category, with the same CONTEST_ID.
std::vector<int> contestDupes(std::string_view text, const DocModel &m, std::string_view contestId, const Record &qso);

}  // namespace adif
