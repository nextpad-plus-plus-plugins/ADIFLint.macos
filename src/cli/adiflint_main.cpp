// adiflint — check ADIF .adi files from the command line with the same rules
// as the Nextpad++ plugin.
//
//   adiflint [--chars] [--quiet] [--fix OUT] [--reformat records|fields OUT] FILE...
//   adiflint [--sort OUT | --sort-by KEYS OUT | --field-order FIELDS OUT | --dedupe OUT
//            | --csv OUT | --summary | --cabrillo OUT
//            | --export pota|wwff|sota DIR | --from-csv OUT] [--call CALL] [--contest ID] FILE
//
// Prints FILE:LINE:COLUMN: severity: message for each problem. Exit status is
// 1 when any file has errors, 2 on a usage or I/O failure, 0 otherwise. The
// log tools write a new file and never change FILE.
#include "adif_edit.h"
#include "adif_formats.h"
#include "adif_lint.h"
#include "adif_programs.h"
#include "adif_spec.h"
#include "adif_tools.h"

#include <cctype>
#include <ctime>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

void usage() {
    std::fprintf(stderr,
                 "usage: adiflint [--chars] [--quiet] [--fix OUT] [--reformat records|fields OUT] FILE...\n"
                 "  --chars     data lengths count UTF-8 characters, not bytes\n"
                 "  --quiet     errors only\n"
                 "  --fix OUT   write FILE with corrected data lengths to OUT (one FILE only)\n"
                 "  --reformat records|fields OUT\n"
                 "              write FILE with one record (or one field) per line to OUT (one FILE only;\n"
                 "              needs correct lengths, so combine with --fix only by running twice)\n"
                 "Log tools (one FILE; FILE itself is never changed):\n"
                 "  --fix-all OUT        data lengths, then every problem with a known repair (e.g. MODE USB\n"
                 "                       becomes MODE SSB, SUBMODE USB; 2026-10-06 becomes 20261006); exit 1\n"
                 "                       if errors are left\n"
                 "  --sort OUT           records by QSO_DATE and TIME_ON\n"
                 "  --sort-by KEYS OUT   records by fields, e.g. BAND,CALL:desc,QSO_DATE (bands by frequency,\n"
                 "                       numbers by value; records without a value last)\n"
                 "  --field-order FIELDS OUT\n"
                 "                       every record's fields in this order, e.g. CALL,QSO_DATE,TIME_ON (the\n"
                 "                       others after them); data copied byte for byte\n"
                 "  --dedupe OUT         remove repeated QSOs (same CALL, band, mode within 2 minutes)\n"
                 "  --csv OUT            a CSV file with a column per field\n"
                 "  --summary            print the log summary\n"
                 "  --cabrillo OUT       a Cabrillo 3.0 log (--contest ID, --call CALL)\n"
                 "  --export pota|wwff|sota DIR\n"
                 "                       one upload file per park (reference, summit) and UTC day into DIR\n"
                 "                       (--call CALL for records without STATION_CALLSIGN or OPERATOR)\n"
                 "  --from-csv OUT       FILE is a CSV file: write it as an ADIF log to OUT\n"
                 "Checks against ADIF %s (%s).\n",
                 adif::kSpecVersion, adif::kSpecDate);
}

bool writeFile(const std::string &path, const std::string &data) {
    std::ofstream o(path, std::ios::binary);
    o.write(data.data(), (std::streamsize)data.size());
    if (!o) {
        std::fprintf(stderr, "adiflint: cannot write %s\n", path.c_str());
        return false;
    }
    std::fprintf(stderr, "wrote %s\n", path.c_str());
    return true;
}

std::string utcNow(const char *format) {
    std::time_t now = std::time(nullptr);
    std::tm utc{};
    gmtime_r(&now, &utc);
    char buf[32];
    std::strftime(buf, sizeof buf, format, &utc);
    return buf;
}

bool readFile(const char *path, std::string *out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    *out = ss.str();
    return true;
}

}  // namespace

int main(int argc, char **argv) {
    adif::LintOptions opt;
    bool quiet = false;
    const char *fixOut = nullptr, *reformatOut = nullptr;
    std::string tool, toolOut, program, call, contest, list;  // a log tool, its output, and options
    adif::Layout layout = adif::Layout::RecordPerLine;
    std::vector<const char *> files;
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--chars")) opt.lengthUnit = adif::LengthUnit::Characters;
        else if (!std::strcmp(argv[i], "--quiet")) quiet = true;
        else if (!std::strcmp(argv[i], "--fix") && i + 1 < argc) fixOut = argv[++i];
        else if (!std::strcmp(argv[i], "--reformat") && i + 2 < argc &&
                 (!std::strcmp(argv[i + 1], "records") || !std::strcmp(argv[i + 1], "fields"))) {
            layout = !std::strcmp(argv[i + 1], "fields") ? adif::Layout::FieldPerLine : adif::Layout::RecordPerLine;
            reformatOut = argv[i + 2];
            i += 2;
        }
        else if ((!std::strcmp(argv[i], "--sort") || !std::strcmp(argv[i], "--dedupe") || !std::strcmp(argv[i], "--csv") ||
                  !std::strcmp(argv[i], "--fix-all") ||
                  !std::strcmp(argv[i], "--cabrillo") || !std::strcmp(argv[i], "--from-csv")) &&
                 i + 1 < argc && tool.empty()) {
            tool = argv[i] + 2;
            toolOut = argv[++i];
        } else if ((!std::strcmp(argv[i], "--sort-by") || !std::strcmp(argv[i], "--field-order")) && i + 2 < argc && tool.empty()) {
            tool = argv[i] + 2;
            list = argv[i + 1];
            toolOut = argv[i + 2];
            i += 2;
        } else if (!std::strcmp(argv[i], "--summary") && tool.empty()) {
            tool = "summary";
        } else if (!std::strcmp(argv[i], "--export") && i + 2 < argc && tool.empty() &&
                   (!std::strcmp(argv[i + 1], "pota") || !std::strcmp(argv[i + 1], "wwff") || !std::strcmp(argv[i + 1], "sota"))) {
            tool = "export";
            program = argv[i + 1];
            toolOut = argv[i + 2];
            i += 2;
        } else if (!std::strcmp(argv[i], "--call") && i + 1 < argc) {
            call = argv[++i];
        } else if (!std::strcmp(argv[i], "--contest") && i + 1 < argc) {
            contest = argv[++i];
        }
        else if (argv[i][0] == '-') {
            usage();
            return 2;
        } else files.push_back(argv[i]);
    }
    if (files.empty() || ((fixOut || reformatOut || !tool.empty()) && files.size() != 1) || (fixOut && reformatOut) ||
        (!tool.empty() && (fixOut || reformatOut))) {
        usage();
        return 2;
    }
    if (tool == "from-csv") {
        std::string csv;
        if (!readFile(files[0], &csv)) {
            std::fprintf(stderr, "adiflint: cannot read %s\n", files[0]);
            return 2;
        }
        adif::CsvImport ci = adif::importCsv(csv);
        for (const auto &c : ci.columns)
            std::fprintf(stderr, "column %s -> %s\n", c.first.c_str(), c.second.empty() ? "(left out)" : c.second.c_str());
        for (const std::string &n : ci.notes) std::fprintf(stderr, "%s\n", n.c_str());
        std::string out = adif::newLogHeader("adiflint", utcNow("%Y%m%d %H%M%S"), "\n");
        for (const auto &rec : ci.records) out += adif::buildRecord(rec, adif::Layout::RecordPerLine, "\n", opt.lengthUnit, true).text;
        return writeFile(toolOut, out) ? 0 : 2;
    }

    opt.today = utcNow("%Y%m%d");
    int status = 0;
    for (const char *path : files) {
        std::string text;
        if (!readFile(path, &text)) {
            std::fprintf(stderr, "adiflint: cannot read %s\n", path);
            return 2;
        }
        opt.buildModel = reformatOut != nullptr || !tool.empty();
        adif::LintResult r = adif::lint(text, opt);

        // Byte offset -> 1-based line and column (column in bytes).
        size_t line = 1, lineStart = 0, scanned = 0;
        for (const adif::Diagnostic &d : r.diagnostics) {
            for (; scanned < d.start; ++scanned)
                if (text[scanned] == '\n') {
                    ++line;
                    lineStart = scanned + 1;
                }
            if (quiet && d.severity != adif::Severity::Error) continue;
            std::printf("%s:%zu:%zu: %s: %s%s%s%s\n", path, line, d.start - lineStart + 1, adif::severityName(d.severity),
                        d.message.c_str(), d.code.empty() ? "" : " [", d.code.c_str(), d.code.empty() ? "" : "]");
        }
        std::fprintf(stderr, "%s: %zu record(s), %zu error(s), %zu warning(s), %zu note(s)%s; %zu length fix(es) available\n",
                     path, r.records, r.errors, r.warnings, r.infos, r.truncated ? " (list truncated)" : "",
                     r.fixes.size());
        if (r.errors) status = 1;

        if (!tool.empty()) {
            bool crlf = text.find("\r\n") != std::string::npos;
            std::string eol = crlf ? "\r\n" : "\n";
            std::vector<adif::Record> recs = adif::records(text, r.model);
            if ((tool == "sort" || tool == "sort-by" || tool == "field-order" || tool == "dedupe") && (!adif::canReformat(r))) {
                std::fprintf(stderr, "adiflint: fix the data lengths and malformed tags in %s first\n", path);
                return 2;
            }
            if (tool == "fix-all") {
                // Lengths first, then the repairs; a repair can reveal another, so a few passes.
                std::string cur = adif::applyFixes(text, r.fixes);
                size_t repaired = 0;
                for (int pass = 0; pass < 3; ++pass) {
                    adif::LintOptions o = opt;
                    o.buildModel = true;
                    adif::LintResult rr = adif::lint(cur, o);
                    size_t n = 0;
                    std::vector<adif::TextEdit> edits = adif::quickFixEdits(cur, rr.model, rr.diagnostics, opt.lengthUnit, opt.utf8, &n);
                    if (edits.empty()) break;
                    cur = adif::applyTextEdits(cur, edits);
                    repaired += n;
                }
                if (!writeFile(toolOut, cur)) return 2;
                adif::LintResult left = adif::lint(cur, opt);
                std::fprintf(stderr, "%zu length fix(es), %zu other repair(s); %zu error(s) left\n", r.fixes.size(), repaired,
                             left.errors);
                return left.errors ? 1 : 0;  // the result, not the input, decides
            } else if (tool == "summary") {
                std::string name = path;
                std::printf("%s", adif::summaryReport(text, r.model, name.substr(name.find_last_of('/') + 1)).c_str());
            } else if (tool == "sort") {
                bool changed = false;
                std::string out = adif::sortedByTime(text, r.model, eol, &changed);
                if (!writeFile(toolOut, out)) return 2;
                if (!changed) std::fprintf(stderr, "(already in date and time order)\n");
            } else if (tool == "sort-by" || tool == "field-order") {
                std::vector<std::string> names;
                std::string item;
                for (size_t k = 0; k <= list.size(); ++k) {
                    if (k == list.size() || list[k] == ',') {
                        if (!item.empty()) names.push_back(item);
                        item.clear();
                    } else {
                        item.push_back((char)std::toupper((unsigned char)list[k]));
                    }
                }
                std::string out;
                if (tool == "sort-by") {
                    std::vector<adif::SortKey> keys;
                    for (const std::string &n : names) {
                        size_t colon = n.find(':');
                        std::string dir = colon == std::string::npos ? "" : n.substr(colon + 1);
                        keys.push_back({n.substr(0, colon), dir == "DESC" || dir == "D"});
                    }
                    bool changed = false;
                    out = adif::sortedBy(text, r.model, keys, eol, &changed);
                    if (!changed) std::fprintf(stderr, "(already in that order)\n");
                } else {
                    size_t edited = 0, skipped = 0;
                    out = adif::applyTextEdits(text, adif::fieldOrderEdits(text, r.model, names, &edited, &skipped));
                    std::fprintf(stderr, "%zu record(s) reordered, %zu left as they were\n", edited, skipped);
                }
                if (!writeFile(toolOut, out)) return 2;
            } else if (tool == "dedupe") {
                std::vector<adif::DupeSet> sets = adif::findDuplicates(text, r.model, adif::DupeOptions());
                size_t removed = 0;
                for (const auto &d : sets) removed += d.remove.size();
                std::string out = adif::applyTextEdits(text, adif::duplicateEdits(text, r.model, sets, true, opt.lengthUnit, opt.utf8));
                if (!writeFile(toolOut, out)) return 2;
                std::fprintf(stderr, "removed %zu repeated record(s)\n", removed);
            } else if (tool == "csv") {
                if (!writeFile(toolOut, adif::toCsv(recs, adif::tableColumns(recs)))) return 2;
            } else if (tool == "cabrillo") {
                adif::CabrilloOptions o;
                o.contest = contest;
                o.callsign = call;
                o.createdBy = "adiflint";
                adif::CabrilloLog cl = adif::toCabrillo(recs, o);
                if (!writeFile(toolOut, cl.text)) return 2;
                std::fprintf(stderr, "%zu QSO line(s), %zu incomplete, %zu record(s) left out\n", cl.qsos, cl.incomplete, cl.skipped);
            } else if (tool == "export") {
                adif::Program p = program == "wwff" ? adif::Program::WWFF : program == "sota" ? adif::Program::SOTA : adif::Program::POTA;
                std::vector<adif::PotaFile> fs = adif::programExport(p, text, r.model, call, "adiflint", utcNow("%Y%m%d %H%M%S"), eol,
                                                                     opt.lengthUnit, opt.utf8, utcNow("%Y%m%d"));
                if (fs.empty()) std::fprintf(stderr, "no %s activations in %s\n", adif::programName(p), path);
                for (const auto &f : fs) {
                    if (!writeFile(toolOut + "/" + f.name, f.text)) return 2;
                    for (const std::string &n : f.notes) std::fprintf(stderr, "  %s\n", n.c_str());
                }
            }
        }
        if (fixOut) {
            std::ofstream out(fixOut, std::ios::binary);
            std::string fixed = adif::applyFixes(text, r.fixes);
            out.write(fixed.data(), (std::streamsize)fixed.size());
            if (!out) {
                std::fprintf(stderr, "adiflint: cannot write %s\n", fixOut);
                return 2;
            }
            std::fprintf(stderr, "wrote %s with %zu length fix(es)\n", fixOut, r.fixes.size());
        }
        if (reformatOut) {
            if (!adif::canReformat(r)) {
                std::fprintf(stderr, "adiflint: not reformatting %s: fix the data lengths and malformed tags first\n", path);
                return 2;
            }
            bool crlf = text.find("\r\n") != std::string::npos;
            std::string out = adif::reformat(text, r.model, layout, crlf ? "\r\n" : "\n");
            std::ofstream o(reformatOut, std::ios::binary);
            o.write(out.data(), (std::streamsize)out.size());
            if (!o) {
                std::fprintf(stderr, "adiflint: cannot write %s\n", reformatOut);
                return 2;
            }
            std::fprintf(stderr, "wrote %s\n", reformatOut);
        }
    }
    return status;
}
