// Mutation fuzz and worst-case timing for the ADI validator.
//
// Build with -fsanitize=address,undefined. Every input is untrusted text from
// the editor, so lint() must never crash, must return in-bounds ranges and
// non-overlapping fixes, and must stay near-linear on hostile inputs.
//
//   fuzz_smoke SEED_FILE [ITERATIONS]
#include "adif_capture.h"
#include "adif_qsl.h"
#include "adif_country.h"
#include "adif_edit.h"
#include "adif_formats.h"
#include "adif_geo.h"
#include "adif_import.h"
#include "adif_lint.h"
#include "adif_programs.h"
#include "adif_profiles.h"
#include "adif_tools.h"
#include "adif_upload.h"

#include <chrono>
#include <cstdio>
#include <fstream>
#include <random>
#include <sstream>
#include <string>

using namespace adif;

static int gFailures = 0;

static void checkInvariants(const std::string &text, const LintResult &r, const char *what) {
    for (const Diagnostic &d : r.diagnostics) {
        if (!(d.start < d.end && d.end <= text.size())) {
            std::printf("FAIL %s: diagnostic range [%zu,%zu) outside %zu bytes\n", what, d.start, d.end, text.size());
            ++gFailures;
            return;
        }
    }
    size_t prev = 0;
    for (const LengthFix &f : r.fixes) {
        if (f.start < prev || f.end > text.size() || f.end <= f.start) {
            std::printf("FAIL %s: bad fix [%zu,%zu)\n", what, f.start, f.end);
            ++gFailures;
            return;
        }
        prev = f.end;
    }
}

// Model offsets go straight into Scintilla calls in the plugin: they must be in
// bounds and ordered, and the editing helpers must keep data intact.
static void checkModel(const std::string &text, const LintResult &r, std::mt19937 &rng) {
    const DocModel &m = r.model;
    size_t n = text.size();
    for (const ModelField &f : m.fields) {
        bool ok = f.tagB < f.nameE && f.nameE < f.lenB && f.lenB < f.lenE && f.lenE <= f.gt && f.gt < n && f.gt < f.valueE + 1 &&
                  f.valueE <= n && (f.typePos == kNoPos || (f.typePos > f.lenE && f.typePos < f.gt));
        if (!ok) {
            std::printf("FAIL model field out of order: tag %zu name %zu len %zu-%zu gt %zu value %zu (n %zu)\n", f.tagB, f.nameE,
                        f.lenB, f.lenE, f.gt, f.valueE, n);
            ++gFailures;
            return;
        }
    }
    for (const ModelGroup &g : m.groups) {
        if (g.firstField + g.fieldCount > m.fields.size() || (g.markerB != kNoPos && !(g.markerB < g.markerE && g.markerE <= n))) {
            std::printf("FAIL model group out of range\n");
            ++gFailures;
            return;
        }
    }
    if (canReformat(r)) {
        std::string out = reformat(text, m, Layout::FieldPerLine, "\n");
        LintOptions o;
        o.buildModel = true;
        LintResult ro = lint(out, o);
        if (ro.model.fields.size() != m.fields.size()) {
            std::printf("FAIL reformat changed the number of fields: %zu -> %zu\n", m.fields.size(), ro.model.fields.size());
            ++gFailures;
            return;
        }
    }
    // Log tools: reports on any model; edits only where the plugin allows them.
    std::vector<Record> recs = records(text, m);
    toCsv(recs, tableColumns(recs));
    summaryReport(text, m, "fuzz");
    potaExport(text, m, "K1AB", "0", "20260101 000000", "\n", LengthUnit::Bytes, true, "20260101");
    for (Program p : {Program::WWFF, Program::SOTA}) {
        programActivations(text, m, p, "K1AB");
        programExport(p, text, m, "K1AB", "0", "20260101 000000", "\n", LengthUnit::Bytes, true, "20260101");
    }
    toCabrillo(recs, CabrilloOptions());
    // Any document read as a site's download, and planned against itself.
    for (ImportSite site : {ImportSite::LoTW, ImportSite::QRZLogbook, ImportSite::EQSL}) {
        std::vector<SiteQso> qsos = siteQsos(site, text, m, "20260101");
        std::vector<ImportItem> items = planImport(text, m, qsos, site);
        std::vector<size_t> all;
        for (size_t i = 0; i < qsos.size(); ++i) all.push_back(i);
        if (items.size() != qsos.size()) {
            std::printf("FAIL import: %zu items for %zu QSOs\n", items.size(), qsos.size());
            ++gFailures;
        }
        importedRecords(qsos, all, Layout::RecordPerLine, "\n", LengthUnit::Bytes, true);
    }
    // Rows without a QSO field (a header read as a record) are dropped; nothing is invented.
    CsvImport back = importCsv(toCsv(recs, tableColumns(recs)));
    if (back.records.size() > recs.size()) {
        std::printf("FAIL CSV round trip: %zu records became %zu\n", recs.size(), back.records.size());
        ++gFailures;
    }
    contacts(text, m);
    auto editsOk = [&](const std::vector<TextEdit> &edits) {
        size_t prev = 0;
        for (const TextEdit &e : edits) {
            if (e.start < prev || e.end < e.start || e.end > n) return false;
            prev = e.end;
        }
        return true;
    };
    if (canReformat(r)) {
        std::vector<int> groups;
        for (const Record &rec : recs) groups.push_back(rec.group);
        BulkEdit op;
        op.field = "MODE";
        op.value = "CW";
        bool ok = editsOk(planEdits(text, m, planBulkEdit(text, m, groups, op).changes, LengthUnit::Bytes, true)) &&
                  editsOk(planEdits(text, m, planTimeShift(text, m, groups, -1441).changes, LengthUnit::Bytes, true)) &&
                  editsOk(duplicateEdits(text, m, findDuplicates(text, m, DupeOptions()), true, LengthUnit::Bytes, true));
        if (!ok) {
            std::printf("FAIL tool edits out of order or bounds\n");
            ++gFailures;
        }
        if (!editsOk(planEdits(text, m, planDistance(text, m, groups).changes, LengthUnit::Bytes, true))) {
            std::printf("FAIL distance edits out of order or bounds\n");
            ++gFailures;
        }
        std::vector<TextEdit> mm = markModified(text, m, groups, LengthUnit::Bytes, true);
        if (!editsOk(mm) || !editsOk(mergeEdits(planEdits(text, m, planBulkEdit(text, m, groups, op).changes, LengthUnit::Bytes, true), mm))) {
            std::printf("FAIL modified-status edits out of order or bounds\n");
            ++gFailures;
        }
        recordKeys(recs);
        if (!recs.empty()) sameContactAs(text, m, recs.front());
        size_t edited = 0, skipped = 0;
        std::vector<TextEdit> fo = fieldOrderEdits(text, m, {"CALL", "QSO_DATE", "TIME_ON", "BAND"}, &edited, &skipped);
        if (!editsOk(fo)) {
            std::printf("FAIL field-order edits out of order or bounds\n");
            ++gFailures;
        } else if (lint(applyTextEdits(text, fo)).records != r.records) {
            std::printf("FAIL reordering fields changed the number of records\n");
            ++gFailures;
        }
        // Quick fixes (Check Log, --fix-all): in bounds, ordered, and never losing or splitting
        // records (adding a missing final <EOR> makes that record count).
        size_t repaired = 0;
        bool addsEor = false;
        for (const Diagnostic &d : r.diagnostics) addsEor |= d.code == "no-eor" && !d.fixes.empty();
        std::vector<TextEdit> qf = quickFixEdits(text, m, r.diagnostics, LengthUnit::Bytes, true, &repaired);
        size_t afterRecords = editsOk(qf) ? lint(applyTextEdits(text, qf)).records : 0;
        if (!editsOk(qf)) {
            std::printf("FAIL quick-fix edits out of order or bounds\n");
            ++gFailures;
        } else if (afterRecords != r.records && !(addsEor && afterRecords == r.records + 1)) {
            std::printf("FAIL quick fixes changed the number of records: %zu -> %zu\n", r.records, afterRecords);
            ++gFailures;
        }
        bool sortedAgain = false;
        std::string byBand = sortedBy(text, m, {{"BAND", false}, {"CALL", true}, {"FREQ", false}}, "\n", &sortedAgain);
        if (lint(byBand).records != r.records) {
            std::printf("FAIL sorting by fields changed the number of records\n");
            ++gFailures;
        }
        bool changed = false;
        std::string sorted = sortedByTime(text, m, "\n", &changed);
        LintResult rs = lint(sorted);
        if (rs.records != r.records) {
            std::printf("FAIL sorting changed the number of records: %zu -> %zu\n", r.records, rs.records);
            ++gFailures;
        }
    }
    if (!m.groups.empty()) {
        const ModelGroup &g = m.groups[rng() % m.groups.size()];
        auto inBounds = [&](const TextEdit &e) { return e.start <= e.end && e.end <= n; };
        bool ok = inBounds(insertField(text, m, g, "CALL", "W1AW", LengthUnit::Bytes, true));
        if (g.fieldCount) {
            size_t i = rng() % g.fieldCount;
            ok = ok && inBounds(removeField(text, m, g, i)) &&
                 inBounds(setFieldValue(text, m.fields[g.firstField + i], "x", LengthUnit::Characters, true));
            valueChoices(text, m, &g, fieldName(text, m.fields[g.firstField + i]));
        }
        fieldNameChoices(m, g.header);
        if (!ok) {
            std::printf("FAIL edit out of bounds\n");
            ++gFailures;
        }
    }
}

static double lintMs(const std::string &text, LintOptions opt = {}) {
    auto t0 = std::chrono::steady_clock::now();
    LintResult r = lint(text, opt);
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    checkInvariants(text, r, "timing input");
    return ms;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: fuzz_smoke SEED_FILE [ITERATIONS]\n");
        return 2;
    }
    std::ifstream in(argv[1], std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    std::string seed = ss.str().substr(0, 20000);  // a header plus ~100 records
    int iterations = argc > 2 ? std::atoi(argv[2]) : 3000;

    std::mt19937 rng(7);
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
    const double limitMsCapture = 10000;
#else
    const double limitMsCapture = 2000;
#endif
#else
    const double limitMsCapture = 2000;
#endif
    static const char kAlphabet[] = "<>:0123456789EORHABCDLMNSTxyz \r\n\t\x80\xC3\xBF-_.,{}";
    LintOptions chars;
    chars.lengthUnit = LengthUnit::Characters;
    for (int i = 0; i < iterations; ++i) {
        std::string t = seed;
        int edits = 1 + (int)(rng() % 20);
        for (int k = 0; k < edits && !t.empty(); ++k) {
            size_t at = rng() % t.size();
            char c = kAlphabet[rng() % (sizeof kAlphabet - 1)];
            switch (rng() % 4) {
                case 0: t[at] = c; break;
                case 1: t.insert(at, 1, c); break;
                case 2: t.erase(at, 1 + rng() % 8); break;
                case 3: t = t.substr(0, at); break;  // truncation
            }
        }
        LintOptions o = (i & 1) ? chars : LintOptions{};
        o.buildModel = true;
        LintResult r = lint(t, o);
        checkInvariants(t, r, "mutation");
        checkModel(t, r, rng);
        std::string repaired = applyFixes(t, r.fixes);
        LintResult r2 = lint(repaired, (i & 1) ? chars : LintOptions{});
        checkInvariants(repaired, r2, "repaired");
        if (gFailures) break;
    }

    // Network replies (QRZ, eQSL, POTA spots), CSV and country files are untrusted too.
    const std::vector<std::string> replies = {
        "RESULT=FAIL&REASON=Unable%20to%20add%20QSO:%20duplicate&COUNT=0",
        "Result: 1 out of 2 records added<BR>Warning: Y=2026 M=10 D=06 Bad record: Duplicate<BR>Error: down<BR>",
        "RESULT=OK&COUNT=1&ADIF=&lt;call:4&gt;K1AE &lt;qso_date:8&gt;20261006 &#60;eor&#x3e; &amp;&#;&#99999999;",
        "<HTML>Your ADIF log file has been built<BR><A HREF=\"downloadedfiles/x.adi\">.ADI file</A>Error: No such Username</HTML>",
        "Call,Date,UTC,Freq (kHz),Mode\r\n\xEF\xBB\xBF\"W1AW\",2026-10-06,23:10,\"14,250\",SSB\r\n'K1AB;\"\"x\",,\n",
        "DL,Fed. Rep. of Germany,230,EU,14,28,51.00,-10.00,-1.0,DA DB =DL0ABC(14)[28]<51/-10>{EU}~-1~ DL/P;\n"
        "K,United States,291,NA,5,8,37.60,91.87,5.0,AA K N W =W1AW/7(3)[6];\n",
        "<StationDataFile>\n  <StationData name=\"Home &amp; QTH\">\n    <CALL>KW9D</CALL><DXCC>291</DXCC><GRIDSQUARE/>"
        "<US_STATE>IL</US_STATE><US_COUNTY>Cook &#233;&#x1F600;</US_COUNTY>\n  </StationData>\n</StationDataFile>\n"};
    static const char kNet[] = "<>/:&=%+ \r\n0123456789RPRTFrequency.-ABCDEFabcdef;\"";
    for (int i = 0; i < iterations * 4; ++i) {
        std::string t = replies[(size_t)i % replies.size()];
        int edits = 1 + (int)(rng() % 12);
        for (int k = 0; k < edits && !t.empty(); ++k) {
            size_t at = rng() % t.size();
            char c = kNet[rng() % (sizeof kNet - 1)];
            switch (rng() % 4) {
                case 0: t[at] = c; break;
                case 1: t.insert(at, 1, c); break;
                case 2: t.erase(at, 1 + rng() % 8); break;
                case 3: t = t.substr(0, at); break;
            }
        }
        parseQrzReply(t);
        parseEqslReply(t);
        formDecode(t);
        hzToMHz(t.substr(0, 20));
        khzToMHz(t.substr(0, 20));
        spotFields(t.substr(0, 12), t.substr(0, 10), t.substr(0, 6), t.substr(0, 12));
        QrzReply qr;
        std::string page;
        parseQrzFetch(t, &qr, &page);
        htmlDecode(t);
        std::string error;
        eqslInboxLink(t, &error);
        importCsv(t);
        CountryTable table;
        table.load(t);
        CountryInfo ci;
        table.lookup(t.substr(0, 12), &ci);
        countryFields(table, t.substr(t.size() / 2, 10));
        gridDistanceText(t.substr(0, 6), t.substr(t.size() / 3, 8));
        for (Program p : {Program::WWFF, Program::SOTA}) programSpotFields(p, t.substr(0, 10), t.substr(0, 8), "CW", t.substr(0, 12));
        referenceSummary(t.substr(0, 14), ReferenceHistory());
        parseProfiles(t);
        for (const TqslLocation &loc : parseStationData(t)) {
            Record r;
            r.fields = {{"STATION_CALLSIGN", t.substr(0, 6)}, {"MY_GRIDSQUARE", t.substr(t.size() / 2, 6)}, {"MY_STATE", t.substr(0, 2)},
                        {"MY_CNTY", t.substr(0, 9)}, {"MY_CQ_ZONE", t.substr(0, 3)}};
            lotwLocationProblem(r, loc);
        }
        std::vector<std::string> bad;
        std::string why;
        for (Program p : {Program::POTA, Program::WWFF, Program::SOTA}) parseReferences(p, t.substr(0, 40), &bad, &why);
    }

    // Datagrams and TCP messages from other programs (Monitor): any bytes at all.
    const FieldList qso = {{"CALL", "K1AB"}, {"QSO_DATE", "20261009"}, {"TIME_ON", "235930"}, {"FREQ", "14.07415"},
                           {"MODE", "FT4"},  {"RST_SENT", "-10"},      {"NAME", "Ann"},       {"STATION_CALLSIGN", "KW9D"}};
    const std::string rec = "<CALL:4>K1AB <QSO_DATE:8>20261009 <TIME_ON:6>120000 <FREQ:9>14.074000 <MODE:3>FT8 <EOR>";
    const std::vector<std::string> captures = {
        wsjtxQsoLogged("WSJT-X", qso),
        wsjtxLoggedAdif("JTDX", "\n<adif_ver:5>3.1.0\n<programid:6>WSJT-X\n<EOH>\n" + rec),
        "<?xml version=\"1.0\"?><contactinfo><contestname>CQ-WW-CW</contestname><timestamp>2026-10-09 16:43:38</timestamp>"
        "<txfreq>352519</txfreq><mode>USB</mode><call>W1AW</call><power>100</power><ID>f9ff</ID></contactinfo>",
        "<?xml version=\"1.0\"?><contactdelete><call>W1AW</call><ID>f9ff</ID></contactdelete>",
        "<command:3>log<parameters:" + std::to_string(rec.size()) + ">" + rec + "\r\n",
        "ver\rdb add {CALL=\"K1AB\" QSO_DATE=\"20261009\" TIME_ON=\"120000\" FREQ=\"14074000\" MODE=\"FT8\" }\rexit\r",
        "ADD " + rec + rec,
        "{\"params\":{\"CALL\":\"K1AB\"},\"type\":\"LOG.QSO\",\"value\":\"" + rec + "\\u00e9\\ud83d\\ude00\\\"\"}"};
    for (int i = 0; i < iterations * 4; ++i) {
        std::string t = captures[(size_t)i % captures.size()];
        int edits = 1 + (int)(rng() % 12);
        for (int k = 0; k < edits && !t.empty(); ++k) {
            size_t at = rng() % t.size();
            char c = (i & 1) ? (char)(rng() & 0xff) : kNet[rng() % (sizeof kNet - 1)];
            switch (rng() % 4) {
                case 0: t[at] = c; break;
                case 1: t.insert(at, 1, c); break;
                case 2: t.erase(at, 1 + rng() % 8); break;
                case 3: t = t.substr(0, at); break;
            }
        }
        for (const CapturedQso &q : parseCapture(t, "fuzz")) {
            bool named = true;
            for (const auto &f : q.fields)
                for (char c : f.first) named &= !(c >= 'a' && c <= 'z');
            bool complete = true;
            if (q.kind != CapturedQso::Kind::Delete && q.problem.empty())
                for (const char *n : {"CALL", "QSO_DATE", "TIME_ON", "MODE"}) {
                    bool has = false;
                    for (const auto &f : q.fields) has |= f.first == n && !f.second.empty();
                    complete &= has;
                }
            if (!named || !complete) {
                std::printf("FAIL capture: %s fields from %zu bytes\n", named ? "missing" : "lower-case", t.size());
                ++gFailures;
                break;
            }
        }
        parseLoggerCommand(t);
        parseN1mmXml(t);
        if (gFailures) break;
    }
    {
        auto t0 = std::chrono::steady_clock::now();
        for (const std::string &s : {std::string(1 << 16, '<'), std::string(1 << 16, '&'), [] {
                 std::string x = "<contactinfo>";
                 while (x.size() < (1u << 16)) x += "<call>";
                 return x;
             }()})
            for (int k = 0; k < 4; ++k) parseCapture(s, "fuzz");
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        std::printf("%-26s %6.1f ms\n", "hostile datagrams", ms);
        if (ms > limitMsCapture) {
            std::printf("FAIL hostile datagrams: %.0f ms is too slow\n", ms);
            ++gFailures;
        }
    }

    // Hostile shapes, ~2 MB each: these must stay well under a second in a release build.
    // The unoptimised ASan+UBSan build runs about 25 times slower, so it gets more time;
    // a quadratic slowdown would still blow far past either limit.
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define ADIF_FUZZ_SANITIZED 1
#endif
#endif
#ifdef ADIF_FUZZ_SANITIZED
    const double limitMs = 10000;
#else
    const double limitMs = 3000;
#endif
    const size_t big = 2u << 20;
    struct Case { const char *name; std::string text; LintOptions opt; };
    Case cases[] = {
        {"all '<'", std::string(big, '<'), {}},
        {"unclosed tags", [&] { std::string s; while (s.size() < big) s += "<CALL:4 "; return s; }(), {}},
        {"tiny fields", [&] { std::string s; while (s.size() < big) s += "<A:1>x"; return s; }(), {}},
        {"lengths too long (bytes)", [&] { std::string s; while (s.size() < big) s += "<NOTES:99999>x\n"; return s; }(), {}},
        {"lengths too long (chars)", [&] { std::string s; while (s.size() < big) s += "<NOTES:99999>\xC3\xBC\n"; return s; }(), chars},
        {"one huge value", "x<EOH><NOTES:" + std::to_string(big) + ">" + std::string(big, 'a') + "<EOR>", {}},
        {"diagnostic flood", [&] { std::string s = "x<EOH>"; while (s.size() < big) s += "<BAND:3>99m<EOR>"; return s; }(), {}},
    };
    for (Case &c : cases) {
        double ms = lintMs(c.text, c.opt);
        std::printf("%-26s %6.1f ms\n", c.name, ms);
        if (ms > limitMs) {
            std::printf("FAIL %s: %.0f ms is too slow\n", c.name, ms);
            ++gFailures;
        }
    }

    std::printf("%d mutation iterations, %s\n", iterations, gFailures ? "FAILED" : "ok");
    return gFailures ? 1 : 0;
}
