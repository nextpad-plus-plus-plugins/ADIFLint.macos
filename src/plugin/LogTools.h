// Log tools in the plugin: Log Table, Summary, Activation Tracker, Worked
// Before, Bulk Edit and Time Shift, Sort, Remove Duplicates, Merge Another Log,
// CSV and POTA export. The ADIF work is in src/core/adif_tools; this file
// builds the windows (ToolWindow) and edits the document through PluginHost.
#pragma once

#include "adif_tools.h"

#include <string>
#include <utility>
#include <vector>

namespace logtools {

void cmdLogTable();
void cmdSummary();
void cmdActivationTracker();
void cmdWorkedBefore();
void cmdBulkEdit();
void cmdTimeShift();
void cmdOrganize();  // Sort and Organize: records by any fields, fields in any order
void cmdRemoveDuplicates();
void cmdMergeLog();
void cmdImportWsjtxLog();  // Merge, from WSJT-X's own log
void cmdExportCsv();
void cmdExportPota();
void cmdPotaSpots();
void cmdImportCsv();
void cmdExportCabrillo();
void openActivationExport(adif::Program p);  // Export Activation Logs for a program

// Called with a spot's New QSO fields (CALL, FREQ, BAND, MODE, SUBMODE, SIG, SIG_INFO, POTA_REF).
void setSpotHandler(void (^handler)(const std::vector<std::pair<std::string, std::string>> &fields));

// The active document was re-checked (after an edit), or another one became active.
void documentChanged();
void bufferActivated();

// From the logs folder chosen in Worked Before (the active file left out):
// "K1ABC: 4 QSOs in 2 other logs; last ...", or "" when none or not indexed yet.
// Starts indexing the folder in the background when needed.
std::string workedBefore(const std::string &call);
// Hunting: "US-1234: a new park!" or "US-1234: worked 3 times before, last ..."
// from this log and the Worked Before folder.
std::string referenceLine(const std::string &ref);
// Whether a reference has been worked in this log or the folder's logs.
bool referenceWorked(const std::string &ref);

// Called on the main thread whenever the folder index is rebuilt.
void setIndexListener(void (^listener)(void));

}  // namespace logtools
