#include "adif_spec.h"

#include <algorithm>

namespace adif {

static inline unsigned char upperAscii(unsigned char c) {
    return (c >= 'a' && c <= 'z') ? (unsigned char)(c - 'a' + 'A') : c;
}

int compareNoCase(std::string_view a, std::string_view b) {
    size_t n = std::min(a.size(), b.size());
    for (size_t i = 0; i < n; ++i) {
        unsigned char x = upperAscii((unsigned char)a[i]);
        unsigned char y = upperAscii((unsigned char)b[i]);
        if (x != y) return x < y ? -1 : 1;
    }
    if (a.size() == b.size()) return 0;
    return a.size() < b.size() ? -1 : 1;
}

bool equalsNoCase(std::string_view a, std::string_view b) {
    return a.size() == b.size() && compareNoCase(a, b) == 0;
}

const FieldDef *findField(std::string_view name) {
    size_t n = 0;
    const FieldDef *t = fieldTable(&n);
    const FieldDef *end = t + n;
    const FieldDef *it = std::lower_bound(t, end, name, [](const FieldDef &f, std::string_view key) {
        return compareNoCase(f.name, key) < 0;
    });
    return (it != end && compareNoCase(it->name, name) == 0) ? it : nullptr;
}

const EnumDef *findEnum(std::string_view name) {
    size_t n = 0;
    const EnumDef *t = enumTable(&n);
    for (size_t i = 0; i < n; ++i)
        if (equalsNoCase(t[i].name, name)) return &t[i];
    return nullptr;
}

const EnumValue *findEnumValue(const EnumDef &e, std::string_view value, std::string_view scope) {
    const EnumValue *end = e.values + e.count;
    const EnumValue *it = std::lower_bound(e.values, end, value, [](const EnumValue &v, std::string_view key) {
        return compareNoCase(v.value, key) < 0;
    });
    for (; it != end && compareNoCase(it->value, value) == 0; ++it) {
        if (scope.empty() || (it->scope && equalsNoCase(it->scope, scope))) return it;
    }
    return nullptr;
}

bool enumHasScope(const EnumDef &e, std::string_view scope) {
    for (size_t i = 0; i < e.count; ++i)
        if (e.values[i].scope && equalsNoCase(e.values[i].scope, scope)) return true;
    return false;
}

const BandDef *findBand(std::string_view name) {
    size_t n = 0;
    const BandDef *t = bandTable(&n);
    for (size_t i = 0; i < n; ++i)
        if (equalsNoCase(t[i].name, name)) return &t[i];
    return nullptr;
}

const char *dxccEntityName(std::string_view code) {
    if (code.empty() || code.size() > 4) return nullptr;
    int n = 0;
    for (char c : code) {
        if (c < '0' || c > '9') return nullptr;
        n = n * 10 + (c - '0');
    }
    size_t count = 0;
    const DxccName *t = dxccTable(&count);
    const DxccName *it = std::lower_bound(t, t + count, n, [](const DxccName &d, int key) { return d.code < key; });
    return (it != t + count && it->code == n) ? it->name : nullptr;
}

DataType typeFromIndicator(char c) {
    switch (upperAscii((unsigned char)c)) {
        case 'B': return DataType::Boolean;
        case 'N': return DataType::Number;
        case 'D': return DataType::Date;
        case 'T': return DataType::Time;
        case 'S': return DataType::String;
        case 'I': return DataType::IntlString;
        case 'M': return DataType::MultilineString;
        case 'G': return DataType::IntlMultilineString;
        case 'E': return DataType::Enumeration;
        case 'L': return DataType::Location;
        default: return DataType::Unknown;
    }
}

const char *typeName(DataType t) {
    switch (t) {
        case DataType::Unknown: return "Unknown";
        case DataType::AwardList: return "AwardList";
        case DataType::CreditList: return "CreditList";
        case DataType::SponsoredAwardList: return "SponsoredAwardList";
        case DataType::Boolean: return "Boolean";
        case DataType::Digit: return "Digit";
        case DataType::Integer: return "Integer";
        case DataType::Number: return "Number";
        case DataType::PositiveInteger: return "PositiveInteger";
        case DataType::Character: return "Character";
        case DataType::IntlCharacter: return "IntlCharacter";
        case DataType::Date: return "Date";
        case DataType::Time: return "Time";
        case DataType::IOTARefNo: return "IOTARefNo";
        case DataType::String: return "String";
        case DataType::IntlString: return "IntlString";
        case DataType::MultilineString: return "MultilineString";
        case DataType::IntlMultilineString: return "IntlMultilineString";
        case DataType::Enumeration: return "Enumeration";
        case DataType::GridSquare: return "GridSquare";
        case DataType::GridSquareExt: return "GridSquareExt";
        case DataType::GridSquareList: return "GridSquareList";
        case DataType::Location: return "Location";
        case DataType::POTARef: return "POTARef";
        case DataType::POTARefList: return "POTARefList";
        case DataType::SecondarySubdivisionList: return "SecondarySubdivisionList";
        case DataType::SecondaryAdministrativeSubdivisionListAlt: return "SecondaryAdministrativeSubdivisionListAlt";
        case DataType::SOTARef: return "SOTARef";
        case DataType::WWFFRef: return "WWFFRef";
    }
    return "Unknown";
}

}  // namespace adif
