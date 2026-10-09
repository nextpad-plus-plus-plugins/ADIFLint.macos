// Log tools built on the DocModel: a table of the log, a summary report, bulk
// edits, time shifts, sorting, duplicates, merging another log, CSV export,
// POTA activations and per-park export, and worked-before entries. Pure C++17.
//
// POTA rules used here (docs.pota.app/docs/rules.html, modified 2026-10-04):
//   - an activation is 10 or more QSOs from one park in one UTC day;
//   - a QSO is unique by station, CALL, MODE (SUBMODE supersedes MODE),
//     QSO_DATE, BAND, MY_SIG_INFO, SIG_INFO and location; repeats are rejected;
//   - CALL may not be the STATION_CALLSIGN or OPERATOR;
//   - required: STATION_CALLSIGN or OPERATOR, CALL, QSO_DATE, TIME_ON, BAND,
//     MODE or SUBMODE; MY_SIG=POTA with MY_SIG_INFO naming the park;
//   - a separate log for each park of a multi-park activation.
// File names (docs.pota.app/docs/activator_reference/submitting_logs.html,
// modified 2026-07-08): callsign@park-YYYYMMDD.adi, with the state appended
// for a park that spans several (W8MSC@US-4239-20181231-US-MI.adi).
// MY_POTA_REF/POTA_REF are comma lists of xxxx-nnnnn[@yyyyyy] (ADIF 3.1.7 POTARef).
#pragma once

#include "adif_edit.h"
#include "adif_lint.h"

#include <functional>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace adif {

// ── Records as values ───────────────────────────────────────────────────────

struct Record {
    int group = -1;   // index into DocModel::groups
    int number = 0;   // 1-based record number
    std::vector<std::pair<std::string, std::string>> fields;  // upper-case name, value; in order
    // First value of a field (case-insensitive name); empty if absent.
    const std::string &get(std::string_view name) const;
    bool has(std::string_view name) const;
};

// Every record (non-header group) in document order.
std::vector<Record> records(std::string_view text, const DocModel &m);
// A name for each record that survives edits elsewhere in the log:
// "CALL|QSO_DATE|TIME_ON|BAND|MODE", with "#2", "#3"... on repeats.
std::vector<std::string> recordKeys(const std::vector<Record> &recs);

// Apply sorted, non-overlapping edits to a copy of the text.
std::string applyTextEdits(std::string_view text, const std::vector<TextEdit> &edits);

// Date and time. Days count from 1970-01-01; times are minutes or seconds of day.
bool parseAdifDate(std::string_view date, long *days);          // YYYYMMDD
bool parseAdifTime(std::string_view time, int *seconds);        // HHMM or HHMMSS
std::string formatAdifDate(long days);                          // YYYYMMDD
std::string formatAdifTime(int seconds, bool withSeconds);      // HHMM or HHMMSS
// "YYYY-MM-DD" and "HH:MM[:SS]" for display; the input when malformed.
std::string displayDate(std::string_view date);
std::string displayTime(std::string_view time);
// QSO_DATE + TIME_ON as seconds since 1970, or -1 when either is missing or malformed.
long long qsoStart(const Record &r);

// The mode POTA stores: SUBMODE when given, else MODE (upper case).
std::string effectiveMode(const Record &r);
// BAND, or the band containing FREQ when BAND is missing (lower case as in the spec).
std::string effectiveBand(const Record &r);

// ── Log table and summary ───────────────────────────────────────────────────

// Columns for a table of the log: the usual QSO fields the log uses, in a
// fixed order, then its other fields by how many records have them.
std::vector<std::string> tableColumns(const std::vector<Record> &recs);

// A plain-text summary: counts, date range, bands, modes, days, entities,
// states, grids, parks, QSL and upload status.
std::string summaryReport(std::string_view text, const DocModel &m, std::string_view title);

// ── Bulk edits ──────────────────────────────────────────────────────────────

enum class BulkAction { Set, Replace, Remove, Rename };

struct BulkEdit {
    BulkAction action = BulkAction::Set;
    std::string field;          // the field to change
    std::string value;          // Set: the new value; Replace: the replacement text
    std::string find;           // Replace: the text to find (ASCII case-insensitive), every occurrence
    std::string newName;        // Rename: the new field name
    bool onlyMissing = false;   // Set: only records without the field (or with it empty)
};

struct RecordFilter {
    enum Kind { All, Equals, Contains, Missing, Present };
    Kind kind = All;
    std::string field;
    std::string value;  // Equals/Contains, ASCII case-insensitive
};
bool matchesFilter(const Record &r, const RecordFilter &f);

// One planned change to one field of one record.
struct PlannedChange {
    enum Kind { Add, Change, Remove, Rename };
    Kind kind = Change;
    int group = -1;           // DocModel group
    int record = 0;           // 1-based, for display
    size_t fieldIndex = 0;    // DocModel::fields index (Change, Remove, Rename)
    std::string call;
    std::string field;        // upper case
    std::string before, after;  // values; for Rename, the old and new names
};

struct ChangePlan {
    std::vector<PlannedChange> changes;
    size_t records = 0;      // records with at least one change
    size_t skipped = 0;      // records left alone
    std::string skipReason;  // why, when skipped > 0
};

// Plan a bulk edit over the given groups (DocModel indices).
ChangePlan planBulkEdit(std::string_view text, const DocModel &m, const std::vector<int> &groups, const BulkEdit &op);
// Shift QSO_DATE/TIME_ON (and QSO_DATE_OFF/TIME_OFF) by `minutes`, keeping
// each time's HHMM or HHMMSS form. Records without a valid date and time are skipped.
ChangePlan planTimeShift(std::string_view text, const DocModel &m, const std::vector<int> &groups, long long minutes);
// The same with an amount per record, e.g. a time zone's offset on the QSO's
// date: `shiftFor` gets the record's start (QSO_DATE + TIME_ON as written, in
// seconds since 1970) and sets the seconds to add, or returns false with `why`
// to leave the record alone. The end moves by the start's amount.
using ShiftFor = std::function<bool(long long start, long long *seconds, std::string *why)>;
ChangePlan planTimeShiftWith(std::string_view text, const DocModel &m, const std::vector<int> &groups, const ShiftFor &shiftFor);

// A local wall-clock time (seconds since 1970, read as if it were UTC) to UTC in
// a zone whose offset from UTC at a UTC instant is offsetAt(utc) seconds (east
// positive, daylight saving included). Skipped: the clocks jumped over it
// (spring forward). Repeated: it happened twice (fall back); `utc` gets the first.
enum class LocalTime { Unique, Skipped, Repeated };
LocalTime localToUtc(long long wall, const std::function<long long(long long utc)> &offsetAt, long long *utc);
// DISTANCE (km, short path) from MY_GRIDSQUARE and GRIDSQUARE for records that
// have both locators and no DISTANCE yet. Others are skipped with the reason.
ChangePlan planDistance(std::string_view text, const DocModel &m, const std::vector<int> &groups);
// The edits for planned changes: values rewritten with correct lengths, new
// fields inserted at each record's end (one insertion per record), names
// renamed in place. Sorted and non-overlapping.
std::vector<TextEdit> planEdits(std::string_view text, const DocModel &m, const std::vector<PlannedChange> &changes,
                                LengthUnit unit, bool utf8);

// ── Sorting, duplicates, merging ────────────────────────────────────────────

// The document with its records in QSO_DATE/TIME_ON order. Records without a
// valid date and time keep their order, after the others. Comments between
// records move with the record after them; blank runs between records become
// the log's usual separator. Needs canReformat() on the lint result and every
// record ended by <EOR>. `changed` reports whether the order changed.
std::string sortedByTime(std::string_view text, const DocModel &m, std::string_view eol, bool *changed);

// Text order with digit runs compared by value ("K2AB" before "K10AB") and
// case ignored; two plain numbers ("-10", "14.074") compare as numbers.
int naturalCompare(std::string_view a, std::string_view b);
// Two values of a field, in the order a log sorts them: bands by frequency
// (160m before 20m), dates and times in time order (with or without - and :),
// numbers by value, anything else as naturalCompare. -1, 0 or 1.
int compareFieldValues(std::string_view field, std::string_view a, std::string_view b);

struct SortKey {
    std::string field;  // an ADIF field name
    bool descending = false;
};
// The document with its records ordered by the keys, the first key first. A
// record without a value for a key goes after those with one, whichever the
// direction; records that tie keep their order. Comments and separators as
// sortedByTime(), with the same requirements.
std::string sortedBy(std::string_view text, const DocModel &m, const std::vector<SortKey> &keys, std::string_view eol,
                     bool *changed);

// Every record's fields put in `order` (the ones it has), the others after them
// in their own order. Each data specifier is copied byte for byte and the
// whitespace between fields stays where it was: only the order changes. The
// header is left alone, and so is a record with a wrong length or anything but
// whitespace between its fields (counted in `skipped`). `changedRecords` counts
// the records edited.
std::vector<TextEdit> fieldOrderEdits(std::string_view text, const DocModel &m, const std::vector<std::string> &order,
                                      size_t *changedRecords, size_t *skipped);

struct DupeOptions {
    int windowMinutes = 2;  // start times this close are the same contact
};

// The same contact: same CALL, band and mode (SUBMODE, else MODE), start
// times within the window, and no different STATION_CALLSIGN, MY_SIG_INFO,
// SIG_INFO, MY_POTA_REF or POTA_REF (park-to-park lines repeated for each park
// of a multi-park activation are not duplicates).
bool sameQso(const Record &a, const Record &b, const DupeOptions &opt);

// For New QSO: records POTA would count as the same contact as `qso` (record
// numbers): same CALL, band (BAND or FREQ), mode (MODE, and SUBMODE when both
// have one) and UTC date, and no different SIG_INFO/POTA_REF, MY_SIG_INFO/
// MY_POTA_REF or STATION_CALLSIGN. A park-to-park contact logged once for each
// park of a two-fer is not a repeat.
std::vector<int> sameContactAs(std::string_view text, const DocModel &m, const Record &qso);
// Records logging this station under any of its calls (K1ABC, K1ABC/P, VE3/K1ABC).
size_t timesWorkedAs(std::string_view text, const DocModel &m, std::string_view call);

struct DupeSet {
    int keep = -1;                 // group kept: the one with the most fields, else the first
    std::vector<int> remove;       // groups removed
    std::vector<std::pair<std::string, std::string>> fill;  // fields the kept record lacks, from the removed ones
};
std::vector<DupeSet> findDuplicates(std::string_view text, const DocModel &m, const DupeOptions &opt);
// Remove the duplicate records (each with the blank run after it) and, when
// `fill` is set, add the missing fields to the kept records.
std::vector<TextEdit> duplicateEdits(std::string_view text, const DocModel &m, const std::vector<DupeSet> &sets, bool fill,
                                     LengthUnit unit, bool utf8);

struct MergePlan {
    std::vector<int> add;                        // source groups to add
    std::vector<std::pair<int, int>> duplicates; // (source group, target group) skipped
    std::vector<std::string> undefinedFields;    // source USERDEF fields the target's header lacks
    size_t emptyRecords = 0;                     // source records without fields
};
MergePlan planMerge(std::string_view target, const DocModel &targetModel, std::string_view source,
                    const DocModel &sourceModel, const DupeOptions &opt, bool skipDuplicates);
// The source records, rebuilt in the target's layout and length unit, joined
// for appendRecord().
std::string mergedRecords(std::string_view source, const DocModel &sourceModel, const std::vector<int> &groups,
                          Layout layout, std::string_view eol, LengthUnit unit, bool utf8);

// ── Spreadsheet editing (the Log Table) ─────────────────────────────────────

struct CellChange {
    int group = -1;     // the record (DocModel group)
    std::string field;  // upper case
    std::string value;  // empty: remove the field
};
// What to write for a value typed or pasted into a table cell: a date shown as
// 2026-10-06 or 2026/10/06 is written 20261006, a time shown as 22:30 or
// 22:30:15 is written 2230 or 223015; anything else is trimmed.
std::string cellValue(std::string_view field, std::string_view shown);
// Edits setting each record's fields: a field the record has gets the new value
// (or is removed when the value is empty), a new one is added before <EOR>, and
// the last change to a field wins. Sorted and non-overlapping, one record's
// changes never overlapping another's.
std::vector<TextEdit> cellEdits(std::string_view text, const DocModel &m, const std::vector<CellChange> &changes,
                                LengthUnit unit, bool utf8);
// Edits removing these records, each with the blank run after it (the last
// record: the blank run before it). Sorted and non-overlapping.
std::vector<TextEdit> removeRecordsEdits(std::string_view text, const DocModel &m, const std::vector<int> &groups);
// Tab-separated rows for a spreadsheet (Numbers, Excel): a value with a tab,
// quote or line break is quoted, quotes doubled; lines end in CR LF.
std::string toTsv(const std::vector<std::vector<std::string>> &rows);

// ── Quick fixes ─────────────────────────────────────────────────────────────

// Edits applying the repairs of `diagnostics` (from lint() of `text` with
// buildModel; see Diagnostic::fixes) as one change. Records with a wrong length
// are left alone (Fix Lengths first); where two repairs touch the same text the
// first wins. *applied: how many diagnostics' repairs the edits carry.
std::vector<TextEdit> quickFixEdits(std::string_view text, const DocModel &m, const std::vector<Diagnostic> &diagnostics,
                                    LengthUnit unit, bool utf8, size_t *applied = nullptr);

// ── CSV ─────────────────────────────────────────────────────────────────────

// RFC 4180: a header row of field names, CRLF line ends, values with a comma,
// quote or line break quoted. A value a spreadsheet would run as a formula
// (starting with =, +, -, @, tab or CR and not a plain number such as -10) gets
// a leading apostrophe.
std::string toCsv(const std::vector<Record> &recs, const std::vector<std::string> &columns);

// ── POTA ────────────────────────────────────────────────────────────────────

// xxxx-nnnn[n][@yyyyyy] (ADIF POTARef).
bool isPotaRef(std::string_view ref);
// The logging station's parks: MY_POTA_REF's list, else MY_SIG_INFO (a comma
// list too) when MY_SIG is POTA, or is empty and the value is a park reference.
std::vector<std::string> myParks(const Record &r);
// The other station's parks: POTA_REF's list, else SIG_INFO when SIG is POTA
// (or empty and the value is a park reference).
std::vector<std::string> theirParks(const Record &r);
// STATION_CALLSIGN, else OPERATOR (upper case).
std::string stationCall(const Record &r);

// Award programs with references: Parks on the Air, World Wide Flora & Fauna, Summits on the Air.
enum class Program { POTA, WWFF, SOTA };
const char *programName(Program p);  // "POTA", "WWFF", "SOTA"
// The logging station's (`mine`) or the other station's references in a program:
// POTA as myParks()/theirParks(); WWFF from MY_WWFF_REF/WWFF_REF, else SIG WWFF
// with SIG_INFO; SOTA from MY_SOTA_REF/SOTA_REF, else SIG SOTA with SIG_INFO.
struct Record;
std::vector<std::string> programRefs(const Record &r, Program p, bool mine);

struct Activation {
    Program program = Program::POTA;
    size_t needed = 10;    // QSOs (SOTA: different stations) for the activation to count
    std::string station;   // STATION_CALLSIGN or OPERATOR; may be empty
    std::string park;      // the reference as logged (POTA with any @location)
    std::string date;      // YYYYMMDD (UTC); for WWFF the first day
    std::string lastDate;  // WWFF: the last day (its 44 QSOs may span several)
    std::vector<int> groups;  // the records, in document order
    size_t qsos = 0;          // unique QSOs that count
    size_t duplicates = 0;    // repeats POTA would reject
    size_t invalid = 0;       // missing required fields, or working your own call
    size_t p2p = 0;           // counted QSOs with the other station in a park
    size_t noStation = 0;     // records without STATION_CALLSIGN or OPERATOR, counted for `station`
    std::string first, last;  // TIME_ON of the earliest and latest record
    std::map<std::string, size_t> bands, modes;  // counted QSOs
    bool activated() const { return qsos >= needed; }
};
// One per station, park and UTC date, in date order. Records without
// STATION_CALLSIGN or OPERATOR count for `defaultStation`, or else for the
// station most of the log's records name.
std::vector<Activation> activations(std::string_view text, const DocModel &m, std::string_view defaultStation = {});

struct PotaFile {
    std::string name;     // callsign@park-YYYYMMDD[-location].adi
    std::string station, park, date;
    std::string text;     // a complete ADI file
    size_t records = 0, qsos = 0;
    std::vector<std::string> notes;  // e.g. "7 QSOs: 3 short of an activation"
};
// One file per station, park and UTC day. Each record gets MY_SIG=POTA,
// MY_SIG_INFO=park (and MY_POTA_REF=park if it had MY_POTA_REF), and
// STATION_CALLSIGN (`defaultStation`, else the log's usual station) when it has
// neither STATION_CALLSIGN nor OPERATOR. '/' in a callsign becomes '_' in the
// file name; names are unique ("-2" is added if two would clash).
std::vector<PotaFile> potaExport(std::string_view text, const DocModel &m, std::string_view defaultStation,
                                 std::string_view programVersion, std::string_view utcTimestamp, std::string_view eol,
                                 LengthUnit unit, bool utf8, std::string_view todayUtc);

// A POTA spot (api.pota.app/spot/activator, checked 2026-10-07: "frequency" in
// kHz as text, "mode" SSB, CW, FT8, FT4 or empty, "reference" the park) as New
// QSO fields: CALL, FREQ (MHz), BAND, MODE and SUBMODE (SSB: LSB below 10 MHz
// except 60 m, else USB; FT4 is MFSK/FT4; any other ADIF mode or submode by
// name), SIG=POTA, SIG_INFO and POTA_REF. Unusable values are left out.
std::vector<std::pair<std::string, std::string>> spotFields(std::string_view activator, std::string_view kHz,
                                                            std::string_view mode, std::string_view reference);
// "14059.1" (kHz) -> "14.0591" (MHz); empty when not a number.
// "14074000" (Hz) -> "14.074" (ADIF FREQ is in MHz); a decimal part is rounded
// ("14074000.000000"). Empty when not a number.
std::string hzToMHz(std::string_view hz);
std::string khzToMHz(std::string_view kHz);

// ── Worked before ───────────────────────────────────────────────────────────

struct Contact {
    std::string call;      // as logged, upper case
    std::string baseCall;  // lookupCall(call): "VE3/K1ABC/P" -> "K1ABC"
    std::string date, time, band, mode, myPark, theirPark;
    std::vector<std::string> theirRefs;  // the other station's POTA, WWFF and SOTA references
    int record = 0;
};
std::vector<Contact> contacts(std::string_view text, const DocModel &m);

struct WorkedHit {
    std::string log;  // file name
    Contact contact;
};
// "K1ABC: 4 QSOs in 2 logs, last 2026-09-30 14:05 on 20m SSB (US-7929.adi). Bands: 20m, 40m."
std::string workedSummary(std::string_view call, const std::vector<WorkedHit> &hits);

}  // namespace adif
