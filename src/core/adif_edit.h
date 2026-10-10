// Editing helpers built on the DocModel from lint(): reformatting, field edits
// with correct data lengths, and the name/value lists used by autocomplete and
// the record panel. Pure C++17, no editor dependencies.
#pragma once

#include "adif_lint.h"

#include <functional>
#include <string>
#include <string_view>
#include <vector>

namespace adif {

struct TextEdit {
    size_t start = 0, end = 0;  // replace [start, end) of the original text
    std::string text;
};

enum class Layout { RecordPerLine, FieldPerLine };

// Rebuild the document with one record (or one field) per line. Every data
// specifier, marker and comment is copied byte-for-byte; only the whitespace
// between them changes. The model must come from lint() on `text` with no
// structural errors and no pending length fixes (otherwise data boundaries are
// guesses); canReformat() checks that.
bool canReformat(const LintResult &r);
std::string reformat(std::string_view text, const DocModel &model, Layout layout, std::string_view eol);

// Model lookups. Positions are byte offsets into the linted text.
size_t groupStart(const DocModel &m, const ModelGroup &g);
size_t groupEnd(const DocModel &m, const ModelGroup &g);
int groupAt(const DocModel &m, size_t pos);  // the group containing pos, else the last one before it; -1 if none
int fieldAt(const DocModel &m, size_t pos);  // field whose tag or data contains pos (end inclusive); -1 if none
int recordNumber(const DocModel &m, int group);  // 1-based among non-header groups; 0 for the header
size_t recordCount(const DocModel &m);

std::string_view fieldName(std::string_view text, const ModelField &f);
std::string_view fieldValue(std::string_view text, const ModelField &f);
// First field of the group with that name (case-insensitive); empty if none.
std::string_view groupValue(std::string_view text, const DocModel &m, const ModelGroup &g, std::string_view name);

// "<NAME:LENGTH[:T]>VALUE" with LENGTH measured in `unit`.
std::string makeSpecifier(std::string_view name, std::string_view value, LengthUnit unit, bool utf8, char indicator = 0);

// Replace a field's data, keeping its name spelling and type indicator.
TextEdit setFieldValue(std::string_view text, const ModelField &f, std::string_view value, LengthUnit unit, bool utf8);
// Add a field at the end of a group, matching the group's separator (space or line break).
TextEdit insertField(std::string_view text, const DocModel &m, const ModelGroup &g, std::string_view name,
                     std::string_view value, LengthUnit unit, bool utf8);
// Remove the group's index-th field and the whitespace separating it from what follows.
TextEdit removeField(std::string_view text, const DocModel &m, const ModelGroup &g, size_t index);

// Field names for autocomplete: header fields (and EOH) inside the header,
// otherwise QSO fields that ADI can carry, plus the file's USERDEF and APP_
// fields, and EOR. Upper case, sorted.
std::vector<std::string> fieldNameChoices(const DocModel &m, bool header);
// Values offered for a field: its enumeration (filtered by the record's MODE
// for SUBMODE, by DXCC for STATE/CNTY), Y/N for Booleans, a USERDEF field's
// list. Import-only values are left out. Empty when there is no list.
std::vector<std::string> valueChoices(std::string_view text, const DocModel &m, const ModelGroup *g,
                                      std::string_view fieldName);
// The same, with the record's other values supplied by `lookup` (field name ->
// value, empty if absent); used where the record is not in the document yet.
std::vector<std::string> valueChoicesWith(const DocModel &m, std::string_view fieldName,
                                          const std::function<std::string(std::string_view)> &lookup);
// One-line description: "CALL (String): The contacted station's callsign".
std::string describeField(const DocModel &m, std::string_view name);

// What the UI shows about a field: its type, a brief description (the first
// paragraph of the spec's), the full spec text, and whether it has a value list.
struct FieldInfo {
    std::string name;     // upper case
    std::string type;     // "String", "Enumeration", ... or "" when unknown
    std::string brief;
    std::string details;  // may equal brief
    bool hasValues = false;
};
FieldInfo fieldInfo(const DocModel &m, std::string_view name);

// ── New QSO ─────────────────────────────────────────────────────────────────

struct QsoField {
    std::string name;   // upper case
    std::string value;  // pre-filled value, may be empty
    bool carry = false; // keeps its value from one contact to the next
};

// Fields that usually stay the same between contacts: the station's own
// details (MY_*, STATION_CALLSIGN, OPERATOR...) and BAND, FREQ, MODE, SUBMODE.
bool isCarriedField(std::string_view name);
// The fields to ask for in a new QSO: the last record's fields in its order,
// then CALL, QSO_DATE, TIME_ON, BAND, FREQ, MODE, SUBMODE, RST_SENT, RST_RCVD.
// Carried fields take the last record's values; QSO_DATE/TIME_ON take the given
// UTC date (YYYYMMDD) and time (HHMMSS, shortened to HHMM if the log uses HHMM);
// RST_SENT/RST_RCVD default from the mode.
std::vector<QsoField> newQsoTemplate(std::string_view text, const DocModel &m, std::string_view utcDate,
                                     std::string_view utcTime);
// CALL, QSO_DATE, TIME_ON and MODE: every new QSO has them (plus BAND or FREQ).
bool isRequiredQsoField(std::string_view name);
// Carried fields that describe the station rather than the contact: MY_*,
// STATION_CALLSIGN, OPERATOR, OWNER_CALLSIGN, TX_PWR, PROP_MODE, SAT_*, CONTEST_ID.
bool isStationField(std::string_view name);
// The same rows for a chosen list of fields, in that order. Required fields the
// list lacks are added first (and BAND when neither BAND nor FREQ is listed).
std::vector<QsoField> newQsoTemplateFor(std::string_view text, const DocModel &m, std::string_view utcDate,
                                        std::string_view utcTime, const std::vector<std::string> &fields);
// Station fields in the log's last record that are not among `shown`, with
// their values: written with each new QSO when the user keeps them hidden.
std::vector<std::pair<std::string, std::string>> hiddenStationFields(std::string_view text, const DocModel &m,
                                                                     const std::vector<std::string> &shown);
// Usual default report for a mode: "59" for phone, "599" for CW and RTTY, else empty.
std::string defaultReport(std::string_view mode);
// The ADIF band containing a frequency in MHz (inclusive edges), or empty.
std::string bandForFrequency(std::string_view mhz);
// How the log lays out its records (from the last record with two or more fields).
Layout recordLayout(std::string_view text, const DocModel &m);
// A record from name/value pairs (empty values are left out), with correct lengths.
struct BuiltRecord {
    std::string text;
    std::vector<std::pair<size_t, size_t>> ranges;  // per input field, [start, end) in text; kNoPos if left out
};
BuiltRecord buildRecord(const std::vector<std::pair<std::string, std::string>> &fields, Layout layout, std::string_view eol,
                        LengthUnit unit, bool utf8);
// Append a record at the end of the document, adding line breaks so it starts
// on its own line (after a blank line in the one-field-per-line layout).
// `recordStart` receives where the record begins in the edited document.
TextEdit appendRecord(std::string_view text, const DocModel &m, std::string_view record, std::string_view eol,
                      size_t *recordStart);
// A header for a brand-new log.
std::string newLogHeader(std::string_view programVersion, std::string_view utcTimestamp, std::string_view eol);

}  // namespace adif
