// SOTA and WWFF beside POTA: activations, export files and spots for each
// program, and hunting history (has this park, reference or summit been worked?).
//
// Rules (checked 2026-10-07):
//   POTA: see adif_tools.h.
//   WWFF Global Rules v5.10 (2025-09-03, wwff.co): 44 QSOs for an activation
//     to count towards activator awards (4.6), accrued over any number of
//     activations (4.7); the same call on another band, mode or date is a
//     separate QSO (4.6). Logs are named "callsign@xxFF-xxxx YYYYMMDD" (WWFF
//     LogSearch upload tutorial v1.3, April 2025).
//   SOTA: one QSO activates a summit; four QSOs with different stations score
//     its points. This comes from SOTA guides: sota.org.uk's rules pages could
//     not be read (they need a browser), so check them. SOTA has no file-name
//     rule. The SOTA API is not used: its terms forbid AI-written software
//     without prior approval.
#pragma once

#include "adif_tools.h"

#include <string>
#include <string_view>
#include <vector>

namespace adif {

// POTA: activations(); WWFF: one per station and reference over all dates,
// needing 44; SOTA: one per station, summit and UTC date, counting different
// stations, needing 4 for the summit's points.
std::vector<Activation> programActivations(std::string_view text, const DocModel &m, Program p,
                                           std::string_view defaultStation = {});

// Upload files. POTA: potaExport(). WWFF: one per station, reference and run of
// consecutive UTC days, named for the first, "KW9D @ KFF-1234 20261006.adi" ('/' in
// the call becomes '-'), MY_WWFF_REF set. SOTA: one per station,
// summit and date, "KW9D_W7A-AE-001_20261006.adi" ('/' becomes '-'), MY_SOTA_REF set.
std::vector<PotaFile> programExport(Program p, std::string_view text, const DocModel &m, std::string_view defaultStation,
                                    std::string_view programVersion, std::string_view utcTimestamp, std::string_view eol,
                                    LengthUnit unit, bool utf8, std::string_view todayUtc);

// A spot as New QSO fields: as spotFields(), with SIG and SIG_INFO for the
// program and WWFF_REF or SOTA_REF (POTA: spotFields() itself).
std::vector<std::pair<std::string, std::string>> programSpotFields(Program p, std::string_view activator, std::string_view kHz,
                                                                   std::string_view mode, std::string_view reference);

// ZLOTA (New Zealand On The Air, ontheair.nz): references are ZLP/ (park), ZLH/
// (hut), ZLI/ (island), ZLL/ (lake), ZLV/ (volcano) or ZLB/ (lighthouse), then a
// two-letter area and a number, such as ZLH/HB-072 (its api/assettypes and
// api/assets, read 2026-10-10). Logged as SIG ZLOTA with the reference in SIG_INFO.
bool isZlotaRef(std::string_view ref);

// Hunting: how often a reference was worked in these contacts (any program;
// a POTA reference's @location is ignored).
struct ReferenceHistory {
    size_t qsos = 0;
    std::string lastDate, lastLog;
};
ReferenceHistory referenceHistory(std::string_view ref, const std::vector<WorkedHit> &hits);
// "US-1234: a new park!" or "US-1234: worked 3 times before, last 2026-09-30 (US-7929.adi)".
std::string referenceSummary(std::string_view ref, const ReferenceHistory &h);

}  // namespace adif
