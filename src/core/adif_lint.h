// ADI file validation and length repair (ADIF 3.1.7, section IV.A).
//
// Pure C++17 with no editor or platform dependencies: the Nextpad++ plugin,
// the adiflint command-line tool and the tests all call lint() on a byte
// buffer and get back diagnostics as byte ranges plus the length fixes.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace adif {

enum class Severity : unsigned char { Info, Warning, Error };

// What a data length L counts. ADIF 3.1.7 allows only ASCII in ADI files, where
// bytes and characters are the same; programs that write UTF-8 anyway disagree,
// so the unit is a user choice.
enum class LengthUnit : unsigned char { Bytes, Characters };

struct LintOptions {
    LengthUnit lengthUnit = LengthUnit::Bytes;
    bool utf8 = true;               // text is UTF-8 (Characters mode counts code points)
    size_t maxDiagnostics = 10000;  // stop storing (but keep counting) beyond this
    bool buildModel = false;        // fill LintResult::model
    std::string today;              // UTC YYYYMMDD: QSO dates after it are flagged; empty: not checked
};

constexpr size_t kNoPos = SIZE_MAX;

// A suggested repair, applied by quickFixEdits() (adif_tools.h).
enum class FixKind : unsigned char {
    SetValue,     // set `field` in the diagnostic's record to `value`, adding the field when missing
    RemoveField,  // remove the `field` specifier the diagnostic is on
    InsertText,   // insert `value` at byte offset `at`
    DeleteText,   // delete the diagnostic's own range
};
struct FieldFix {
    FixKind kind = FixKind::SetValue;
    std::string field;  // upper case
    std::string value;
    size_t at = kNoPos;  // InsertText only
};

struct Diagnostic {
    size_t start = 0;  // byte offset, inclusive
    size_t end = 0;    // byte offset, exclusive; always > start
    Severity severity = Severity::Error;
    bool structural = false;  // the file's structure is unclear here (wrong length, malformed tag...)
    std::string message;
    std::string code;              // stable kind ("length", "freq-band"...); empty for the rest
    std::string field;             // the field it is about (upper case), when known
    std::vector<FieldFix> fixes;   // the repair, applied together; empty when there is none
    std::string fixLabel;          // what the repair does, e.g. "MODE SSB, SUBMODE USB"
};
// The kinds that have codes: length (Fix Lengths repairs them), mode-is-submode,
// submode-mode, mode-missing, date-format, time-format, freq-band, band-missing,
// case, future-date, sat-name, sat-prop, pota-station, dup-field, no-eor, bom,
// minimum-fields.

// One data specifier, <NAME:LENGTH[:T]>DATA, as byte offsets.
struct ModelField {
    size_t tagB = 0;          // '<'; the name starts at tagB + 1
    size_t nameE = 0;         // end of the name (the ':')
    size_t lenB = 0, lenE = 0;
    size_t typePos = kNoPos;  // type indicator letter, if any
    size_t gt = 0;            // '>'; the data starts at gt + 1
    size_t valueE = 0;        // end of the data (the intended data when lengthOk is false)
    bool lengthOk = true;
};

// The header or one record: consecutive fields plus the <EOH>/<EOR> ending them.
struct ModelGroup {
    bool header = false;
    size_t firstField = 0, fieldCount = 0;  // into DocModel::fields
    size_t markerB = kNoPos, markerE = kNoPos;  // the <EOH>/<EOR> tag; kNoPos when missing
};

struct UserFieldInfo {
    std::string name;                 // as written in the USERDEFn header field
    char indicator = 0;               // data type indicator, upper case, or 0
    std::vector<std::string> values;  // enumeration, if one was given
};

// The document's structure, for colouring, reformatting, the record panel and
// autocomplete. Offsets are bytes into the linted text.
struct DocModel {
    bool hasBom = false;
    size_t firstTag = kNoPos;                 // the first well-formed tag
    size_t headerTextB = 0, headerTextE = 0;  // text before the first tag (trimmed)
    std::vector<ModelField> fields;
    std::vector<ModelGroup> groups;           // in document order
    std::vector<std::pair<size_t, size_t>> otherText;  // other non-blank text outside specifiers (trimmed)
    std::vector<UserFieldInfo> userFields;
    std::vector<std::pair<std::string, char>> appFields;  // APP_ names (upper case) and first indicator
};

// Replace the length digits at [start, end) with `digits`.
struct LengthFix {
    size_t start = 0;
    size_t end = 0;
    std::string digits;
};

struct LintResult {
    std::vector<Diagnostic> diagnostics;  // sorted by start
    std::vector<LengthFix> fixes;         // sorted by start, non-overlapping
    size_t errors = 0, warnings = 0, infos = 0;  // totals, including any not stored
    size_t structuralErrors = 0;                 // errors with Diagnostic::structural set
    size_t records = 0;
    DocModel model;                              // when LintOptions::buildModel
    bool hasHeader = false;
    bool truncated = false;  // more diagnostics than maxDiagnostics
};

LintResult lint(std::string_view text, const LintOptions &options = {});

// Apply fixes (as returned by lint on the same text) and return the new text.
std::string applyFixes(std::string_view text, const std::vector<LengthFix> &fixes);

size_t measureLength(std::string_view data, LengthUnit unit, bool utf8);

// Parse an ADIF Number (§II.B): optional '-', digits, at most one '.'. Not locale-sensitive.
bool parseAdifNumber(std::string_view v, double *out);
// A 2, 4, 6 or 8 character Maidenhead locator (§II.B GridSquare).
bool isAdifGridSquare(std::string_view v);
// §II.B WWFFRef (xxFF-nnnn) and SOTARef (association/region-number).
bool isAdifWwffRef(std::string_view v);
bool isAdifSotaRef(std::string_view v);
const char *severityName(Severity s);

}  // namespace adif
