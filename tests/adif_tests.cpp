// Tests for the ADI validator and length fixer.
//
// Expected results come from the ADIF 3.1.7 text (section numbers in each case),
// not from the implementation: each case states what the spec says should be
// reported, and the official ADIF test-QSO file must lint clean.
#include "adif_edit.h"
#include "adif_enrich.h"
#include "adif_lint.h"
#include "adif_spec.h"
#include "adif_profiles.h"
#include "adif_capture.h"
#include "adif_tools.h"
#include "adif_upload.h"
#include "adif_geo.h"
#include "adif_country.h"
#include "adif_programs.h"
#include "adif_formats.h"
#include "adif_import.h"

#include <algorithm>
#include <cmath>
#include <map>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

using namespace adif;

static int gFailures = 0, gChecks = 0;

#define CHECK(cond, ...)                                    \
    do {                                                    \
        ++gChecks;                                          \
        if (!(cond)) {                                      \
            ++gFailures;                                    \
            std::printf("FAIL %s:%d: ", __FILE__, __LINE__); \
            std::printf(__VA_ARGS__);                       \
            std::printf("\n");                              \
        }                                                   \
    } while (0)

static const char kHeader[] = "test\n<ADIF_VER:5>3.1.7\n<EOH>\n";

static std::string dump(const LintResult &r) {
    std::string s;
    for (const Diagnostic &d : r.diagnostics)
        s += std::string("    ") + severityName(d.severity) + " [" + std::to_string(d.start) + "," +
             std::to_string(d.end) + "): " + d.message + "\n";
    return s;
}

static size_t count(const LintResult &r, Severity sev, const char *needle) {
    size_t n = 0;
    for (const Diagnostic &d : r.diagnostics)
        if (d.severity == sev && d.message.find(needle) != std::string::npos) ++n;
    return n;
}

// A complete record with the guideline-minimum fields, plus `extra`.
static std::string record(const std::string &extra) {
    return "<QSO_DATE:8>20240115 <TIME_ON:4>1830 <CALL:4>WF1B <BAND:3>20m <MODE:2>CW " + extra + "<EOR>\n";
}

static LintResult lintRecord(const std::string &extra, LintOptions opt = {}) {
    return lint(std::string(kHeader) + record(extra), opt);
}

// The record lints with exactly `n` diagnostics of `sev` containing `needle`.
static void expect(const char *name, const LintResult &r, Severity sev, const char *needle, size_t n = 1) {
    size_t got = count(r, sev, needle);
    CHECK(got == n, "%s: expected %zu %s containing \"%s\", got %zu\n%s", name, n, severityName(sev), needle, got,
          dump(r).c_str());
}

static void expectClean(const char *name, const LintResult &r) {
    CHECK(r.errors == 0 && r.warnings == 0, "%s: expected no errors or warnings\n%s", name, dump(r).c_str());
}

static std::string fixed(const std::string &text, LintOptions opt = {}) {
    LintResult r = lint(text, opt);
    return applyFixes(text, r.fixes);
}

static void testStructure() {
    expectClean("minimal record", lintRecord(""));

    // §IV.A.1 / §IV.A.6: wrong lengths.
    {
        std::string t = std::string(kHeader) + "<CALL:4>VE3AAA <BAND:3>20m<EOR>\n";
        LintResult r = lint(t);
        expect("short length", r, Severity::Error, "Length 4 does not match the data 'VE3AAA' (6 bytes)");
        expect("short length reads", r, Severity::Error, "Importers read only 'VE3A'");
        CHECK(fixed(t) == std::string(kHeader) + "<CALL:6>VE3AAA <BAND:3>20m<EOR>\n", "short fix: %s", fixed(t).c_str());
    }
    {
        std::string t = std::string(kHeader) + "<CALL:9>VE3AAA\n<BAND:3>20m<EOR>\n";
        LintResult r = lint(t);
        expect("long length", r, Severity::Error, "swallowing what follows");
        CHECK(fixed(t) == std::string(kHeader) + "<CALL:6>VE3AAA\n<BAND:3>20m<EOR>\n", "long fix: %s", fixed(t).c_str());
    }
    {
        std::string t = std::string(kHeader) + "<CALL:99>VE3AAA";
        expect("past EOF", lint(t), Severity::Error, "runs past the end of the file");
        expect("past EOF no EOR", lint(t), Severity::Error, "not ended by <EOR>");
    }
    {
        std::string t = std::string(kHeader) + "<CALL:99999999999999999999>WF1B<EOR>\n";
        expect("length overflow", lint(t), Severity::Error, "does not match");
    }
    {   // Resources §III.B
        std::string t = std::string(kHeader) + "<CALL:04>WF1B<EOR>\n";
        expect("leading zeros", lint(t), Severity::Warning, "Leading zeros");
        CHECK(fixed(t) == std::string(kHeader) + "<CALL:4>WF1B<EOR>\n", "leading zero fix: %s", fixed(t).c_str());
    }
    {   // The length includes the line break that separates fields.
        std::string t = std::string(kHeader) + "<CALL:5>WF1B\n<BAND:3>20m<EOR>\n";
        expect("trailing break", lint(t), Severity::Error, "ends with a line break");
        CHECK(fixed(t) == std::string(kHeader) + "<CALL:4>WF1B\n<BAND:3>20m<EOR>\n", "trailing break fix: %s", fixed(t).c_str());
    }
    {   // Data may legitimately contain '<...>' when the length is right (§IV.A.1).
        std::string t = std::string(kHeader) + "<COMMENT:10>x<CALL:1>y <EOR>\n";
        LintResult r = lint(t);
        expect("tag-like data", r, Severity::Warning, "looks like a data specifier");
        CHECK(r.fixes.empty(), "tag-like data must not be 'fixed'");
        CHECK(count(r, Severity::Error, "does not match") == 0, "tag-like data is not a length error\n%s", dump(r).c_str());
    }
    {   // Zero length followed by text.
        std::string t = std::string(kHeader) + "<COMMENT:0>hello\n<EOR>\n";
        CHECK(fixed(t) == std::string(kHeader) + "<COMMENT:5>hello\n<EOR>\n", "zero-length fix: %s", fixed(t).c_str());
    }

    // Malformed specifiers.
    expect("no length", lint(std::string(kHeader) + "<CALL>WF1B<EOR>\n"), Severity::Error, "has no data length");
    expect("plus length", lint(std::string(kHeader) + "<CALL:+4>WF1B<EOR>\n"), Severity::Error, "unsigned whole number");
    expect("two-letter type", lint(std::string(kHeader) + "<CALL:4:SS>WF1B<EOR>\n"), Severity::Error, "single letter");
    expect("unclosed", lint(std::string(kHeader) + "<CALL:4 WF1B\n<EOR>\n"), Severity::Error, "not closed");
    expect("stray tag-like text", lint(std::string(kHeader) + record("") + "<grin>\n"), Severity::Warning, "not a valid data specifier");
    expect("missing '<'", lint(std::string(kHeader) + record("") + "CALL:4>WF1B\n"), Severity::Warning, "without its '<'");

    // Records.
    expect("empty record", lint(std::string(kHeader) + record("") + "<EOR>\n"), Severity::Warning, "Empty record");
    expect("duplicate field", lintRecord("<CALL:4>K1ABC "), Severity::Error, "appears more than once in this record");
    expect("minimum fields", lint(std::string(kHeader) + "<CALL:4>WF1B<EOR>\n"), Severity::Info, "QSO_DATE, TIME_ON, BAND or FREQ, MODE");
    expectClean("comments between records are allowed",
                lint(std::string(kHeader) + record("") + "==== a comment ====\n" + record("")));
}

static void testHeader() {
    expect("starts with '<'", lint("<ADIF_VER:5>3.1.7<EOH>" + record("")), Severity::Warning, "starts with '<'");
    expect("text but no EOH", lint("hello\n" + record("")), Severity::Warning, "no <EOH> ends it");
    expect("duplicate header field", lint("x <ADIF_VER:5>3.1.7 <ADIF_VER:5>3.1.6 <EOH>" + record("")), Severity::Error,
           "more than once in this header");
    expect("QSO field in header", lint("x <CALL:4>WF1B <EOH>" + record("")), Severity::Warning, "not a header field");
    expect("bad ADIF_VER", lint("x <ADIF_VER:3>3.1 <EOH>" + record("")), Severity::Warning, "ADIF_VER should be X.Y.Z");
    expect("bad timestamp", lint("x <CREATED_TIMESTAMP:13>20240115 1830 <EOH>" + record("")), Severity::Error,
           "CREATED_TIMESTAMP must be");
    expectClean("good timestamp", lint("x <CREATED_TIMESTAMP:15>20240115 183000 <EOH>" + record("")));
    expect("second EOH", lint(std::string(kHeader) + "<EOH>" + record("")), Severity::Error, "Second <EOH>");
    expect("EOH after records", lint(record("") + "<EOH>"), Severity::Error, "after records");
    expect("header field in record", lintRecord("<PROGRAMID:3>abc "), Severity::Warning, "is a header field");
    expect("header without EOH", lint("x <ADIF_VER:5>3.1.7"), Severity::Error, "header is not ended by <EOH>");
    {
        std::string bom = "\xEF\xBB\xBF" + std::string(kHeader) + record("");
        expect("BOM", lint(bom), Severity::Warning, "byte-order mark");
    }
}

static void testTypes() {
    // Date §II.B
    expectClean("leap day", lintRecord("<QSO_DATE_OFF:8>20240229 "));
    expect("not leap", lintRecord("<QSO_DATE_OFF:8>21000229 "), Severity::Error, "day is not in that month");
    expect("Feb 30", lintRecord("<QSO_DATE_OFF:8>20230230 "), Severity::Error, "day is not in that month");
    expect("year 1929", lintRecord("<QSO_DATE_OFF:8>19291231 "), Severity::Error, "1930 or later");
    // Time
    expect("hour 24", lintRecord("<TIME_OFF:4>2400 "), Severity::Error, "hour must be 00-23");
    expect("time length", lintRecord("<TIME_OFF:3>123 "), Severity::Error, "HHMM or HHMMSS");
    expectClean("HHMMSS", lintRecord("<TIME_OFF:6>235959 "));
    // Number, Resources §III.A
    expect("plus sign", lintRecord("<FREQ:7>+14.074 "), Severity::Error, "not a valid Number");
    expect("comma", lintRecord("<FREQ:6>14,074 "), Severity::Error, "not a valid Number");
    expectClean("leading point", lintRecord("<TX_PWR:2>.5 "));
    expectClean("trailing point", lintRecord("<TX_PWR:2>5. "));
    expect("bare minus", lintRecord("<ALTITUDE:1>- "), Severity::Warning, "says there is no value");  // a placeholder
    expect("minus dot", lintRecord("<ALTITUDE:2>-. "), Severity::Error, "not a valid Number");
    // Ranges from the field table
    expect("CQZ 41", lintRecord("<CQZ:2>41 "), Severity::Error, "CQZ must be 1 to 40");
    expect("AGE 121", lintRecord("<AGE:3>121 "), Severity::Error, "AGE must be 0 to 120");
    expectClean("K_INDEX 9", lintRecord("<K_INDEX:1>9 "));
    expect("PositiveInteger 0", lintRecord("<FISTS:1>0 "), Severity::Error, "greater than 0");
    expect("Integer letters", lintRecord("<SRX:2>1a "), Severity::Error, "not a valid Integer");
    expect("PositiveInteger letters", lintRecord("<FISTS:2>1a "), Severity::Error, "not a valid PositiveInteger");
    // Boolean
    expect("boolean", lintRecord("<FORCE_INIT:1>X "), Severity::Error, "expected Y or N");
    expectClean("boolean lower", lintRecord("<FORCE_INIT:1>y "));
    // Locators and references
    expectClean("grid", lintRecord("<GRIDSQUARE:6>FN31pr "));
    expect("grid odd", lintRecord("<GRIDSQUARE:3>FN3 "), Severity::Error, "Maidenhead");
    expect("grid letters", lintRecord("<GRIDSQUARE:4>SS00 "), Severity::Error, "Maidenhead");
    expectClean("grid ext", lintRecord("<GRIDSQUARE_EXT:4>AB12 "));
    expectClean("vucc", lintRecord("<VUCC_GRIDS:9>FN31,FN32 "));
    expectClean("location", lintRecord("<LAT:11>N040 06.150 "));
    expect("latitude 91", lintRecord("<LAT:11>N091 00.000 "), Severity::Error, "cannot exceed 90");
    expect("location letter", lintRecord("<LON:11>X040 06.150 "), Severity::Error, "N, S, E or W");
    expectClean("iota", lintRecord("<IOTA:6>NA-001 "));
    expect("iota short", lintRecord("<IOTA:4>NA-1 "), Severity::Error, "CC-XXX");
    expect("iota continent", lintRecord("<IOTA:6>XX-001 "), Severity::Error, "CC-XXX");
    expectClean("pota", lintRecord("<POTA_REF:6>K-5033 "));
    expectClean("pota list", lintRecord("<POTA_REF:19>K-5033,K-4562@US-CA "));
    expect("pota bad", lintRecord("<POTA_REF:4>K-50 "), Severity::Error, "park reference");
    expectClean("wwff", lintRecord("<WWFF_REF:8>KFF-4655 "));
    expect("wwff bad", lintRecord("<WWFF_REF:6>KFF-46 "), Severity::Error, "WWFF reference");
    expectClean("sota", lintRecord("<SOTA_REF:9>W2/WE-003 "));
    expect("sota bad", lintRecord("<SOTA_REF:7>W2WE003 "), Severity::Warning, "SOTA reference");
    expectClean("credit list", lintRecord("<CREDIT_SUBMITTED:28>IOTA,WAS:LOTW&CARD,DXCC:CARD "));
    expect("credit bad", lintRecord("<CREDIT_SUBMITTED:5>BOGUS "), Severity::Error, "not a Credit value");
    expect("credit medium", lintRecord("<CREDIT_SUBMITTED:7>WAS:FAX "), Severity::Error, "QSL_Medium");
    // Characters
    expect("tab in String", lintRecord("<NAME:4>B\tob "), Severity::Error, "Control character 0x09");
    expectClean("CRLF in MultilineString", lintRecord("<NOTES:9>line\r\nTwo "));
    expect("LF in MultilineString", lintRecord("<NOTES:8>line\nTwo "), Severity::Warning, "must be CR LF");
    expect("Intl field in ADI", lintRecord("<NAME_INTL:3>Bob "), Severity::Error, "ADI files cannot carry");
    // Type indicators
    expect("indicator mismatch", lintRecord("<QSO_DATE_OFF:8:N>20240101 "), Severity::Warning, "does not match QSO_DATE_OFF");
    expect("unknown indicator", lintRecord("<COMMENT:2:Z>hi "), Severity::Error, "Unknown data type indicator 'Z'");
}

static void testEnumerations() {
    expectClean("band case-insensitive", lintRecord("<BAND_RX:3>20M "));
    expect("band unknown", lintRecord("<BAND_RX:3>21m "), Severity::Error, "not a valid BAND_RX");
    expect("mode unknown", lint(std::string(kHeader) + "<QSO_DATE:8>20240115 <TIME_ON:4>1830 <CALL:4>WF1B <BAND:3>20m <MODE:3>XYZ <EOR>"),
           Severity::Error, "not a valid MODE");
    {   // Mode C4FM is import-only; the spec says to export DIGITALVOICE + SUBMODE C4FM.
        LintResult r = lint(std::string(kHeader) + "<QSO_DATE:8>20240115 <TIME_ON:4>1830 <CALL:4>WF1B <BAND:2>2m <MODE:4>C4FM <EOR>");
        expect("import-only mode", r, Severity::Warning, "import-only (deprecated) MODE value");
        expect("import-only note", r, Severity::Warning, "DIGITALVOICE");
    }
    expect("QSL_RCVD V import-only", lintRecord("<QSL_RCVD:1>V "), Severity::Warning, "import-only");
    expect("ANT_PATH", lintRecord("<ANT_PATH:1>Q "), Severity::Error, "not a valid ANT_PATH");
    expect("import-only field", lintRecord("<GUEST_OP:4>K1AB "), Severity::Warning, "GUEST_OP is import-only");

    // Submode[MODE]
    auto withMode = [](const char *mode, const char *submode) {
        std::string m = mode, s = submode;
        std::string t = std::string(kHeader) + "<QSO_DATE:8>20240115 <TIME_ON:4>1830 <CALL:4>WF1B <BAND:3>20m ";
        if (!m.empty()) t += "<MODE:" + std::to_string(m.size()) + ">" + m + " ";
        if (!s.empty()) t += "<SUBMODE:" + std::to_string(s.size()) + ">" + s + " ";
        return lint(t + "<EOR>\n");
    };
    expect("submode wrong mode", withMode("FT8", "FT4"), Severity::Error, "belongs to MODE MFSK, not FT8");
    expectClean("submode right mode", withMode("MFSK", "FT4"));
    expectClean("submode case", withMode("ssb", "usb"));
    expect("submode unknown", withMode("MFSK", "FT99"), Severity::Info, "not a registered ADIF submode of MODE MFSK");
    expect("submode without mode", withMode("", "FT4"), Severity::Warning, "MODE is missing");

    // Band edges are inclusive (Band enumeration table).
    expect("freq outside band", lintRecord("<FREQ:4>14.5 "), Severity::Warning, "outside BAND 20m");
    expectClean("freq at upper edge", lintRecord("<FREQ:5>14.35 "));
    expectClean("freq at lower edge", lintRecord("<FREQ:2>14 "));

    // Primary_Administrative_Subdivision[DXCC]
    expectClean("state ok", lintRecord("<DXCC:3>291 <STATE:2>MA "));
    expectClean("dxcc leading zero", lintRecord("<DXCC:4>0291 <STATE:2>ma "));
    expect("state wrong", lintRecord("<DXCC:3>291 <STATE:2>XX "), Severity::Warning,
           "not one of ADIF's STATE codes for United States of America (DXCC 291), which are");
    // Another entity's own list (Hungary: counties), not US states; a callbook's 'H' isn't on it.
    expectClean("hungary county", lintRecord("<DXCC:3>239 <STATE:2>BP "));
    expect("hungary callbook state", lintRecord("<DXCC:3>239 <STATE:1>H "), Severity::Warning,
           "'H' is not one of ADIF's STATE codes for Hungary (DXCC 239), which are BA, BE, BN, BO, BP, CS, FE, GY, HB, HE and 10 more");
    expectClean("an entity without a list", lintRecord("<DXCC:3>202 <STATE:2>PR "));
    // A placeholder in free text is just text; CONT NA (North America) is a value, not "n/a".
    expectClean("free text none", lintRecord("<COMMENT:4>none "));
    expectClean("continent NA", lintRecord("<CONT:2>NA "));
    expectClean("CLASS kept", lintRecord("<CLASS:2>1D <ARRL_SECT:3>EMA "));
    expectClean("state without dxcc", lintRecord("<STATE:2>XX "));
    expect("dxcc unknown", lintRecord("<DXCC:3>999 "), Severity::Error, "not a valid DXCC");
    expect("contest id", lintRecord("<CONTEST_ID:9>MY-SPRINT "), Severity::Info, "not in ADIF's Contest_ID list");
}

static void testUserAndAppFields() {
    std::string hdr = "x\n<USERDEF1:19:E>SweaterSize,{S,M,L}\n<USERDEF2:15:N>ShoeSize,{5:20}\n<EOH>\n";
    expectClean("userdef enum ok", lint(hdr + record("<sweatersize:1>m <SHOESIZE:2>10 ")));
    expect("userdef enum bad", lint(hdr + record("<SWEATERSIZE:2>XL ")), Severity::Error, "not one of the values defined");
    expect("userdef range", lint(hdr + record("<SHOESIZE:2>21 ")), Severity::Error, "SHOESIZE must be 5 to 20");
    expect("userdef ADIF name", lint("x <USERDEF1:4:S>CALL <EOH>" + record("")), Severity::Error, "is an ADIF field name");
    expect("userdef in record", lintRecord("<USERDEF1:3:S>FOO "), Severity::Warning, "belongs in the header");
    expect("userdef bad range", lint("x <USERDEF1:11:N>Size,{20:5} <EOH>" + record("")), Severity::Error, "low < high");
    expect("unknown field", lintRecord("<FOO:3>bar "), Severity::Warning, "Unknown field FOO");
    expectClean("app field", lintRecord("<APP_LOGGER_RIG:3:S>abc "));
    expect("app name", lintRecord("<APP_LOGGER:3>abc "), Severity::Warning, "APP_PROGRAMID_FIELDNAME");
    expect("app type change", lint(std::string(kHeader) + record("<APP_X_WPM:2:N>18 ") + record("<APP_X_WPM:2:S>18 ")),
           Severity::Error, "must not change the type");
    expect("app typed value", lintRecord("<APP_X_DATE:8:D>20241301 "), Severity::Error, "month must be 01-12");
}

static void testNonAscii() {
    // "Jürg" is 4 characters and 5 UTF-8 bytes. No separator after the value,
    // so a wrong length runs into <EOR> instead of absorbing a space.
    const std::string pre = std::string(kHeader) + "<QSO_DATE:8>20240115 <TIME_ON:4>1830 <CALL:4>WF1B <BAND:3>20m <MODE:2>CW ";
    const std::string bytes5 = pre + "<NAME:5>J\xC3\xBCrg<EOR>\n";
    const std::string chars4 = pre + "<NAME:4>J\xC3\xBCrg<EOR>\n";

    LintResult r = lint(bytes5);
    expect("non-ASCII warning", r, Severity::Warning, "Non-ASCII text");
    CHECK(count(r, Severity::Error, "does not match") == 0, "5 bytes is right in Bytes mode\n%s", dump(r).c_str());

    r = lint(chars4);
    expect("bytes mode mismatch", r, Severity::Error, "would match if lengths counted characters");
    CHECK(fixed(chars4) == bytes5, "bytes-mode fix uses 5: %s", fixed(chars4).c_str());

    LintOptions chars;
    chars.lengthUnit = LengthUnit::Characters;
    r = lint(chars4, chars);
    CHECK(count(r, Severity::Error, "does not match") == 0, "4 characters is right in Characters mode\n%s", dump(r).c_str());
    r = lint(bytes5, chars);
    expect("chars mode mismatch", r, Severity::Error, "would match if lengths counted bytes");
    CHECK(fixed(bytes5, chars) == chars4, "characters-mode fix uses 4: %s", fixed(bytes5, chars).c_str());

    // Malformed UTF-8 must not break Characters mode.
    r = lint(pre + "<NAME:3>\x80\x80\xC3<EOR>\n", chars);
    CHECK(r.diagnostics.size() > 0, "malformed UTF-8 still produces diagnostics");
}

// ── Editing: model, reformat, field edits, choices ──────────────────────────

static LintResult lintModel(const std::string &t, LintOptions opt = {}) {
    opt.buildModel = true;
    return lint(t, opt);
}

// Every field as NAME=VALUE, in order: what an importer would see.
static std::vector<std::string> fieldList(const std::string &t, const DocModel &m) {
    std::vector<std::string> v;
    for (const ModelGroup &g : m.groups) {
        for (size_t i = 0; i < g.fieldCount; ++i) {
            const ModelField &f = m.fields[g.firstField + i];
            v.push_back(std::string(fieldName(t, f)) + "=" + std::string(fieldValue(t, f)));
        }
        v.push_back(g.markerB == kNoPos ? "(no marker)" : t.substr(g.markerB, g.markerE - g.markerB));
    }
    return v;
}

static std::string applyEdit(const std::string &t, const TextEdit &e) {
    return t.substr(0, e.start) + e.text + t.substr(e.end);
}

static void testModel() {
    std::string t = "hdr text\n<ADIF_VER:5>3.1.7\n<EOH>\n<CALL:4>WF1B <BAND:3>20m <EOR>\n== note ==\n<CALL:5>K1ABC\n<MODE:2>CW\n<EOR>\n";
    LintResult r = lintModel(t);
    const DocModel &m = r.model;
    CHECK(m.groups.size() == 3, "3 groups, got %zu", m.groups.size());
    CHECK(m.groups[0].header && !m.groups[1].header && !m.groups[2].header, "header flags");
    CHECK(m.groups[1].fieldCount == 2 && m.groups[2].fieldCount == 2, "field counts");
    CHECK(t.substr(m.headerTextB, m.headerTextE - m.headerTextB) == "hdr text", "header text");
    CHECK(m.otherText.size() == 1 && t.substr(m.otherText[0].first, m.otherText[0].second - m.otherText[0].first) == "== note ==",
          "comment between records recorded");
    CHECK(t.substr(m.groups[2].markerB, m.groups[2].markerE - m.groups[2].markerB) == "<EOR>", "marker range");
    size_t k1 = t.find("K1ABC");
    CHECK(groupAt(m, k1) == 2 && recordNumber(m, 2) == 2 && recordCount(m) == 2, "groupAt/recordNumber");
    CHECK(fieldAt(m, k1) == (int)m.groups[2].firstField, "fieldAt on data");
    CHECK(fieldAt(m, t.find("<MODE")) == (int)m.groups[2].firstField + 1, "fieldAt on tag");
    CHECK(groupAt(m, t.find("== note")) == 1, "between records: the previous record");
    CHECK(groupValue(t, m, m.groups[2], "mode") == "CW", "groupValue case-insensitive");

    // USERDEF and APP_ fields reach the model.
    std::string u = "x <USERDEF1:19:E>SweaterSize,{S,M,L} <EOH>" + record("<APP_LOG_RIG:3:S>abc ");
    LintResult ru = lintModel(u);
    CHECK(ru.model.userFields.size() == 1 && ru.model.userFields[0].name == "SweaterSize" &&
              ru.model.userFields[0].indicator == 'E' && ru.model.userFields[0].values.size() == 3,
          "user field in model");
    CHECK(ru.model.appFields.size() == 1 && ru.model.appFields[0].first == "APP_LOG_RIG" && ru.model.appFields[0].second == 'S',
          "app field in model");

    // A stray tag after the data is reported on its own, not as part of the length.
    LintResult rs = lint(std::string(kHeader) + "<CALL:4>WF1B <grin> <EOR>\n");
    CHECK(count(rs, Severity::Error, "does not match") == 0 && rs.fixes.empty(), "stray tag is not a length error\n%s", dump(rs).c_str());
    expect("stray tag warning", rs, Severity::Warning, "not a valid data specifier");
}

static void testReformat() {
    std::string messy = "hdr text\n<ADIF_VER:5>3.1.7 <PROGRAMID:3>abc <EOH>\n"
                        "<CALL:4>WF1B\n\n<BAND:3>20m\t<EOR>== note ==\n<CALL:5>K1ABC <MODE:2>CW<EOR>";
    LintResult r = lintModel(messy);
    CHECK(canReformat(r), "messy file can be reformatted\n%s", dump(r).c_str());
    std::string rec = reformat(messy, r.model, Layout::RecordPerLine, "\n");
    std::string wantRec = "hdr text\n<ADIF_VER:5>3.1.7\n<PROGRAMID:3>abc\n<EOH>\n\n"
                          "<CALL:4>WF1B <BAND:3>20m <EOR>\n== note ==\n<CALL:5>K1ABC <MODE:2>CW <EOR>\n";
    CHECK(rec == wantRec, "record-per-line:\n%s", rec.c_str());
    std::string fld = reformat(messy, r.model, Layout::FieldPerLine, "\r\n");
    std::string wantFld = "hdr text\r\n<ADIF_VER:5>3.1.7\r\n<PROGRAMID:3>abc\r\n<EOH>\r\n\r\n"
                          "<CALL:4>WF1B\r\n<BAND:3>20m\r\n<EOR>\r\n\r\n== note ==\r\n<CALL:5>K1ABC\r\n<MODE:2>CW\r\n<EOR>\r\n";
    CHECK(fld == wantFld, "field-per-line:\n%s", fld.c_str());
    CHECK(fieldList(rec, lintModel(rec).model) == fieldList(messy, r.model), "record layout keeps every field");
    CHECK(fieldList(fld, lintModel(fld).model) == fieldList(messy, r.model), "field layout keeps every field");

    // Data containing spaces, line breaks and '<' survives untouched.
    std::string tricky = std::string(kHeader) + "<NOTES:16>a <b> c\r\nline 2 <COMMENT:3>   <EOR>";
    LintResult rt = lintModel(tricky);
    CHECK(canReformat(rt), "tricky can be reformatted\n%s", dump(rt).c_str());
    std::string out = reformat(tricky, rt.model, Layout::FieldPerLine, "\n");
    CHECK(fieldList(out, lintModel(out).model) == fieldList(tricky, rt.model), "tricky data kept: %s", out.c_str());

    CHECK(!canReformat(lintModel(std::string(kHeader) + "<CALL:3>WF1B <EOR>")), "wrong length blocks reformat");
    CHECK(!canReformat(lintModel(std::string(kHeader) + "<CALL:4 WF1B <EOR>")), "malformed tag blocks reformat");
}

static void testFieldEdits() {
    std::string t = std::string(kHeader) + "<CALL:4>W1AW <BAND:3>20m <MODE:2>CW <EOR>\n";
    LintResult r = lintModel(t);
    const ModelGroup &g = r.model.groups[1];
    const ModelField &call = r.model.fields[g.firstField];

    std::string a = applyEdit(t, setFieldValue(t, call, "W1AW/P", LengthUnit::Bytes, true));
    CHECK(a.find("<CALL:6>W1AW/P <BAND") != std::string::npos, "set value: %s", a.c_str());
    expectClean("edited value lints clean", lint(a));

    std::string typed = std::string(kHeader) + "<APP_X_WPM:2:N>18 <EOR>\n";
    LintResult rt = lintModel(typed);
    std::string b = applyEdit(typed, setFieldValue(typed, rt.model.fields[rt.model.groups[1].firstField], "120",
                                                   LengthUnit::Bytes, true));
    CHECK(b.find("<APP_X_WPM:3:N>120") != std::string::npos, "keeps type indicator: %s", b.c_str());

    std::string c = applyEdit(t, insertField(t, r.model, g, "RST_SENT", "599", LengthUnit::Bytes, true));
    CHECK(c.find("<MODE:2>CW <RST_SENT:3>599 <EOR>") != std::string::npos, "insert with space: %s", c.c_str());

    std::string lines = std::string(kHeader) + "<CALL:4>W1AW\r\n<MODE:2>CW\r\n<EOR>\r\n";
    LintResult rl = lintModel(lines);
    std::string d = applyEdit(lines, insertField(lines, rl.model, rl.model.groups[1], "NAME", "J\xC3\xBCrg", LengthUnit::Characters, true));
    CHECK(d.find("<MODE:2>CW\r\n<NAME:4>J\xC3\xBCrg\r\n<EOR>") != std::string::npos, "insert with CRLF, chars: %s", d.c_str());

    std::string open = std::string(kHeader) + "<CALL:4>W1AW <MODE:2>CW";
    LintResult ro = lintModel(open);
    std::string e2 = applyEdit(open, insertField(open, ro.model, ro.model.groups[1], "BAND", "20m", LengthUnit::Bytes, true));
    const std::string tail = "<MODE:2>CW <BAND:3>20m";
    CHECK(e2.size() > tail.size() && e2.compare(e2.size() - tail.size(), tail.size(), tail) == 0,
          "insert into unterminated record: %s", e2.c_str());

    std::string f = applyEdit(t, removeField(t, r.model, g, 1));
    CHECK(f.find("<CALL:4>W1AW <MODE:2>CW <EOR>") != std::string::npos, "remove middle: %s", f.c_str());
    std::string h = applyEdit(t, removeField(t, r.model, g, 2));
    CHECK(h.find("<BAND:3>20m <EOR>") != std::string::npos, "remove last: %s", h.c_str());
    std::string i = applyEdit(lines, removeField(lines, rl.model, rl.model.groups[1], 0));
    CHECK(i == std::string(kHeader) + "<MODE:2>CW\r\n<EOR>\r\n", "remove a line: %s", i.c_str());
}

static void testChoices() {
    std::string t = "x <USERDEF1:19:E>SweaterSize,{S,M,L} <EOH>" + record("<APP_LOG_RIG:3:S>abc ") +
                    "<QSO_DATE:8>20240115 <MODE:4>MFSK <DXCC:3>291 <EOR>\n";
    LintResult r = lintModel(t);
    const DocModel &m = r.model;
    auto has = [](const std::vector<std::string> &v, const char *x) { return std::find(v.begin(), v.end(), x) != v.end(); };

    auto rec = fieldNameChoices(m, false);
    CHECK(has(rec, "CALL") && has(rec, "EOR") && has(rec, "SWEATERSIZE") && has(rec, "APP_LOG_RIG"), "record names");
    CHECK(!has(rec, "GUEST_OP") && !has(rec, "NAME_INTL") && !has(rec, "ADIF_VER"), "no import-only, _INTL or header names");
    CHECK(std::is_sorted(rec.begin(), rec.end()), "names sorted");
    auto hdr = fieldNameChoices(m, true);
    CHECK(has(hdr, "ADIF_VER") && has(hdr, "USERDEF2") && has(hdr, "EOH") && !has(hdr, "CALL"), "header names");

    const ModelGroup &g1 = m.groups[1], &g2 = m.groups[2];
    auto band = valueChoices(t, m, &g1, "BAND");
    CHECK(!band.empty() && band.front() == "2190m", "bands in frequency order");
    auto mode = valueChoices(t, m, &g1, "MODE");
    CHECK(has(mode, "FT8") && !has(mode, "C4FM"), "modes without import-only values");
    auto sub = valueChoices(t, m, &g2, "SUBMODE");
    CHECK(has(sub, "FT4") && !has(sub, "USB"), "submodes of MFSK only");
    auto cw = valueChoices(t, m, &g1, "SUBMODE");
    CHECK(has(cw, "PCW") && !has(cw, "USB"), "submodes of CW only");
    std::string ft8 = std::string(kHeader) + "<MODE:3>FT8 <EOR>\n";
    LintResult rf = lintModel(ft8);
    CHECK(has(valueChoices(ft8, rf.model, &rf.model.groups[1], "SUBMODE"), "USB"), "FT8 has no submodes: all are offered");
    auto state = valueChoices(t, m, &g2, "STATE");
    CHECK(has(state, "MA") && !has(state, "ON"), "STATE for DXCC 291");
    CHECK(valueChoices(t, m, &g1, "STATE").empty(), "no DXCC: no STATE list");
    CHECK(valueChoices(t, m, &g1, "QSL_RCVD").size() == 4, "QSL_RCVD without import-only V");
    CHECK(valueChoices(t, m, &g1, "FORCE_INIT") == std::vector<std::string>({"N", "Y"}), "Boolean");
    CHECK(valueChoices(t, m, &g1, "sweatersize").size() == 3, "USERDEF list");
    CHECK(valueChoices(t, m, &g1, "CALL").empty() && valueChoices(t, m, &g1, "DXCC").empty(), "no list for free text or bare codes");

    CHECK(describeField(m, "call") == "CALL (String): The contacted station's callsign", "describe: %s", describeField(m, "call").c_str());
    FieldInfo fi = fieldInfo(m, "comment");
    CHECK(fi.name == "COMMENT" && fi.type == "String" && fi.brief == "Comment field for QSO" &&
              fi.details.find("QSLMSG") != std::string::npos && !fi.hasValues,
          "COMMENT: brief from the spec's first paragraph, details keep the notes: %s", fi.brief.c_str());
    CHECK(fieldInfo(m, "BAND").hasValues && fieldInfo(m, "SUBMODE").hasValues && fieldInfo(m, "SUBMODE").type == "String",
          "value lists flagged");
    CHECK(fieldInfo(m, "GUEST_OP").brief.find("(import-only)") != std::string::npos, "import-only flagged");
    CHECK(fieldInfo(m, "SweaterSize").brief == "User-defined field, from this log's header" && fieldInfo(m, "SweaterSize").hasValues,
          "user field info");
    CHECK(describeField(m, "SweaterSize") == "SWEATERSIZE (user-defined, Enumeration)", "describe user: %s",
          describeField(m, "SweaterSize").c_str());
}

static void testNewQso() {
    // A log laid out like a POTA activation export (one record per line).
    std::string t = "Generated by X\n<ADIF_VER:5>3.1.7\n<EOH>\n\n"
                    "<CALL:6>WA8IHW <QSO_DATE:8>20261006 <TIME_ON:6>222800 <BAND:3>20m <MODE:3>SSB "
                    "<STATION_CALLSIGN:4>KW9D <FREQ:6>14.310 <MY_SIG_INFO:7>US-7929 <MY_STATE:2>KS <SIG:4>POTA <EOR>\n";
    LintResult r = lintModel(t);
    auto tpl = newQsoTemplate(t, r.model, "20261007", "013005");
    std::vector<std::string> names;
    for (const QsoField &q : tpl) names.push_back(q.name);
    std::vector<std::string> want = {"CALL", "QSO_DATE", "TIME_ON", "BAND", "MODE", "STATION_CALLSIGN", "FREQ", "MY_SIG_INFO",
                                     "MY_STATE", "SIG", "SUBMODE", "RST_SENT", "RST_RCVD"};
    CHECK(names == want, "template keeps the log's field order, then the core fields");
    auto value = [&](const char *n) {
        for (const QsoField &q : tpl)
            if (q.name == n) return q.value;
        return std::string("?");
    };
    CHECK(value("CALL").empty() && value("SIG").empty(), "per-contact fields start empty");
    CHECK(value("STATION_CALLSIGN") == "KW9D" && value("MY_SIG_INFO") == "US-7929" && value("FREQ") == "14.310" &&
              value("MODE") == "SSB",
          "station fields, band, frequency and mode carry over");
    CHECK(value("QSO_DATE") == "20261007" && value("TIME_ON") == "013005", "UTC date and time");
    CHECK(value("RST_SENT") == "59" && value("RST_RCVD") == "59", "default report for SSB");
    std::string hhmm = std::string(kHeader) + "<CALL:4>W1AW <TIME_ON:4>1830 <MODE:2>CW <EOR>\n";
    LintResult rh = lintModel(hhmm);
    auto tpl2 = newQsoTemplate(hhmm, rh.model, "20261007", "013005");
    for (const QsoField &q : tpl2) {
        if (q.name == "TIME_ON") CHECK(q.value == "0130", "time shortened to the log's HHMM");
        if (q.name == "RST_SENT") CHECK(q.value == "599", "default report for CW");
    }
    CHECK(newQsoTemplate("", lintModel("").model, "20261007", "013005").size() == 9, "empty log: the core fields");

    CHECK(bandForFrequency("14.310") == "20m" && bandForFrequency("14.35") == "20m" && bandForFrequency("7.074") == "40m" &&
              bandForFrequency("146.52") == "2m" && bandForFrequency("15.0").empty() && bandForFrequency("abc").empty(),
          "band for frequency");
    CHECK(defaultReport("FT8").empty(), "no default report for FT8");

    // Build and append a record in the log's layout.
    std::vector<std::pair<std::string, std::string>> fields = {
        {"CALL", "K1ABC"}, {"QSO_DATE", "20261007"}, {"TIME_ON", "013005"}, {"BAND", "20m"}, {"MODE", "SSB"},
        {"NAME", ""},      {"MY_SIG_INFO", "US-7929"}};
    CHECK(recordLayout(t, r.model) == Layout::RecordPerLine, "one-record-per-line log");
    BuiltRecord br = buildRecord(fields, Layout::RecordPerLine, "\n", LengthUnit::Bytes, true);
    CHECK(br.text == "<CALL:5>K1ABC <QSO_DATE:8>20261007 <TIME_ON:6>013005 <BAND:3>20m <MODE:3>SSB <MY_SIG_INFO:7>US-7929 <EOR>\n",
          "built record: %s", br.text.c_str());
    CHECK(br.ranges[5].first == kNoPos && br.text.substr(br.ranges[1].first, br.ranges[1].second - br.ranges[1].first) ==
                                              "<QSO_DATE:8>20261007",
          "field ranges");
    size_t at = 0;
    std::string appended = applyEdit(t, appendRecord(t, r.model, br.text, "\n", &at));
    CHECK(appended == t + br.text && at == t.size(), "appended after the last record");
    LintResult ra = lintModel(appended);
    CHECK(ra.errors == 0 && ra.records == 2, "appended log lints clean\n%s", dump(ra).c_str());

    std::string noBreak = t.substr(0, t.size() - 1);  // no line break at the end
    std::string a2 = applyEdit(noBreak, appendRecord(noBreak, lintModel(noBreak).model, br.text, "\n", &at));
    CHECK(a2 == noBreak + "\n" + br.text && at == noBreak.size() + 1, "line break added before the record");

    std::string lines = std::string(kHeader) + "<CALL:4>W1AW\n<MODE:2>CW\n<EOR>\n";
    LintResult rl = lintModel(lines);
    CHECK(recordLayout(lines, rl.model) == Layout::FieldPerLine, "one-field-per-line log");
    BuiltRecord bl = buildRecord({{"CALL", "K1ABC"}, {"MODE", "CW"}}, Layout::FieldPerLine, "\n", LengthUnit::Bytes, true);
    std::string a3 = applyEdit(lines, appendRecord(lines, rl.model, bl.text, "\n", &at));
    CHECK(a3 == lines + "\n<CALL:5>K1ABC\n<MODE:2>CW\n<EOR>\n", "field-per-line record after a blank line:\n%s", a3.c_str());

    std::string h = newLogHeader("0.3.0", "20261007 013005", "\n");
    std::string fresh = h + br.text;
    LintResult rf = lint(fresh);
    CHECK(rf.errors == 0 && rf.warnings == 0 && rf.hasHeader && rf.records == 1, "new log header lints clean\n%s",
          dump(rf).c_str());

    // Duplicates: same call, band, mode and UTC date.
    CHECK(sameContact(appended, ra.model, "k1abc", "20M", "ssb", "20261007") == std::vector<int>({2}), "same contact found");
    CHECK(sameContact(appended, ra.model, "K1ABC", "40m", "SSB", "20261007").empty(), "other band is not a duplicate");
    CHECK(timesWorked(appended, ra.model, "WA8IHW") == 1 && timesWorked(appended, ra.model, "N0NE") == 0, "times worked");

    // A chosen field list: its order, required fields added, carried values kept.
    auto custom = newQsoTemplateFor(t, r.model, "20261007", "013005", {"call", "freq", "rst_sent", "SIG_INFO", "STATE"});
    std::vector<std::string> cn;
    for (const QsoField &q : custom) cn.push_back(q.name);
    CHECK(cn == std::vector<std::string>({"QSO_DATE", "TIME_ON", "MODE", "CALL", "FREQ", "RST_SENT", "SIG_INFO", "STATE"}),
          "custom list: required fields first, then the chosen order");
    for (const QsoField &q : custom) {
        if (q.name == "FREQ") CHECK(q.value == "14.310" && q.carry, "FREQ carried");
        if (q.name == "STATE") CHECK(q.value.empty() && !q.carry, "STATE (the contact's) not carried");
        if (q.name == "RST_SENT") CHECK(q.value == "59", "report default for the carried mode");
    }
    auto withBand = newQsoTemplateFor(t, r.model, "20261007", "013005", {"CALL"});
    CHECK(withBand.size() == 5 && withBand[3].name == "BAND" && withBand[3].value == "20m" && withBand[4].name == "CALL", "BAND added when neither BAND nor FREQ is listed");
    auto hidden = hiddenStationFields(t, r.model, cn);
    using Pairs = std::vector<std::pair<std::string, std::string>>;
    const Pairs wantHidden = {{"STATION_CALLSIGN", "KW9D"}, {"MY_SIG_INFO", "US-7929"}, {"MY_STATE", "KS"}};
    CHECK(hidden == wantHidden, "hidden station fields from the last record");
    CHECK(isStationField("MY_GRIDSQUARE") && isStationField("operator") && !isStationField("FREQ") && !isStationField("NAME"),
          "station fields");
    CHECK(isRequiredQsoField("call") && !isRequiredQsoField("BAND"), "required fields");

    // Value lists for a record that is not in the document yet.
    auto sub = valueChoicesWith(r.model, "SUBMODE", [](std::string_view k) { return k == "MODE" ? std::string("MFSK") : std::string(); });
    CHECK(std::find(sub.begin(), sub.end(), "FT4") != sub.end() && std::find(sub.begin(), sub.end(), "USB") == sub.end(),
          "submodes for a typed MODE");
}

// Sample responses from the QRZ XML spec 1.34 (AA7BQ) and the HamQTH API docs (OK2CQR).
static std::map<std::string, std::string> qrzSample() {
    return {{"call", "AA7BQ"},     {"dxcc", "291"},       {"fname", "FRED L"},     {"name", "LLOYD"},
            {"addr1", "8711 E PINNACLE PEAK RD 193"},     {"addr2", "SCOTTSDALE"}, {"state", "AZ"},
            {"zip", "85255"},      {"country", "United States"},                   {"lat", "34.23456"},
            {"lon", "-112.34356"}, {"grid", "DM32af"},    {"county", "Maricopa"},  {"land", "USA"},
            {"cqzone", "3"},       {"ituzone", "2"},      {"geoloc", "user"}};
}

static std::map<std::string, std::string> hamqthSample() {
    return {{"callsign", "ok2cqr"}, {"nick", "Petr"},       {"qth", "Neratovice"},   {"country", "Czech Republic"},
            {"adif", "503"},        {"itu", "28"},          {"cq", "15"},            {"grid", "jo70gg"},
            {"adr_name", "Petr Hlozek"},                    {"adr_city", "Neratovice"}, {"latitude", "50.07"},
            {"longitude", "14.42"}, {"continent", "EU"}};
}

static void testEnrich() {
    FieldMap q = mapQrz(qrzSample());
    CHECK(q["NAME"] == "FRED L LLOYD" && q["QTH"] == "SCOTTSDALE" && q["STATE"] == "AZ" && q["CNTY"] == "AZ,Maricopa",
          "QRZ name/QTH/state/county");
    CHECK(q["GRIDSQUARE"] == "DM32af" && q["DXCC"] == "291" && q["COUNTRY"] == "UNITED STATES OF AMERICA" &&
              q["CQZ"] == "3" && q["ITUZ"] == "2",
          "QRZ grid, entity (ADIF name, not QRZ's 'land'), zones");
    CHECK(q["LAT"] == "N034 14.074" && q["LON"] == "W112 20.614", "QRZ position: %s %s", q["LAT"].c_str(), q["LON"].c_str());
    auto coarse = qrzSample();
    coarse["geoloc"] = "dxcc";
    FieldMap qc = mapQrz(coarse);
    CHECK(!qc.count("GRIDSQUARE") && !qc.count("LAT") && qc.count("STATE"), "coarse QRZ coordinates are not used");
    auto foreign = qrzSample();
    foreign["dxcc"] = "1";  // Canada: AZ is not a Canadian province
    FieldMap qf = mapQrz(foreign);
    CHECK(!qf.count("STATE") && !qf.count("CNTY") && qf["COUNTRY"] == "CANADA", "STATE checked against the entity");
    auto accent = qrzSample();
    accent["fname"] = "J\xC3\xBCRG";
    CHECK(!mapQrz(accent).count("NAME"), "non-ASCII values are dropped (ADI is ASCII)");

    FieldMap h = mapHamQth(hamqthSample());
    CHECK(h["NAME"] == "Petr Hlozek" && h["QTH"] == "Neratovice" && h["GRIDSQUARE"] == "jo70gg" && h["DXCC"] == "503" &&
              h["COUNTRY"] == "CZECH REPUBLIC" && h["CQZ"] == "15" && h["ITUZ"] == "28" && h["CONT"] == "EU",
          "HamQTH fields");
    CHECK(h["LAT"] == "N050 04.200" && h["LON"] == "E014 25.200", "HamQTH position: %s %s", h["LAT"].c_str(), h["LON"].c_str());
    CHECK(!h.count("STATE"), "no US state for a Czech station");

    CHECK(lookupCall("VE3/K1ABC/P") == "K1ABC" && lookupCall("k1abc/7") == "K1ABC" && lookupCall("K1ABC/QRP") == "K1ABC" &&
              lookupCall("W1AW") == "W1AW" && lookupCall("KH6/K1ABC") == "K1ABC",
          "base call for lookup");
    CHECK(isPortableCall("K1ABC/P") && !isPortableCall("K1ABC"), "portable calls");
    CHECK(adifLocation(-0.0001, true) == "S000 00.006" && adifLocation(12.99999999, false) == "E013 00.000",
          "location rounding: %s %s", adifLocation(-0.0001, true).c_str(), adifLocation(12.99999999, false).c_str());

    // Proposals: fill missing only; skip location away from home.
    std::string t = std::string(kHeader) +
                    "<CALL:5>AA7BQ <QSO_DATE:8>20261006 <TIME_ON:4>2300 <BAND:3>20m <MODE:3>SSB <NAME:4>Fred <EOR>\n"
                    "<CALL:7>AA7BQ/P <QSO_DATE:8>20261006 <TIME_ON:4>2310 <BAND:3>20m <MODE:3>SSB <EOR>\n"
                    "<CALL:5>AA7BQ <QSO_DATE:8>20261006 <TIME_ON:4>2320 <BAND:3>20m <MODE:3>SSB <SIG_INFO:6>K-1234 <EOR>\n";
    LintResult r = lintModel(t);
    EnrichOptions opt;
    opt.fields = {"NAME", "QTH", "STATE", "CNTY", "GRIDSQUARE", "DXCC", "COUNTRY", "CQZ", "ITUZ"};
    std::vector<EnrichChange> ch;
    for (int gi = 1; gi <= 3; ++gi) proposeChanges(t, r.model, gi, q, opt, "QRZ.com", ch);
    auto changesFor = [&](int group) {
        std::vector<std::string> v;
        for (const EnrichChange &c : ch)
            if (c.group == group) v.push_back(c.field);
        return v;
    };
    std::vector<std::string> first = changesFor(1);
    CHECK(first.size() == 8 && std::find(first.begin(), first.end(), "NAME") == first.end(),
          "record 1: missing fields only (NAME already set), got %zu", first.size());
    CHECK(changesFor(2) == std::vector<std::string>({"NAME"}), "portable call: name only");
    CHECK(changesFor(3) == std::vector<std::string>({"NAME"}), "park-to-park: name only");
    opt.proposeReplacements = true;
    std::vector<EnrichChange> ch2;
    proposeChanges(t, r.model, 1, q, opt, "QRZ.com", ch2);
    bool sawName = false;
    for (const EnrichChange &c : ch2)
        if (c.field == "NAME") sawName = c.replace && !c.accepted && c.current == "Fred";
    CHECK(sawName, "replacement offered unticked when asked for");

    // Apply: one insertion per record, lengths right, lint clean.
    std::vector<TextEdit> edits = enrichmentEdits(t, r.model, ch, LengthUnit::Bytes, true);
    CHECK(edits.size() == 3, "one edit per record, got %zu", edits.size());
    std::string out = t;
    for (auto it = edits.rbegin(); it != edits.rend(); ++it) out = applyEdit(out, *it);
    LintResult ro = lintModel(out);
    CHECK(ro.errors == 0 && ro.warnings == 0, "enriched log lints clean\n%s", dump(ro).c_str());
    CHECK(out.find("<NAME:4>Fred <QTH:10>SCOTTSDALE <STATE:2>AZ <CNTY:11>AZ,Maricopa ") != std::string::npos,
          "fields added before <EOR>:\n%s", out.c_str());
    CHECK(out.find("<CALL:7>AA7BQ/P <QSO_DATE:8>20261006 <TIME_ON:4>2310 <BAND:3>20m <MODE:3>SSB <NAME:12>FRED L LLOYD <EOR>") !=
              std::string::npos,
          "portable record got only the name");

}

// Reformatting the official file must keep every field and marker, in order.
// ── Log tools ───────────────────────────────────────────────────────────────

static int errorsIn(const std::string &t) {
    LintResult r = lint(t);
    return (int)r.errors;
}

static std::string valueOf(const std::string &t, int recordNo, const char *field) {
    LintResult r = lintModel(t);
    for (const Record &rec : records(t, r.model))
        if (rec.number == recordNo) return rec.get(field);
    return "?";
}

static void testToolsBasics() {
    // Dates: ADIF Date is YYYYMMDD of a real calendar date (§II.B); Time is HHMM or HHMMSS.
    long d = 0;
    CHECK(parseAdifDate("20240229", &d) && formatAdifDate(d) == "20240229", "leap day round-trips");
    CHECK(!parseAdifDate("20230229", nullptr) && !parseAdifDate("20241301", nullptr) && !parseAdifDate("2024011", nullptr),
          "impossible dates rejected");
    CHECK(parseAdifDate("19700101", &d) && d == 0, "epoch is day 0");
    int s = 0;
    CHECK(parseAdifTime("2359", &s) && s == 86340 && parseAdifTime("235959", &s) && s == 86399, "times parse");
    CHECK(!parseAdifTime("2400", nullptr) && !parseAdifTime("1260", nullptr) && !parseAdifTime("12345", nullptr),
          "bad times rejected");
    CHECK(formatAdifTime(3661, true) == "010101" && formatAdifTime(3661, false) == "0101", "time formats");
    CHECK(displayDate("20261007") == "2026-10-07" && displayTime("1405") == "14:05" && displayTime("140530") == "14:05:30",
          "display forms");

    std::string t = std::string(kHeader) +
                    "<call:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:3>SSB <STATION_CALLSIGN:4>W1AW "
                    "<NAME:3>Bob <EOR>\n"
                    "<CALL:4>N0CX <QSO_DATE:8>20240115 <TIME_ON:4>1840 <FREQ:5>7.074 <MODE:3>MFSK <SUBMODE:3>FT4 "
                    "<STATION_CALLSIGN:4>W1AW <EOR>\n";
    LintResult r = lintModel(t);
    std::vector<Record> recs = records(t, r.model);
    CHECK(recs.size() == 2 && recs[0].number == 1 && recs[1].number == 2, "two records");
    CHECK(recs[0].get("CALL") == "K1AB" && recs[0].get("call") == "K1AB" && recs[0].fields[0].first == "CALL",
          "names upper-cased, lookups case-insensitive");
    CHECK(effectiveMode(recs[1]) == "FT4" && effectiveBand(recs[1]) == "40m", "SUBMODE supersedes MODE; band from FREQ");
    CHECK(qsoStart(recs[1]) - qsoStart(recs[0]) == 600, "start times 10 minutes apart");

    std::vector<std::string> cols = tableColumns(recs);
    std::vector<std::string> want = {"QSO_DATE", "TIME_ON", "CALL", "BAND", "FREQ", "MODE", "SUBMODE", "NAME", "STATION_CALLSIGN"};
    CHECK(cols == want, "table columns: usual fields first, station fields last");

    std::string rep = summaryReport(t, r.model, "test.adi");
    CHECK(rep.find("Summary of test.adi") == 0, "report title");
    CHECK(rep.find("QSOs (with a CALL)    2") != std::string::npos && rep.find("Callsigns worked      2") != std::string::npos,
          "report counts:\n%s", rep.c_str());
    CHECK(rep.find("20m") != std::string::npos && rep.find("40m") != std::string::npos && rep.find("FT4") != std::string::npos,
          "report bands and modes");
    CHECK(rep.find("2024-01-15 18:30 UTC") != std::string::npos && rep.find("Station callsigns     W1AW") != std::string::npos,
          "report first QSO and station");
}

static void testBulkEdit() {
    std::string t = std::string(kHeader) +
                    "<CALL:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:3>SSB <MY_GRIDSQUARE:6>EM28ab <EOR>\n"
                    "<CALL:4>N0CX <QSO_DATE:8>20240115 <TIME_ON:4>1840 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>W2XY <QSO_DATE:8>20240115 <TIME_ON:4>1850 <BAND:3>40m <MODE:2>CW <MY_GRIDSQUARE:6>EM28AB <EOR>\n";
    LintResult r = lintModel(t);
    std::vector<int> all;
    for (const Record &rec : records(t, r.model)) all.push_back(rec.group);

    // Set: change one, add one, leave the one already right alone.
    BulkEdit op;
    op.field = "my_gridsquare";
    op.value = "EM28AB";
    ChangePlan p = planBulkEdit(t, r.model, all, op);
    CHECK(p.changes.size() == 2 && p.records == 2, "set: 2 changes (%zu)", p.changes.size());
    std::string t2 = applyTextEdits(t, planEdits(t, r.model, p.changes, LengthUnit::Bytes, true));
    CHECK(errorsIn(t2) == 0, "set: result is valid");
    CHECK(valueOf(t2, 1, "MY_GRIDSQUARE") == "EM28AB" && valueOf(t2, 2, "MY_GRIDSQUARE") == "EM28AB" &&
              valueOf(t2, 3, "MY_GRIDSQUARE") == "EM28AB",
          "set: every record has the value");

    op.onlyMissing = true;
    p = planBulkEdit(t, r.model, all, op);
    CHECK(p.changes.size() == 1 && p.changes[0].kind == PlannedChange::Add && p.skipped == 2, "set only where missing");

    // Filter: only CW records.
    RecordFilter cw;
    cw.kind = RecordFilter::Equals;
    cw.field = "MODE";
    cw.value = "cw";
    std::vector<int> cwGroups;
    for (const Record &rec : records(t, r.model))
        if (matchesFilter(rec, cw)) cwGroups.push_back(rec.group);
    CHECK(cwGroups.size() == 2, "filter MODE equals cw (case-insensitive)");

    // Replace text inside values, case-insensitively.
    BulkEdit rep;
    rep.action = BulkAction::Replace;
    rep.field = "MY_GRIDSQUARE";
    rep.find = "ab";
    rep.value = "XY";
    p = planBulkEdit(t, r.model, all, rep);
    CHECK(p.changes.size() == 2 && p.changes[0].after == "EM28XY" && p.changes[1].after == "EM28XY", "replace text");

    // Remove a field everywhere.
    BulkEdit rm;
    rm.action = BulkAction::Remove;
    rm.field = "MY_GRIDSQUARE";
    p = planBulkEdit(t, r.model, all, rm);
    t2 = applyTextEdits(t, planEdits(t, r.model, p.changes, LengthUnit::Bytes, true));
    CHECK(p.changes.size() == 2 && t2.find("MY_GRIDSQUARE") == std::string::npos && errorsIn(t2) == 0, "remove field");
    CHECK(t2.find("<MODE:3>SSB <EOR>") != std::string::npos, "remove keeps one separator");

    // Rename, but not where it would duplicate a field (§IV.A.3: a field appears once per record).
    std::string t3 = std::string(kHeader) + "<CALL:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:2>CW "
                                            "<APP_X_GRID:4>EM28 <EOR>\n"
                                            "<CALL:4>N0CX <QSO_DATE:8>20240115 <TIME_ON:4>1840 <BAND:3>20m <MODE:2>CW "
                                            "<APP_X_GRID:4>EM29 <GRIDSQUARE:4>EM29 <EOR>\n";
    r = lintModel(t3);
    all.clear();
    for (const Record &rec : records(t3, r.model)) all.push_back(rec.group);
    BulkEdit rn;
    rn.action = BulkAction::Rename;
    rn.field = "APP_X_GRID";
    rn.newName = "gridsquare";
    p = planBulkEdit(t3, r.model, all, rn);
    CHECK(p.changes.size() == 1 && p.skipped == 1, "rename skips a record that already has the name");
    t2 = applyTextEdits(t3, planEdits(t3, r.model, p.changes, LengthUnit::Bytes, true));
    CHECK(t2.find("<GRIDSQUARE:4>EM28") != std::string::npos && errorsIn(t2) == 0, "rename keeps the length");

    BulkEdit bad;
    bad.field = "NAME";
    CHECK(planBulkEdit(t3, r.model, all, bad).changes.empty(), "set with no value does nothing");
}

static void testTimeShift() {
    std::string t = std::string(kHeader) +
                    "<CALL:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>2330 <TIME_OFF:4>2350 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>N0CX <QSO_DATE:8>20240101 <TIME_ON:6>001000 <QSO_DATE_OFF:8>20240101 <TIME_OFF:6>001500 "
                    "<BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>W2XY <QSO_DATE:7>2024011 <TIME_ON:4>1850 <BAND:3>40m <MODE:2>CW <EOR>\n";
    LintResult r = lintModel(t);
    std::vector<int> all;
    for (const Record &rec : records(t, r.model)) all.push_back(rec.group);

    ChangePlan p = planTimeShift(t, r.model, all, 20);
    std::string t2 = applyTextEdits(t, planEdits(t, r.model, p.changes, LengthUnit::Bytes, true));
    CHECK(p.records == 2 && p.skipped == 1, "malformed date skipped (%zu, %zu)", p.records, p.skipped);
    CHECK(valueOf(t2, 1, "QSO_DATE") == "20240115" && valueOf(t2, 1, "TIME_ON") == "2350" &&
              valueOf(t2, 1, "TIME_OFF") == "0010",
          "TIME_OFF without QSO_DATE_OFF wraps past midnight (implicitly the next day)");
    CHECK(valueOf(t2, 2, "TIME_ON") == "003000" && valueOf(t2, 2, "TIME_OFF") == "003500", "HHMMSS kept");

    p = planTimeShift(t, r.model, all, -20);
    t2 = applyTextEdits(t, planEdits(t, r.model, p.changes, LengthUnit::Bytes, true));
    CHECK(valueOf(t2, 2, "QSO_DATE") == "20231231" && valueOf(t2, 2, "TIME_ON") == "235000" &&
              valueOf(t2, 2, "QSO_DATE_OFF") == "20231231" && valueOf(t2, 2, "TIME_OFF") == "235500",
          "back across New Year");
    p = planTimeShift(t, r.model, all, 5 * 60);
    t2 = applyTextEdits(t, planEdits(t, r.model, p.changes, LengthUnit::Bytes, true));
    CHECK(valueOf(t2, 1, "QSO_DATE") == "20240116" && valueOf(t2, 1, "TIME_ON") == "0430", "forward 5 hours");
    CHECK(errorsIn(t2) == errorsIn(t), "no new errors");
    CHECK(planTimeShift(t, r.model, all, 0).changes.empty(), "zero shift does nothing");
}

// US Central time in 2026 (US rule: daylight time from the second Sunday in
// March, 02:00 local, to the first Sunday in November, 02:00 local): UTC-6, and
// UTC-5 from 2026-03-08 08:00 UTC to 2026-11-01 07:00 UTC.
static long long centralOffset(long long utc) {
    long spring = 0, fall = 0;
    parseAdifDate("20260308", &spring);
    parseAdifDate("20261101", &fall);
    long long from = (long long)spring * 86400 + 8 * 3600, to = (long long)fall * 86400 + 7 * 3600;
    return utc >= from && utc < to ? -5 * 3600 : -6 * 3600;
}

static long long at(const char *date, const char *time) {
    long d = 0;
    int t = 0;
    parseAdifDate(date, &d);
    parseAdifTime(time, &t);
    return (long long)d * 86400 + t;
}

static void testTimeZones() {
    long long u = 0;
    CHECK(localToUtc(at("20261006", "1730"), centralOffset, &u) == LocalTime::Unique && u == at("20261006", "2230"),
          "CDT 17:30 is 22:30 UTC");
    CHECK(localToUtc(at("20260115", "1200"), centralOffset, &u) == LocalTime::Unique && u == at("20260115", "1800"),
          "CST 12:00 is 18:00 UTC");
    CHECK(localToUtc(at("20260308", "0230"), centralOffset, &u) == LocalTime::Skipped, "02:30 on 8 March never happened");
    CHECK(localToUtc(at("20260308", "0330"), centralOffset, &u) == LocalTime::Unique && u == at("20260308", "0830"),
          "03:30 CDT after the jump");
    CHECK(localToUtc(at("20261101", "0130"), centralOffset, &u) == LocalTime::Repeated && u == at("20261101", "0630"),
          "01:30 on 1 November happened twice; the first is CDT");
    CHECK(localToUtc(at("20261101", "0230"), centralOffset, &u) == LocalTime::Unique && u == at("20261101", "0830"),
          "02:30 CST after the fall back");
    auto india = [](long long) { return 5 * 3600 + 1800LL; };
    CHECK(localToUtc(at("20260101", "0010"), india, &u) == LocalTime::Unique && u == at("20251231", "1840"),
          "UTC+5:30 back across New Year");

    // A log written in Central time, converted to UTC; the impossible and doubled times are left alone.
    std::string t = std::string(kHeader) +
                    "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:6>173015 <TIME_OFF:4>1745 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>N0CX <QSO_DATE:8>20260308 <TIME_ON:4>0230 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>W2XY <QSO_DATE:8>20261101 <TIME_ON:4>0130 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>K9ZZ <QSO_DATE:8>20261231 <TIME_ON:4>2000 <BAND:3>20m <MODE:2>CW <EOR>\n";
    LintResult r = lintModel(t);
    std::vector<int> all;
    for (const Record &rec : records(t, r.model)) all.push_back(rec.group);
    ChangePlan p = planTimeShiftWith(t, r.model, all, [](long long start, long long *sec, std::string *why) {
        long long utc = 0;
        LocalTime k = localToUtc(start, centralOffset, &utc);
        if (k != LocalTime::Unique) {
            *why = k == LocalTime::Skipped ? "skipped" : "repeated";
            return false;
        }
        *sec = utc - start;
        return true;
    });
    std::string t2 = applyTextEdits(t, planEdits(t, r.model, p.changes, LengthUnit::Bytes, true));
    CHECK(p.records == 2 && p.skipped == 2, "two converted, two left alone (%zu, %zu)", p.records, p.skipped);
    CHECK(p.skipReason == "record 2 (N0CX): skipped; record 3 (W2XY): repeated", "reasons name the records: %s",
          p.skipReason.c_str());
    CHECK(valueOf(t2, 1, "TIME_ON") == "223015" && valueOf(t2, 1, "TIME_OFF") == "2245" && valueOf(t2, 4, "QSO_DATE") == "20270101" &&
              valueOf(t2, 4, "TIME_ON") == "0200",
          "CDT +5 h with seconds kept; CST +6 h into the new year");
    CHECK(valueOf(t2, 2, "TIME_ON") == "0230" && valueOf(t2, 3, "TIME_ON") == "0130", "skipped records unchanged");

    // And back: UTC to Central time.
    r = lintModel(t2);
    p = planTimeShiftWith(t2, r.model, std::vector<int>{r.model.groups[1].header ? 2 : 1}, [](long long start, long long *sec, std::string *) {
        *sec = centralOffset(start);
        return true;
    });
    std::string t3 = applyTextEdits(t2, planEdits(t2, r.model, p.changes, LengthUnit::Bytes, true));
    CHECK(valueOf(t3, 1, "TIME_ON") == "173015" && valueOf(t3, 1, "QSO_DATE") == "20261006", "UTC back to CDT: %s",
          valueOf(t3, 1, "TIME_ON").c_str());
}

static void testSortDupesMerge() {
    std::string t = std::string(kHeader) + "\n" +
                    "<CALL:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>1850 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>N0CX <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "// worked twice\n"
                    "<CALL:4>W2XY <QSO_DATE:8>20240114 <TIME_ON:4>1840 <BAND:3>40m <MODE:2>CW <EOR>\n"
                    "<CALL:4>Z9ZZ <BAND:3>40m <MODE:2>CW <EOR>\n";
    LintResult r = lintModel(t);
    bool changed = false;
    std::string s = sortedByTime(t, r.model, "\n", &changed);
    CHECK(changed, "order changed");
    size_t w2 = s.find("W2XY"), n0 = s.find("N0CX"), k1 = s.find("K1AB"), z9 = s.find("Z9ZZ"), c = s.find("// worked twice");
    CHECK(w2 < n0 && n0 < k1 && k1 < z9, "by date and time, undated last:\n%s", s.c_str());
    CHECK(c != std::string::npos && c < w2 && s.find("<EOH>\n\n// worked twice\n<CALL:4>W2XY") != std::string::npos,
          "comment moves with its record:\n%s", s.c_str());
    LintResult rs = lintModel(s);
    CHECK(rs.records == 4 && rs.errors == r.errors, "same records, no new errors");
    sortedByTime(s, rs.model, "\n", &changed);
    CHECK(!changed, "already sorted");

    // Duplicates: same call, band, mode within the window; park-to-park lines for different parks are not.
    std::string d = std::string(kHeader) +
                    "<CALL:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>k1ab <QSO_DATE:8>20240115 <TIME_ON:6>183045 <BAND:3>20M <MODE:2>CW <NAME:3>Bob <EOR>\n"
                    "<CALL:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>1900 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>N0CX <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:3>SSB <SIG:4>POTA <SIG_INFO:6>K-0001 <EOR>\n"
                    "<CALL:4>N0CX <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:3>SSB <SIG:4>POTA <SIG_INFO:6>K-0002 <EOR>\n"
                    "<CALL:4>W2XY <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>W2XY <QSO_DATE:8>20240115 <TIME_ON:4>1831 <BAND:3>20m <MODE:2>CW <QTH:3>Rye <EOR>\n";
    r = lintModel(d);
    std::vector<DupeSet> sets = findDuplicates(d, r.model, DupeOptions());
    CHECK(sets.size() == 2, "two duplicate sets (%zu)", sets.size());
    if (sets.size() == 2) {
        CHECK(recordNumber(r.model, sets[0].keep) == 2 && sets[0].remove.size() == 1 &&
                  recordNumber(r.model, sets[0].remove[0]) == 1,
              "keeps the record with more fields");
        CHECK(recordNumber(r.model, sets[1].keep) == 7 && sets[1].fill.empty(), "W2XY keeps record 7");
    }
    std::string dd = applyTextEdits(d, duplicateEdits(d, r.model, sets, true, LengthUnit::Bytes, true));
    LintResult rd = lintModel(dd);
    CHECK(rd.records == 5 && rd.errors == 0, "two records removed, still valid:\n%s", dd.c_str());
    CHECK(dd.find("<EOR>\n<EOR>") == std::string::npos && dd.find("\n\n") == std::string::npos, "no gaps left behind");

    // Fill: the kept record gains what only the removed one had.
    std::string f = std::string(kHeader) +
                    "<CALL:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:2>CW <NAME:3>Bob <QTH:3>Rye <EOR>\n"
                    "<CALL:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>1831 <BAND:3>20m <MODE:2>CW <GRIDSQUARE:4>FN31 <EOR>\n";
    r = lintModel(f);
    sets = findDuplicates(f, r.model, DupeOptions());
    std::string ff = applyTextEdits(f, duplicateEdits(f, r.model, sets, true, LengthUnit::Bytes, true));
    CHECK(sets.size() == 1 && sets[0].fill.size() == 1 && valueOf(ff, 1, "GRIDSQUARE") == "FN31" &&
              lintModel(ff).records == 1 && errorsIn(ff) == 0,
          "fill missing fields:\n%s", ff.c_str());

    // Merge: add the other log's new QSOs in this log's layout.
    std::string target = std::string(kHeader) +
                         "<CALL:4>K1AB\n<QSO_DATE:8>20240115\n<TIME_ON:4>1830\n<BAND:3>20m\n<MODE:2>CW\n<EOR>\n";
    std::string source = "other log\n<ADIF_VER:5>3.1.7 <USERDEF1:8:N>EPC_RANK <EOH>\n"
                         "<CALL:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>1831 <BAND:3>20m <MODE:2>CW <EOR>\n"
                         "<CALL:4>N0CX <QSO_DATE:8>20240116 <TIME_ON:4>0100 <BAND:3>40m <MODE:3>SSB <NAME:5>José <EOR>\n"
                         "<CALL:4>N0CX <QSO_DATE:8>20240116 <TIME_ON:4>0100 <BAND:3>40m <MODE:3>SSB <EOR>\n"
                         "<EOR>\n";
    LintResult rt = lintModel(target), rsrc = lintModel(source);
    MergePlan mp = planMerge(target, rt.model, source, rsrc.model, DupeOptions(), true);
    CHECK(mp.add.size() == 1 && mp.duplicates.size() == 2 && mp.emptyRecords == 1, "merge: 1 new, 2 duplicates, 1 empty");
    CHECK(mp.duplicates.size() == 2 && mp.duplicates[0].second == (int)rt.model.groups.size() - 1 && mp.duplicates[1].second == -1,
          "duplicate of a target record, then of an added one");
    CHECK(mp.undefinedFields.size() == 1 && mp.undefinedFields[0] == "EPC_RANK", "USERDEF the target lacks");
    std::string add = mergedRecords(source, rsrc.model, mp.add, recordLayout(target, rt.model), "\n", LengthUnit::Bytes, true);
    size_t at = 0;
    std::string merged = applyTextEdits(target, {appendRecord(target, rt.model, add, "\n", &at)});
    LintResult rm = lintModel(merged);
    CHECK(rm.records == 2 && rm.fixes.empty() && add.find("<CALL:4>N0CX\n") == 0, "merged in field-per-line layout:\n%s",
          merged.c_str());
    CHECK(add.find("<NAME:5>José") != std::string::npos, "lengths in bytes");
    std::string addChars = mergedRecords(source, rsrc.model, mp.add, Layout::RecordPerLine, "\n", LengthUnit::Characters, true);
    CHECK(addChars.find("<NAME:4>José <EOR>\n") != std::string::npos, "lengths recounted in characters:\n%s", addChars.c_str());
    MergePlan all = planMerge(target, rt.model, source, rsrc.model, DupeOptions(), false);
    CHECK(all.add.size() == 3, "merge everything when not skipping duplicates");
}

static void testCsv() {
    std::vector<Record> recs(1);
    recs[0].fields = {{"CALL", "K1AB"}, {"COMMENT", "Hi, \"Bob\"\nbye"}, {"RST_SENT", "-10"}, {"NAME", "=HYPERLINK(\"x\")"},
                      {"QTH", "@home"}};
    std::string csv = toCsv(recs, {"CALL", "COMMENT", "RST_SENT", "NAME", "QTH", "GRIDSQUARE"});
    CHECK(csv == "CALL,COMMENT,RST_SENT,NAME,QTH,GRIDSQUARE\r\n"
                 "K1AB,\"Hi, \"\"Bob\"\"\nbye\",-10,\"'=HYPERLINK(\"\"x\"\")\",'@home,\r\n",
          "RFC 4180 quoting and formula guard:\n%s", csv.c_str());
}

static void testPota() {
    // ADIF 3.1.7 POTARef: xxxx-nnnnn[@yyyyyy], 1-4 character program, 4 or 5 digits, ISO 3166-2 location.
    for (const char *ok : {"K-5033", "K-10000", "VE-5082@CA-AB", "K-4562@US-CA", "US-7929", "8P-0012"})
        CHECK(isPotaRef(ok), "%s is a park", ok);
    for (const char *bad : {"US-79", "K-123456", "K5033", "-1234", "TOOLONG-1234", "K-5033@US", "K-5033@USCA12"})
        CHECK(!isPotaRef(bad), "%s is not a park", bad);

    Record r;
    r.fields = {{"MY_POTA_REF", "k-0817, K-4566@US-WY"}};
    CHECK(myParks(r) == std::vector<std::string>({"K-0817", "K-4566@US-WY"}), "MY_POTA_REF list");
    r.fields = {{"MY_SIG", "POTA"}, {"MY_SIG_INFO", "US-7929"}};
    CHECK(myParks(r) == std::vector<std::string>({"US-7929"}), "MY_SIG POTA + MY_SIG_INFO");
    r.fields = {{"MY_SIG", "SOTA"}, {"MY_SIG_INFO", "W7A/AE-001"}};
    CHECK(myParks(r).empty(), "other programs are not parks");
    r.fields = {{"MY_SIG_INFO", "US-7929"}};
    CHECK(myParks(r).size() == 1, "MY_SIG_INFO alone when it is a park reference");
    r.fields = {{"SIG", "POTA"}, {"SIG_INFO", "US-1234"}};
    CHECK(theirParks(r) == std::vector<std::string>({"US-1234"}), "park-to-park");

    // Rules: 10 QSOs in one UTC day; repeats of CALL/BAND/MODE/SIG_INFO do not count; working yourself is invalid.
    std::string t = std::string(kHeader);
    auto rec = [](const std::string &call, const char *date, const char *time, const char *band, const char *mode,
                  const std::string &extra) {
        return "<CALL:" + std::to_string(call.size()) + ">" + call + " <QSO_DATE:8>" + date + " <TIME_ON:4>" + time +
               " <BAND:3>" + band + " <MODE:" + std::to_string(std::strlen(mode)) + ">" + mode +
               " <STATION_CALLSIGN:4>KW9D <MY_SIG:4>POTA <MY_SIG_INFO:7>US-7929 " + extra + "<EOR>\n";
    };
    for (int i = 0; i < 9; ++i) t += rec("K1A" + std::string(1, (char)('A' + i)), "20261006", "2200", "20m", "SSB", "");
    t += rec("K1AA", "20261006", "2210", "20m", "SSB", "");                                   // duplicate
    t += rec("K1AA", "20261006", "2211", "40m", "SSB", "");                                   // new band: counts
    t += rec("N0CX", "20261006", "2212", "20m", "SSB", "<SIG:4>POTA <SIG_INFO:7>US-0001 ");  // park-to-park
    t += rec("N0CX", "20261006", "2213", "20m", "SSB", "<SIG:4>POTA <SIG_INFO:7>US-0002 ");  // other park: counts
    t += rec("KW9D", "20261006", "2214", "20m", "SSB", "");                                   // own call: invalid
    t += rec("W2XY", "20261007", "0005", "20m", "CW", "");                                    // next UTC day
    LintResult m = lintModel(t);
    CHECK(m.errors == 0, "fixture is valid:\n%s", dump(m).c_str());
    std::vector<Activation> acts = activations(t, m.model);
    CHECK(acts.size() == 2, "two park-days (%zu)", acts.size());
    if (acts.size() == 2) {
        const Activation &a = acts[0];
        CHECK(a.park == "US-7929" && a.date == "20261006" && a.station == "KW9D", "first activation");
        CHECK(a.qsos == 12 && a.duplicates == 1 && a.invalid == 1 && a.p2p == 2 && a.activated(),
              "counts: %zu qsos, %zu dupes, %zu invalid, %zu p2p", a.qsos, a.duplicates, a.invalid, a.p2p);
        CHECK(a.first == "220000" && a.last == "221400" && a.bands.at("40m") == 1, "times and bands");
        CHECK(acts[1].date == "20261007" && acts[1].qsos == 1 && !acts[1].activated(), "second day separate");
    }

    // Export: one file per park and day, named callsign@park-date; a two-fer gives one file per park.
    std::string two = std::string(kHeader) +
                      "<CALL:4>K1AB <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:2>CW "
                      "<MY_POTA_REF:20>US-1234,K-4562@US-CA <EOR>\n";
    m = lintModel(two);
    std::vector<PotaFile> files = potaExport(two, m.model, "k0nr/p", "0.7.0", "20261007 120000", "\n", LengthUnit::Bytes,
                                             true, "20261007");
    CHECK(files.size() == 2, "two files for a two-fer (%zu)", files.size());
    if (files.size() == 2) {
        CHECK(files[0].name == "K0NR_P@K-4562-20240115-US-CA.adi" && files[1].name == "K0NR_P@US-1234-20240115.adi",
              "names: %s, %s", files[0].name.c_str(), files[1].name.c_str());
        LintResult fr = lintModel(files[1].text);
        std::vector<Record> fx = records(files[1].text, fr.model);
        CHECK(fr.errors == 0 && fx.size() == 1, "exported file is valid:\n%s%s", files[1].text.c_str(), dump(fr).c_str());
        if (fx.size() == 1) {
            CHECK(fx[0].get("MY_SIG") == "POTA" && fx[0].get("MY_SIG_INFO") == "US-1234" &&
                      fx[0].get("MY_POTA_REF") == "US-1234" && fx[0].get("STATION_CALLSIGN") == "K0NR/P",
                  "park fields and station call");
        }
        CHECK(files[0].text.find("<MY_SIG_INFO:6>K-4562") != std::string::npos &&
                  files[0].text.find("<MY_POTA_REF:12>K-4562@US-CA") != std::string::npos,
              "location stays in MY_POTA_REF");
        CHECK(!files[0].notes.empty() && files[0].notes[0].find("short of the 10") != std::string::npos, "short activation noted");
    }
}

static void testSpots() {
    CHECK(khzToMHz("14059.1") == "14.0591" && khzToMHz("14282") == "14.282" && khzToMHz("7074.0") == "7.074" &&
              khzToMHz("146520") == "146.520" && khzToMHz("x").empty() && khzToMHz("14.").empty() && khzToMHz("").empty(),
          "kHz to MHz");
    auto get = [](const std::vector<std::pair<std::string, std::string>> &v, const char *k) {
        for (const auto &p : v)
            if (p.first == k) return p.second;
        return std::string("-");
    };
    auto f = spotFields("wg0y", "14059.1", "CW", "US-12593");
    CHECK(get(f, "CALL") == "WG0Y" && get(f, "FREQ") == "14.0591" && get(f, "BAND") == "20m" && get(f, "MODE") == "CW" &&
              get(f, "SUBMODE") == "-" && get(f, "SIG") == "POTA" && get(f, "SIG_INFO") == "US-12593" &&
              get(f, "POTA_REF") == "US-12593",
          "CW spot");
    CHECK(get(spotFields("K1AB", "7185", "SSB", "US-0001"), "SUBMODE") == "LSB" &&
              get(spotFields("K1AB", "5357", "SSB", "US-0001"), "SUBMODE") == "USB" &&
              get(spotFields("K1AB", "14282", "SSB", "US-0001"), "SUBMODE") == "USB",
          "SSB sideband: LSB below 10 MHz except 60 m");
    auto ft4 = spotFields("K1AB", "14080.0", "FT4", "US-0001");
    CHECK(get(ft4, "MODE") == "MFSK" && get(ft4, "SUBMODE") == "FT4", "FT4 is MFSK/FT4");
    CHECK(get(spotFields("K1AB", "14074.0", "FT8", "US-0001"), "MODE") == "FT8", "FT8");
    auto unknown = spotFields("K1AB<x>", "abc", "", "not a park");
    CHECK(get(unknown, "CALL") == "-" && get(unknown, "FREQ") == "-" && get(unknown, "MODE") == "-" && get(unknown, "SIG") == "-",
          "bad values left out");
}

static void testWorkedBefore() {
    std::string t = std::string(kHeader) +
                    "<CALL:10>VE3/K1AB/P <QSO_DATE:8>20240115 <TIME_ON:4>1830 <BAND:3>20m <MODE:2>CW <EOR>\n";
    LintResult r = lintModel(t);
    std::vector<Contact> cs = contacts(t, r.model);
    CHECK(cs.size() == 1 && cs[0].baseCall == "K1AB" && cs[0].band == "20m", "contact with base call");
    std::vector<WorkedHit> hits = {{"a.adi", cs[0]}, {"b.adi", cs[0]}};
    hits[1].contact.date = "20240301";
    hits[1].contact.band = "40m";
    std::string s = workedSummary("k1ab", hits);
    CHECK(s.find("K1AB: 2 QSOs in 2 other logs; last 2024-03-01 18:30 on 40m CW (b.adi).") == 0 &&
              s.find("Bands: 40m, 20m.") != std::string::npos,
          "summary: %s", s.c_str());
    CHECK(workedSummary("K1AB", {}).empty(), "nothing worked");
}

// ── Frequencies ─────────────────────────────────────────────────────────────

static void testFrequencies() {
    CHECK(hzToMHz("14074000") == "14.074" && hzToMHz("7000000") == "7.000" && hzToMHz("144390000") == "144.390" &&
              hzToMHz("14285500") == "14.2855" && hzToMHz("1840123") == "1.840123" && hzToMHz(" 5332000\n") == "5.332",
          "Hz to MHz: %s %s", hzToMHz("14285500").c_str(), hzToMHz("1840123").c_str());
    CHECK(hzToMHz("14074000.000000") == "14.074" && hzToMHz("7074000.6") == "7.074001", "decimal Hz rounded");
    CHECK(hzToMHz("").empty() && hzToMHz("14.07x").empty() && hzToMHz("-5").empty() && hzToMHz("abc").empty() &&
              hzToMHz(".5").empty(),
          "non-numbers");
    CHECK(bandForFrequency(hzToMHz("14074000")) == "20m" && bandForFrequency(hzToMHz("50313000")) == "6m", "band from Hz");
}

// ── Uploads ─────────────────────────────────────────────────────────────────

static void testUpload() {
    // The status fields exist in ADIF 3.1.7 with the enumerations used.
    for (UploadService s : {UploadService::QRZ, UploadService::LoTW, UploadService::ClubLog, UploadService::EQSL}) {
        UploadFields f = uploadFields(s);
        const FieldDef *st = findField(f.status), *dt = findField(f.date);
        CHECK(st && dt && st->type == DataType::Enumeration && dt->type == DataType::Date, "%s fields", f.status);
        if (st) CHECK(findEnumValue(*findEnum(st->enumeration), "Y") != nullptr, "%s has Y", f.status);
    }

    std::string t = std::string(kHeader) +
                    "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>SSB <STATION_CALLSIGN:4>KW9D "
                    "<QRZCOM_QSO_UPLOAD_STATUS:1>Y <QRZCOM_QSO_UPLOAD_DATE:8>20261006 <EOR>\n"
                    "<CALL:4>N0CX <QSO_DATE:8>20261006 <TIME_ON:4>2205 <BAND:3>20m <MODE:3>SSB <QRZCOM_QSO_UPLOAD_STATUS:1>N "
                    "<LOTW_QSL_SENT:1>I <EOR>\n"
                    "<CALL:4>W2XY <QSO_DATE:8>20261006 <TIME_ON:4>2210 <BAND:3>20m <MODE:3>SSB <QRZCOM_QSO_UPLOAD_STATUS:1>M "
                    "<LOTW_QSL_SENT:1>R <EOR>\n"
                    "<CALL:4>K9ZZ <QSO_DATE:8>20261006 <TIME_ON:4>2215 <FREQ:6>14.285 <EOR>\n"
                    "<CALL:4>WA1A <QSO_DATE:8>20261006 <TIME_ON:4>2220 <BAND:3>40m <MODE:2>CW <EOR>\n";
    LintResult r = lintModel(t);
    std::vector<UploadItem> q = uploadItems(t, r.model, UploadService::QRZ);
    CHECK(q.size() == 5, "5 items");
    if (q.size() == 5) {
        CHECK(q[0].done && !uploadWanted(q[0]), "Y: already uploaded");
        CHECK(q[1].skip && !uploadWanted(q[1]), "N: do not upload (ADIF QSO_Upload_Status)");
        CHECK(q[2].replace && uploadWanted(q[2]), "M: modified, sent again with REPLACE");
        CHECK(q[3].problem == "no MODE" && !uploadWanted(q[3]), "missing MODE: %s", q[3].problem.c_str());
        CHECK(uploadWanted(q[4]) && q[4].band == "40m" && q[4].mode == "CW", "new record wanted");
    }
    std::vector<UploadItem> l = uploadItems(t, r.model, UploadService::LoTW);
    CHECK(l.size() == 5 && uploadWanted(l[0]) && l[1].skip && uploadWanted(l[2]), "LoTW: I skipped, R and empty wanted");

    std::string adi = recordAdi(t, r.model, q[0].group);
    CHECK(adi == "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>SSB <STATION_CALLSIGN:4>KW9D <EOR>",
          "record ADI without status fields: %s", adi.c_str());
    std::string file = uploadFile(t, r.model, {q[0].group, q[4].group}, "0.7.0", "20261007 120000");
    LintResult fr = lintModel(file);
    CHECK(fr.records == 2 && fr.errors == 0 && fr.hasHeader, "upload file is valid ADIF:\n%s", file.c_str());

    CHECK(formEncode("a b&c=<d>") == "a%20b%26c%3D%3Cd%3E" && formDecode("a+b%26c%3d") == "a b&c=", "form encoding");
    std::string body = qrzInsertBody("ABCD-1234", "<CALL:4>K1AB <EOR>", true);
    CHECK(body == "KEY=ABCD-1234&ACTION=INSERT&ADIF=%3CCALL%3A4%3EK1AB%20%3CEOR%3E&OPTION=REPLACE", "QRZ body: %s", body.c_str());
    CHECK(qrzStatusBody("K") == "KEY=K&ACTION=STATUS", "QRZ status body");
    QrzReply qr = parseQrzReply("RESULT=OK&LOGID=130877&COUNT=1\n");
    CHECK(qr.ok() && qr.logid == "130877" && qr.count == "1", "QRZ OK");
    qr = parseQrzReply("RESULT=FAIL&REASON=Unable to add QSO to database: duplicate&EXTENDED=");
    CHECK(!qr.ok() && qr.duplicate() && qr.reason == "Unable to add QSO to database: duplicate", "QRZ duplicate");
    qr = parseQrzReply("RESULT=AUTH&REASON=invalid api key");
    CHECK(!qr.ok() && !qr.duplicate() && qr.result == "AUTH", "QRZ auth");
    CHECK(parseQrzReply("<html>oops</html>").result.empty(), "QRZ unreadable");

    EqslReply e = parseEqslReply("<HTML><!-- Reply form eQSL.cc ADIF Real-time Interface -->\r\n<BODY>Information: Received 120 bytes<BR>"
                                 "Result: 1 out of 1 records added<BR></BODY></HTML>");
    CHECK(e.added == 1 && e.total == 1 && e.errors.empty() && !e.duplicate && e.info.size() == 1, "eQSL added");
    e = parseEqslReply("Result: 0 out of 1 records added<BR>Warning: Y=2026 M=10 D=06 K1AB Bad record: Duplicate<BR>");
    CHECK(e.added == 0 && e.duplicate && e.warnings.size() == 1, "eQSL duplicate");
    e = parseEqslReply("Error: No match on eQSL_User/eQSL_Pswd<BR>");
    CHECK(e.added == -1 && e.errors.size() == 1 && e.errors[0] == "No match on eQSL_User/eQSL_Pswd", "eQSL error");

    CHECK(tqslExitMeaning(0).find("uploaded") != std::string::npos && tqslExitMeaning(11).find("LoTW") != std::string::npos &&
              tqslExitMeaning(42) == "TQSL exit code 42",
          "TQSL exit codes");

    // Marking: change an existing status, add the missing ones, one edit per record.
    std::vector<TextEdit> edits = markUploaded(t, r.model, {q[0].group, q[2].group, q[4].group}, UploadService::QRZ, "20261007",
                                               LengthUnit::Bytes, true);
    std::string marked = applyTextEdits(t, edits);
    LintResult mr = lintModel(marked);
    std::vector<Record> recs = records(marked, mr.model);
    CHECK(mr.errors == r.errors && recs.size() == 5, "marking keeps the log valid");
    if (recs.size() == 5) {
        CHECK(recs[0].get("QRZCOM_QSO_UPLOAD_STATUS") == "Y" && recs[0].get("QRZCOM_QSO_UPLOAD_DATE") == "20261007" &&
                  recs[2].get("QRZCOM_QSO_UPLOAD_STATUS") == "Y" && recs[4].get("QRZCOM_QSO_UPLOAD_STATUS") == "Y" &&
                  recs[4].get("QRZCOM_QSO_UPLOAD_DATE") == "20261007" && recs[1].get("QRZCOM_QSO_UPLOAD_STATUS") == "N",
              "status and date set:\n%s", marked.c_str());
    }
    std::string mp = multipartBody({{"email", "a@b.c", ""}, {"file", "<EOR>", "log.adi"}}, "XyZ");
    CHECK(mp == "--XyZ\r\nContent-Disposition: form-data; name=\"email\"\r\n\r\na@b.c\r\n"
                "--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"log.adi\"\r\nContent-Type: application/octet-stream"
                "\r\n\r\n<EOR>\r\n--XyZ--\r\n",
          "multipart:\n%s", mp.c_str());
}

// ── Fixes found in review (2026-10-07) ──────────────────────────────────────

static void testReviewFixes() {
    // New QSO's repeat rule follows POTA: another park is another contact.
    std::string d = std::string(kHeader) +
                    "<CALL:4>N0CX <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>SSB <SUBMODE:3>USB <SIG:4>POTA "
                    "<SIG_INFO:7>US-0001 <EOR>\n"
                    "<CALL:6>K1AB/P <QSO_DATE:8>20261006 <TIME_ON:4>2205 <BAND:3>40m <MODE:2>CW <EOR>\n";
    LintResult r = lintModel(d);
    Record q;
    q.fields = {{"CALL", "N0CX"}, {"QSO_DATE", "20261006"}, {"BAND", "20m"}, {"MODE", "SSB"}, {"SIG_INFO", "US-0002"}};
    CHECK(sameContactAs(d, r.model, q).empty(), "a different park is not a repeat");
    q.fields[4].second = "US-0001";
    CHECK(sameContactAs(d, r.model, q) == std::vector<int>({1}), "the same park is");
    q.fields.pop_back();
    CHECK(sameContactAs(d, r.model, q).size() == 1, "no park given: still a repeat (MODE matches; SUBMODE only one side)");
    q.fields[3].second = "CW";
    CHECK(sameContactAs(d, r.model, q).empty(), "another mode is not");
    CHECK(timesWorkedAs(d, r.model, "K1AB") == 1 && timesWorkedAs(d, r.model, "VE3/K1AB") == 1 && timesWorkedAs(d, r.model, "W2XY") == 0,
          "portable forms count as the same station");

    // A record without a station callsign belongs to the log's usual station.
    std::string b = std::string(kHeader) +
                    "<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>SSB <STATION_CALLSIGN:4>KW9D "
                    "<MY_SIG:4>POTA <MY_SIG_INFO:7>US-7929 <EOR>\n"
                    "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>2201 <BAND:3>20m <MODE:3>SSB <MY_SIG:4>POTA <MY_SIG_INFO:7>US-7929 <EOR>\n";
    r = lintModel(b);
    std::vector<Activation> acts = activations(b, r.model);
    CHECK(acts.size() == 1 && acts[0].qsos == 2 && acts[0].station == "KW9D" && acts[0].noStation == 1,
          "one activation of 2 QSOs (%zu)", acts.size());
    std::vector<PotaFile> files = potaExport(b, r.model, "", "0", "x", "\n", LengthUnit::Bytes, true, "20261007");
    CHECK(files.size() == 1 && files[0].records == 2 && files[0].text.find("<CALL:4>K1AB <QSO_DATE:8>20261006") != std::string::npos &&
              files[0].notes.size() == 2 && files[0].notes[1] == "STATION_CALLSIGN KW9D added to 1 record",
          "one file, the record given KW9D");
    // Names never clash, even when two stations map to one file name.
    std::string clash = std::string(kHeader) +
                        "<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>SSB <STATION_CALLSIGN:6>KW9D/P "
                        "<MY_SIG_INFO:7>US-7929 <EOR>\n"
                        "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>2201 <BAND:3>20m <MODE:3>SSB <STATION_CALLSIGN:6>KW9D_P "
                        "<MY_SIG_INFO:7>US-7929 <EOR>\n";
    r = lintModel(clash);
    files = potaExport(clash, r.model, "", "0", "x", "\n", LengthUnit::Bytes, true, "20261007");
    CHECK(files.size() == 2 && files[0].name != files[1].name && files[1].name == "KW9D_P@US-7929-20261006-2.adi",
          "unique names: %s", files.size() == 2 ? files[1].name.c_str() : "");
    // A park listed twice is one park.
    std::string c = std::string(kHeader) + "<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>SSB "
                                           "<STATION_CALLSIGN:4>KW9D <MY_POTA_REF:15>US-1234,us-1234 <EOR>\n";
    r = lintModel(c);
    acts = activations(c, r.model);
    CHECK(acts.size() == 1 && acts[0].groups.size() == 1, "repeated park counted once");

    // Upload status: an edited QSO that was uploaded becomes M (ADIF QSO_Upload_Status).
    CHECK(isTrackingField("QSL_RCVD") && isTrackingField("lotw_qsl_sent") && isTrackingField("APP_X") &&
              isTrackingField("QRZCOM_QSO_UPLOAD_STATUS") && !isTrackingField("NAME") && !isTrackingField("QSL_VIA") &&
              !isTrackingField("GRIDSQUARE"),
          "tracking fields");
    std::string u = std::string(kHeader) +
                    "<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>SSB <QRZCOM_QSO_UPLOAD_STATUS:1>Y "
                    "<CLUBLOG_QSO_UPLOAD_STATUS:1>N <LOTW_QSL_SENT:1>Y <EOR>\n"
                    "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>2201 <BAND:3>20m <MODE:3>SSB <CLUBLOG_QSO_UPLOAD_STATUS:1>Y <EOR>\n";
    r = lintModel(u);
    std::string u2 = applyTextEdits(u, markModified(u, r.model, {1, 1, 2}, LengthUnit::Bytes, true));
    CHECK(u2.find("<QRZCOM_QSO_UPLOAD_STATUS:1>M <CLUBLOG_QSO_UPLOAD_STATUS:1>N <LOTW_QSL_SENT:1>Y") != std::string::npos &&
              u2.find("<CLUBLOG_QSO_UPLOAD_STATUS:1>M <EOR>") != std::string::npos && u2.size() == u.size(),
          "Y becomes M for QRZ.com and Club Log only; N and LoTW untouched:\n%s", u2.c_str());
    // Merging: an edit overlapping one already planned is dropped.
    std::vector<TextEdit> merged = mergeEdits({{10, 20, "a"}, {30, 30, "b"}}, {{15, 16, "x"}, {20, 25, "y"}, {30, 30, "z"}, {31, 31, "w"}});
    CHECK(merged.size() == 4 && merged[1].text == "y" && merged[3].text == "w", "merge keeps only non-overlapping extras");

    // Record keys survive edits elsewhere.
    std::string k = std::string(kHeader) + "<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>SSB <EOR>\n"
                                           "<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2200 <BAND:3>20m <MODE:3>SSB <EOR>\n";
    r = lintModel(k);
    std::vector<std::string> keys = recordKeys(records(k, r.model));
    CHECK(keys.size() == 2 && keys[0] == "K1AA|20261006|2200|20m|SSB" && keys[1] == "K1AA|20261006|2200|20m|SSB#2", "keys");
}

// ── Features added 2026-10-07: distance, country data, SOTA/WWFF, hunting, CSV, Cabrillo, confirmations ──

static std::string gCtyPath;

static void testGeo() {
    double lat = 0, lon = 0;
    CHECK(gridToLatLon("FN31", &lat, &lon) && lat == 41.5 && lon == -73.0, "FN31 centre: %f %f", lat, lon);
    CHECK(gridToLatLon("fn31pr", &lat, &lon) && std::fabs(lat - 41.729167) < 1e-5 && std::fabs(lon + 72.708333) < 1e-5,
          "FN31pr centre");
    CHECK(!gridToLatLon("ZZ99", &lat, &lon) && !gridToLatLon("FN3", &lat, &lon), "not locators");
    // Expected values from an independent haversine on the same centres.
    CHECK(gridDistanceKm("FN31pr", "IO91wm") == "5415" && gridDistanceKm("EM28", "DM32") == "1757" &&
              gridDistanceKm("FN31", "FN31") == "0",
          "distances: %s %s", gridDistanceKm("FN31pr", "IO91wm").c_str(), gridDistanceKm("EM28", "DM32").c_str());
    CHECK(gridDistanceText("FN31pr", "IO91wm") == "5,415 km at 52\xC2\xB0" && gridDistanceText("EM28", "DM32") == "1,757 km at 253\xC2\xB0",
          "text: %s", gridDistanceText("FN31pr", "IO91wm").c_str());
    CHECK(gridDistanceKm("", "FN31").empty(), "needs both");
}

static void testCountry() {
    std::ifstream in(gCtyPath, std::ios::binary);
    std::stringstream ss;
    ss << in.rdbuf();
    CountryTable t;
    std::string error;
    CHECK(t.load(ss.str(), &error) && t.entities() > 300, "cty.csv loads (%zu entities) %s", t.entities(), error.c_str());
    CountryInfo c;
    CHECK(t.lookup("K1AB", &c) && c.dxcc == 291 && c.cq == 5 && c.itu == 8 && c.continent == "NA", "K1AB: USA, CQ 5, ITU 8");
    CHECK(t.lookup("W0ABC", &c) && c.dxcc == 291 && c.cq == 4 && c.itu == 7, "W0: zone overrides (4)[7]");
    CHECK(t.lookup("VE3ABC", &c) && c.dxcc == 1, "VE3: Canada");
    CHECK(t.lookup("VE3/K1AB", &c) && c.dxcc == 1 && t.lookup("K1AB/VE3", &c) && c.dxcc == 1, "portable in Canada");
    CHECK(t.lookup("K1AB/P", &c) && c.dxcc == 291 && t.lookup("K1AB/4", &c) && c.dxcc == 291, "suffixes ignored");
    CHECK(t.lookup("KH6ABC", &c) && c.dxcc == 110 && t.lookup("KH6/K1AB", &c) && c.dxcc == 110, "Hawaii");
    CHECK(!t.lookup("K1AB/MM", &c) && !t.lookup("", &c), "maritime mobile and empty: no entity");
    CHECK(t.lookup("G4ABC", &c) && c.dxcc == 223 && t.lookup("EA8ABC", &c) && c.dxcc == 29, "England, Canary Islands");
    CHECK(t.lookup("IG9ABC", &c) && c.dxcc == 248 && c.cq == 33 && c.continent == "AF", "IG9: Italy for DXCC, CQ 33, Africa");
    FieldMap f = countryFields(t, "k1ab");
    CHECK(f["DXCC"] == "291" && f["COUNTRY"] == "UNITED STATES OF AMERICA" && f["CQZ"] == "5" && f["ITUZ"] == "8" && f["CONT"] == "NA",
          "fields with ADIF's entity name");
    CountryTable bad;
    CHECK(!bad.load("not,a,country,file\n", &error) && !error.empty(), "a wrong file is refused");
}

static void testPrograms() {
    auto rec = [](const std::string &call, const char *date, const char *band, const char *extra) {
        return "<CALL:" + std::to_string(call.size()) + ">" + call + " <QSO_DATE:8>" + date + " <TIME_ON:4>1200 <BAND:" +
               std::to_string(std::strlen(band)) + ">" + band + " <MODE:2>CW <STATION_CALLSIGN:4>KW9D " + extra + "<EOR>\n";
    };
    // WWFF: 44 over two days; the same call again the next day counts.
    std::string w = std::string(kHeader);
    for (int i = 0; i < 30; ++i) w += rec("K1A" + std::to_string(i), "20261006", "20m", "<MY_WWFF_REF:8>KFF-1234 ");
    for (int i = 0; i < 14; ++i) w += rec("K1A" + std::to_string(i), "20261007", "20m", "<MY_SIG:4>WWFF <MY_SIG_INFO:8>KFF-1234 ");
    w += rec("K1A0", "20261007", "20m", "<MY_WWFF_REF:8>KFF-1234 ");  // a repeat the same day
    LintResult r = lintModel(w);
    std::vector<Activation> a = programActivations(w, r.model, Program::WWFF);
    CHECK(a.size() == 1 && a[0].qsos == 44 && a[0].duplicates == 1 && a[0].activated() && a[0].date == "20261006" &&
              a[0].lastDate == "20261007",
          "WWFF: 44 QSOs over two days (%zu, %zu)", a.size(), a.empty() ? 0 : a[0].qsos);
    std::vector<PotaFile> files =
        programExport(Program::WWFF, w, r.model, "", "0", "20261008 000000", "\n", LengthUnit::Bytes, true, "20261008");
    // One log per activation, its consecutive days joined and named for the first (wwff.co FAQ).
    CHECK(files.size() == 1 && files[0].name == "KW9D @ KFF-1234 20261006.adi" && files[0].records == 45 &&
              files[0].qsos == 44 && files[0].text.find("on 2026-10-06 to 2026-10-07 UTC") != std::string::npos,
          "WWFF: one file for the two-day activation: %s (%zu records)", files.empty() ? "" : files[0].name.c_str(),
          files.empty() ? 0 : files[0].records);
    if (files.size() == 1) {
        LintResult fr = lintModel(files[0].text);
        CHECK(fr.errors == 0 && files[0].text.find("<MY_WWFF_REF:8>KFF-1234 <EOR>") != std::string::npos,
              "MY_WWFF_REF added where only MY_SIG_INFO had it:\n%s%s", files[0].text.substr(0, 400).c_str(), dump(fr).c_str());
    }
    // Days with a gap are separate activations; '/' in the call becomes '-'.
    std::string w2 = std::string(kHeader) + rec("K1AA", "20261006", "20m", "<MY_WWFF_REF:8>KFF-1234 ") +
                     rec("K1AB", "20261009", "20m", "<MY_WWFF_REF:8>KFF-1234 ");
    for (size_t at; (at = w2.find("<STATION_CALLSIGN:4>KW9D ")) != std::string::npos;)
        w2.replace(at, 25, "<STATION_CALLSIGN:6>KW9D/P ");
    r = lintModel(w2);
    files = programExport(Program::WWFF, w2, r.model, "", "0", "20261010 000000", "\n", LengthUnit::Bytes, true, "20261010");
    CHECK(files.size() == 2 && files[0].name == "KW9D-P @ KFF-1234 20261006.adi" && files[1].name == "KW9D-P @ KFF-1234 20261009.adi",
          "WWFF: separate days apart, '/' as '-': %s", files.empty() ? "" : files[0].name.c_str());
    // SOTA: different stations; 4 for the points.
    std::string s = std::string(kHeader) + rec("K1AA", "20261006", "20m", "<MY_SOTA_REF:9>W7A/AE-001 ") +
                    rec("K1AA", "20261006", "40m", "<MY_SOTA_REF:9>W7A/AE-001 ") + rec("K1AB", "20261006", "20m", "<MY_SOTA_REF:9>W7A/AE-001 ") +
                    rec("K1AC", "20261006", "20m", "<MY_SOTA_REF:9>W7A/AE-001 ") + rec("KW9D", "20261006", "20m", "<MY_SOTA_REF:9>W7A/AE-001 ");
    r = lintModel(s);
    a = programActivations(s, r.model, Program::SOTA);
    CHECK(a.size() == 1 && a[0].qsos == 3 && a[0].duplicates == 1 && a[0].invalid == 1 && !a[0].activated() && a[0].needed == 4,
          "SOTA: 3 stations (another band is the same station), own call invalid");
    files = programExport(Program::SOTA, s, r.model, "", "0", "x", "\n", LengthUnit::Bytes, true, "20261008");
    CHECK(files.size() == 1 && files[0].name == "KW9D_W7A-AE-001_20261006.adi" && !files[0].notes.empty() &&
              files[0].notes[0] == "3 stations: 1 more for the summit's points",
          "SOTA file: %s", files.empty() ? "" : files[0].name.c_str());

    auto get = [](const std::vector<std::pair<std::string, std::string>> &v, const char *k) {
        for (const auto &p : v)
            if (p.first == k) return p.second;
        return std::string("-");
    };
    auto wf = programSpotFields(Program::WWFF, "K3MTO", "144025", "CW", "kff-5255");
    CHECK(get(wf, "SIG") == "WWFF" && get(wf, "WWFF_REF") == "KFF-5255" && get(wf, "POTA_REF") == "-" && get(wf, "BAND") == "2m",
          "WWFF spot fields");

    // Hunting history across logs.
    std::string h = std::string(kHeader) + rec("N0CX", "20261001", "20m", "<SIG:4>POTA <SIG_INFO:7>US-1234 ") +
                    rec("N0CY", "20261003", "20m", "<POTA_REF:13>US-1234@US-KS ") + rec("K3MTO", "20261004", "2m", "<WWFF_REF:8>KFF-5255 ");
    r = lintModel(h);
    std::vector<WorkedHit> hits;
    for (const Contact &c : contacts(h, r.model)) hits.push_back({"a.adi", c});
    CHECK(hits.size() == 3 && hits[1].contact.theirRefs == std::vector<std::string>({"US-1234@US-KS"}), "contacts keep references");
    ReferenceHistory rh = referenceHistory("us-1234", hits);
    CHECK(rh.qsos == 2 && rh.lastDate == "20261003", "US-1234 worked twice (location ignored)");
    CHECK(referenceSummary("US-1234", rh) == "US-1234: worked 2 times before, last 2026-10-03 (a.adi)" &&
              referenceSummary("US-9999", referenceHistory("US-9999", hits)) == "US-9999: a new park!" &&
              referenceSummary("KFF-5255", referenceHistory("KFF-5255", hits)).find("worked 1 time") != std::string::npos,
          "summaries");
    // A WWFF reference also has the shape of a POTA park: it is called a reference.
    CHECK(referenceSummary("KFF-9999", referenceHistory("KFF-9999", hits)) == "KFF-9999: a new reference!" &&
              referenceSummary("W7A/AE-001", referenceHistory("W7A/AE-001", hits)) == "W7A/AE-001: a new summit!",
          "WWFF and SOTA kinds");
}

static void testFormats() {
    std::string csv = "\xEF\xBB\xBF" "Callsign,Date,UTC,Freq (kHz),Mode,RST Sent,RST Rcvd,Park,Notes,Weird\r\n"
                      "k1ab,2026-10-06,22:30,14285,ssb,59,57,us-1234,\"Hi, there\",x\r\n"
                      "N0CX,10/06/26,2231,7074,FT8,-10,'-05,,'=SUM(A1),\r\n"
                      "\r\n";
    CsvImport ci = importCsv(csv);
    CHECK(ci.records.size() == 2, "two data rows (%zu)", ci.records.size());
    std::vector<std::pair<std::string, std::string>> wantCols = {
        {"Callsign", "CALL"}, {"Date", "QSO_DATE"}, {"UTC", "TIME_ON"},   {"Freq (kHz)", "FREQ"},  {"Mode", "MODE"},
        {"RST Sent", "RST_SENT"}, {"RST Rcvd", "RST_RCVD"}, {"Park", "POTA_REF"}, {"Notes", "COMMENT"}, {"Weird", ""}};
    CHECK(ci.columns == wantCols, "column mapping");
    if (ci.records.size() == 2) {
        Record a;
        a.fields = ci.records[0];
        CHECK(a.get("CALL") == "K1AB" && a.get("QSO_DATE") == "20261006" && a.get("TIME_ON") == "2230" && a.get("FREQ") == "14.285" &&
                  a.get("MODE") == "SSB" && a.get("POTA_REF") == "US-1234" && a.get("COMMENT") == "Hi, there",
              "row 2 converted");
        Record b;
        b.fields = ci.records[1];
        CHECK(b.get("QSO_DATE") == "10/06/26" && b.get("FREQ") == "7.074" && b.get("RST_SENT") == "-10" && b.get("RST_RCVD") == "-05" &&
                  b.get("COMMENT") == "=SUM(A1)",
              "row 3: ambiguous date kept as written; formula guard undone");
    }
    CHECK(ci.notes.size() == 1 && ci.notes[0] == "row 3: date \"10/06/26\" not understood (use YYYY-MM-DD)", "note: %s",
          ci.notes.empty() ? "" : ci.notes[0].c_str());
    // Our own CSV export comes back unchanged.
    std::vector<Record> recs(1);
    recs[0].fields = {{"CALL", "K1AB"}, {"QSO_DATE", "20261006"}, {"TIME_ON", "223000"}, {"RST_SENT", "-10"}, {"NAME", "=X"}};
    CsvImport back = importCsv(toCsv(recs, {"CALL", "QSO_DATE", "TIME_ON", "RST_SENT", "NAME"}));
    CHECK(back.records.size() == 1 && back.records[0] == recs[0].fields, "CSV round trip");

    // Cabrillo.
    std::vector<Record> c(4);
    c[0].fields = {{"CALL", "W1AW"}, {"QSO_DATE", "20261006"}, {"TIME_ON", "223015"}, {"FREQ", "14.0255"}, {"MODE", "CW"},
                   {"RST_SENT", "599"}, {"RST_RCVD", "599"}, {"STX", "1"}, {"SRX_STRING", "CT"}, {"STATION_CALLSIGN", "KW9D"}};
    c[1].fields = {{"CALL", "K1AB"}, {"QSO_DATE", "20261006"}, {"TIME_ON", "2231"}, {"BAND", "2m"}, {"MODE", "SSB"}, {"SUBMODE", "USB"}};
    c[2].fields = {{"CALL", "N0CX"}, {"QSO_DATE", "20261006"}, {"TIME_ON", "2232"}, {"BAND", "40m"}, {"MODE", "FT8"}};
    c[3].fields = {{"CALL", "BAD"}};
    CabrilloOptions o;
    o.contest = "arrl-ss cw!";
    o.callsign = "kw9d";
    o.createdBy = "ADIF Lint 0.8.0";
    CabrilloLog cl = toCabrillo(c, o);
    CHECK(cl.text.find("START-OF-LOG: 3.0\nCONTEST: ARRL-SSCW\nCALLSIGN: KW9D\nCREATED-BY: ADIF Lint 0.8.0\n") == 0,
          "header:\n%s", cl.text.c_str());
    CHECK(cl.text.find("QSO: 14026 CW 2026-10-06 2230 KW9D          599 1      W1AW          599 CT\n") != std::string::npos,
          "HF line in kHz:\n%s", cl.text.c_str());
    CHECK(cl.text.find("QSO:   144 PH 2026-10-06 2231 KW9D            - -      K1AB            - -\n") != std::string::npos &&
              cl.text.find("QSO:  7000 DG 2026-10-06 2232") != std::string::npos,
          "VHF band, PH, DG, missing parts as -:\n%s", cl.text.c_str());
    CHECK(cl.qsos == 3 && cl.incomplete == 2 && cl.skipped == 1 && cl.text.substr(cl.text.size() - 12) == "END-OF-LOG:\n",
          "counts and end");
}

static void testGridEdits() {
    CHECK(cellValue("QSO_DATE", "2026-10-06") == "20261006" && cellValue("QSO_DATE", "2026/10/06") == "20261006" &&
              cellValue("TIME_ON", "22:30") == "2230" && cellValue("TIME_ON", " 22:30:15 ") == "223015" &&
              cellValue("QSO_DATE", "6 Oct") == "6 Oct" && cellValue("CALL", " K1AB ") == "K1AB" && cellValue("NAME", "a-b") == "a-b",
          "cell values");
    std::string t = std::string(kHeader) +
                    "<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2230 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>K1BB\n<QSO_DATE:8>20261006\n<TIME_ON:4>2231\n<BAND:3>40m\n<MODE:3>SSB\n<EOR>\n"
                    "<CALL:4>K1CC <QSO_DATE:8>20261006 <TIME_ON:4>2232 <BAND:3>20m <MODE:2>CW <EOR>\n";
    LintResult r = lintModel(t);
    auto group = [&](int record) {
        int n = 0;
        for (size_t i = 0; i < r.model.groups.size(); ++i)
            if (!r.model.groups[i].header && ++n == record) return (int)i;
        return -1;
    };
    std::vector<CellChange> ch = {{group(1), "MODE", "SSB"},     {group(1), "RST_SENT", "59"}, {group(1), "RST_RCVD", "57"},
                                  {group(1), "MODE", "FT8"},     {group(2), "BAND", ""},       {group(2), "FREQ", "7.074"},
                                  {group(3), "CALL", "K1CC/P"},  {group(3), "COMMENT", ""}};
    std::string out = applyTextEdits(t, cellEdits(t, r.model, ch, LengthUnit::Bytes, true));
    CHECK(out.find("<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2230 <BAND:3>20m <MODE:3>FT8 <RST_SENT:2>59 <RST_RCVD:2>57 <EOR>") !=
                  std::string::npos &&
              out.find("<CALL:4>K1BB\n<QSO_DATE:8>20261006\n<TIME_ON:4>2231\n<MODE:3>SSB\n<FREQ:5>7.074\n<EOR>") != std::string::npos &&
              out.find("<CALL:6>K1CC/P <QSO_DATE:8>20261006") != std::string::npos && lint(out).errors == 0,
          "set, last change wins, remove, add in the record's layout, nothing for an absent empty field:\n%s", out.c_str());
    CHECK(cellEdits(t, r.model, {{group(1), "CALL", "K1AA"}}, LengthUnit::Bytes, true).empty(), "an unchanged value makes no edit");
    std::string del = applyTextEdits(t, removeRecordsEdits(t, r.model, {group(2), group(3)}));
    CHECK(del == std::string(kHeader) + "<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2230 <BAND:3>20m <MODE:2>CW <EOR>\n",
          "records 2 and 3 removed with their blank runs:\n[%s]", del.c_str());
    std::string mid = applyTextEdits(t, removeRecordsEdits(t, r.model, {group(2)}));
    CHECK(mid.find("<EOR>\n<CALL:4>K1CC") != std::string::npos && mid.find("K1BB") == std::string::npos, "a middle record removed");
    std::string tsv = toTsv({{"CALL", "NAME", "COMMENT"}, {"K1AA", "Bob \"Rob\" Smith", "line1\r\nline2"}, {"K1BB", "a\tb", ""}});
    CHECK(tsv == "CALL\tNAME\tCOMMENT\r\nK1AA\t\"Bob \"\"Rob\"\" Smith\"\t\"line1\r\nline2\"\r\nK1BB\t\"a\tb\"\t\r\n", "TSV:\n%s", tsv.c_str());
    std::vector<std::vector<std::string>> back = parseCsv(tsv);
    CHECK(back.size() == 3 && back[1][1] == "Bob \"Rob\" Smith" && back[1][2] == "line1\r\nline2" && back[2][1] == "a\tb",
          "TSV reads back with the CSV parser");
}

static void testOrganize() {
    // Comparisons: bands by frequency, times with or without seconds or colons, numbers by value, calls naturally.
    CHECK(compareFieldValues("BAND", "160m", "20m") < 0 && compareFieldValues("BAND", "2m", "70cm") < 0 &&
              compareFieldValues("band", "20M", "20m") == 0 && compareFieldValues("BAND", "20m", "xyz") < 0,
          "bands by frequency");
    CHECK(compareFieldValues("TIME_ON", "2230", "223015") < 0 && compareFieldValues("TIME_ON", "22:30", "2230") == 0 &&
              compareFieldValues("QSO_DATE", "2026-10-06", "20261005") > 0,
          "times and dates");
    CHECK(compareFieldValues("FREQ", "7.074", "14.074") < 0 && compareFieldValues("DISTANCE", "900", "1200") < 0 &&
              compareFieldValues("CALL", "K2AB", "K10AB") < 0 && compareFieldValues("CALL", "k1ab", "K1AB") == 0,
          "numbers and calls");
    CHECK(naturalCompare("-10", "2") < 0 && naturalCompare("A9", "A10") < 0 && naturalCompare("abc", "ABD") < 0, "natural order");

    // Records by BAND, then CALL descending; a record without BAND goes last; a comment moves with its record.
    std::string t = std::string(kHeader) +
                    "<CALL:4>K1AA <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>K1BB <BAND:3>40m <MODE:2>CW <EOR>\n"
                    "note about K1CC\n"
                    "<CALL:4>K1CC <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<CALL:4>K1DD <MODE:2>CW <EOR>\n"
                    "<CALL:4>K1EE <BAND:4>160m <MODE:2>CW <EOR>\n";
    LintResult r = lintModel(t);
    bool changed = false;
    std::string s = sortedBy(t, r.model, {{"BAND", false}, {"CALL", true}}, "\n", &changed);
    std::vector<std::string> calls;
    for (size_t p = s.find("<CALL:4>"); p != std::string::npos; p = s.find("<CALL:4>", p + 1)) calls.push_back(s.substr(p + 8, 4));
    CHECK(changed && calls == std::vector<std::string>({"K1EE", "K1BB", "K1CC", "K1AA", "K1DD"}),
          "160m, 40m, then 20m by CALL descending, no BAND last:\n%s", s.c_str());
    CHECK(s.find("note about K1CC\n<CALL:4>K1CC") != std::string::npos && lint(s).errors == 0, "the comment moved with K1CC");
    LintResult rs = lintModel(s);
    sortedBy(s, rs.model, {{"BAND", false}, {"CALL", true}}, "\n", &changed);
    CHECK(!changed, "sorting again changes nothing");
    s = sortedBy(t, r.model, {{"BAND", true}}, "\n", &changed);
    calls.clear();
    for (size_t p = s.find("<CALL:4>"); p != std::string::npos; p = s.find("<CALL:4>", p + 1)) calls.push_back(s.substr(p + 8, 4));
    CHECK(calls == std::vector<std::string>({"K1AA", "K1CC", "K1BB", "K1EE", "K1DD"}),
          "descending: ties keep their order, no BAND still last");

    // Field order: listed fields first, the rest in their order; gaps stay where they were; data byte for byte.
    std::string f = std::string(kHeader) +
                    "<QSO_DATE:8>20261006 <TIME_ON:4>2230 <CALL:4>K1AA <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<MODE:3>SSB\n<BAND:3>40m\n<CALL:4>K1BB\n<QSO_DATE:8>20261006\n<TIME_ON:4>2231\n<EOR>\n"
                    "<CALL:4>K1CC <QSO_DATE:8>20261006 <TIME_ON:4>2232 <BAND:3>20m <MODE:2>CW <EOR>\n"
                    "<MODE:2>CW <CALL:4>K1DDX <BAND:3>20m <EOR>\n";  // a wrong length: left alone
    LintResult fr = lintModel(f);
    size_t edited = 0, skipped = 0;
    std::vector<TextEdit> e = fieldOrderEdits(f, fr.model, {"CALL", "QSO_DATE", "TIME_ON"}, &edited, &skipped);
    std::string fo = applyTextEdits(f, e);
    CHECK(edited == 2 && skipped == 1, "2 records reordered, K1CC already in order, K1DD skipped (%zu, %zu)", edited, skipped);
    CHECK(fo.find("<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>2230 <BAND:3>20m <MODE:2>CW <EOR>") != std::string::npos &&
              fo.find("<CALL:4>K1BB\n<QSO_DATE:8>20261006\n<TIME_ON:4>2231\n<MODE:3>SSB\n<BAND:3>40m\n<EOR>") != std::string::npos &&
              fo.find("<MODE:2>CW <CALL:4>K1DDX <BAND:3>20m <EOR>") != std::string::npos && fo.substr(0, sizeof kHeader - 1) == kHeader,
          "fields reordered, layout kept, comment record untouched:\n%s", fo.c_str());
    CHECK(lint(fo).errors == lint(f).errors && fo.size() == f.size(), "same size, no new errors");
    LintResult fr2 = lintModel(fo);
    CHECK(fieldOrderEdits(fo, fr2.model, {"CALL", "QSO_DATE", "TIME_ON"}, &edited, &skipped).empty(), "a second run changes nothing");
}

static void testImport() {
    auto applied = [](const std::string &log, const LintResult &lr, const std::vector<ImportItem> &items,
                      const std::vector<SiteQso> &qsos) {
        std::vector<EnrichChange> changes;
        std::vector<size_t> adds;
        for (const ImportItem &i : items) {
            if (i.kind == ImportItem::Kind::Update) changes.insert(changes.end(), i.changes.begin(), i.changes.end());
            if (i.kind == ImportItem::Kind::Add && qsos[i.qso].problem.empty()) adds.push_back(i.qso);
        }
        std::string out = applyTextEdits(log, enrichmentEdits(log, lr.model, changes, LengthUnit::Bytes, true));
        LintResult mr = lintModel(out);
        size_t start = 0;
        std::string records = importedRecords(qsos, adds, recordLayout(out, mr.model), "\n", LengthUnit::Bytes, true);
        return applyTextEdits(out, {appendRecord(out, mr.model, records, "\n", &start)});
    };
    auto kind = [](const std::vector<ImportItem> &items, size_t q) { return items[q].kind; };

    // LoTW (qso_qsl=no): your uploaded QSOs, confirmed or not.
    std::string log = std::string(kHeader) +
                      "<CALL:5>K1ABC <QSO_DATE:8>20261006 <TIME_ON:6>230000 <BAND:3>20m <MODE:3>SSB <LOTW_QSL_RCVD:1>N <EOR>\n"
                      "<CALL:4>W1AW <QSO_DATE:8>20261006 <TIME_ON:4>2310 <BAND:3>40m <MODE:2>CW <EOR>\n"
                      "<CALL:5>N0CAL <QSO_DATE:8>20261006 <TIME_ON:4>2320 <BAND:3>20m <MODE:3>FT8 <EOR>\n";
    std::string report =
        "ARRL Logbook of the World Status Report\n<PROGRAMID:4>LoTW\n<APP_LoTW_LASTQSORX:19>2026-10-07 01:02:03\n<eoh>\n"
        "<STATION_CALLSIGN:4>KW9D <CALL:5>K1ABC <BAND:3>20M <FREQ:8>14.25000 <MODE:3>SSB <QSO_DATE:8>20261006 <TIME_ON:6>232500 "
        "<APP_LoTW_RXQSO:19>2026-10-07 01:02:03 <QSL_RCVD:1>Y <QSLRDATE:8>20261010 <DXCC:3>291 <COUNTRY:24>UNITED STATES OF AMERICA "
        "<GRIDSQUARE:4>FN42 <STATE:2>MA <CNTY:11>MA,Franklin <CQZ:1>5 <ITUZ:1>8 <MY_GRIDSQUARE:4>EN52 <eor>\n"
        "<STATION_CALLSIGN:4>KW9D <CALL:4>W1AW <BAND:3>20M <MODE:2>CW <QSO_DATE:8>20261006 <TIME_ON:6>231000 "
        "<APP_LoTW_RXQSO:19>2026-10-07 01:02:03 <QSL_RCVD:1>N <MY_GRIDSQUARE:4>EN52 <eor>\n"
        "<STATION_CALLSIGN:4>KW9D <CALL:5>N0CAL <BAND:3>20M <APP_LoTW_MODE:3>FT4 <QSO_DATE:8>20261006 <TIME_ON:6>232000 "
        "<QSL_RCVD:1>Y <QSLRDATE:8>20261011 <GRIDSQUARE:4>EN34 <eor>\n"
        "<STATION_CALLSIGN:4>KW9D <CALL:5>N0CAL <BAND:3>20M <MODE:3>FT8 <QSO_DATE:8>20261006 <TIME_ON:6>232100 <QSL_RCVD:1>N <eor>\n"
        "<CALL:4>NOTM <BAND:3>20M <QSO_DATE:8>20261006 <TIME_ON:6>232200 <eor>\n"
        "<APP_LoTW_EOF>\n";
    LintResult rl = lintModel(log), rr = lintModel(report);
    std::vector<SiteQso> lq = siteQsos(ImportSite::LoTW, report, rr.model, "20261012");
    CHECK(lq.size() == 5, "5 LoTW records (%zu)", lq.size());
    if (lq.size() == 5) {
        CHECK(lq[0].confirmed && lq[0].update["LOTW_QSL_RCVD"] == "Y" && lq[0].update["LOTW_QSLRDATE"] == "20261010" &&
                  lq[0].update["LOTW_QSL_SENT"] == "Y" && lq[0].update["LOTW_QSLSDATE"] == "20261007" &&
                  lq[0].update["GRIDSQUARE"] == "FN42" && !lq[0].update.count("MY_GRIDSQUARE"),
              "LoTW confirmation and the confirming station's details");
        CHECK(!lq[1].confirmed && !lq[1].update.count("LOTW_QSL_RCVD") && !lq[1].update.count("GRIDSQUARE"), "unconfirmed: no QSL fields");
        CHECK(lq[2].mode == "MFSK" && lq[2].problem.empty(), "APP_LoTW_MODE FT4 -> MFSK/FT4 (%s)", lq[2].mode.c_str());
        CHECK(lq[4].problem == "no MODE", "a record without a mode can't be added: %s", lq[4].problem.c_str());
        std::vector<ImportItem> items = planImport(log, rl.model, lq, ImportSite::LoTW);
        CHECK(kind(items, 0) == ImportItem::Kind::Update && items[0].record == 1, "K1ABC matched record 1 (25 minutes apart)");
        bool upgraded = false;
        for (const EnrichChange &c : items[0].changes)
            if (c.field == "LOTW_QSL_RCVD") upgraded = c.replace && c.accepted && c.current == "N" && c.value == "Y";
        CHECK(upgraded, "LOTW_QSL_RCVD N -> Y offered and ticked");
        CHECK(kind(items, 1) == ImportItem::Kind::Add, "W1AW on 20m is not the log's 40m QSO: added");
        std::string out = applied(log, rl, items, lq);
        LintResult ro = lint(out);
        CHECK(ro.errors == 0 && out.find("<LOTW_QSL_RCVD:1>Y") != std::string::npos &&
                  out.find("<CALL:4>W1AW <QSO_DATE:8>20261006 <TIME_ON:6>231000 <BAND:3>20M <MODE:2>CW <STATION_CALLSIGN:4>KW9D "
                           "<MY_GRIDSQUARE:4>EN52 <LOTW_QSL_SENT:1>Y <LOTW_QSLSDATE:8>20261007 <EOR>") != std::string::npos,
              "LoTW import applied:\n%s", out.c_str());
    }

    // The same mode beats the same mode group: N0CAL FT8 in LoTW matches the log's FT8, and the FT4 one is new.
    {
        std::vector<ImportItem> items = planImport(log, rl.model, lq, ImportSite::LoTW);
        CHECK(lq.size() == 5 && items[3].kind == ImportItem::Kind::Update && items[2].kind == ImportItem::Kind::Add,
              "exact mode wins: FT8 updates record 3, FT4 is added (%d %d)", lq.size() == 5 ? (int)items[3].kind : -1,
              lq.size() == 5 ? (int)items[2].kind : -1);
    }

    // eQSL InBox: the sender's record; their RST_SENT is your RST_RCVD; offered to add, not ticked.
    std::string elog = std::string(kHeader) +
                       "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>2230 <BAND:3>20m <MODE:3>SSB <EQSL_QSL_RCVD:1>N <EOR>\n";
    LintResult el = lintModel(elog);
    std::string inbox = "ADIF 3 Export from eQSL.cc\n<PROGRAMID:21>eQSL.cc DownloadInBox\n<ADIF_Ver:5>3.1.6\n<EOH>\n"
                        "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>2245 <BAND:3>20M <MODE:3>SSB <RST_SENT:2>59 <QSL_SENT:1>Y "
                        "<QSL_SENT_VIA:1>E <GRIDSQUARE:6>FN31pr <EQSL_QSL_RCVD:1>Y <EQSL_QSLRDATE:8>20261007 <EOR>\n"
                        "<CALL:4>W9NO <QSO_DATE:8>20261006 <TIME_ON:4>2250 <BAND:3>40M <MODE:2>CW <RST_SENT:3>579 "
                        "<EQSL_QSL_RCVD:1>Y <EQSL_QSLRDATE:8>20261007 <EOR>\n";
    LintResult ir = lintModel(inbox);
    std::vector<SiteQso> eq = siteQsos(ImportSite::EQSL, inbox, ir.model, "20261012");
    std::vector<ImportItem> ei = planImport(elog, el.model, eq, ImportSite::EQSL);
    CHECK(eq.size() == 2 && ei[0].kind == ImportItem::Kind::Update && ei[1].kind == ImportItem::Kind::Add && !eq[1].addByDefault,
          "eQSL: K1AB updated (15 minutes apart), W9NO offered unticked");
    bool eqUp = false;
    for (const EnrichChange &c : ei[0].changes) eqUp |= c.field == "EQSL_QSL_RCVD" && c.replace && c.current == "N";
    CHECK(eqUp, "EQSL_QSL_RCVD N -> Y");
    std::string eout = applied(elog, el, ei, eq);
    CHECK(lint(eout).errors == 0 &&
              eout.find("<CALL:4>W9NO <QSO_DATE:8>20261006 <TIME_ON:4>2250 <BAND:3>40M <MODE:2>CW <RST_RCVD:3>579 "
                        "<EQSL_QSL_RCVD:1>Y <EQSL_QSLRDATE:8>20261007 <EOR>") != std::string::npos &&
              eout.find("<RST_SENT") == std::string::npos,
          "eQSL import applied:\n%s", eout.c_str());

    // QRZ.com Logbook FETCH: entities decoded; '_' in calls is '/'; APP_QRZLOG_STATUS C is confirmed.
    std::string qlog = std::string(kHeader) +
                       "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>2230 <BAND:3>20m <MODE:3>SSB <EOR>\n"
                       "<CALL:6>N0CX/P <QSO_DATE:8>20261006 <TIME_ON:4>2240 <BAND:3>40m <MODE:2>CW <EOR>\n";
    LintResult ql = lintModel(qlog);
    std::string body = "RESULT=OK&COUNT=3&ADIF=&lt;call:6&gt;N0CX_P &lt;qso_date:8&gt;20261006 &lt;time_on:4&gt;2241 "
                       "&lt;band:3&gt;40m &lt;mode:2&gt;CW &lt;app_qrzlog_status:1&gt;C &lt;app_qrzlog_qsldate:8&gt;20261008 "
                       "&lt;app_qrzlog_logid:9&gt;123456789 &lt;eor&gt;\n&lt;call:4&gt;K1AB &lt;qso_date:8&gt;20261006 "
                       "&lt;time_on:4&gt;2230 &lt;band:3&gt;20m &lt;mode:3&gt;SSB &lt;app_qrzlog_status:1&gt;N &lt;eor&gt;\n"
                       "&lt;call:4&gt;W2XY &lt;qso_date:8&gt;20261006 &lt;time_on:4&gt;2300 &lt;band:3&gt;20m &lt;mode:3&gt;FT4 "
                       "&lt;station_callsign:4&gt;KW9D &lt;comment:5&gt;hello &lt;app_qrzlog_status:1&gt;N &lt;eor&gt;\n";
    QrzReply q;
    std::string adif;
    CHECK(parseQrzFetch(body, &q, &adif) && q.result == "OK" && q.count == "3" && adif.find("<call:6>N0CX_P") == 0,
          "FETCH parsed: %s", adif.substr(0, 40).c_str());
    LintResult fr = lintModel(adif);
    std::vector<SiteQso> qq = siteQsos(ImportSite::QRZLogbook, adif, fr.model, "20261009");
    std::vector<ImportItem> qi = planImport(qlog, ql.model, qq, ImportSite::QRZLogbook);
    CHECK(qq.size() == 3 && qq[0].call == "N0CX/P" && qq[0].confirmed && qq[0].update["APP_QRZLOG_QSLDATE"] == "20261008" &&
              qq[0].update["QRZCOM_QSO_DOWNLOAD_DATE"] == "20261009" && !qq[1].confirmed,
          "QRZ records read");
    CHECK(qi[0].kind == ImportItem::Kind::Update && qi[0].record == 2 && qi[1].kind == ImportItem::Kind::Update &&
              qi[1].changes.size() == 1 && qi[1].changes[0].field == "QRZCOM_QSO_UPLOAD_STATUS" && qi[2].kind == ImportItem::Kind::Add,
          "QRZ: N0CX/P confirmed, K1AB marked uploaded, W2XY added");
    std::string qout = applied(qlog, ql, qi, qq);
    CHECK(lint(qout).errors == 0 &&
              qout.find("<CALL:4>W2XY <QSO_DATE:8>20261006 <TIME_ON:4>2300 <BAND:3>20m <MODE:4>MFSK <STATION_CALLSIGN:4>KW9D "
                        "<COMMENT:5>hello <SUBMODE:3>FT4 <QRZCOM_QSO_UPLOAD_STATUS:1>Y <EOR>") != std::string::npos &&
              qout.find("APP_QRZLOG_LOGID") == std::string::npos,
          "QRZ import applied:\n%s", qout.c_str());
    CHECK(qrzFetchBody("AB-12", 7, 250) == "KEY=AB-12&ACTION=FETCH&OPTION=MAX%3A250%2CAFTERLOGID%3A7" &&
              qrzFetchBody("AB-12", 0, 250, "2026-10-06+2026-10-07") ==
                  "KEY=AB-12&ACTION=FETCH&OPTION=BETWEEN%3A2026-10-06%2B2026-10-07%2CMAX%3A250%2CAFTERLOGID%3A0",
          "FETCH body: %s", qrzFetchBody("AB-12", 0, 250, "2026-10-06+2026-10-07").c_str());
    CHECK(htmlDecode("&lt;a&gt; &amp;&#65;&#x42; &bogus; &") == "<a> &AB &bogus; &", "entities");
    std::string err;
    CHECK(eqslInboxLink("<HTML>Your ADIF log file has been built<BR><A HREF=\"../downloadedfiles/x123.adi\">.ADI file</A>"
                        "<A HREF=\"../downloadedfiles/x123.txt\">.TXT</A></HTML>",
                        &err) == "../downloadedfiles/x123.adi",
          "eQSL link");
    CHECK(eqslInboxLink("<html>Error: No such Username/Password found<br></html>", &err).empty() &&
              err == "No such Username/Password found",
          "eQSL error: %s", err.c_str());
}

static void testOfficialReformat(const std::string &text) {
    LintResult r = lintModel(text);
    CHECK(canReformat(r), "official file can be reformatted");
    std::vector<std::string> before = fieldList(text, r.model);
    for (Layout layout : {Layout::RecordPerLine, Layout::FieldPerLine}) {
        std::string out = reformat(text, r.model, layout, "\r\n");
        LintResult ro = lintModel(out);
        CHECK(ro.errors == 0 && ro.warnings == 0 && ro.records == r.records,
              "reformatted official file lints clean (%zu errors, %zu warnings, %zu records)\n%s", ro.errors, ro.warnings,
              ro.records, dump(ro).substr(0, 2000).c_str());
        CHECK(!out.empty() && out[0] != '<', "reformatted official file keeps its header");
        CHECK(fieldList(out, ro.model) == before, "reformatted official file keeps every field");
        CHECK(reformat(out, ro.model, layout, "\r\n") == out, "reformat is idempotent");
    }
}

static std::string readFile(const char *path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

// The official ADIF 3.1.7 test-QSO file must lint without errors or warnings,
// and breaking lengths in it must be repaired back to exactly the original.
static void testOfficialFile(const char *path) {
    std::string text = readFile(path);
    CHECK(text.size() > 100000, "official test file missing or short: %s", path);
    LintResult r = lint(text);
    CHECK(r.errors == 0 && r.warnings == 0, "official file: %zu errors, %zu warnings\n%s", r.errors, r.warnings,
          dump(r).substr(0, 4000).c_str());
    CHECK(r.records == 6197, "official file records: %zu", r.records);
    CHECK(r.fixes.empty(), "official file needs no fixes: %zu", r.fixes.size());
    testOfficialReformat(text);

    // Property: rewrite the length of N random fields to a wrong value; Fix
    // Lengths must restore the original byte-for-byte.
    std::mt19937 rng(20260322);
    std::vector<size_t> lengthStarts;
    for (size_t i = 0; i + 1 < text.size(); ++i) {
        if (text[i] != '<') continue;
        size_t colon = text.find(':', i), gt = text.find('>', i);
        if (colon == std::string::npos || gt == std::string::npos || colon > gt) continue;
        if (text[i + 1] == '/' || text.compare(i, 5, "<EOR>") == 0) continue;
        lengthStarts.push_back(colon + 1);
    }
    for (int round = 0; round < 25; ++round) {
        std::string broken = text;
        std::vector<size_t> picks;
        for (int k = 0; k < 40; ++k) picks.push_back(lengthStarts[rng() % lengthStarts.size()]);
        std::sort(picks.begin(), picks.end());
        picks.erase(std::unique(picks.begin(), picks.end()), picks.end());
        // Edit from the end so earlier offsets stay valid.
        for (auto it = picks.rbegin(); it != picks.rend(); ++it) {
            size_t b = *it, e = b;
            while (e < broken.size() && isdigit((unsigned char)broken[e])) ++e;
            unsigned long len = std::stoul(broken.substr(b, e - b));
            unsigned long wrong = (rng() % 2 && len > 1) ? len - 1 - rng() % (len - 1) : len + 1 + rng() % 5;
            broken.replace(b, e - b, std::to_string(wrong));
        }
        LintResult br = lint(broken);
        CHECK(br.errors > 0, "round %d: broken lengths not detected", round);
        std::string repaired = applyFixes(broken, br.fixes);
        if (repaired != text) {
            size_t d = 0;
            while (d < repaired.size() && d < text.size() && repaired[d] == text[d]) ++d;
            CHECK(false, "round %d: repair differs at byte %zu: got '%s' want '%s'", round, d,
                  repaired.substr(d > 40 ? d - 40 : 0, 80).c_str(), text.substr(d > 40 ? d - 40 : 0, 80).c_str());
            break;
        }
    }
}

// Diagnostic codes and their repairs: each repair, applied alone, removes its
// problem and leaves the record otherwise valid.
static void testQuickFixes() {
    struct Case {
        const char *code, *rec, *after;
    };
    const Case cases[] = {
        {"mode-is-submode", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:3>USB <EOR>\n",
         "<MODE:3>SSB <SUBMODE:3>USB <EOR>"},
        {"mode-is-submode", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:5>PSK31 <EOR>\n",
         "<MODE:3>PSK <SUBMODE:5>PSK31 <EOR>"},
        {"submode-mode", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:3>FT8 <SUBMODE:3>FT4 <EOR>\n",
         "<MODE:4>MFSK <SUBMODE:3>FT4"},
        {"mode-missing", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <SUBMODE:3>JS8 <EOR>\n",
         "<SUBMODE:3>JS8 <MODE:4>MFSK <EOR>"},
        {"date-format", "<CALL:4>K1AB <QSO_DATE:10>2026-10-06 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <EOR>\n",
         "<QSO_DATE:8>20261006 "},
        {"time-format", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:8>12:00:30 <BAND:3>20m <MODE:2>CW <EOR>\n",
         "<TIME_ON:6>120030 "},
        {"freq-band", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <FREQ:5>14074 <BAND:3>20m <MODE:2>CW <EOR>\n",
         "<FREQ:6>14.074 <BAND:3>20m"},
        {"freq-band", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <FREQ:5>7.074 <BAND:3>20m <MODE:2>CW <EOR>\n",
         "<FREQ:5>7.074 <BAND:3>40m"},
        {"band-missing", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <FREQ:6>14.074 <MODE:2>CW <EOR>\n",
         "<MODE:2>CW <BAND:3>20m <EOR>"},
        {"case", "<CALL:4>k1ab <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <STATE:2>ma <EOR>\n", "<CALL:4>K1AB "},
        {"sat-prop", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:4>70cm <MODE:3>SSB <SAT_NAME:4>AO-7 <EOR>\n",
         "<SAT_NAME:4>AO-7 <PROP_MODE:3>SAT <EOR>"},
        {"dup-field", "<CALL:4>K1AB <CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <EOR>\n",
         "\n<CALL:4>K1AB <QSO_DATE:8>"},
        {"no-eor", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW\n", "<MODE:2>CW <EOR>"},
        {"placeholder", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <IOTA:4>none <EOR>\n",
         "<MODE:2>CW <EOR>"},
        {"placeholder", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <GRIDSQUARE:3>N/A <BAND:3>20m <MODE:2>CW <EOR>\n",
         "<TIME_ON:4>1200 <BAND:3>20m"},
        {"field-day-class", "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <ARRL_SECT:2>1D <EOR>\n",
         "<MODE:2>CW <CLASS:2>1D <EOR>"},
        {"field-day-class", "<CALL:4>K1AB <ARRL_SECT:3>12f <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <EOR>\n",
         "<CALL:4>K1AB <QSO_DATE:8>"},
        {"import-only", "<CALL:5>XE1AA <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <DXCC:2>50 <STATE:2>DF <EOR>\n",
         "<STATE:3>CMX <EOR>"},
    };
    for (const Case &c : cases) {
        std::string text = std::string(kHeader) + c.rec;
        LintResult r = lintModel(text);
        std::vector<Diagnostic> mine;
        for (const Diagnostic &d : r.diagnostics)
            if (d.code == c.code) mine.push_back(d);
        CHECK(!mine.empty() && !mine[0].fixes.empty() && !mine[0].fixLabel.empty(), "%s: a repair is offered\n%s", c.code,
              dump(r).c_str());
        size_t applied = 0;
        std::string fixed = applyTextEdits(text, quickFixEdits(text, r.model, mine, LengthUnit::Bytes, true, &applied));
        LintResult after = lintModel(fixed);
        size_t left = 0;
        for (const Diagnostic &d : after.diagnostics) left += d.code == c.code;
        CHECK(applied == mine.size() && left == 0 && after.errors == 0 && fixed.find(c.after) != std::string::npos,
              "%s: repaired to '%s':\n%s%s", c.code, c.after, fixed.c_str(), dump(after).c_str());
    }

    // A subdivision not on the entity's list: removal is offered but marked as dropping data.
    {
        std::string hu = std::string(kHeader) + "<CALL:5>HA5XX <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW "
                                               "<DXCC:3>239 <STATE:1>H <EOR>\n";
        LintResult hr = lintModel(hu);
        std::vector<Diagnostic> sub;
        for (const Diagnostic &d : hr.diagnostics)
            if (d.code == "subdivision") sub.push_back(d);
        CHECK(sub.size() == 1 && sub[0].dropsData && sub[0].fixLabel == "remove STATE H", "subdivision: removal offered, flagged");
        std::string removed = applyTextEdits(hu, quickFixEdits(hu, hr.model, sub, LengthUnit::Bytes, true));
        CHECK(removed.find("<STATE") == std::string::npos && removed.find("<DXCC:3>239 <EOR>") != std::string::npos,
              "STATE removed:\n%s", removed.c_str());
    }
    // TX_PWR with its unit (WSJT-X writes what you type).
    for (const auto &[typed, want] : std::vector<std::pair<std::string, std::string>>{
             {"30W", "<TX_PWR:2>30 "}, {"5 w", "<TX_PWR:1>5 "}, {"1.5kW", "<TX_PWR:4>1500 "}, {"100 Watts", "<TX_PWR:3>100 "}}) {
        std::string pw = std::string(kHeader) + "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <TX_PWR:" +
                         std::to_string(typed.size()) + ">" + typed + " <EOR>\n";
        LintResult pr = lintModel(pw);
        std::string fixedPw = applyTextEdits(pw, quickFixEdits(pw, pr.model, pr.diagnostics, LengthUnit::Bytes, true));
        CHECK(fixedPw.find(want) != std::string::npos && lintModel(fixedPw).errors == 0, "TX_PWR %s repaired:\n%s", typed.c_str(),
              fixedPw.c_str());
    }

    // No repair where the right value is unknown; the BOM; a future date (with today given).
    LintResult r = lintModel(std::string(kHeader) + "<CALL:4>K1AB <CALL:4>K1AC <QSO_DATE:8>20261006 <TIME_ON:4>1200 "
                                                   "<BAND:3>20m <MODE:2>CW <EOR>\n");
    bool noFix = false;
    for (const Diagnostic &d : r.diagnostics) noFix |= d.code == "dup-field" && d.fixes.empty();
    CHECK(noFix, "two different CALLs: no repair offered\n%s", dump(r).c_str());
    std::string bom = "\xEF\xBB\xBF" + std::string(kHeader) + record("");
    r = lintModel(bom);
    std::string unbommed = applyTextEdits(bom, quickFixEdits(bom, r.model, r.diagnostics, LengthUnit::Bytes, true));
    CHECK(unbommed == std::string(kHeader) + record(""), "the BOM removed");
    LintOptions opt;
    opt.today = "20261009";
    r = lint(std::string(kHeader) + "<CALL:4>K1AB <QSO_DATE:8>20261010 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <EOR>\n", opt);
    expect("future date", r, Severity::Warning, "is after today");
    r = lint(std::string(kHeader) + record(""), opt);
    expectClean("a past date", r);

    // POTA: the log's usual STATION_CALLSIGN fills a record without one.
    std::string pota = std::string(kHeader) +
                       "<CALL:4>K1AA <QSO_DATE:8>20261006 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <STATION_CALLSIGN:4>KW9D "
                       "<MY_POTA_REF:7>US-7929 <EOR>\n"
                       "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1201 <BAND:3>20m <MODE:2>CW <MY_POTA_REF:7>US-7929 <EOR>\n";
    r = lintModel(pota);
    std::vector<Diagnostic> ps;
    for (const Diagnostic &d : r.diagnostics)
        if (d.code == "pota-station") ps.push_back(d);
    CHECK(ps.size() == 1 && ps[0].fixLabel == "STATION_CALLSIGN KW9D", "pota-station repair: %s",
          ps.empty() ? "none" : ps[0].fixLabel.c_str());
    std::string potaFixed = applyTextEdits(pota, quickFixEdits(pota, r.model, ps, LengthUnit::Bytes, true));
    CHECK(potaFixed.find("<MY_POTA_REF:7>US-7929 <STATION_CALLSIGN:4>KW9D <EOR>") != std::string::npos, "pota-station:\n%s",
          potaFixed.c_str());

    // A record with a wrong length is left for Fix Lengths.
    std::string broken = std::string(kHeader) + "<CALL:3>K1AB <QSO_DATE:10>2026-10-06 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW <EOR>\n";
    r = lintModel(broken);
    CHECK(quickFixEdits(broken, r.model, r.diagnostics, LengthUnit::Bytes, true).empty(), "no repairs in a record with a wrong length");

    // Several repairs in one record, applied together.
    std::string many = std::string(kHeader) + "<CALL:4>k1ab <QSO_DATE:10>2026-10-06 <TIME_ON:5>12:00 <FREQ:5>14074 <BAND:3>20m "
                                             "<MODE:3>LSB <EOR>\n";
    r = lintModel(many);
    size_t applied = 0;
    std::string all = applyTextEdits(many, quickFixEdits(many, r.model, r.diagnostics, LengthUnit::Bytes, true, &applied));
    LintResult after = lintModel(all);
    CHECK(applied == 5 && after.errors == 0 && after.warnings == 0 &&
              all.find("<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <FREQ:6>14.074 <BAND:3>20m <MODE:3>SSB <SUBMODE:3>LSB <EOR>") !=
                  std::string::npos,
          "five repairs at once (%zu):\n%s%s", applied, all.c_str(), dump(after).c_str());
}

// Station profiles and activations.
static void testProfiles() {
    StationProfile home, portable;
    home.name = "Home";
    home.set("station_callsign", "KW9D");
    home.set("MY_GRIDSQUARE", "EN52");
    portable.name = "Portable, T1";
    portable.set("STATION_CALLSIGN", "KW9D/P");
    portable.set("MY_RIG", "Elecraft T1");
    portable.set("TX_PWR", "5");
    portable.tqslLocation = "KW9D portable";
    std::string text = profilesText({home, portable}, "0.10", "20261009 120000");
    std::vector<StationProfile> back = parseProfiles(text);
    CHECK(lint(text).errors == 0 && back.size() == 2 && back[0].name == "Home" && back[0].get("STATION_CALLSIGN") == "KW9D" &&
              back[1].name == "Portable, T1" && back[1].get("MY_RIG") == "Elecraft T1" && back[1].tqslLocation == "KW9D portable",
          "profiles round trip:\n%s", text.c_str());
    home.set("MY_GRIDSQUARE", "");
    CHECK(home.get("MY_GRIDSQUARE").empty() && home.fields.size() == 1, "an empty value removes the field");

    std::vector<std::string> bad;
    std::string why;
    std::vector<std::string> refs = parseReferences(Program::POTA, "us-7929, US-1234 us-7929", &bad, &why);
    CHECK(refs == std::vector<std::string>({"US-7929", "US-1234"}) && bad.empty() && why.empty(), "POTA two-fer parsed");
    refs = parseReferences(Program::POTA, "US-7929, 7929", &bad, &why);
    CHECK(refs.size() == 1 && bad == std::vector<std::string>({"7929"}) && why.find("Not a POTA reference: 7929") == 0, "bad ref: %s",
          why.c_str());
    bad.clear();
    refs = parseReferences(Program::WWFF, "KFF-1234, KFF-5678", &bad, &why);
    CHECK(refs.size() == 2 && why.find("one reference per log") != std::string::npos, "WWFF takes one: %s", why.c_str());
    refs = parseReferences(Program::SOTA, "w7a/ae-001", &bad, &why);
    CHECK(refs == std::vector<std::string>({"W7A/AE-001"}) && why.empty(), "SOTA summit");

    FieldList pota = activationFields(Program::POTA, {"US-7929", "US-1234"});
    CHECK(pota == FieldList({{"MY_SIG", "POTA"}, {"MY_SIG_INFO", "US-7929,US-1234"}, {"MY_POTA_REF", "US-7929,US-1234"}}),
          "POTA activation fields");
    CHECK(activationFields(Program::WWFF, {"KFF-1234"}) ==
              FieldList({{"MY_SIG", "WWFF"}, {"MY_SIG_INFO", "KFF-1234"}, {"MY_WWFF_REF", "KFF-1234"}}),
          "WWFF activation fields");
    CHECK(activationFields(Program::SOTA, {"W7A/AE-001"}) == FieldList({{"MY_SOTA_REF", "W7A/AE-001"}}), "SOTA activation fields");
    // A record written with them is counted as that activation.
    std::string rec = std::string(kHeader) + "<CALL:4>K1AB <QSO_DATE:8>20261009 <TIME_ON:4>1200 <BAND:3>20m <MODE:2>CW "
                                            "<STATION_CALLSIGN:4>KW9D <MY_SIG:4>POTA <MY_SIG_INFO:15>US-7929,US-1234 "
                                            "<MY_POTA_REF:15>US-7929,US-1234 <EOR>\n";
    LintResult r = lintModel(rec);
    std::vector<Activation> acts = programActivations(rec, r.model, Program::POTA);
    CHECK(r.errors == 0 && acts.size() == 2 && acts[0].qsos == 1 && acts[1].qsos == 1, "a two-fer QSO counts for both parks (%zu)",
          acts.size());

    CHECK(activationFileName(Program::POTA, "kw9d", {"US-7929", "US-1234"}, "20261009") == "KW9D@US-7929+US-1234-20261009.adi",
          "POTA log name");
    CHECK(activationFileName(Program::WWFF, "KW9D/P", {"KFF-1234"}, "20261009") == "KW9D-P @ KFF-1234 20261009.adi", "WWFF log name");
    CHECK(activationFileName(Program::SOTA, "KW9D", {"W7A/AE-001"}, "20261009") == "KW9D_W7A-AE-001_20261009.adi", "SOTA log name");
    CHECK(overlay({{"STATION_CALLSIGN", "KW9D"}, {"MY_GRIDSQUARE", "EN52"}}, {{"my_gridsquare", "EN52wa"}, {"MY_SIG", "POTA"}}) ==
              FieldList({{"STATION_CALLSIGN", "KW9D"}, {"MY_GRIDSQUARE", "EN52wa"}, {"MY_SIG", "POTA"}}),
          "overlay: the profile wins, new fields follow");
}

static std::string capturedGet(const CapturedQso &q, const char *name) {
    for (const auto &f : q.fields)
        if (f.first == name) return f.second;
    return {};
}

static void testCapture() {
    // WSJT-X QSO Logged (type 5), built as WSJT-X writes it.
    FieldList qso = {{"CALL", "k1ab"},          {"GRIDSQUARE", "FN42"},     {"FREQ", "14.07415"},       {"MODE", "FT4"},
                     {"RST_SENT", "-10"},       {"RST_RCVD", "-05"},        {"TX_PWR", "30"},           {"COMMENT", "tnx"},
                     {"NAME", "Ann"},           {"QSO_DATE", "20261009"},   {"TIME_ON", "235930"},      {"QSO_DATE_OFF", "20261010"},
                     {"TIME_OFF", "000115"},    {"OPERATOR", "KW9D"},       {"STATION_CALLSIGN", "KW9D"}, {"MY_GRIDSQUARE", "EN52"}};
    std::string msg = wsjtxQsoLogged("WSJT-X", qso);
    bool isWsjtx = false;
    std::vector<CapturedQso> got = parseWsjtxMessage(msg, &isWsjtx);
    CHECK(isWsjtx && got.size() == 1 && got[0].wsjtxType == 5 && got[0].client == "WSJT-X" && got[0].problem.empty(),
          "type 5 parsed (%zu)", got.size());
    if (got.size() == 1) {
        const CapturedQso &q = got[0];
        CHECK(capturedGet(q, "CALL") == "K1AB" && capturedGet(q, "QSO_DATE") == "20261009" && capturedGet(q, "TIME_ON") == "235930" &&
                  capturedGet(q, "QSO_DATE_OFF") == "20261010" && capturedGet(q, "TIME_OFF") == "000115",
              "type 5 dates across midnight: %s %s", capturedGet(q, "QSO_DATE").c_str(), capturedGet(q, "TIME_ON").c_str());
        CHECK(capturedGet(q, "FREQ") == "14.07415" && capturedGet(q, "BAND") == "20m", "type 5 FREQ in MHz and BAND: %s",
              capturedGet(q, "FREQ").c_str());
        CHECK(capturedGet(q, "MODE") == "MFSK" && capturedGet(q, "SUBMODE") == "FT4", "FT4 written as MFSK + FT4");
        CHECK(capturedGet(q, "STATION_CALLSIGN") == "KW9D" && capturedGet(q, "MY_GRIDSQUARE") == "EN52" &&
                  capturedGet(q, "RST_SENT") == "-10" && capturedGet(q, "NAME") == "Ann" && capturedGet(q, "STX_STRING").empty(),
              "type 5 other fields");
    }
    // QDateTime: Julian day 2451545 is 2000-01-01 (Qt's QDate::toJulianDay).
    std::string y2k = wsjtxQsoLogged("x", {{"CALL", "K1AB"}, {"QSO_DATE", "20000101"}, {"TIME_ON", "000000"}});
    size_t at = 16 + 1;  // magic, schema, type, Id length + "x"
    long long jd = 0;
    for (size_t i = 0; i < 8; ++i) jd = (jd << 8) | (unsigned char)y2k[at + i];
    CHECK(jd == 2451545, "Julian day of 2000-01-01: %lld", jd);
    // A time with an offset from UTC (timespec 2): 01:30 at UTC+2 is 23:30 UTC the day before.
    std::string off = wsjtxQsoLogged("x", {{"CALL", "K1AB"}, {"QSO_DATE", "20261009"}, {"TIME_ON", "013000"}, {"FREQ", "7.074"}, {"MODE", "FT8"}});
    size_t spec = at + 8 + 4;
    off[spec] = 2;
    off.insert(spec + 1, std::string("\x00\x00\x1c\x20", 4));  // +7200 s
    got = parseWsjtxMessage(off);
    CHECK(got.size() == 1 && capturedGet(got[0], "QSO_DATE_OFF") == "20261008" && capturedGet(got[0], "TIME_OFF") == "233000",
          "offset from UTC applied: %s", got.empty() ? "" : capturedGet(got[0], "TIME_OFF").c_str());
    // Logged ADIF (type 12), as WSJT-X sends it: a header, then one record.
    std::string adif = "\n<adif_ver:5>3.1.0\n<programid:6>WSJT-X\n<EOH>\n<call:4>W1AW <gridsquare:4>FN31 <mode:3>FT8 "
                       "<rst_sent:3>-12 <rst_rcvd:3>-09 <qso_date:8>20261009 <time_on:6>120015 <qso_date_off:8>20261009 "
                       "<time_off:6>120130 <band:3>20m <freq:9>14.075123 <station_callsign:4>KW9D <my_gridsquare:4>EN52 <eor>";
    got = parseWsjtxMessage(wsjtxLoggedAdif("JTDX", adif), &isWsjtx);
    CHECK(isWsjtx && got.size() == 1 && got[0].wsjtxType == 12 && got[0].client == "JTDX" && capturedGet(got[0], "CALL") == "W1AW" &&
              capturedGet(got[0], "TIME_ON") == "120015" && capturedGet(got[0], "BAND") == "20m" && got[0].problem.empty(),
          "type 12 parsed (%zu)", got.size());
    // Other types are WSJT-X but carry no QSO; short or foreign bytes are neither.
    std::string heartbeat("\xad\xbc\xcb\xda\x00\x00\x00\x03\x00\x00\x00\x00", 12);
    heartbeat += wsjtxString("WSJT-X");
    got = parseWsjtxMessage(heartbeat, &isWsjtx);
    CHECK(isWsjtx && got.empty(), "heartbeat ignored");
    for (size_t n = 0; n < msg.size(); n += 7) parseWsjtxMessage(msg.substr(0, n));  // truncations must not crash
    got = parseWsjtxMessage("<call:4>K1AB <eor>", &isWsjtx);
    CHECK(!isWsjtx && got.empty(), "ADIF isn't a WSJT-X message");

    // Plain ADIF payloads.
    got = parseAdifPayload("ADD <call:4>K1AB <qso_date:8>20261009 <time_on:4>1200 <freq:5>7.074 <mode:3>FT8 <eor>", "Log4OM");
    CHECK(got.size() == 1 && capturedGet(got[0], "BAND") == "40m" && got[0].source == "Log4OM" && got[0].problem.empty(),
          "Log4OM ADD record");
    got = parseAdifPayload("<call:4>K1AB <qso_date:8>20261009 <time_on:4>1200 <band:3>20m <mode:2>CW <EOR><call:4>K2CD "
                           "<qso_date:8>20261009 <time_on:4>1201 <band:3>20m <mode:2>CW",
                           "ADIF over UDP");
    CHECK(got.size() == 2 && capturedGet(got[1], "CALL") == "K2CD", "two records, the last without <EOR> (%zu)", got.size());
    got = parseAdifPayload("<call:4>K1AB <band:3>20m <eor>", "ADIF over UDP");
    CHECK(got.size() == 1 && got[0].problem == "no QSO_DATE, TIME_ON, MODE", "missing fields named: %s",
          got.empty() ? "" : got[0].problem.c_str());
    got = parseAdifPayload("<call:4>K1AB <qso_date:10>2026-10-09 <time_on:5>12:00 <band:3>20m <mode:3>USB <eor>", "x");
    CHECK(got.size() == 1 && capturedGet(got[0], "QSO_DATE") == "20261009" && capturedGet(got[0], "TIME_ON") == "1200" &&
              capturedGet(got[0], "MODE") == "SSB" && capturedGet(got[0], "SUBMODE") == "USB",
          "dates, times and USB normalised");
    CHECK(parseAdifPayload("no tags at all", "x").empty() && parseAdifPayload("", "x").empty(), "no ADIF, no QSOs");

    // N1MM Logger+ contact broadcasts.
    std::string n1mm = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<contactinfo>\n<app>N1MM</app>\n<contestname>DXPEDITION</contestname>\n"
                       "<timestamp>2026-10-09 16:43:38</timestamp>\n<mycall>KW9D</mycall>\n<band>3.5</band>\n<rxfreq>352519</rxfreq>\n"
                       "<txfreq>352519</txfreq>\n<operator></operator>\n<mode>CW</mode>\n<call>W1AW</call>\n<snt>599</snt>\n"
                       "<sntnr>5</sntnr>\n<rcv>579</rcv>\n<rcvnr>0</rcvnr>\n<name>Hiram &amp; co</name>\n<power>KW</power>\n"
                       "<ID>f9ffac4fcd3e479ca86e137df1338531</ID>\n</contactinfo>";
    got = parseCapture(n1mm, "UDP");
    CHECK(got.size() == 1 && got[0].kind == CapturedQso::Kind::Add && got[0].id == "f9ffac4fcd3e479ca86e137df1338531", "N1MM contactinfo");
    if (got.size() == 1) {
        const CapturedQso &q = got[0];
        CHECK(capturedGet(q, "CALL") == "W1AW" && capturedGet(q, "QSO_DATE") == "20261009" && capturedGet(q, "TIME_ON") == "164338" &&
                  capturedGet(q, "FREQ") == "3.52519" && capturedGet(q, "BAND") == "80m" && capturedGet(q, "RST_RCVD") == "579" &&
                  capturedGet(q, "STX") == "5" && capturedGet(q, "SRX").empty() && capturedGet(q, "NAME") == "Hiram & co" &&
                  capturedGet(q, "RX_PWR").empty() && capturedGet(q, "STATION_CALLSIGN") == "KW9D" &&
                  capturedGet(q, "APP_N1MM_ID") == "f9ffac4fcd3e479ca86e137df1338531" && q.problem.empty(),
              "N1MM fields: FREQ %s", capturedGet(q, "FREQ").c_str());
        CHECK(capturedGet(q, "CONTEST_ID").empty() && capturedGet(q, "APP_N1MM_CONTESTNAME") == "DXPEDITION",
              "N1MM's own contest name kept apart");
    }
    std::string replace = n1mm;
    replace.replace(replace.find("<contactinfo>"), 13, "<contactreplace>");
    replace.replace(replace.find("</contactinfo>"), 14, "</contactreplace>");
    replace.replace(replace.find("DXPEDITION"), 10, "CQ-WW-CW");
    got = parseCapture(replace, "UDP");
    CHECK(got.size() == 1 && got[0].kind == CapturedQso::Kind::Replace && capturedGet(got[0], "CONTEST_ID") == "CQ-WW-CW",
          "N1MM contactreplace, an ADIF contest id");
    got = parseCapture("<?xml version=\"1.0\"?><contactdelete><app>N1MM</app><timestamp>2026-10-09 16:43:38</timestamp>"
                       "<call>W1AW</call><ID>f9ffac4fcd3e479ca86e137df1338531</ID></contactdelete>",
                       "UDP");
    CHECK(got.size() == 1 && got[0].kind == CapturedQso::Kind::Delete && got[0].id == "f9ffac4fcd3e479ca86e137df1338531",
          "N1MM contactdelete");
    CHECK(parseCapture("<?xml version=\"1.0\"?><RadioInfo><Freq>1407400</Freq></RadioInfo>", "UDP").empty(),
          "N1MM radio info is not a QSO");

    // Commands to loggers, as GridTracker sends them.
    std::string rec = "<CALL:4>K1AB <QSO_DATE:8>20261009 <TIME_ON:6>120000 <FREQ:9>14.074000 <MODE:3>FT8 <EOR>";
    std::string dxk = "<command:3>log<parameters:" + std::to_string(rec.size()) + ">" + rec + "\r\n";
    got = parseCapture(dxk, "TCP");
    CHECK(got.size() == 1 && capturedGet(got[0], "CALL") == "K1AB" && capturedGet(got[0], "BAND") == "20m", "DXKeeper log command");
    got = parseCapture("ver\rdb add {CALL=\"K1AB\" QSO_DATE=\"20261009\" TIME_ON=\"120000\" FREQ=\"14074000\" MODE=\"FT8\" }\rexit\r", "TCP");
    CHECK(got.size() == 1 && capturedGet(got[0], "FREQ") == "14.074" && capturedGet(got[0], "BAND") == "20m" && got[0].problem.empty(),
          "HRD db add, FREQ without its point: %s", got.empty() ? "" : capturedGet(got[0], "FREQ").c_str());
    got = parseCapture(" " + rec, "ADIF over UDP");
    CHECK(got.size() == 1 && got[0].source == "ADIF over UDP", "plain ADIF by default");
    // JS8Call's API: LOG.QSO carries the record as a JSON string; other messages carry none.
    got = parseCapture("{\"params\":{\"CALL\":\"K1AB\",\"_ID\":-1},\"type\":\"LOG.QSO\",\"value\":\"<call:4>K1AB <gridsquare:4>FN42 "
                       "<mode:3>MFSK <submode:3>JS8 <qso_date:8>20261009 <time_on:6>120000 <band:3>40m <freq:8>7.078000 "
                       "<name:7>Ren\\u00e9 \\\"R\\\" <comment:5>a\\/b\\n\"}",
                       "UDP");
    CHECK(got.size() == 1 && got[0].source == "JS8Call" && capturedGet(got[0], "SUBMODE") == "JS8" &&
              capturedGet(got[0], "NAME") == "Ren\xC3\xA9 \"R\"" && got[0].problem.empty(),
          "JS8Call LOG.QSO: %s", got.empty() ? "" : capturedGet(got[0], "NAME").c_str());
    CHECK(parseCapture("{\"type\":\"RX.ACTIVITY\",\"value\":\"<call:4>K1AB <eor>\",\"params\":{}}", "UDP").empty() &&
              parseCapture("{\"params\":{\"type\":\"LOG.QSO\"},\"type\":\"STATION.STATUS\",\"value\":\"\"}", "UDP").empty() &&
              parseCapture("{\"type\":\"LOG.QSO\",\"value\":\"\\ud83d\\ude00<call:4>K1AB", "UDP").empty(),
          "other JS8Call messages, a nested type and broken JSON give nothing");

    // Into a log: adds, duplicates, N1MM replace and delete.
    CaptureFormat fmt;
    fmt.programVersion = "0.10";
    fmt.timestamp = "20261009 120000";
    std::string log;
    std::vector<CaptureOutcome> outs;
    std::string why;
    std::vector<CapturedQso> first = parseCapture(n1mm, "UDP");
    std::vector<CapturedQso> batch = parseAdifPayload(
        "<call:4>K1AB <qso_date:8>20261009 <time_on:4>1200 <band:3>20m <mode:2>CW <eor>"
        "<call:4>K1AB <qso_date:8>20261009 <time_on:4>1201 <band:3>20m <mode:2>CW <eor>",  // the same QSO again
        "x");
    batch.insert(batch.begin(), first.begin(), first.end());
    CHECK(applyCaptured(log, batch, fmt, &outs, &why) && outs.size() == 3 && outs[0].result == CaptureResult::Added &&
              outs[1].result == CaptureResult::Added && outs[2].result == CaptureResult::Duplicate && outs[2].record == 2,
          "a blank log gets a header, two QSOs and a duplicate skipped: %s", why.c_str());
    LintResult lr = lintModel(log);
    CHECK(lr.errors == 0 && recordCount(lr.model) == 2 && log.find("<EOH>") != std::string::npos, "the new log lints clean:\n%s",
          log.c_str());
    std::string before = log;
    got = parseCapture(replace, "UDP");  // the same N1MM ID, now with a contest
    CHECK(applyCaptured(log, got, fmt, &outs, &why) && outs.size() == 1 && outs[0].result == CaptureResult::Replaced &&
              outs[0].record == 1 && log.find("<CONTEST_ID:8>CQ-WW-CW") != std::string::npos && recordCount(lintModel(log).model) == 2,
          "N1MM replace in place:\n%s", log.c_str());
    TextEdit edit = minimalEdit(before, log);
    std::string redone = before;
    redone.replace(edit.start, edit.end - edit.start, edit.text);
    CHECK(redone == log && edit.start > before.find("<EOH>") && edit.end < before.size(), "one small edit does it");
    got = parseCapture("<?xml version=\"1.0\"?><contactdelete><call>W1AW</call><ID>F9FFAC4FCD3E479CA86E137DF1338531</ID></contactdelete>",
                       "UDP");
    CHECK(applyCaptured(log, got, fmt, &outs, &why) && outs[0].result == CaptureResult::Deleted && recordCount(lintModel(log).model) == 1 &&
              log.find("W1AW") == std::string::npos && lintModel(log).errors == 0,
          "N1MM delete:\n%s", log.c_str());
    CHECK(applyCaptured(log, got, fmt, &outs, &why) && outs[0].result == CaptureResult::NotFound, "deleting it again finds nothing");
    std::string broken = log + "<call:4>K9XX <band:3>20m";
    std::string kept = broken;
    CHECK(!applyCaptured(broken, batch, fmt, &outs, &why) && why.find("no <EOR>") != std::string::npos && broken == kept,
          "a last record without <EOR> refuses: %s", why.c_str());
    std::string notes = "Shopping list: milk";
    CHECK(!applyCaptured(notes, batch, fmt, &outs, &why) && why == "It isn't an ADIF log.", "plain text refuses: %s", why.c_str());
    std::string crlf = "x\r\n<EOH>\r\n";
    fmt.eol = "\r\n";
    CHECK(applyCaptured(crlf, {batch[1]}, fmt, &outs, &why) && crlf.find("<EOR>\r\n") != std::string::npos &&
              lintModel(crlf).errors == 0,
          "the log's line ends");
    fmt.eol = "\n";
    TextEdit utf = minimalEdit("a\xC3\xA9z", "a\xC3\xA8z");  // é -> è share a lead byte
    CHECK(utf.start == 1 && utf.end == 3 && utf.text == "\xC3\xA8", "edits keep whole UTF-8 characters");

    // The queue file round trip keeps actions and sources.
    std::vector<CapturedQso> queue = batch;
    queue.push_back(parseCapture("<contactdelete><ID>abc</ID><call>W1AW</call></contactdelete>", "UDP")[0]);
    std::string qt = queueText(queue, "0.10", "20261009 120000");
    std::vector<CapturedQso> back = parseQueue(qt);
    CHECK(lint(qt).errors == 0 && back.size() == 4 && back[0].source == "N1MM Logger+" && back[0].id == "f9ffac4fcd3e479ca86e137df1338531" &&
              back[3].kind == CapturedQso::Kind::Delete && back[3].id == "abc" && capturedGet(back[1], "CALL") == "K1AB" &&
              capturedGet(back[1], "APP_ADIFLINT_SOURCE").empty(),
          "queue round trip:\n%s", qt.c_str());
}

int main(int argc, char **argv) {
    testStructure();
    testHeader();
    testTypes();
    testEnumerations();
    testUserAndAppFields();
    testNonAscii();
    testModel();
    testReformat();
    testFieldEdits();
    testChoices();
    testNewQso();
    testEnrich();
    testToolsBasics();
    testBulkEdit();
    testTimeShift();
    testTimeZones();
    testSortDupesMerge();
    testCsv();
    testPota();
    testWorkedBefore();
    testFrequencies();
    testSpots();
    testUpload();
    testReviewFixes();
    testGeo();
    if (argc > 2) {
        gCtyPath = argv[2];
        testCountry();
    } else {
        std::printf("note: cty.csv not given; skipping\n");
    }
    testPrograms();
    testFormats();
    testImport();
    testOrganize();
    testGridEdits();
    testQuickFixes();
    testProfiles();
    testCapture();
    if (argc > 1) testOfficialFile(argv[1]);
    else std::printf("note: official test file not given; skipping\n");
    std::printf("%d/%d checks passed\n", gChecks - gFailures, gChecks);
    return gFailures ? 1 : 0;
}
