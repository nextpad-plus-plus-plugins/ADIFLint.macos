// ADI validation and length repair. Section references are to the ADIF 3.1.7
// specification (2026-03-22) unless marked "Resources", which means the ADIF
// 3.1.7 Resources document.
//
// How a data specifier is read
// ----------------------------
// Strictly (§IV.A.1), <F:L:T> is followed by exactly L units of data, and any
// text between specifiers is ignored (§IV.A.6). A wrong L therefore never
// "fails" for an importer: it silently truncates the value, or swallows the
// next specifier. To report what the user meant, each specifier is checked
// against the next well-formed tag:
//
//   consistent  the declared data ends at or before the next tag and only
//               whitespace separates them, or it deliberately contains
//               tag-like text and whitespace follows its end;
//   too short   non-whitespace text sits between the declared end and the
//               next tag;
//   too long    the declared data runs into the next tag (or past the end).
//
// For an inconsistent length the intended value is the text up to the next
// tag, minus trailing whitespace; validation continues on that value, and a
// LengthFix sets L to its length.
#include "adif_lint.h"

#include "adif_spec.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>

namespace adif {
namespace {

constexpr size_t npos = std::string_view::npos;
constexpr size_t kMaxTagScan = 512;      // longest '<...>' accepted; bounds the work per '<'
constexpr size_t kMaxLengthDigits = 18;  // always fits in uint64_t

bool isWs(unsigned char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
bool isDigit(unsigned char c) { return c >= '0' && c <= '9'; }
bool isAlpha(unsigned char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
bool isAlnum(unsigned char c) { return isDigit(c) || isAlpha(c); }
unsigned char up(unsigned char c) { return (c >= 'a' && c <= 'z') ? (unsigned char)(c - 32) : c; }
bool isUtf8Continuation(unsigned char c) { return (c & 0xC0) == 0x80; }

bool allDigits(std::string_view s) {
    if (s.empty()) return false;
    for (unsigned char c : s)
        if (!isDigit(c)) return false;
    return true;
}

std::string upper(std::string_view s) {
    std::string out(s);
    for (char &c : out) c = (char)up((unsigned char)c);
    return out;
}

bool startsWithNoCase(std::string_view s, std::string_view prefix) {
    return s.size() >= prefix.size() && equalsNoCase(s.substr(0, prefix.size()), prefix);
}

// Printable, bounded rendering of data for messages.
std::string snippet(std::string_view s, size_t max = 40) {
    std::string out;
    size_t i = 0;
    for (; i < s.size() && out.size() < max; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (c == '\r') out += "\\r";
        else if (c == '\n') out += "\\n";
        else if (c == '\t') out += "\\t";
        else if (c < 32 || c == 127) {
            char b[8];
            snprintf(b, sizeof b, "\\x%02X", c);
            out += b;
        } else out += (char)c;
    }
    if (i < s.size()) {
        while (!out.empty() && isUtf8Continuation((unsigned char)out.back())) out.pop_back();
        if (!out.empty() && (unsigned char)out.back() >= 0xC0) out.pop_back();  // drop a cut lead byte
        out += "...";
    }
    return out;
}

std::string fmtNumber(double v) {
    char b[32];
    snprintf(b, sizeof b, "%g", v);
    return b;
}

// What loggers write for "no value": none, n/a, -, ?, unknown, null.
bool isPlaceholder(std::string_view v) {
    for (const char *p : {"none", "n/a", "-", "--", "---", "?", "unknown", "null"})
        if (equalsNoCase(v, p)) return true;
    return false;
}

// "HUNGARY" -> "Hungary", "UNITED STATES OF AMERICA" -> "United States Of America".
std::string titleCase(std::string_view s) {
    std::string out(s);
    bool start = true;
    for (char &c : out) {
        unsigned char u = (unsigned char)c;
        if (u >= 'A' && u <= 'Z' && !start) c = (char)(u + 32);
        start = !((u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z') || (u >= '0' && u <= '9') || u == '\'');
    }
    for (const char *small : {" Of ", " And ", " The ", " De "}) {  // "United States of America"
        for (size_t at; (at = out.find(small)) != std::string::npos;) out[at + 1] = (char)(out[at + 1] + 32);
    }
    return out;
}

// MHz for a fix: up to 6 decimals, trailing zeros dropped (14.074, not 14.074000).
std::string fmtMHz(double v) {
    char b[48];
    snprintf(b, sizeof b, "%.6f", v);
    std::string out = b;
    while (!out.empty() && out.back() == '0') out.pop_back();
    if (!out.empty() && out.back() == '.') out.pop_back();
    return out;
}

// The band a frequency (MHz) is in, or nullptr.
const BandDef *bandAt(double mhz) {
    size_t n = 0;
    const BandDef *b = bandTable(&n);
    const double kTol = 1e-9;  // edges are inclusive; absorb binary rounding of decimal MHz
    for (size_t i = 0; i < n; ++i)
        if (mhz >= b[i].lowerMHz - kTol && mhz <= b[i].upperMHz + kTol) return &b[i];
    return nullptr;
}

std::vector<std::string_view> split(std::string_view s, char sep) {
    std::vector<std::string_view> out;
    size_t b = 0;
    for (;;) {
        size_t e = s.find(sep, b);
        out.push_back(s.substr(b, e == npos ? npos : e - b));
        if (e == npos) break;
        b = e + 1;
    }
    return out;
}

// ADIF Number (§II.B): optional '-', one or more digits, at most one '.'. Parsed
// by hand because strtod is locale-sensitive (Resources §III.A).
bool parseNumber(std::string_view v, double *out) {
    size_t i = 0;
    bool neg = false, digits = false, point = false;
    double value = 0, scale = 1;
    if (i < v.size() && v[i] == '-') {
        neg = true;
        ++i;
    }
    for (; i < v.size(); ++i) {
        unsigned char c = (unsigned char)v[i];
        if (isDigit(c)) {
            digits = true;
            if (!point) value = value * 10 + (c - '0');
            else {
                scale /= 10;
                value += (c - '0') * scale;
            }
        } else if (c == '.' && !point) point = true;
        else return false;
    }
    if (!digits) return false;
    if (out) *out = neg ? -value : value;
    return true;
}

bool parseInteger(std::string_view v, bool allowMinus) {
    if (allowMinus && !v.empty() && v[0] == '-') v.remove_prefix(1);
    return allDigits(v);
}

int twoDigits(std::string_view s, size_t at) { return (s[at] - '0') * 10 + (s[at + 1] - '0'); }

// Date (§II.B): YYYYMMDD, 1930 <= YYYY, valid month and day.
const char *dateProblem(std::string_view v) {
    if (v.size() != 8 || !allDigits(v)) return "a Date is 8 digits, YYYYMMDD";
    int y = twoDigits(v, 0) * 100 + twoDigits(v, 2), m = twoDigits(v, 4), d = twoDigits(v, 6);
    if (y < 1930) return "the year must be 1930 or later";
    if (m < 1 || m > 12) return "the month must be 01-12";
    static const int kDays[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    bool leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    int dim = kDays[m - 1] + (m == 2 && leap ? 1 : 0);
    if (d < 1 || d > dim) return "the day is not in that month";
    return nullptr;
}

// Time (§II.B): HHMM or HHMMSS.
const char *timeProblem(std::string_view v) {
    if ((v.size() != 4 && v.size() != 6) || !allDigits(v)) return "a Time is HHMM or HHMMSS";
    if (twoDigits(v, 0) > 23) return "the hour must be 00-23";
    if (twoDigits(v, 2) > 59) return "the minutes must be 00-59";
    if (v.size() == 6 && twoDigits(v, 4) > 59) return "the seconds must be 00-59";
    return nullptr;
}

// GridSquare (§II.B): 2, 4, 6 or 8 character Maidenhead locator, case-insensitive.
bool isGridSquare(std::string_view v) {
    if (v.size() != 2 && v.size() != 4 && v.size() != 6 && v.size() != 8) return false;
    for (size_t i = 0; i < v.size(); ++i) {
        unsigned char c = up((unsigned char)v[i]);
        switch (i) {
            case 0: case 1: if (c < 'A' || c > 'R') return false; break;
            case 4: case 5: if (c < 'A' || c > 'X') return false; break;
            default: if (!isDigit(c)) return false; break;
        }
    }
    return true;
}

// GridSquareExt (§II.B): characters 9-10 (A-X) and optionally 11-12 (digits).
bool isGridSquareExt(std::string_view v) {
    if (v.size() != 2 && v.size() != 4) return false;
    for (size_t i = 0; i < 2; ++i) {
        unsigned char c = up((unsigned char)v[i]);
        if (c < 'A' || c > 'X') return false;
    }
    return v.size() == 2 || (isDigit((unsigned char)v[2]) && isDigit((unsigned char)v[3]));
}

// Location (§II.B): XDDD MM.MMM, X in {E,W,N,S}, 0 <= DDD <= 180, 00.000 <= MM.MMM <= 59.999.
const char *locationProblem(std::string_view v) {
    if (v.size() != 11) return "a Location is 11 characters, XDDD MM.MMM";
    unsigned char x = up((unsigned char)v[0]);
    if (x != 'N' && x != 'S' && x != 'E' && x != 'W') return "it must start with N, S, E or W";
    if (!isDigit(v[1]) || !isDigit(v[2]) || !isDigit(v[3]) || v[4] != ' ' || !isDigit(v[5]) || !isDigit(v[6]) ||
        v[7] != '.' || !isDigit(v[8]) || !isDigit(v[9]) || !isDigit(v[10]))
        return "the form is XDDD MM.MMM";
    int deg = (v[1] - '0') * 100 + twoDigits(v, 2);
    if (deg > 180) return "degrees must be 000-180";
    if ((x == 'N' || x == 'S') && deg > 90) return "a latitude cannot exceed 90 degrees";
    if (twoDigits(v, 5) > 59) return "minutes must be below 60";
    return nullptr;
}

// IOTARefNo (§II.B): CC-XXX, CC a Continent, 001 <= XXX <= 999.
bool isIota(std::string_view v) {
    if (v.size() != 6 || v[2] != '-' || !allDigits(v.substr(3))) return false;
    const EnumDef *cont = findEnum("Continent");
    if (cont && !findEnumValue(*cont, v.substr(0, 2))) return false;
    return v.substr(3) != "000";
}

// POTARef (§II.B): xxxx-nnnnn[@yyyyyy], 6-17 characters.
bool isPotaRef(std::string_view v) {
    if (v.size() < 6 || v.size() > 17) return false;
    size_t dash = v.find('-');
    if (dash == npos || dash < 1 || dash > 4) return false;
    for (size_t i = 0; i < dash; ++i)
        if (!isAlnum((unsigned char)v[i])) return false;
    std::string_view rest = v.substr(dash + 1);
    size_t at = rest.find('@');
    std::string_view number = rest.substr(0, at);
    if ((number.size() != 4 && number.size() != 5) || !allDigits(number)) return false;
    if (at == npos) return true;
    std::string_view loc = rest.substr(at + 1);
    if (loc.size() < 4 || loc.size() > 6) return false;
    for (unsigned char c : loc)
        if (!isAlnum(c) && c != '-') return false;
    return true;
}

// WWFFRef (§II.B): xxFF-nnnn, 8-11 characters, xx 1-4 characters.
bool isWwffRef(std::string_view v) {
    if (v.size() < 8 || v.size() > 11) return false;
    size_t ff = v.size() - 7;  // "FF-nnnn" is the last 7 characters
    if (ff < 1 || ff > 4) return false;
    for (size_t i = 0; i < ff; ++i)
        if (!isAlnum((unsigned char)v[i])) return false;
    return up(v[ff]) == 'F' && up(v[ff + 1]) == 'F' && v[ff + 2] == '-' && allDigits(v.substr(ff + 3));
}

// SOTARef (§II.B): association, '/', region-number, e.g. W2/WE-003, G/LD-003.
// The spec's wording is loose, so a mismatch is only a warning.
bool isSotaRef(std::string_view v) {
    size_t slash = v.find('/');
    if (slash == npos || slash == 0 || v.find('/', slash + 1) != npos) return false;
    for (size_t i = 0; i < slash; ++i)
        if (!isAlnum((unsigned char)v[i])) return false;
    std::string_view rest = v.substr(slash + 1);
    size_t dash = rest.find('-');
    if (dash == npos || dash == 0 || !allDigits(rest.substr(dash + 1))) return false;
    for (size_t i = 0; i < dash; ++i)
        if (!isAlnum((unsigned char)rest[i])) return false;
    return true;
}

enum class TagKind { Field, EOH, EOR };

struct Tag {
    size_t lt = 0, gt = 0;      // '<' and '>'
    size_t nameB = 0, nameE = 0;
    size_t lenB = 0, lenE = 0;  // length digits
    size_t typePos = npos;      // type indicator letter
    TagKind kind = TagKind::Field;
    uint64_t length = 0;
    bool overflow = false;      // more digits than we accept
};

struct Spec {
    Tag tag;
    std::string name;            // upper case
    size_t valueB = 0, valueE = 0;
    size_t cleanE = 0;           // valueE without a trailing CR/LF
    bool lengthOk = true;
};

struct UserDef {
    DataType type = DataType::String;
    std::vector<std::string> values;  // enumeration, if given
    bool hasRange = false;
    double lo = 0, hi = 0;
};

class Linter {
public:
    Linter(std::string_view text, const LintOptions &opt) : t_(text), n_(text.size()), opt_(opt) {}
    LintResult run();

private:
    using Fields = std::map<std::string, const Spec *, std::less<>>;

    std::string_view t_;
    size_t n_;
    LintOptions opt_;
    LintResult r_;

    bool startsWithLt_ = false;
    bool sawTag_ = false;
    bool sawEOH_ = false;
    bool sawRecord_ = false;
    size_t firstTag_ = 0;
    std::vector<Spec> cur_;                    // specifiers since the last <EOH>/<EOR>
    size_t groupFirstField_ = 0;               // model index of cur_[0]
    std::map<std::string, UserDef> userDefs_;  // by upper-case field name
    std::map<std::string, char> appTypes_;     // APP_ field -> indicator of first occurrence
    size_t lastDiag_ = npos;                   // index of the diagnostic just stored, npos when not stored
    std::map<std::string, size_t> stations_;   // STATION_CALLSIGN values, for the pota-station fix
    std::vector<size_t> potaStation_;          // pota-station diagnostics awaiting that fix
    // Characters mode: code points before each kCpBlock-byte block, built on first use.
    static constexpr size_t kCpBlock = 256;
    mutable std::vector<uint64_t> cpBlocks_;

    void diag(Severity s, size_t b, size_t e, std::string msg, bool structural = false);
    bool stored() const { return lastDiag_ != npos; }  // the diagnostic just made was kept
    // Give the diagnostic just made its code, field and repair (no-op when it was not stored).
    void annotate(const char *code, std::string field, std::vector<FieldFix> fixes = {}, std::string label = {}) {
        if (lastDiag_ == npos) return;
        Diagnostic &d = r_.diagnostics[lastDiag_];
        d.code = code;
        d.field = std::move(field);
        d.fixes = std::move(fixes);
        d.fixLabel = std::move(label);
    }
    static FieldFix setTo(std::string field, std::string value) {
        return FieldFix{FixKind::SetValue, std::move(field), std::move(value), kNoPos};
    }
    void diagTag(Severity s, const Spec &sp, std::string msg) { diag(s, sp.tag.lt, sp.tag.gt + 1, std::move(msg)); }
    void diagValue(Severity s, const Spec &sp, size_t valueEnd, std::string msg) {
        if (valueEnd > sp.valueB) diag(s, sp.valueB, valueEnd, std::move(msg));
        else diagTag(s, sp, std::move(msg));
    }

    std::string_view view(size_t b, size_t e) const { return t_.substr(b, e - b); }
    bool allWs(size_t b, size_t e) const;
    size_t trimEnd(size_t b, size_t e) const;
    size_t advance(size_t from, uint64_t units, LengthUnit unit) const;
    size_t advanceChars(size_t from, uint64_t units) const;
    bool consistentAt(size_t dataB, uint64_t len, LengthUnit unit, size_t next) const;
    bool parseTag(size_t lt, Tag &tag, std::string *why) const;
    size_t findNextTag(size_t from) const;
    const char *unitWord(size_t count) const;

    void ignored(size_t b, size_t e);
    bool strayTagGap(size_t b, size_t e) const;
    void closeGroup(bool header, const Tag *marker);
    size_t readField(const Tag &tag);
    void endHeader(const Tag &tag);
    void endRecord(const Tag &tag);
    void endOfFile();

    Fields index(const std::vector<Spec> &group, const char *where);
    std::string_view value(const Fields &f, const char *name) const;
    void validateHeader(const std::vector<Spec> &group);
    void defineUserField(const Spec &sp);
    void validateRecord(const std::vector<Spec> &group, const Tag *eor);
    void validateField(const Spec &sp, const Fields &f, bool inHeader);
    DataType appFieldType(const Spec &sp);
    void checkIndicator(const Spec &sp, DataType expected);
    void checkValue(const Spec &sp, DataType type, std::string_view v, size_t vEnd, const FieldDef *fd,
                    const UserDef *ud, const Fields &f);
    void checkChars(const Spec &sp, std::string_view v, size_t vEnd, bool multiline);
    void checkEnumeration(const Spec &sp, std::string_view v, size_t vEnd, const FieldDef &fd, bool strict,
                          const Fields &f);
    void checkFreqInBand(const Fields &f, const char *freqName, const char *bandName);
    void checkPractice(const std::vector<Spec> &group, const Fields &f, const Tag *eor);
};

void Linter::diag(Severity s, size_t b, size_t e, std::string msg, bool structural) {
    if (n_ == 0) return;
    if (b >= n_) b = n_ - 1;
    if (e > n_) e = n_;
    if (e <= b) e = b + 1;
    switch (s) {
        case Severity::Error: ++r_.errors; break;
        case Severity::Warning: ++r_.warnings; break;
        case Severity::Info: ++r_.infos; break;
    }
    if (structural && s == Severity::Error) ++r_.structuralErrors;
    lastDiag_ = npos;
    if (r_.diagnostics.size() >= opt_.maxDiagnostics) {
        r_.truncated = true;
        return;
    }
    Diagnostic d;
    d.start = b, d.end = e, d.severity = s, d.structural = structural, d.message = std::move(msg);
    r_.diagnostics.push_back(std::move(d));
    lastDiag_ = r_.diagnostics.size() - 1;
}

bool Linter::allWs(size_t b, size_t e) const {
    for (size_t i = b; i < e; ++i)
        if (!isWs((unsigned char)t_[i])) return false;
    return true;
}

size_t Linter::trimEnd(size_t b, size_t e) const {
    while (e > b && isWs((unsigned char)t_[e - 1])) --e;
    return e;
}

// Position after `units` units of data starting at `from`, or npos past the end.
size_t Linter::advance(size_t from, uint64_t units, LengthUnit unit) const {
    if (units > n_ - from) return npos;  // every unit is at least one byte
    if (unit == LengthUnit::Bytes || !opt_.utf8) return from + (size_t)units;
    return advanceChars(from, units);
}

// A character is counted at each byte that is not a UTF-8 continuation byte
// (so malformed sequences still advance). A block index keeps each lookup at
// O(log n + kCpBlock) instead of walking the data, which matters when a file
// is full of wrong, large lengths.
size_t Linter::advanceChars(size_t from, uint64_t units) const {
    if (units == 0) return from;
    if (cpBlocks_.empty()) {
        cpBlocks_.reserve(n_ / kCpBlock + 2);
        uint64_t c = 0;
        for (size_t i = 0; i < n_; ++i) {
            if (i % kCpBlock == 0) cpBlocks_.push_back(c);
            c += !isUtf8Continuation((unsigned char)t_[i]);
        }
        cpBlocks_.push_back(c);  // sentinel: total, for the block starting at n_ (rounded up)
    }
    size_t blockStart = from - from % kCpBlock;
    uint64_t before = cpBlocks_[from / kCpBlock];
    for (size_t i = blockStart; i < from; ++i) before += !isUtf8Continuation((unsigned char)t_[i]);
    uint64_t target = before + units;  // the end is the start of character number `target`
    if (target > cpBlocks_.back()) return npos;
    if (target == cpBlocks_.back()) return n_;
    size_t k = (size_t)(std::upper_bound(cpBlocks_.begin(), cpBlocks_.end() - 1, target) - cpBlocks_.begin()) - 1;
    uint64_t c = cpBlocks_[k];
    for (size_t i = k * kCpBlock; i < n_; ++i) {
        if (isUtf8Continuation((unsigned char)t_[i])) continue;
        if (c == target) return i;
        ++c;
    }
    return n_;
}

// Would a length of `len` units be consistent (see the file comment)?
bool Linter::consistentAt(size_t dataB, uint64_t len, LengthUnit unit, size_t next) const {
    size_t end = advance(dataB, len, unit);
    if (end == npos) return false;
    if (end <= next) return allWs(end, next);
    return allWs(end, findNextTag(end));
}

// Parse the tag starting at '<' (lt). Returns false for text that is not a
// well-formed <F:L[:T]>, <EOH> or <EOR>; `why` (optional) says what is wrong.
bool Linter::parseTag(size_t lt, Tag &tag, std::string *why) const {
    tag = Tag{};
    tag.lt = tag.gt = lt;
    size_t limit = std::min(n_, lt + kMaxTagScan);
    size_t gt = npos;
    for (size_t i = lt + 1; i < limit; ++i) {
        unsigned char c = (unsigned char)t_[i];
        if (c == '>') {
            gt = i;
            break;
        }
        if (c == '<' || c == '\r' || c == '\n') break;
    }
    if (gt == npos) {
        if (why) *why = "it is not closed by '>'";
        return false;
    }
    tag.gt = gt;
    std::string_view inner = view(lt + 1, gt);
    size_t c1 = inner.find(':');
    std::string_view name = inner.substr(0, c1);
    tag.nameB = lt + 1;
    tag.nameE = tag.nameB + name.size();
    if (equalsNoCase(name, "EOH") || equalsNoCase(name, "EOR")) {
        tag.kind = equalsNoCase(name, "EOH") ? TagKind::EOH : TagKind::EOR;
        if (c1 == npos) return true;
        if (why) *why = "<EOH> and <EOR> take no length";
        return false;
    }
    if (c1 == npos) {
        if (why) *why = inner.empty() ? "it is empty" : "it has no data length (expected <NAME:LENGTH>)";
        return false;
    }
    if (name.empty()) {
        if (why) *why = "it has no field name";
        return false;
    }
    for (unsigned char c : name) {
        if (c < 32 || c == 127 || c == ',' || c == '{' || c == '}') {
            if (why) *why = "the field name contains a character that is not allowed";
            return false;
        }
    }
    if (name.front() == ' ' || name.back() == ' ') {
        if (why) *why = "the field name begins or ends with a space";
        return false;
    }
    size_t c2 = inner.find(':', c1 + 1);
    std::string_view len = inner.substr(c1 + 1, c2 == npos ? npos : c2 - c1 - 1);
    tag.lenB = tag.nameE + 1;
    tag.lenE = tag.lenB + len.size();
    if (!allDigits(len)) {
        if (why) *why = len.empty() ? "it has no data length" : "the data length must be an unsigned whole number";
        return false;
    }
    if (len.size() > kMaxLengthDigits) {
        tag.overflow = true;
    } else {
        for (unsigned char c : len) tag.length = tag.length * 10 + (c - '0');
    }
    if (c2 != npos) {
        std::string_view type = inner.substr(c2 + 1);
        if (type.size() != 1 || !isAlpha((unsigned char)type[0])) {
            if (why) *why = "the data type indicator must be a single letter";
            return false;
        }
        tag.typePos = tag.lenE + 1;
    }
    tag.kind = TagKind::Field;
    return true;
}

size_t Linter::findNextTag(size_t from) const {
    Tag tag;
    while (from < n_) {
        const void *hit = memchr(t_.data() + from, '<', n_ - from);
        if (!hit) return n_;
        size_t lt = (size_t)((const char *)hit - t_.data());
        if (parseTag(lt, tag, nullptr)) return lt;
        from = lt + 1;
    }
    return n_;
}

const char *Linter::unitWord(size_t count) const {
    bool chars = opt_.lengthUnit == LengthUnit::Characters && opt_.utf8;
    if (count == 1) return chars ? "character" : "byte";
    return chars ? "characters" : "bytes";
}

LintResult Linter::run() {
    if (n_ >= 3 && (unsigned char)t_[0] == 0xEF && (unsigned char)t_[1] == 0xBB && (unsigned char)t_[2] == 0xBF)
        diag(Severity::Warning, 0, 3,
             "UTF-8 byte-order mark at the start of the file. ADI files are ASCII (§II.B); some importers reject it.");
    if (n_ >= 3 && (unsigned char)t_[0] == 0xEF && (unsigned char)t_[1] == 0xBB && (unsigned char)t_[2] == 0xBF)
        annotate("bom", "", {FieldFix{FixKind::DeleteText, "", "", kNoPos}}, "remove the byte-order mark");
    startsWithLt_ = n_ > 0 && t_[0] == '<';
    r_.model.hasBom = n_ >= 3 && (unsigned char)t_[0] == 0xEF && (unsigned char)t_[1] == 0xBB &&
                      (unsigned char)t_[2] == 0xBF;

    size_t pos = 0;
    size_t textStart = 0;  // end of the last specifier or marker: text from here on is outside them
    while (pos < n_) {
        const void *hit = memchr(t_.data() + pos, '<', n_ - pos);
        if (!hit) break;
        size_t lt = (size_t)((const char *)hit - t_.data());

        Tag tag;
        std::string why;
        if (!parseTag(lt, tag, &why)) {
            if (r_.diagnostics.size() >= opt_.maxDiagnostics) {  // only counting now: skip the message
                diag(Severity::Warning, lt, lt + 1, std::string());
                pos = lt + 1;
                continue;
            }
            // Errors for things meant as specifiers; warnings for stray '<' in text.
            size_t innerEnd = tag.gt;
            if (tag.gt == lt) {  // unclosed: look as far as the scan did
                innerEnd = lt + 1;
                while (innerEnd < std::min(n_, lt + kMaxTagScan) && t_[innerEnd] != '<' && t_[innerEnd] != '\r' &&
                       t_[innerEnd] != '\n')
                    ++innerEnd;
            }
            std::string_view inner = view(lt + 1, innerEnd);
            bool meant = inner.find(':') != npos || findField(inner) != nullptr || tag.kind != TagKind::Field;
            size_t end = tag.gt > lt ? tag.gt + 1 : lt + 1;
            diag(meant ? Severity::Error : Severity::Warning, lt, end,
                 "'" + snippet(view(lt, end)) + "' is not a valid data specifier: " + why + ".", meant);
            pos = lt + 1;
            continue;
        }
        ignored(textStart, lt);
        if (!sawTag_) {
            sawTag_ = true;
            firstTag_ = lt;
            r_.model.firstTag = lt;
        }
        if (tag.kind == TagKind::EOH) {
            endHeader(tag);
            pos = tag.gt + 1;
        } else if (tag.kind == TagKind::EOR) {
            endRecord(tag);
            pos = tag.gt + 1;
        } else {
            pos = readField(tag);
        }
        textStart = pos;
    }
    ignored(textStart, n_);
    endOfFile();

    // pota-station: the log's usual STATION_CALLSIGN is the repair, when it has one.
    std::string usual;
    size_t most = 0;
    for (const auto &[call, n] : stations_)
        if (n > most) most = n, usual = call;
    if (!usual.empty())
        for (size_t i : potaStation_) {
            r_.diagnostics[i].fixes = {setTo("STATION_CALLSIGN", usual)};
            r_.diagnostics[i].fixLabel = "STATION_CALLSIGN " + usual;
        }

    std::stable_sort(r_.diagnostics.begin(), r_.diagnostics.end(), [](const Diagnostic &a, const Diagnostic &b) {
        if (a.start != b.start) return a.start < b.start;
        return a.severity > b.severity;
    });
    std::sort(r_.fixes.begin(), r_.fixes.end(),
              [](const LengthFix &a, const LengthFix &b) { return a.start < b.start; });
    return std::move(r_);
}

// Text between specifiers. A header may hold arbitrary text (§IV.A.3) and text
// between records is explicitly allowed and ignored (§IV.A.6), so it is only
// flagged when it contains what looks like a data specifier missing its '<'
// (e.g. "CALL:4>WF1B"): that data is silently lost on import.
void Linter::ignored(size_t b, size_t e) {
    if (b >= e) return;
    if (!sawTag_ && b == 0 && r_.model.hasBom) b = 3;
    size_t s = b;
    while (s < e && isWs((unsigned char)t_[s])) ++s;
    size_t se = trimEnd(s, e);
    if (opt_.buildModel && s < se) {
        if (!sawTag_) {
            r_.model.headerTextB = s;
            r_.model.headerTextE = se;
        } else {
            r_.model.otherText.emplace_back(s, se);
        }
    }
    if (!sawTag_) return;
    if (!sawEOH_ && !sawRecord_ && !startsWithLt_) return;  // still inside a possible header
    for (size_t gt = b; gt < e; ++gt) {
        if (t_[gt] != '>') continue;
        // Walk back over [:letter] digits ':' name.
        size_t i = gt;
        if (i >= b + 2 && isAlpha((unsigned char)t_[i - 1]) && t_[i - 2] == ':') i -= 2;
        size_t digitsEnd = i;
        while (i > b && isDigit((unsigned char)t_[i - 1])) --i;
        if (i == digitsEnd || i == b || t_[i - 1] != ':') continue;
        size_t nameEnd = --i;
        while (i > b && (isAlnum((unsigned char)t_[i - 1]) || t_[i - 1] == '_')) --i;
        if (i == nameEnd) continue;
        diag(Severity::Warning, i, gt + 1,
             "'" + snippet(view(i, gt + 1)) + "' looks like a data specifier without its '<', so importers ignore it "
             "and its data (§IV.A.6).");
        return;
    }
}

// Non-blank text after the declared data that starts with '<' is a malformed
// tag (reported separately), not data the length forgot: "<CALL:4>WF1B <grin>".
bool Linter::strayTagGap(size_t b, size_t e) const {
    while (b < e && isWs((unsigned char)t_[b])) ++b;
    return b < e && t_[b] == '<';
}

void Linter::closeGroup(bool header, const Tag *marker) {
    if (opt_.buildModel) {
        ModelGroup g;
        g.header = header;
        g.firstField = groupFirstField_;
        g.fieldCount = r_.model.fields.size() - groupFirstField_;
        if (marker) {
            g.markerB = marker->lt;
            g.markerE = marker->gt + 1;
        }
        r_.model.groups.push_back(g);
        groupFirstField_ = r_.model.fields.size();
    }
    cur_.clear();
}

size_t Linter::readField(const Tag &tag) {
    Spec sp;
    sp.tag = tag;
    sp.name = upper(view(tag.nameB, tag.nameE));
    const size_t dataB = tag.gt + 1;
    const size_t declaredEnd = tag.overflow ? npos : advance(dataB, tag.length, opt_.lengthUnit);
    const size_t next = findNextTag(dataB);
    std::string_view digits = view(tag.lenB, tag.lenE);

    bool ok;
    bool swallows = false;
    if (declaredEnd != npos && declaredEnd <= next) {
        ok = allWs(declaredEnd, next) || strayTagGap(declaredEnd, next);
    } else {
        ok = declaredEnd != npos && allWs(declaredEnd, findNextTag(declaredEnd));
        swallows = ok;  // consistent, but the data contains a well-formed tag
    }

    size_t resume;
    if (ok) {
        sp.valueB = dataB;
        sp.valueE = declaredEnd;
        resume = declaredEnd;
        if (digits.size() > 1 && digits[0] == '0') {
            diag(Severity::Warning, tag.lenB, tag.lenE,
                 "Leading zeros in a data length are import-only (Resources §III.B); exporters must not write them.");
            annotate("length", upper(view(tag.nameB, tag.nameE)), {}, "Fix Lengths");
            r_.fixes.push_back(LengthFix{tag.lenB, tag.lenE, std::to_string(tag.length)});
        }
        if (swallows) {
            Tag inner;
            parseTag(next, inner, nullptr);
            diag(Severity::Warning, dataB, declaredEnd,
                 "The data contains '" + snippet(view(next, inner.gt + 1)) +
                     "', which looks like a data specifier. If this length is too long, that field is lost.");
        }
    } else {
        sp.lengthOk = false;
        sp.valueB = dataB;
        sp.valueE = trimEnd(dataB, next);
        resume = next;
        std::string_view intended = view(sp.valueB, sp.valueE);
        size_t want = measureLength(intended, opt_.lengthUnit, opt_.utf8);
        std::string msg = "Length " + std::string(digits) + " does not match the data '" + snippet(intended) + "' (" +
                          std::to_string(want) + " " + unitWord(want) + ").";
        if (declaredEnd == npos) {
            msg += " It runs past the end of the file.";
        } else if (declaredEnd <= next) {
            msg += " Importers read only '" + snippet(view(dataB, declaredEnd)) + "'.";
        } else {
            msg += " Importers also read '" + snippet(view(next, declaredEnd)) + "', swallowing what follows.";
        }
        bool nonAscii = false;
        for (unsigned char c : intended) nonAscii |= c >= 0x80;
        if (nonAscii && opt_.utf8 && !tag.overflow) {
            LengthUnit other = opt_.lengthUnit == LengthUnit::Bytes ? LengthUnit::Characters : LengthUnit::Bytes;
            if (consistentAt(dataB, tag.length, other, next))
                msg += other == LengthUnit::Characters
                           ? " (It would match if lengths counted characters instead of bytes.)"
                           : " (It would match if lengths counted bytes instead of characters.)";
        }
        msg += " Fix Lengths corrects it.";
        diag(Severity::Error, tag.lt, tag.gt + 1, std::move(msg), true);
        annotate("length", upper(view(tag.nameB, tag.nameE)), {}, "Fix Lengths");
        r_.fixes.push_back(LengthFix{tag.lenB, tag.lenE, std::to_string(want)});
    }
    sp.cleanE = sp.valueE;
    while (sp.cleanE > sp.valueB && (t_[sp.cleanE - 1] == '\r' || t_[sp.cleanE - 1] == '\n')) --sp.cleanE;
    if (opt_.buildModel) {
        ModelField mf;
        mf.tagB = tag.lt;
        mf.nameE = tag.nameE;
        mf.lenB = tag.lenB;
        mf.lenE = tag.lenE;
        mf.typePos = tag.typePos == npos ? kNoPos : tag.typePos;
        mf.gt = tag.gt;
        mf.valueE = sp.valueE;
        mf.lengthOk = sp.lengthOk;
        r_.model.fields.push_back(mf);
    }
    cur_.push_back(std::move(sp));
    return resume;
}

void Linter::endHeader(const Tag &tag) {
    if (sawEOH_) {
        diag(Severity::Error, tag.lt, tag.gt + 1, "Second <EOH>: a file has only one header (§IV.A.2).", true);
    } else if (sawRecord_) {
        diag(Severity::Error, tag.lt, tag.gt + 1, "<EOH> after records: the header must come first (§IV.A.2).", true);
    } else if (startsWithLt_) {
        diag(Severity::Warning, 0, 1,
             "The file starts with '<', which means it has no header (§IV.A.3), yet <EOH> follows. "
             "Put a line of text before the first '<' so importers read these fields as the header.");
    }
    validateHeader(cur_);
    closeGroup(true, &tag);
    sawEOH_ = true;
    r_.hasHeader = true;
}

void Linter::endRecord(const Tag &tag) {
    if (cur_.empty()) {
        diag(Severity::Warning, tag.lt, tag.gt + 1, "Empty record: <EOR> with no fields before it.");
    } else {
        if (!sawEOH_ && !sawRecord_ && !startsWithLt_) {
            if (allWs(0, firstTag_) || (firstTag_ == 3 && n_ >= 3 && (unsigned char)t_[0] == 0xEF))
                diag(Severity::Info, firstTag_, firstTag_ + 1,
                     "The file does not start with '<', so strictly it begins with a header, but no <EOH> "
                     "ends it (§IV.A.3). Remove the leading whitespace or add <EOH>.");
            else
                diag(Severity::Warning, 0, trimEnd(0, firstTag_),
                     "Text before the first '<' begins a header (§IV.A.3), but no <EOH> ends it before the "
                     "first record. Add <EOH> after the header.");
        }
        validateRecord(cur_, &tag);
        ++r_.records;
    }
    sawRecord_ = true;
    closeGroup(false, &tag);
}

void Linter::endOfFile() {
    if (cur_.empty()) return;
    bool allHeaderFields = true;
    for (const Spec &sp : cur_) {
        const FieldDef *fd = findField(sp.name);
        bool userdef = startsWithNoCase(sp.name, "USERDEF");
        if (!(fd && fd->header) && !userdef) allHeaderFields = false;
    }
    const Spec &last = cur_.back();
    if (!sawEOH_ && !sawRecord_ && allHeaderFields) {
        diag(Severity::Error, last.tag.lt, last.tag.gt + 1, "The header is not ended by <EOH> (§IV.A.3).", true);
        validateHeader(cur_);
        closeGroup(true, nullptr);
    } else {
        diag(Severity::Error, last.tag.lt, last.tag.gt + 1,
             "The last record is not ended by <EOR>, so importers may drop it (§IV.A.6).");
        if (last.lengthOk)
            annotate("no-eor", "", {FieldFix{FixKind::InsertText, "", " <EOR>", last.cleanE}}, "add <EOR>");
        validateRecord(cur_, nullptr);
        closeGroup(false, nullptr);
    }
}

Linter::Fields Linter::index(const std::vector<Spec> &group, const char *where) {
    Fields f;
    for (const Spec &sp : group) {
        auto [it, added] = f.emplace(sp.name, &sp);
        if (added) continue;
        diagTag(Severity::Error, sp,
                sp.name + " appears more than once in this " + where +
                    (std::strcmp(where, "header") == 0 ? " (§III.C.1.a)." : " (§III.C.1.b)."));
        if (!stored()) continue;
        // The same value twice: removing this copy loses nothing.
        bool same = sp.lengthOk && it->second->lengthOk &&
                    view(sp.valueB, sp.cleanE) == view(it->second->valueB, it->second->cleanE);
        if (same) annotate("dup-field", sp.name, {FieldFix{FixKind::RemoveField, sp.name, "", kNoPos}}, "remove this copy");
        else annotate("dup-field", sp.name);
    }
    return f;
}

std::string_view Linter::value(const Fields &f, const char *name) const {
    auto it = f.find(name);
    if (it == f.end()) return {};
    return view(it->second->valueB, it->second->cleanE);
}

void Linter::validateHeader(const std::vector<Spec> &group) {
    Fields f = index(group, "header");
    for (const Spec &sp : group) {
        if (startsWithNoCase(sp.name, "USERDEF") && allDigits(std::string_view(sp.name).substr(7))) {
            defineUserField(sp);
            continue;
        }
        const FieldDef *fd = findField(sp.name);
        if (!fd) {
            diagTag(Severity::Warning, sp, "Unknown header field " + sp.name + ".");
            continue;
        }
        if (!fd->header) {
            diagTag(Severity::Warning, sp, sp.name + " is a QSO field, not a header field; importers may ignore it here.");
            continue;
        }
        validateField(sp, f, true);
    }
    std::string_view ver = value(f, "ADIF_VER");
    if (!ver.empty()) {
        auto parts = split(ver, '.');
        bool ok = parts.size() == 3 && allDigits(parts[0]) && parts[1].size() == 1 && allDigits(parts[1]) &&
                  parts[2].size() == 1 && allDigits(parts[2]);
        const Spec *sp = f.at("ADIF_VER");
        if (!ok)
            diagValue(Severity::Warning, *sp, sp->cleanE, "ADIF_VER should be X.Y.Z, e.g. 3.1.7.");
        else if (compareNoCase(ver, kSpecVersion) > 0 && ver.size() == std::strlen(kSpecVersion))
            diagValue(Severity::Info, *sp, sp->cleanE,
                      "The file declares ADIF " + std::string(ver) + "; these checks follow ADIF " + kSpecVersion + ".");
    }
    std::string_view ts = value(f, "CREATED_TIMESTAMP");
    if (!ts.empty()) {
        const Spec *sp = f.at("CREATED_TIMESTAMP");
        bool ok = ts.size() == 15 && ts[8] == ' ' && !dateProblem(ts.substr(0, 8)) && ts.substr(9).size() == 6 &&
                  !timeProblem(ts.substr(9));
        if (!ok)
            diagValue(Severity::Error, *sp, sp->cleanE,
                      "CREATED_TIMESTAMP must be 'YYYYMMDD HHMMSS' (15 characters, UTC).");
    }
}

// <USERDEFn:L:T>FIELDNAME[,{A,B,C}|,{low:high}]  (§IV.A.5)
void Linter::defineUserField(const Spec &sp) {
    std::string_view n = std::string_view(sp.name).substr(7);
    if (n[0] == '0')
        diagTag(Severity::Warning, sp, "In USERDEFn, n must be a positive integer without leading zeros (§IV.A.5).");
    UserDef ud;
    if (sp.tag.typePos == npos) {
        diagTag(Severity::Warning, sp, sp.name + " should give a data type indicator, e.g. <" + sp.name + ":8:N> (§IV.A.5).");
    } else {
        char ind = t_[sp.tag.typePos];
        ud.type = typeFromIndicator(ind);
        if (ud.type == DataType::Unknown) {
            diagTag(Severity::Error, sp, std::string("Unknown data type indicator '") + ind + "'.");
            ud.type = DataType::String;
        } else if (ud.type == DataType::IntlString || ud.type == DataType::IntlMultilineString) {
            diagTag(Severity::Info, sp,
                    std::string("Type ") + typeName(ud.type) + " cannot be used in ADI files (§IV.A.1), so this user "
                    "field can only carry data in ADX.");
        }
    }
    std::string_view v = view(sp.valueB, sp.cleanE);
    size_t comma = v.find(',');
    std::string_view name = v.substr(0, comma);
    if (name.empty()) {
        diagValue(Severity::Error, sp, sp.cleanE, sp.name + " does not name a field.");
        return;
    }
    if (findField(name)) {
        diagValue(Severity::Error, sp, sp.cleanE, "'" + std::string(name) + "' is an ADIF field name, so it cannot be a user-defined field (§IV.A.5).");
        return;
    }
    for (unsigned char c : name) {
        if (c == ':' || c == '<' || c == '>' || c == '{' || c == '}' || c < 32) {
            diagValue(Severity::Error, sp, sp.cleanE, "A user-defined field name may not contain , : < > { } (§IV.A.5).");
            return;
        }
    }
    if (name.front() == ' ' || name.back() == ' ') {
        diagValue(Severity::Error, sp, sp.cleanE, "A user-defined field name may not begin or end with a space (§IV.A.5).");
        return;
    }
    if (comma != npos) {
        std::string_view spec = v.substr(comma + 1);
        if (spec.size() < 2 || spec.front() != '{' || spec.back() != '}') {
            diagValue(Severity::Error, sp, sp.cleanE, "After the field name, expected ,{A,B,C} or ,{low:high} (§IV.A.5).");
        } else {
            std::string_view inner = spec.substr(1, spec.size() - 2);
            size_t colon = inner.find(':');
            if (colon != npos) {
                double lo = 0, hi = 0;
                if (!parseNumber(inner.substr(0, colon), &lo) || !parseNumber(inner.substr(colon + 1), &hi) || !(lo < hi)) {
                    diagValue(Severity::Error, sp, sp.cleanE, "A range must be {low:high} with low < high, both Numbers (§IV.A.5).");
                } else {
                    ud.hasRange = true;
                    ud.lo = lo;
                    ud.hi = hi;
                }
            } else {
                for (std::string_view item : split(inner, ',')) ud.values.emplace_back(item);
            }
        }
    }
    std::string key = upper(name);
    if (userDefs_.count(key))
        diagValue(Severity::Error, sp, sp.cleanE, "'" + std::string(name) + "' is defined by more than one USERDEF field.");
    if (opt_.buildModel) {
        char ind = sp.tag.typePos == npos ? 0 : (char)up((unsigned char)t_[sp.tag.typePos]);
        r_.model.userFields.push_back(UserFieldInfo{std::string(name), ind, ud.values});
    }
    userDefs_[key] = std::move(ud);
}

void Linter::validateRecord(const std::vector<Spec> &group, const Tag *eor) {
    Fields f = index(group, "record");
    for (const Spec &sp : group) validateField(sp, f, false);

    checkFreqInBand(f, "FREQ", "BAND");
    checkFreqInBand(f, "FREQ_RX", "BAND_RX");
    checkPractice(group, f, eor);

    // Resources §III.C: a guideline, not a rule, so only a note.
    std::string missing;
    auto need = [&](bool present, const char *what) {
        if (!present) missing += (missing.empty() ? "" : ", ") + std::string(what);
    };
    need(!value(f, "QSO_DATE").empty(), "QSO_DATE");
    need(!value(f, "TIME_ON").empty(), "TIME_ON");
    need(!value(f, "CALL").empty(), "CALL");
    need(!value(f, "BAND").empty() || !value(f, "FREQ").empty(), "BAND or FREQ");
    need(!value(f, "MODE").empty(), "MODE");
    if (!missing.empty()) {
        std::string msg = "This record has no " + missing +
                          ". ADIF's guideline minimum for a QSO is QSO_DATE, TIME_ON, CALL, BAND or FREQ, MODE (Resources §III.C).";
        if (eor) diag(Severity::Info, eor->lt, eor->gt + 1, std::move(msg));
        else diagTag(Severity::Info, group.back(), std::move(msg));
        annotate("minimum-fields", "");
    }
}

// What services and award programs expect beyond the spec's rules.
void Linter::checkPractice(const std::vector<Spec> &group, const Fields &f, const Tag *eor) {
    auto at = [&](const char *name) -> const Spec * {
        auto it = f.find(name);
        return it == f.end() ? nullptr : it->second;
    };
    auto onRecord = [&](Severity sev, std::string msg) {
        if (eor) diag(sev, eor->lt, eor->gt + 1, std::move(msg));
        else diagTag(sev, group.back(), std::move(msg));
    };
    std::string_view stationValue = value(f, "STATION_CALLSIGN");
    std::string station = stationValue.empty() ? std::string() : upper(stationValue);
    if (!station.empty()) ++stations_[station];

    // BAND missing while FREQ says it: POTA's log checker reads BAND, not FREQ
    // (docs.pota.app "ADIF for POTA reference", modified 2026-07-08).
    double mhz = 0;
    if (const Spec *fq = at("FREQ"); fq && value(f, "BAND").empty() && parseNumber(value(f, "FREQ"), &mhz)) {
        if (const BandDef *b = bandAt(mhz)) {
            diagValue(Severity::Info, *fq, fq->cleanE,
                      "No BAND; FREQ " + std::string(value(f, "FREQ")) + " MHz is in the " + b->name +
                          " band. Some services, POTA among them, read BAND only.");
            if (stored()) annotate("band-missing", "BAND", {setTo("BAND", b->name)}, std::string("BAND ") + b->name);
        }
    }

    // Callsigns and states are written in upper case by convention; some services compare them exactly.
    for (const char *name : {"CALL", "STATION_CALLSIGN", "OPERATOR", "STATE", "MY_STATE"}) {
        const Spec *sp = at(name);
        if (!sp || !sp->lengthOk) continue;
        std::string_view v = view(sp->valueB, sp->cleanE);
        bool lower = false;
        for (unsigned char c : v) lower |= c >= 'a' && c <= 'z';
        if (!lower) continue;
        diagValue(Severity::Info, *sp, sp->cleanE, std::string(name) + " '" + snippet(v) + "' is usually written in upper case.");
        if (stored()) annotate("case", name, {setTo(name, upper(v))}, upper(v));
    }

    // A date after today: POTA's checker refuses future dates (ADIF for POTA reference).
    std::string_view date = value(f, "QSO_DATE");
    if (!opt_.today.empty() && !dateProblem(date) && date > std::string_view(opt_.today)) {
        const Spec *sp = at("QSO_DATE");
        diagValue(Severity::Warning, *sp, sp->cleanE,
                  "QSO_DATE " + std::string(date) + " is after today (UTC). POTA and other services refuse future dates.");
        annotate("future-date", "QSO_DATE");
    }

    // Satellites: LoTW matches a satellite QSO by PROP_MODE SAT and SAT_NAME
    // (lotw.arrl.org/lotw-help/satellite-qsos, checked 2026-10-09).
    std::string_view prop = value(f, "PROP_MODE"), sat = value(f, "SAT_NAME");
    if (equalsNoCase(prop, "SAT") && sat.empty()) {
        const Spec *sp = at("PROP_MODE");
        diagValue(Severity::Info, *sp, sp->cleanE, "PROP_MODE is SAT but SAT_NAME is missing; LoTW needs both for a satellite QSO.");
        annotate("sat-name", "SAT_NAME");
    } else if (!sat.empty() && !equalsNoCase(prop, "SAT")) {
        const Spec *sp = at("SAT_NAME");
        diagValue(Severity::Warning, *sp, sp->cleanE,
                  prop.empty() ? std::string("SAT_NAME is set but PROP_MODE is missing; LoTW needs PROP_MODE SAT for a satellite QSO.")
                               : "SAT_NAME is set but PROP_MODE is " + std::string(prop) + "; a satellite QSO is PROP_MODE SAT.");
        annotate("sat-prop", "PROP_MODE", {setTo("PROP_MODE", "SAT")}, "PROP_MODE SAT");
    }

    // POTA activation records need STATION_CALLSIGN or OPERATOR (ADIF for POTA reference).
    bool pota = !value(f, "MY_POTA_REF").empty() || equalsNoCase(value(f, "MY_SIG"), "POTA");
    if (pota && station.empty() && value(f, "OPERATOR").empty()) {
        onRecord(Severity::Info, "POTA needs STATION_CALLSIGN or OPERATOR in each record of an activation log.");
        annotate("pota-station", "STATION_CALLSIGN");
        if (lastDiag_ != npos) potaStation_.push_back(lastDiag_);
    }
}

void Linter::checkIndicator(const Spec &sp, DataType expected) {
    if (sp.tag.typePos == npos) return;
    char ind = t_[sp.tag.typePos];
    DataType given = typeFromIndicator(ind);
    if (given == DataType::Unknown)
        diagTag(Severity::Error, sp, std::string("Unknown data type indicator '") + ind + "'.");
    else if (given != expected)
        diagTag(Severity::Warning, sp,
                std::string("Type indicator '") + ind + "' (" + typeName(given) + ") does not match " + sp.name +
                    ", which is " + typeName(expected) + ".");
}

DataType Linter::appFieldType(const Spec &sp) {
    std::string_view rest = std::string_view(sp.name).substr(4);
    size_t us = rest.find('_');
    if (us == npos || us == 0 || us + 1 >= rest.size())
        diagTag(Severity::Warning, sp, "Application-defined fields are named APP_PROGRAMID_FIELDNAME (§IV.A.4).");
    char ind = sp.tag.typePos != npos ? (char)up((unsigned char)t_[sp.tag.typePos]) : 0;
    auto it = appTypes_.find(sp.name);
    if (it == appTypes_.end()) {
        appTypes_[sp.name] = ind;
        if (opt_.buildModel) r_.model.appFields.emplace_back(sp.name, ind);
    } else if (ind && it->second && ind != it->second) {
        diagTag(Severity::Error, sp,
                std::string("This APP_ field was first typed '") + it->second + "'; later occurrences must not change "
                "the type (§IV.A.4).");
    } else if (!ind) {
        ind = it->second;
    }
    if (!ind) return DataType::MultilineString;  // no indicator: MultilineString (§IV.A.4)
    DataType t = typeFromIndicator(ind);
    if (t == DataType::Unknown) diagTag(Severity::Error, sp, std::string("Unknown data type indicator '") + ind + "'.");
    return t;
}

void Linter::validateField(const Spec &sp, const Fields &f, bool inHeader) {
    const FieldDef *fd = findField(sp.name);
    const UserDef *ud = nullptr;
    DataType type;
    if (fd) {
        type = fd->type;
        if (fd->header && !inHeader)
            diagTag(Severity::Warning, sp, sp.name + " is a header field; it does not belong in a record.");
        if (fd->importOnly)
            diagTag(Severity::Warning, sp, sp.name + " is import-only (deprecated); exporters must not write it.");
        checkIndicator(sp, type);
    } else if (startsWithNoCase(sp.name, "USERDEF") && allDigits(std::string_view(sp.name).substr(7))) {
        diagTag(Severity::Warning, sp, sp.name + " defines a user field and belongs in the header (§IV.A.5).");
        return;
    } else if (startsWithNoCase(sp.name, "APP_")) {
        type = appFieldType(sp);
    } else if (auto it = userDefs_.find(sp.name); it != userDefs_.end()) {
        ud = &it->second;
        type = ud->type;
        checkIndicator(sp, type);
    } else {
        diagTag(Severity::Warning, sp,
                "Unknown field " + sp.name + ": not an ADIF " + kSpecVersion +
                    " field, not APP_..., and not defined by a USERDEFn header field.");
        return;
    }
    if (type == DataType::Unknown) return;
    if (type == DataType::IntlString || type == DataType::IntlMultilineString) {
        diagTag(Severity::Error, sp,
                sp.name + " is " + typeName(type) + ", which ADI files cannot carry (§IV.A.1). Use the field without "
                "_INTL, or an ADX file.");
        return;
    }

    size_t vEnd = sp.valueE;
    if (sp.lengthOk && sp.cleanE < sp.valueE && type != DataType::MultilineString) {
        size_t want = measureLength(view(sp.valueB, sp.cleanE), opt_.lengthUnit, opt_.utf8);
        diagTag(Severity::Error, sp,
                "The data ends with a line break, so length " + std::string(view(sp.tag.lenB, sp.tag.lenE)) +
                    " is probably too long; it should be " + std::to_string(want) + ". Fix Lengths corrects it.");
        annotate("length", sp.name, {}, "Fix Lengths");
        r_.fixes.erase(std::remove_if(r_.fixes.begin(), r_.fixes.end(),
                                      [&](const LengthFix &x) { return x.start == sp.tag.lenB; }),
                       r_.fixes.end());
        r_.fixes.push_back(LengthFix{sp.tag.lenB, sp.tag.lenE, std::to_string(want)});
        vEnd = sp.cleanE;
    }
    std::string_view v = view(sp.valueB, vEnd);
    if (v.empty()) return;  // no data: the field's default applies (§III.C.1.b)
    checkValue(sp, type, v, vEnd, fd, ud, f);
}

void Linter::checkChars(const Spec &sp, std::string_view v, size_t vEnd, bool multiline) {
    bool nonAscii = false, control = false, bareBreak = false;
    unsigned char bad = 0;
    for (size_t i = 0; i < v.size(); ++i) {
        unsigned char c = (unsigned char)v[i];
        if (c >= 0x80) nonAscii = true;
        else if (multiline && c == '\r' && i + 1 < v.size() && v[i + 1] == '\n') ++i;
        else if (multiline && (c == '\r' || c == '\n')) bareBreak = true;
        else if (c < 32 || c == 127) {
            if (!control) bad = c;
            control = true;
        }
    }
    if (control) {
        char b[8];
        snprintf(b, sizeof b, "0x%02X", bad);
        diagValue(Severity::Error, sp, vEnd,
                  std::string("Control character ") + b + " is not allowed in " + (multiline ? "a MultilineString" : "a String") +
                      (multiline ? "; only CR LF line breaks are (§II.B)." : "; only ASCII 32-126 is (§II.B)."));
    }
    if (bareBreak)
        diagValue(Severity::Warning, sp, vEnd, "Line breaks in a MultilineString must be CR LF (§II.B); this one is a bare CR or LF.");
    if (nonAscii)
        diagValue(Severity::Warning, sp, vEnd,
                  "Non-ASCII text. ADI fields are ASCII only (§II.B), and programs disagree on whether such lengths "
                  "count bytes or characters. International text belongs in _INTL fields in ADX files.");
}

void Linter::checkEnumeration(const Spec &sp, std::string_view v, size_t vEnd, const FieldDef &fd, bool strict,
                              const Fields &f) {
    // DARC_DOK names no table (its values are an external list); Country is named
    // but not tabulated in the spec. Neither can be checked here.
    const EnumDef *e = fd.enumeration ? findEnum(fd.enumeration) : nullptr;
    if (!e) return;
    const bool dxccCodes = equalsNoCase(e->name, "DXCC_Entity_Code");
    auto normalize = [](std::string_view s) {
        if (allDigits(s)) {
            size_t z = 0;
            while (z + 1 < s.size() && s[z] == '0') ++z;
            s.remove_prefix(z);
        }
        return std::string(s);
    };
    std::string key = dxccCodes ? normalize(v) : std::string(v);
    auto importOnly = [&](const EnumValue *ev) {
        if (!ev->importOnly) return;
        std::string msg = "'" + std::string(v) + "' is an import-only (deprecated) " + sp.name + " value; exporters must not write it.";
        if (ev->note) msg += std::string(" Spec: ") + ev->note;
        diagValue(Severity::Warning, sp, vEnd, std::move(msg));
        // The spec names the new code ("replaced by CMX" for Mexico's DF).
        std::string_view note = ev->note ? std::string_view(ev->note) : std::string_view();
        if (startsWithNoCase(note, "replaced by ")) {
            std::string to(note.substr(12));
            if (!to.empty() && to.find(' ') == std::string::npos)
                annotate("import-only", sp.name, {setTo(sp.name, to)}, sp.name + " " + to);
        }
    };

    if (fd.enumKey) {
        const bool submode = equalsNoCase(e->name, "Submode");
        std::string scope = normalize(value(f, fd.enumKey));
        if (scope.empty()) {
            if (submode) {
                if (const EnumValue *ev = findEnumValue(*e, key)) {
                    diagValue(Severity::Warning, sp, vEnd,
                              "SUBMODE is set but MODE is missing; " + std::string(v) + " belongs to MODE " + ev->scope + ".");
                    annotate("mode-missing", "MODE", {setTo("MODE", ev->scope)}, std::string("MODE ") + ev->scope);
                } else
                    diagValue(Severity::Info, sp, vEnd, "'" + std::string(v) + "' is not a registered ADIF submode.");
            }
            return;
        }
        if (const EnumValue *ev = findEnumValue(*e, key, scope)) {
            importOnly(ev);
            return;
        }
        if (submode) {
            if (const EnumValue *other = findEnumValue(*e, key)) {
                diagValue(Severity::Error, sp, vEnd,
                          "SUBMODE " + std::string(v) + " belongs to MODE " + other->scope + ", not " + scope + ".");
                annotate("submode-mode", "MODE", {setTo("MODE", other->scope)}, std::string("MODE ") + other->scope);
            } else
                diagValue(Severity::Info, sp, vEnd,
                          "'" + std::string(v) + "' is not a registered ADIF submode of MODE " + scope + ".");
            return;
        }
        if (enumHasScope(*e, scope)) {
            // A code ADIF doesn't list for this entity: often a callbook's free text (QRZ.com
            // fills STATE from the other station's profile). Uploads still work, so a warning.
            bool keep = r_.diagnostics.size() < opt_.maxDiagnostics;
            std::string msg = "'" + std::string(v) + "' is not one of ADIF's " + sp.name + " codes for ";
            const char *country = dxccEntityName(scope);
            msg += (country ? titleCase(country) + " (DXCC " + scope + ")" : "DXCC entity " + scope);
            if (keep) {
                std::string codes;
                size_t n = 0;
                const char *previous = "";
                for (size_t i = 0; i < e->count; ++i) {  // sorted, so a repeated code is adjacent
                    const EnumValue &x = e->values[i];
                    if (!x.scope || scope != x.scope || x.importOnly || std::strcmp(x.value, previous) == 0) continue;
                    previous = x.value;
                    if (n++ < 10) codes += (codes.empty() ? "" : ", ") + std::string(x.value);
                }
                if (n) msg += ", which are " + codes + (n > 10 ? " and " + std::to_string(n - 10) + " more" : std::string()) +
                              " (ADIF " + e->name + ")";
            }
            msg += ".";
            diagValue(Severity::Warning, sp, vEnd, std::move(msg));
            if (stored()) {
                annotate("subdivision", sp.name, {FieldFix{FixKind::RemoveField, sp.name, "", kNoPos}},
                         "remove " + sp.name + " " + std::string(v));
                r_.diagnostics[lastDiag_].dropsData = true;
            }
        }
        return;
    }

    // A MODE that is really a submode (USB, FT4, JS8, PSK31...): MODE its mode, SUBMODE the value.
    auto submodeFix = [&]() {
        if (sp.name != "MODE") return;
        const EnumDef *sub = findEnum("Submode");
        const EnumValue *sv = sub ? findEnumValue(*sub, v) : nullptr;
        if (!sv || !sv->scope) return;
        std::string_view current = value(f, "SUBMODE");
        if (!current.empty() && !equalsNoCase(current, sv->value)) return;
        annotate("mode-is-submode", "MODE", {setTo("MODE", sv->scope), setTo("SUBMODE", sv->value)},
                 std::string("MODE ") + sv->scope + ", SUBMODE " + sv->value);
    };
    const EnumValue *ev = findEnumValue(*e, key);
    if (!ev) {
        if (strict)
            diagValue(Severity::Error, sp, vEnd,
                      "'" + std::string(v) + "' is not a valid " + sp.name + " (ADIF " + kSpecVersion + " " + e->name +
                          " enumeration).");
        else
            diagValue(Severity::Info, sp, vEnd, "'" + std::string(v) + "' is not in ADIF's " + e->name + " list.");
        submodeFix();
        // A Field Day class (1D, 2A, 12F) in ARRL_SECT: no section looks like that; it is CLASS.
        bool fieldDayClass = v.size() >= 2 && v.size() <= 3 && allDigits(v.substr(0, v.size() - 1)) &&
                             std::strchr("ABCDEFabcdef", v.back()) != nullptr;
        if (sp.name == "ARRL_SECT" && fieldDayClass && value(f, "CLASS").empty())
            annotate("field-day-class", "ARRL_SECT", {setTo("CLASS", upper(v)), FieldFix{FixKind::RemoveField, "ARRL_SECT", "", kNoPos}},
                     "move to CLASS " + upper(v));
        return;
    }
    importOnly(ev);
    if (ev->importOnly) submodeFix();
}

void Linter::checkValue(const Spec &sp, DataType type, std::string_view v, size_t vEnd, const FieldDef *fd,
                        const UserDef *ud, const Fields &f) {
    auto bad = [&](Severity s, const std::string &why) {
        diagValue(s, sp, vEnd, "'" + snippet(v) + "' is not a valid " + typeName(type) + " for " + sp.name + ": " + why + ".");
    };
    auto range = [&](double x) {
        bool hasMin = (fd && fd->hasMin) || (ud && ud->hasRange);
        bool hasMax = (fd && fd->hasMax) || (ud && ud->hasRange);
        double lo = fd ? fd->minValue : ud ? ud->lo : 0;
        double hi = fd ? fd->maxValue : ud ? ud->hi : 0;
        if ((hasMin && x < lo) || (hasMax && x > hi)) {
            std::string limits = hasMin && hasMax ? fmtNumber(lo) + " to " + fmtNumber(hi)
                                 : hasMin       ? "at least " + fmtNumber(lo)
                                                : "at most " + fmtNumber(hi);
            diagValue(Severity::Error, sp, vEnd, sp.name + " must be " + limits + "; got " + snippet(v) + ".");
        }
    };

    // A placeholder in a field that isn't free text ("none" for IOTA): the field means nothing,
    // so leaving it out loses nothing. Not for an enumeration that has the value.
    if (type != DataType::String && type != DataType::MultilineString && isPlaceholder(v)) {
        const EnumDef *e = fd && fd->enumeration ? findEnum(fd->enumeration) : nullptr;
        if (!(e && findEnumValue(*e, v))) {
            diagValue(Severity::Warning, sp, vEnd,
                      "'" + std::string(v) + "' in " + sp.name + " says there is no value; ADIF leaves the field out instead.");
            annotate("placeholder", sp.name, {FieldFix{FixKind::RemoveField, sp.name, "", kNoPos}}, "remove " + sp.name);
            return;
        }
    }

    switch (type) {
        case DataType::String:
        case DataType::SecondarySubdivisionList:
        case DataType::SecondaryAdministrativeSubdivisionListAlt:
            checkChars(sp, v, vEnd, false);
            break;
        case DataType::MultilineString:
            checkChars(sp, v, vEnd, true);
            break;
        case DataType::Character:
            if (v.size() != 1 || (unsigned char)v[0] < 32 || (unsigned char)v[0] > 126) bad(Severity::Error, "expected one ASCII character");
            break;
        case DataType::Digit:
            if (v.size() != 1 || !isDigit((unsigned char)v[0])) bad(Severity::Error, "expected one digit");
            break;
        case DataType::Boolean:
            if (v.size() != 1 || std::strchr("YyNn", v[0]) == nullptr) bad(Severity::Error, "expected Y or N");
            break;
        case DataType::Integer:
        case DataType::PositiveInteger: {
            bool positive = type == DataType::PositiveInteger;
            double x = 0;
            if (!parseInteger(v, !positive) || !parseNumber(v, &x)) bad(Severity::Error, positive ? "expected digits only" : "expected digits with an optional leading minus");
            else if (positive && x <= 0) bad(Severity::Error, "it must be greater than 0");
            else range(x);
            break;
        }
        case DataType::Number: {
            double x = 0;
            if (!parseNumber(v, &x)) {
                bad(Severity::Error, "expected digits with an optional '-' and at most one '.' (no '+' or ',')");
                // Power with its unit (WSJT-X writes what you type: 30W, 5 w, 1.5kW): ADIF wants watts.
                if ((sp.name == "TX_PWR" || sp.name == "RX_PWR") && stored()) {
                    std::string_view num = v, unit;
                    size_t at = 0;
                    while (at < num.size() && (isDigit((unsigned char)num[at]) || num[at] == '.')) ++at;
                    unit = num.substr(at);
                    num = num.substr(0, at);
                    while (!unit.empty() && unit.front() == ' ') unit.remove_prefix(1);
                    double w = 0;
                    bool kilo = equalsNoCase(unit, "kW");
                    bool watts = kilo || equalsNoCase(unit, "W") || equalsNoCase(unit, "watt") || equalsNoCase(unit, "watts");
                    if (watts && parseNumber(num, &w)) {
                        std::string value = kilo ? fmtMHz(w * 1000) : std::string(num);
                        annotate("power-unit", sp.name, {setTo(sp.name, value)}, sp.name + " " + value);
                    }
                }
            } else {
                range(x);
            }
            break;
        }
        case DataType::Date:
            if (const char *why = dateProblem(v)) {
                bad(Severity::Error, why);
                // 2026-10-06, 2026/10/06, 2026.10.06: year first, so the order is not in doubt.
                std::string digits;
                for (char c : v)
                    if (isDigit((unsigned char)c)) digits += c;
                bool yearFirst = v.size() == 10 && allDigits(v.substr(0, 4)) && std::strchr("-/.", v[4]) && v[7] == v[4];
                if (yearFirst && !dateProblem(digits)) annotate("date-format", sp.name, {setTo(sp.name, digits)}, digits);
                else annotate("date-format", sp.name);
            }
            break;
        case DataType::Time:
            if (const char *why = timeProblem(v)) {
                bad(Severity::Error, why);
                // 22:30 or 22:30:15.
                std::string digits;
                bool colons = (v.size() == 5 && v[2] == ':') || (v.size() == 8 && v[2] == ':' && v[5] == ':');
                for (char c : v)
                    if (isDigit((unsigned char)c)) digits += c;
                if (colons && !timeProblem(digits)) annotate("time-format", sp.name, {setTo(sp.name, digits)}, digits);
                else annotate("time-format", sp.name);
            }
            break;
        case DataType::Enumeration:
            checkChars(sp, v, vEnd, false);  // enumeration values are ASCII (§II.B)
            if (fd) {
                checkEnumeration(sp, v, vEnd, *fd, true, f);
            } else if (ud && !ud->values.empty()) {
                bool found = false;
                for (const std::string &x : ud->values) found |= equalsNoCase(x, v);
                if (!found) {
                    std::string list;
                    for (const std::string &x : ud->values) list += (list.empty() ? "" : ", ") + x;
                    diagValue(Severity::Error, sp, vEnd, "'" + snippet(v) + "' is not one of the values defined for " + sp.name + ": " + list + ".");
                }
            }
            break;
        case DataType::GridSquare:
            if (!isGridSquare(v)) bad(Severity::Error, "expected a 2, 4, 6 or 8 character Maidenhead locator such as FN31pr");
            break;
        case DataType::GridSquareExt:
            if (!isGridSquareExt(v)) bad(Severity::Error, "expected locator characters 9-10 (A-X) and optionally 11-12 (digits)");
            break;
        case DataType::GridSquareList:
            for (std::string_view g : split(v, ','))
                if (!isGridSquare(g)) {
                    bad(Severity::Error, "'" + snippet(g) + "' is not a 2, 4, 6 or 8 character locator");
                    break;
                }
            break;
        case DataType::Location:
            if (const char *why = locationProblem(v)) bad(Severity::Error, why);
            break;
        case DataType::IOTARefNo:
            if (!isIota(v)) bad(Severity::Error, "expected CC-XXX, e.g. NA-001 (continent, dash, 3 digits)");
            break;
        case DataType::POTARef:
            if (!isPotaRef(v)) bad(Severity::Error, "expected a park reference such as K-5033 or VE-5082@CA-AB");
            break;
        case DataType::POTARefList:
            for (std::string_view p : split(v, ','))
                if (!isPotaRef(p)) {
                    bad(Severity::Error, "'" + snippet(p) + "' is not a park reference such as K-5033");
                    break;
                }
            break;
        case DataType::SOTARef:
            if (!isSotaRef(v)) bad(Severity::Warning, "expected a SOTA reference such as W2/WE-003 or G/LD-003");
            break;
        case DataType::WWFFRef:
            if (!isWwffRef(v)) bad(Severity::Error, "expected a WWFF reference such as KFF-4655");
            break;
        case DataType::CreditList:
        case DataType::AwardList: {
            const EnumDef *credit = findEnum("Credit"), *award = findEnum("Award"), *medium = findEnum("QSL_Medium");
            for (std::string_view item : split(v, ',')) {
                size_t colon = item.find(':');
                std::string_view name = item.substr(0, colon);
                if (credit && findEnumValue(*credit, name)) {
                } else if (award && findEnumValue(*award, name)) {
                    diagValue(Severity::Warning, sp, vEnd, "'" + std::string(name) + "' is an Award value; AwardList is import-only. Use Credit values.");
                } else {
                    bad(Severity::Error, "'" + snippet(name) + "' is not a Credit value");
                    break;
                }
                if (colon != npos && medium) {
                    for (std::string_view m : split(item.substr(colon + 1), '&'))
                        if (!findEnumValue(*medium, m)) {
                            bad(Severity::Error, "'" + snippet(m) + "' is not a QSL_Medium (CARD, EQSL, LOTW)");
                            break;
                        }
                }
            }
            break;
        }
        case DataType::SponsoredAwardList: {
            const EnumDef *sponsors = findEnum("Award_Sponsor");
            for (std::string_view item : split(v, ',')) {
                bool ok = false;
                for (size_t i = 0; sponsors && i < sponsors->count; ++i)
                    ok |= startsWithNoCase(item, sponsors->values[i].value) && item.size() > std::strlen(sponsors->values[i].value);
                if (!ok) {
                    bad(Severity::Warning, "'" + snippet(item) + "' does not start with a sponsor such as ARRL_ or CQ_");
                    break;
                }
            }
            break;
        }
        default:
            checkChars(sp, v, vEnd, false);
            break;
    }

    // String-typed fields with a suggested list (CONTEST_ID, SUBMODE).
    if (fd && fd->enumeration && type != DataType::Enumeration && type != DataType::CreditList &&
        type != DataType::SponsoredAwardList)
        checkEnumeration(sp, v, vEnd, *fd, false, f);
}

void Linter::checkFreqInBand(const Fields &f, const char *freqName, const char *bandName) {
    std::string_view band = value(f, bandName), freq = value(f, freqName);
    if (band.empty() || freq.empty()) return;
    const BandDef *b = findBand(band);
    double mhz = 0;
    if (!b || !parseNumber(freq, &mhz)) return;
    // Band edges are inclusive; the tolerance absorbs binary rounding of decimal MHz values.
    const double kTolMHz = 1e-9;
    if (mhz < b->lowerMHz - kTolMHz || mhz > b->upperMHz + kTolMHz) {
        const Spec *sp = f.at(freqName);
        diagValue(Severity::Warning, *sp, sp->cleanE,
                  std::string(freqName) + " " + std::string(freq) + " MHz is outside " + bandName + " " + b->name + " (" +
                      fmtNumber(b->lowerMHz) + "-" + fmtNumber(b->upperMHz) + " MHz).");
        // Written in kHz (14074 for 14.074 MHz)? Otherwise BAND follows FREQ.
        double inMHz = mhz / 1000;
        if (inMHz >= b->lowerMHz - kTolMHz && inMHz <= b->upperMHz + kTolMHz)
            annotate("freq-band", freqName, {setTo(freqName, fmtMHz(inMHz))}, std::string(freqName) + " " + fmtMHz(inMHz) + " (it was kHz)");
        else if (const BandDef *right = bandAt(mhz))
            annotate("freq-band", bandName, {setTo(bandName, right->name)}, std::string(bandName) + " " + right->name);
        else
            annotate("freq-band", freqName);
    }
}

}  // namespace

size_t measureLength(std::string_view data, LengthUnit unit, bool utf8) {
    if (unit == LengthUnit::Bytes || !utf8) return data.size();
    size_t count = 0;
    for (unsigned char c : data) count += !isUtf8Continuation(c);
    return count;
}

bool parseAdifNumber(std::string_view v, double *out) { return parseNumber(v, out); }
bool isAdifGridSquare(std::string_view v) { return isGridSquare(v); }
bool isAdifWwffRef(std::string_view v) { return isWwffRef(v); }
bool isAdifSotaRef(std::string_view v) { return isSotaRef(v); }

const char *severityName(Severity s) {
    switch (s) {
        case Severity::Error: return "error";
        case Severity::Warning: return "warning";
        case Severity::Info: return "note";
    }
    return "note";
}

LintResult lint(std::string_view text, const LintOptions &options) { return Linter(text, options).run(); }

std::string applyFixes(std::string_view text, const std::vector<LengthFix> &fixes) {
    std::string out;
    out.reserve(text.size() + fixes.size());
    size_t pos = 0;
    for (const LengthFix &f : fixes) {
        if (f.start < pos || f.end > text.size() || f.end < f.start) continue;  // defensive: skip overlaps
        out.append(text.substr(pos, f.start - pos));
        out.append(f.digits);
        pos = f.end;
    }
    out.append(text.substr(pos));
    return out;
}

}  // namespace adif
