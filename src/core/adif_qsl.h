// QSL services at a glance (QSL Sync) and LoTW's pre-flight: whether TQSL will
// accept each QSO with the Station Location chosen for the upload.
//
// TQSL (sourceforge.net/p/trustedqsl/tqsl, master 1babc82, read 2026-10-10):
//   - Its folder is $TQSLDIR, else ~/.tqsl on macOS and Linux (src/tqsllib.cpp,
//     tqsl_init). Station Locations are kept in "station_data" there, plain XML
//     (src/location.cpp, tqsl_dump_station_data): <StationDataFile> holding a
//     <StationData name="..."> per location, with an element per field named as
//     TQSL names it (CALL, DXCC, GRIDSQUARE, ITUZ, CQZ, US_STATE, US_COUNTY...).
//   - By default it reports a log's station fields that disagree with the
//     location, and does not sign that QSO (apps/tqsl.cpp: LogVerify defaults to
//     TQSL_LOC_REPORT; src/tqslconvert.cpp): STATION_CALLSIGN (else OPERATOR)
//     against the certificate's call, MY_DXCC against its entity, MY_GRIDSQUARE
//     against GRIDSQUARE (only the first 4 when the log has 4 and the location
//     more), MY_STATE against US_STATE (DXCC 291, 6, 110), CA_PROVINCE (1),
//     RU_OBLAST (15, 54, 61, 125, 151), CN_PROVINCE (318), AU_STATE (150),
//     JA_PREFECTURE (339) or FI_KUNTA (224, 5), MY_CNTY (the part after "ST,")
//     against US_COUNTY or JA_CITY_GUN_KU, MY_ITU_ZONE against ITUZ and
//     MY_CQ_ZONE against CQZ, ignoring case. A field the location leaves empty
//     never refuses a QSO, and neither does a log that leaves the field out.
#pragma once

#include "adif_lint.h"
#include "adif_tools.h"
#include "adif_upload.h"

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

struct TqslLocation {
    std::string name;
    std::vector<std::pair<std::string, std::string>> fields;  // TQSL's names, as saved
    std::string get(std::string_view field) const;            // "" when absent
};

// The Station Locations in TQSL's station_data file.
std::vector<TqslLocation> parseStationData(std::string_view xml);

// Why TQSL would not sign this QSO with this location ("" when it would), naming
// the first field that disagrees: "MY_GRIDSQUARE EN61 (the location: EN52wa)".
std::string lotwLocationProblem(const Record &qso, const TqslLocation &loc);

// For QSL Sync: one service in one log.
struct ServiceSummary {
    size_t toUpload = 0;   // would be offered for upload
    size_t modified = 0;   // among them, changed since an upload (QRZ, Club Log: M)
    size_t uploaded = 0;   // already sent
    size_t notToSend = 0;  // marked N (or I)
    size_t problems = 0;   // can't be sent as they are
    size_t confirmed = 0;  // confirmed by the service: LOTW_QSL_RCVD Y or V, EQSL_QSL_RCVD Y or V,
                           // APP_QRZLOG_STATUS C (as QRZ.com Logbook downloads mark it); Club Log has none
    std::string lastUpload;  // the newest upload date in the log (YYYYMMDD), or ""
};
ServiceSummary serviceSummary(std::string_view text, const DocModel &m, UploadService s);

}  // namespace adif
