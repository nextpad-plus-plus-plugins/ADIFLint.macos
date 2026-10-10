// ADIF specification tables and lookups.
//
// The tables themselves live in adif_spec_317.cpp, generated from the official
// ADIF 3.1.7 JSON export by tools/gen_spec_tables.py. This header is the only
// interface the validator uses, so a future ADIF version is a regenerate, not
// a code change.
#pragma once

#include <cstddef>
#include <string_view>
#include <utility>

namespace adif {

// ADIF 3.1.7 section III.A "Data Types".
enum class DataType : unsigned char {
    Unknown,
    AwardList,
    CreditList,
    SponsoredAwardList,
    Boolean,
    Digit,
    Integer,
    Number,
    PositiveInteger,
    Character,
    IntlCharacter,
    Date,
    Time,
    IOTARefNo,
    String,
    IntlString,
    MultilineString,
    IntlMultilineString,
    Enumeration,
    GridSquare,
    GridSquareExt,
    GridSquareList,
    Location,
    POTARef,
    POTARefList,
    SecondarySubdivisionList,
    SecondaryAdministrativeSubdivisionListAlt,
    SOTARef,
    WWFFRef,
};

struct FieldDef {
    const char *name;         // upper case
    DataType type;            // first listed type ("CreditList,AwardList" -> CreditList)
    const char *enumeration;  // enumeration name, or nullptr
    const char *enumKey;      // field that scopes the enumeration (Submode[MODE] -> "MODE"), or nullptr
    bool header;              // Header Field
    bool importOnly;          // deprecated: accept on import, never export
    bool hasMin, hasMax;
    double minValue, maxValue;
    const char *description;  // brief: the first paragraph of the spec's description
    const char *details;      // the spec's full description text (notes included), or nullptr
};

struct EnumValue {
    const char *value;        // spelling as in the spec
    const char *scope;        // Submode: its Mode; subdivisions/regions: DXCC entity code; else nullptr
    const char *note;         // spec guidance for import-only or deleted values ("replaced by GH"), or nullptr
    bool importOnly;
    // The QSO dates the value is valid for (section II.C "Deletion"), YYYYMMDD or nullptr:
    // from inclusive, before exclusive (ARRL sections, regions, some subdivisions).
    const char *from;
    const char *before;
};

struct EnumDef {
    const char *name;
    const EnumValue *values;  // sorted by ASCII-upper-cased value
    size_t count;
};

struct BandDef {
    const char *name;
    double lowerMHz, upperMHz;  // inclusive band edges
};

struct DxccName {
    int code;
    const char *name;  // e.g. "UNITED STATES OF AMERICA", as in the DXCC_Entity_Code enumeration
    bool deleted;
};

extern const char kSpecVersion[];
extern const char kSpecDate[];

// Raw generated tables.
const FieldDef *fieldTable(size_t *count);
const EnumDef *enumTable(size_t *count);
const BandDef *bandTable(size_t *count);
const DxccName *dxccTable(size_t *count);  // sorted by code

// Case-insensitive lookups (ADIF names and enumeration values are case-insensitive).
const FieldDef *findField(std::string_view name);
const EnumDef *findEnum(std::string_view name);
// Any value matching `value`; when `scope` is non-empty, only one with that scope.
const EnumValue *findEnumValue(const EnumDef &e, std::string_view value, std::string_view scope = {});
// Every row spelling `value` (a code can have several: one per entity or per date range), as [first, last).
std::pair<const EnumValue *, const EnumValue *> enumValueRows(const EnumDef &e, std::string_view value);
// Whether `v` may be used for a QSO on `date` (YYYYMMDD; empty: any date).
bool validOn(const EnumValue &v, std::string_view date);
// True when at least one value of `e` has this scope (e.g. a DXCC entity has subdivisions listed).
bool enumHasScope(const EnumDef &e, std::string_view scope);
const BandDef *findBand(std::string_view name);
// The ADIF entity name for a DXCC code ("291" -> "UNITED STATES OF AMERICA"), or nullptr.
const char *dxccEntityName(std::string_view code);

// Data Type Indicators (section II.B): one letter, case-insensitive.
DataType typeFromIndicator(char c);  // DataType::Unknown when not an indicator
const char *typeName(DataType t);

// ASCII-only case-insensitive comparison, matching the generator's sort order.
int compareNoCase(std::string_view a, std::string_view b);
bool equalsNoCase(std::string_view a, std::string_view b);

}  // namespace adif
