#import "LogTools.h"
#import "Monitor.h"
#import "LotwUsers.h"
#include "adif_capture.h"
#include "adif_compare.h"

#import "Families.h"
#import "Lookup.h"
#import "PluginHost.h"
#import "ToolWindow.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "Scintilla.h"
#include "adif_enrich.h"
#include "adif_spec.h"
#include "adif_tools.h"
#include "adif_upload.h"
#include "adif_programs.h"
#include "adif_formats.h"

#include <sys/stat.h>

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <unordered_map>

using namespace adifhost;

namespace {

// ── Shared helpers ──────────────────────────────────────────────────────────

const std::vector<std::vector<std::string>> kNoRows;
const std::vector<int> kNoSev;
const std::vector<bool> kNoTicks;

NSString *logLine() { return [@"Log: " stringByAppendingString:ADIFString(documentName())]; }

bool hasRecords(const adif::LintResult &r) { return adif::recordCount(r.model) > 0; }

std::vector<int> allRecords(const adif::DocModel &m) {
    std::vector<int> out;
    for (size_t i = 0; i < m.groups.size(); ++i)
        if (!m.groups[i].header) out.push_back((int)i);
    return out;
}

// Records touching the editor selection; the record at the caret when nothing is selected.
std::vector<int> selectionRecords(NppHandle h, const adif::DocModel &m) {
    size_t b = (size_t)sci(h, SCI_GETSELECTIONSTART), e = (size_t)sci(h, SCI_GETSELECTIONEND);
    std::vector<int> out;
    for (size_t i = 0; i < m.groups.size(); ++i) {
        const adif::ModelGroup &g = m.groups[i];
        if (g.header) continue;
        size_t gb = adif::groupStart(m, g), ge = adif::groupEnd(m, g);
        bool touch = b == e ? (gb <= b && b <= ge) : (gb < e && ge > b);
        if (touch) out.push_back((int)i);
    }
    return out;
}

std::string fileName(const std::string &path) {
    size_t slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

std::string stem(const std::string &name) {
    size_t dot = name.find_last_of('.');
    return dot == std::string::npos || dot == 0 ? name : name.substr(0, dot);
}

NSString *tilde(const std::string &path) { return [ADIFString(path) stringByAbbreviatingWithTildeInPath]; }

bool writeFile(const std::string &path, const std::string &data, std::string *error) {
    NSData *d = [NSData dataWithBytes:data.data() length:data.size()];
    NSError *err = nil;
    if ([d writeToFile:ADIFString(path) options:NSDataWritingAtomic error:&err]) return true;
    if (error) *error = ADIFStd(err.localizedDescription ?: @"could not write the file");
    return false;
}

bool readFile(const std::string &path, size_t limit, std::string *out, std::string *error) {
    struct stat st{};
    if (stat(path.c_str(), &st) != 0) {
        if (error) *error = "cannot read " + fileName(path);
        return false;
    }
    if ((size_t)st.st_size > limit) {
        if (error) *error = fileName(path) + " is larger than " + std::to_string(limit >> 20) + " MB";
        return false;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        if (error) *error = "cannot read " + fileName(path);
        return false;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    *out = ss.str();
    return true;
}

// File dialogs. The test harness sets these variables to skip them.
std::string chooseSave(NSString *suggested, NSArray<NSString *> *extensions) {
    if (const char *dir = getenv("ADIFLINT_TEST_SAVE_DIR")) return std::string(dir) + "/" + ADIFStd(suggested);
    NSSavePanel *p = [NSSavePanel savePanel];
    p.nameFieldStringValue = suggested;
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *ext in extensions)
        if (UTType *t = [UTType typeWithFilenameExtension:ext]) [types addObject:t];
    p.allowedContentTypes = types;
    p.canCreateDirectories = YES;
    if ([p runModal] != NSModalResponseOK || !p.URL) return "";
    return ADIFStd(p.URL.path);
}

std::string chooseOpen(NSString *message, bool folder, NSArray<NSString *> *extensions = nil) {
    if (const char *env = getenv(folder ? "ADIFLINT_TEST_FOLDER" : "ADIFLINT_TEST_OPEN_FILE")) return env;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.message = message;
    p.canChooseFiles = !folder;
    p.canChooseDirectories = folder;
    p.allowsMultipleSelection = NO;
    p.canCreateDirectories = folder;
    if (!folder) {
        NSMutableArray<UTType *> *types = [NSMutableArray array];
        for (NSString *ext in extensions ?: @[ @"adi", @"adif" ])
            if (UTType *t = [UTType typeWithFilenameExtension:ext]) [types addObject:t];
        p.allowedContentTypes = types;
    }
    if ([p runModal] != NSModalResponseOK || !p.URL) return "";
    return ADIFStd(p.URL.path);
}

NSArray<NSString *> *nsList(const std::vector<std::string> &v) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:v.size()];
    for (const std::string &s : v) [a addObject:ADIFString(s)];
    return a;
}

// Field names for a field chooser: the log's own fields first, then every QSO field.
std::vector<std::string> fieldChoices(std::string_view text, const adif::DocModel &m) {
    std::vector<std::string> out;
    std::set<std::string> seen;
    for (const adif::Record &r : adif::records(text, m))
        for (const auto &f : r.fields)
            if (seen.insert(f.first).second) out.push_back(f.first);
    std::sort(out.begin(), out.end());
    for (const std::string &n : adif::fieldNameChoices(m, false))
        if (n != "EOR" && seen.insert(n).second) out.push_back(n);
    return out;
}

long parseLong(NSTextField *f) {
    std::string s = ADIFStd(f.stringValue);
    char *end = nullptr;
    long v = std::strtol(s.c_str(), &end, 10);
    return end && *end == 0 ? v : 0;
}

bool isInteger(NSTextField *f) {
    std::string s = ADIFStd(f.stringValue);
    if (s.empty()) return true;
    char *end = nullptr;
    std::strtol(s.c_str(), &end, 10);
    return end && *end == 0;
}

// ── Log Table ───────────────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSSearchField *search = nil;
    NSTextField *count = nil;
    intptr_t buffer = 0;
    std::vector<adif::Record> recs;   // per model row
    std::vector<std::string> columns; // shown, after "#"
    std::vector<std::string> all;     // every field the log uses
    std::vector<size_t> starts;       // record start per model row
    std::vector<std::vector<std::string>> cells;  // the rows as shown (dates and times readable)
    std::vector<std::string> extra;   // columns added with Add Field, before any record has the field
    NSMenu *menu = nil;               // the headings' menu: show or hide columns, add or remove a field
    NSMenuItem *removeItem = nil;     // "Remove FIELD from Every Record" in it
    NSInteger menuColumn = -1;        // the column the headings' menu opened over
    NSStackView *addRow = nil;        // Add Field: the name to add
    NSComboBox *addName = nil;
    bool lotwShown = false;           // the LoTW column (each call's last LoTW upload) after the fields
} table;

// The LoTW column: asked for in the headings' menu, and only while Settings → LoTW Users is on.
bool tableLotwWanted() { return ADIFLotwUsersOn() && setting("tableLotw") == "1"; }

// Hidden columns and the sort, kept in ADIFLint.ini.
std::set<std::string> tableHidden() {
    std::set<std::string> out;
    std::string list = setting("tableHidden"), item;
    for (size_t i = 0; i <= list.size(); ++i) {
        if (i == list.size() || list[i] == ',') {
            if (!item.empty()) out.insert(item);
            item.clear();
        } else {
            item.push_back(list[i]);
        }
    }
    return out;
}

bool isDateField(const std::string &f) {
    const adif::FieldDef *d = adif::findField(f);
    return d && d->type == adif::DataType::Date;
}

bool isTimeField(const std::string &f) {
    const adif::FieldDef *d = adif::findField(f);
    return d && d->type == adif::DataType::Time;
}

void tableRefresh();
void tableEdit(NSInteger row, size_t column, NSString *text);
void tableShowAddField();
void tableRemoveField(NSInteger column);

bool tableVisible() { return table.w && table.w.window.visible; }

void tableUpdateCount() {
    if (!table.w) return;
    size_t shown = [table.w shownRows].size();
    table.count.stringValue = shown == table.recs.size()
                                  ? ADIFString(plural(table.recs.size(), "record"))
                                  : [NSString stringWithFormat:@"%zu of %@", shown, ADIFString(plural(table.recs.size(), "record"))];
}

void tableRefresh() {
    if (!table.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        [table.w setTarget:logLine()];
        table.buffer = buffer();
        table.recs = adif::records(text, r.model);
        table.all = adif::tableColumns(table.recs);
        for (const std::string &f : table.extra)  // added columns, still empty
            if (std::find(table.all.begin(), table.all.end(), f) == table.all.end()) table.all.push_back(f);
        std::set<std::string> hidden = tableHidden();
        std::vector<std::string> cols;
        for (const std::string &c : table.all)
            if (!hidden.count(c)) cols.push_back(c);
        bool lotw = tableLotwWanted();
        if (cols != table.columns || lotw != table.lotwShown || table.w.window.isVisible == NO) {
            table.columns = cols;
            table.lotwShown = lotw;
            std::vector<ADIFToolColumn> tc{{"#", "#", 44}};
            for (const std::string &c : cols) {
                CGFloat w = c == "QSO_DATE" ? 76 : c == "TIME_ON" || c == "TIME_OFF" ? 58 : c == "CALL" ? 84 : c == "BAND" ? 48
                          : c == "MODE" || c == "SUBMODE" ? 56 : c == "FREQ" ? 68 : c.rfind("RST_", 0) == 0 ? 52 : 96;
                tc.push_back({c, c, w});
            }
            if (lotw) tc.push_back({"lotw", "LoTW", 84});  // not a field: read only, left out of copy, export and Organize
            [table.w setColumns:tc checkboxes:NO sortable:YES];
            std::vector<size_t> editable;
            for (size_t i = 1; i <= cols.size(); ++i) editable.push_back(i);
            [table.w setEditableColumns:editable];
            // The remembered sort: "FIELD:a" or "FIELD:d".
            std::string sort = setting("tableSort");
            size_t colon = sort.find(':');
            if (colon != std::string::npos) {
                std::string field = sort.substr(0, colon);
                auto it = std::find(cols.begin(), cols.end(), field);
                NSInteger col = field == "#" ? 0 : it == cols.end() ? -1 : (NSInteger)(it - cols.begin()) + 1;
                if (col >= 0) [table.w setSortColumn:col ascending:sort.substr(colon + 1) != "d"];
            }
        }
        // The headings' menu lists every field; ticked ones are shown.
        [table.menu removeAllItems];
        for (const std::string &c : table.all) {
            NSMenuItem *item = [table.menu addItemWithTitle:ADIFString(c) action:nil keyEquivalent:@""];
            item.state = hidden.count(c) ? NSControlStateValueOff : NSControlStateValueOn;
            ADIFBlockMenuItem(item, ^{
                std::set<std::string> hid = tableHidden();
                if (hid.count(c)) hid.erase(c);
                else if (hid.size() + 1 < table.all.size()) hid.insert(c);  // keep at least one column
                std::string list;
                for (const std::string &x : hid) list += (list.empty() ? "" : ",") + x;
                setSetting("tableHidden", list);
                tableRefresh();
            });
        }
        if (ADIFLotwUsersOn()) {
            NSMenuItem *item = [table.menu addItemWithTitle:@"LoTW (last upload)" action:nil keyEquivalent:@""];
            item.state = table.lotwShown ? NSControlStateValueOn : NSControlStateValueOff;
            ADIFBlockMenuItem(item, ^{
                setSetting("tableLotw", tableLotwWanted() ? "0" : "1");
                tableRefresh();
            });
        }
        [table.menu addItem:NSMenuItem.separatorItem];
        ADIFBlockMenuItem([table.menu addItemWithTitle:@"Add Field..." action:nil keyEquivalent:@""], ^{ tableShowAddField(); });
        table.removeItem = [table.menu addItemWithTitle:@"Remove Field from Every Record" action:nil keyEquivalent:@""];
        ADIFBlockMenuItem(table.removeItem, ^{ tableRemoveField(table.menuColumn); });
        std::vector<std::vector<std::string>> rows;
        table.starts.clear();
        rows.reserve(table.recs.size());
        for (const adif::Record &rec : table.recs) {
            std::vector<std::string> row{std::to_string(rec.number)};
            for (const std::string &c : table.columns) {
                const std::string &v = rec.get(c);
                row.push_back(isDateField(c) ? adif::displayDate(v) : isTimeField(c) ? adif::displayTime(v) : v);
            }
            if (table.lotwShown) row.push_back(ADIFLotwLastUpload(rec.get("CALL")));
            rows.push_back(std::move(row));
            table.starts.push_back(adif::groupStart(r.model, r.model.groups[(size_t)rec.group]));
        }
        table.cells = rows;
        // Keys keep the selection on the same record when others are added, removed or reordered.
        [table.w setRows:rows severities:kNoSev keys:adif::recordKeys(table.recs) ticks:kNoTicks keepTicks:NO];
        if (!hasRecords(r))
            [table.w setStatus:@"No records. Open an ADIF log (.adi), or add one with New QSO." severity:-1];
        else if (r.structuralErrors)
            [table.w setStatus:@"The log has structural errors, so some records may be shown wrongly. Fix Lengths may help."
                      severity:1];
        else
            [table.w setStatus:@"Click a cell and type, or press Return, to edit it; Tab and Return move on. Command-C and "
                               @"Command-V copy and paste cells (to and from Numbers or Excel), Command-D fills down, Delete "
                               @"clears, Command-Delete deletes rows; right-click for more. Double-click # to go to the "
                               @"record. Click a heading to sort; right-click the headings to choose, add or remove columns."
                      severity:-1];
        tableUpdateCount();
    } catch (...) {
    }
}

// ── Log Table editing (spreadsheet) ──

// The log the table shows, ready for an edit; otherwise a message in the table and false.
bool tableEditable(NppHandle h, const adif::LintResult &r) {
    if (table.buffer != buffer() || readOnly(h)) {
        [table.w setStatus:@"Switch back to the log the table shows (and make sure it isn't read-only)." severity:2];
        return false;
    }
    if (r.structuralErrors) {
        [table.w setStatus:@"The log has structural problems (run Fix Lengths, then fix the errors marked in red); nothing "
                           @"was changed."
                  severity:2];
        return false;
    }
    return true;
}

// The selected rows (model rows) in the order shown.
std::vector<NSInteger> tableSelection() {
    std::vector<NSInteger> sel = [table.w selectedRows], out;
    for (NSInteger row : [table.w shownRows])
        if (std::find(sel.begin(), sel.end(), row) != sel.end()) out.push_back(row);
    return out;
}

// A field name as typed or pasted: trimmed, upper case.
std::string upperName(std::string_view s) {
    size_t b = s.find_first_not_of(" \t\r\n"), e = s.find_last_not_of(" \t\r\n");
    std::string out(b == std::string_view::npos ? std::string_view() : s.substr(b, e - b + 1));
    for (char &c : out) c = (char)std::toupper((unsigned char)c);
    return out;
}

// The field of a table column (0 is "#"), or "".
std::string tableField(NSInteger column) {
    return column >= 1 && (size_t)column <= table.columns.size() ? table.columns[(size_t)column - 1] : std::string();
}

// Apply cell changes, record removals and new records as one undo step. An
// uploaded QSO whose data changes becomes M. Then the table is redrawn at once.
bool tableChange(const std::vector<adif::CellChange> &changes, const std::vector<int> &removeGroups,
                 const std::vector<std::vector<std::pair<std::string, std::string>>> &newRecords) {
    NppHandle h = scintilla();
    adif::LintResult r = lint(h);  // a copy: the edit changes the document
    if (!tableEditable(h, r)) return false;
    std::string text(adifhost::text(h));
    std::vector<adif::TextEdit> edits = adif::cellEdits(text, r.model, changes, lengthUnit(), utf8(h));
    std::vector<int> changedData;
    for (const adif::CellChange &c : changes)
        if (!adif::isTrackingField(c.field)) changedData.push_back(c.group);
    edits = adif::mergeEdits(edits, adif::markModified(text, r.model, changedData, lengthUnit(), utf8(h)));
    for (const adif::TextEdit &e : adif::removeRecordsEdits(text, r.model, removeGroups)) edits.push_back(e);
    std::sort(edits.begin(), edits.end(), [](const adif::TextEdit &x, const adif::TextEdit &y) { return x.start < y.start; });
    std::string eolText = eol(h);
    if (!newRecords.empty()) {
        bool blank = text.find_first_not_of(" \t\r\n") == std::string::npos;
        adif::Layout layout = blank ? adif::Layout::RecordPerLine : adif::recordLayout(text, r.model);
        std::string records;
        for (const auto &fields : newRecords) {
            if (fields.empty()) continue;
            if (!records.empty() && layout == adif::Layout::FieldPerLine) records += eolText;
            records += adif::buildRecord(fields, layout, eolText, lengthUnit(), utf8(h)).text;
        }
        if (blank) {
            edits.assign(1, adif::TextEdit{0, text.size(),
                                           adif::newLogHeader(ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"), eolText) + records});
        } else if (!records.empty()) {
            size_t start = 0;
            edits.push_back(adif::appendRecord(text, r.model, records, eolText, &start));
        }
    }
    if (edits.empty()) return false;
    adifhost::apply(h, edits);
    tableRefresh();
    return true;
}

// A value edited in the Log Table: written with its length (an empty value removes the field), as
// one undo step; an uploaded QSO becomes M (modified since upload).
void tableEdit(NSInteger row, size_t column, NSString *text) {
    try {
        if (row < 0 || (size_t)row >= table.recs.size()) return;
        std::string field = tableField((NSInteger)column);
        if (field.empty()) return;
        std::string value = adif::cellValue(field, ADIFStd(text));  // shown as 2026-10-06 and 22:30
        int number = table.recs[(size_t)row].number;
        if (!tableChange({{table.recs[(size_t)row].group, field, value}}, {}, {})) return;
        [table.w setStatus:ADIFString("Record " + std::to_string(number) + ": " + field +
                                      (value.empty() ? " removed" : " set to " + value) + " (one undo step).")
                  severity:-1];
    } catch (...) {
    }
}

void tableCopy() {
    std::vector<NSInteger> rows = tableSelection();
    if (rows.empty()) {
        [table.w setStatus:@"Select the rows to copy." severity:1];
        return;
    }
    std::vector<size_t> cols;
    for (size_t c : [table.w columnOrder])
        if (c >= 1 && c <= table.columns.size()) cols.push_back(c);
    std::vector<std::vector<std::string>> out(1);
    for (size_t c : cols) out[0].push_back(table.columns[c - 1]);
    for (NSInteger row : rows) {
        std::vector<std::string> line;
        for (size_t c : cols) line.push_back((size_t)row < table.cells.size() && c < table.cells[(size_t)row].size() ? table.cells[(size_t)row][c] : "");
        out.push_back(line);
    }
    NSString *tsv = ADIFString(adif::toTsv(out));
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:tsv forType:NSPasteboardTypeString];
    [NSPasteboard.generalPasteboard setString:tsv forType:@"public.utf8-tab-separated-values-text"];
    [table.w setStatus:ADIFString("Copied " + plural(rows.size(), "row") + " of " + plural(cols.size(), "column") +
                                  ", with a heading row of field names: paste into Numbers or Excel, or back into this table.")
              severity:-1];
}

// Rows of cells from pasted text: tab-separated (quotes as a spreadsheet writes them), or one cell per line.
std::vector<std::vector<std::string>> pastedCells(const std::string &text) {
    std::vector<std::vector<std::string>> rows;
    if (text.find('\t') != std::string::npos) {
        rows = adif::parseCsv(text);
    } else {
        std::string line;
        for (size_t i = 0; i <= text.size(); ++i) {
            if (i == text.size() || text[i] == '\n') {
                if (!line.empty() && line.back() == '\r') line.pop_back();
                rows.push_back({line});
                line.clear();
            } else {
                line.push_back(text[i]);
            }
        }
    }
    while (!rows.empty()) {  // no trailing empty rows
        bool empty = true;
        for (const std::string &c : rows.back()) empty &= c.find_first_not_of(" \t") == std::string::npos;
        if (!empty) break;
        rows.pop_back();
    }
    return rows;
}

void tablePaste(NSString *pasted) {
    try {
        std::vector<std::vector<std::string>> rows = pastedCells(ADIFStd(pasted));
        if (rows.empty()) {
            [table.w setStatus:@"Nothing to paste." severity:1];
            return;
        }
        // A heading row of field names (as Copy writes it) places each column by name.
        bool header = rows.size() > 1;
        size_t named = 0;
        for (const std::string &c : rows[0]) {
            std::string f = upperName(c);
            if (f.empty()) continue;
            bool known = adif::findField(f) || std::find(table.all.begin(), table.all.end(), f) != table.all.end() ||
                         f.rfind("APP_", 0) == 0;
            header &= known;
            named += known;
        }
        header &= named > 0;
        std::vector<std::string> fields;
        if (header) {
            for (const std::string &c : rows[0]) fields.push_back(upperName(c));
            rows.erase(rows.begin());
        } else {  // else column by column from the active cell, as shown
            std::vector<size_t> order = [table.w columnOrder];
            auto it = std::find(order.begin(), order.end(), (size_t)std::max<NSInteger>(table.w.activeColumn, 1));
            for (; it != order.end(); ++it)
                if (*it >= 1 && *it <= table.columns.size()) fields.push_back(table.columns[*it - 1]);
        }
        if (fields.empty()) {
            [table.w setStatus:@"Click the cell to paste into first." severity:1];
            return;
        }
        // From the first selected row down; rows past the end of the log become new QSOs.
        std::vector<NSInteger> shown = [table.w shownRows], sel = tableSelection();
        size_t anchor = shown.size();
        if (!sel.empty()) anchor = (size_t)(std::find(shown.begin(), shown.end(), sel.front()) - shown.begin());
        std::vector<adif::CellChange> changes;
        std::vector<std::vector<std::pair<std::string, std::string>>> added;
        size_t updated = 0, ignored = 0;
        for (size_t i = 0; i < rows.size(); ++i) {
            const std::vector<std::string> &cells = rows[i];
            if (cells.size() > fields.size()) ignored = std::max(ignored, cells.size() - fields.size());
            size_t at = anchor + i;
            if (at < shown.size()) {
                int group = table.recs[(size_t)shown[at]].group;
                for (size_t j = 0; j < cells.size() && j < fields.size(); ++j)
                    if (!fields[j].empty()) changes.push_back({group, fields[j], adif::cellValue(fields[j], cells[j])});
                ++updated;
            } else {
                std::vector<std::pair<std::string, std::string>> rec;
                for (size_t j = 0; j < cells.size() && j < fields.size(); ++j) {
                    std::string v = fields[j].empty() ? "" : adif::cellValue(fields[j], cells[j]);
                    if (!v.empty()) rec.emplace_back(fields[j], v);
                }
                if (!rec.empty()) added.push_back(rec);
            }
        }
        if (!tableChange(changes, {}, added) && changes.empty() && added.empty()) return;
        std::string st = "Pasted " + plural(rows.size(), "row") + ": " + plural(updated, "record") + " changed" +
                         (added.empty() ? "" : ", " + plural(added.size(), "new record")) + " (one undo step)." +
                         (ignored ? " " + plural(ignored, "column") + " past the last one left out." : "");
        [table.w setStatus:ADIFString(st) severity:ignored ? 1 : -1];
    } catch (...) {
        [table.w setStatus:@"Something went wrong pasting." severity:2];
    }
}

void tableFillDown() {
    std::vector<NSInteger> rows = tableSelection();
    std::string field = tableField(table.w.activeColumn);
    if (rows.size() < 2 || field.empty()) {
        [table.w setStatus:@"Select two or more rows and click the column: the first row's value is copied down to the others."
                  severity:1];
        return;
    }
    const std::vector<std::string> &first = table.cells[(size_t)rows[0]];
    std::string value = adif::cellValue(field, (size_t)table.w.activeColumn < first.size() ? first[(size_t)table.w.activeColumn] : "");
    std::vector<adif::CellChange> changes;
    for (size_t i = 1; i < rows.size(); ++i) changes.push_back({table.recs[(size_t)rows[i]].group, field, value});
    if (tableChange(changes, {}, {}))
        [table.w setStatus:ADIFString("Filled " + field + (value.empty() ? " (empty)" : " = " + value) + " down " +
                                      plural(rows.size() - 1, "record") + " (one undo step).")
                  severity:-1];
}

void tableClearCells() {
    std::vector<NSInteger> rows = tableSelection();
    std::string field = tableField(table.w.activeColumn);
    if (rows.empty() || field.empty()) {
        [table.w setStatus:@"Click a cell to clear (or select rows and click a column)." severity:1];
        return;
    }
    std::vector<adif::CellChange> changes;
    for (NSInteger row : rows) changes.push_back({table.recs[(size_t)row].group, field, ""});
    if (tableChange(changes, {}, {}))
        [table.w setStatus:ADIFString("Removed " + field + " from " + plural(rows.size(), "record") + " (one undo step).")
                  severity:-1];
}

void tableDeleteRows() {
    std::vector<NSInteger> rows = tableSelection();
    if (rows.empty()) {
        [table.w setStatus:@"Select the rows to delete." severity:1];
        return;
    }
    std::vector<int> groups;
    for (NSInteger row : rows) groups.push_back(table.recs[(size_t)row].group);
    if (tableChange({}, groups, {}))
        [table.w setStatus:ADIFString("Deleted " + plural(rows.size(), "record") + " (one undo step: Command-Z brings them back).")
                  severity:-1];
}

// A new QSO at the end: today's UTC date and time and the station's fields from
// the last record (as New QSO carries them over); then its CALL cell is edited.
void tableAddRow() {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::vector<std::pair<std::string, std::string>> fields;
        for (const adif::QsoField &q : adif::newQsoTemplate(adifhost::text(h), r.model, utcNow("%Y%m%d"), utcNow("%H%M%S")))
            if (!q.value.empty()) fields.emplace_back(q.name, q.value);
        if (fields.empty()) return;
        if (!tableChange({}, {}, {fields})) return;
        NSInteger last = (NSInteger)table.recs.size() - 1;
        auto call = std::find(table.columns.begin(), table.columns.end(), "CALL");
        [table.w setStatus:@"Added a QSO at the end with today's UTC date and time and your station's fields: type its CALL."
                  severity:-1];
        if (last >= 0 && call != table.columns.end())
            [table.w beginEditingRow:last column:(size_t)(call - table.columns.begin()) + 1];
    } catch (...) {
    }
}

void tableShowAddField() {
    if (!table.addRow) return;
    NSMutableArray *names = [NSMutableArray array];
    try {
        NppHandle h = scintilla();
        for (const std::string &f : adif::fieldNameChoices(lint(h).model, false))
            if (std::find(table.columns.begin(), table.columns.end(), f) == table.columns.end()) [names addObject:ADIFString(f)];
    } catch (...) {
    }
    [table.addName removeAllItems];
    [table.addName addItemsWithObjectValues:names];
    table.addName.stringValue = @"";
    table.addRow.hidden = NO;
    [table.w.window makeFirstResponder:table.addName];
}

void tableAddField() {
    std::string f = upperName(ADIFStd(table.addName.stringValue));
    while (!f.empty() && f.back() == ' ') f.pop_back();
    const adif::FieldDef *d = adif::findField(f);
    if (f.empty() || (!(d && !d->header) && f.rfind("APP_", 0) != 0 &&
                      std::find(table.all.begin(), table.all.end(), f) == table.all.end())) {
        [table.w setStatus:ADIFString((f.empty() ? std::string("Type") : f + " is not a QSO field: choose") +
                                      " an ADIF field to add.")
                  severity:2];
        return;
    }
    if (std::find(table.extra.begin(), table.extra.end(), f) == table.extra.end()) table.extra.push_back(f);
    std::set<std::string> hid = tableHidden();
    if (hid.erase(f)) {
        std::string list;
        for (const std::string &x : hid) list += (list.empty() ? "" : ",") + x;
        setSetting("tableHidden", list);
    }
    table.addRow.hidden = YES;
    tableRefresh();
    auto it = std::find(table.columns.begin(), table.columns.end(), f);
    if (it != table.columns.end()) table.w.activeColumn = (NSInteger)(it - table.columns.begin()) + 1;
    [table.w.window makeFirstResponder:nil];
    [table.w setStatus:ADIFString("Added the column " + f + ": select a row and type its value (or paste a column of values).")
              severity:-1];
}

// Remove a column's field from every record (one undo step).
void tableRemoveField(NSInteger column) {
    std::string field = tableField(column >= 1 ? column : table.w.activeColumn);
    if (field.empty()) {
        [table.w setStatus:@"Right-click the heading of the column to remove." severity:1];
        return;
    }
    std::vector<adif::CellChange> changes;
    for (const adif::Record &rec : table.recs)
        if (rec.has(field)) changes.push_back({rec.group, field, ""});
    table.extra.erase(std::remove(table.extra.begin(), table.extra.end(), field), table.extra.end());
    if (changes.empty()) {
        tableRefresh();
        [table.w setStatus:ADIFString("No record has " + field + ".") severity:-1];
        return;
    }
    if (tableChange(changes, {}, {}))
        [table.w setStatus:ADIFString("Removed " + field + " from " + plural(changes.size(), "record") + " (one undo step).")
                  severity:-1];
}

// Groups (DocModel indices) of the rows selected in the Log Table, when it shows the active log.
bool tableSelection(std::vector<int> *groups) {
    if (!tableVisible() || table.buffer != buffer()) return false;
    for (NSInteger row : [table.w selectedRows])
        if ((size_t)row < table.recs.size()) groups->push_back(table.recs[(size_t)row].group);
    return !groups->empty();
}

void exportCsv(const std::vector<adif::Record> &recs, const std::vector<std::string> &columns, ADIFToolWindow *w) {
    try {
        NppHandle h = scintilla();
        std::string name = documentName();
        std::string dest = chooseSave(ADIFString(stem(path().empty() ? std::string("log") : name) + ".csv"), @[ @"csv" ]);
        if (dest.empty()) return;
        std::string error;
        if (!writeFile(dest, adif::toCsv(recs, columns), &error)) {
            if (w) [w setStatus:ADIFString("Could not save: " + error) severity:2];
            else showTip(h, "ADIF Lint: could not save the CSV file: " + error);
            return;
        }
        std::string done = "Saved " + plural(recs.size(), "record") + " to " + fileName(dest) + ".";
        if (w) [w setStatus:ADIFString(done) severity:-1];
        else showTip(h, "ADIF Lint: " + done);
    } catch (...) {
    }
}

void openBulkEdit(bool shift, bool fromTable);

// ── Summary ─────────────────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
} summary;

void summaryRefresh() {
    if (!summary.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        [summary.w setTarget:logLine()];
        [summary.w setText:ADIFString(adif::summaryReport(adifhost::text(h), r.model, documentName()))];
        [summary.w setStatus:r.errors ? ADIFString("The log has " + plural(r.errors, "error") +
                                                    "; records with problems may be counted wrongly.")
                                      : @""
                    severity:r.errors ? 1 : -1];
    } catch (...) {
    }
}

// ── Activation Tracker ──────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSPopUpButton *program = nil;
    std::vector<adif::Activation> acts;
    std::vector<size_t> starts;
} tracker;

adif::Program trackerProgram();

void trackerRefresh() {
    if (!tracker.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        [tracker.w setTarget:logLine()];
        adif::Program prog = trackerProgram();
        bool wwff = prog == adif::Program::WWFF, sota = prog == adif::Program::SOTA;
        tracker.acts = adif::programActivations(text, r.model, prog);
        tracker.starts.clear();
        std::string today = utcNow("%Y%m%d");
        std::vector<std::vector<std::string>> rows;
        std::vector<int> sev;
        auto join = [](const std::map<std::string, size_t> &m) {
            std::vector<std::pair<std::string, size_t>> v(m.begin(), m.end());
            std::string s;
            for (const auto &kv : v) s += (s.empty() ? "" : " ") + kv.first + ":" + std::to_string(kv.second);
            return s;
        };
        for (const adif::Activation &a : tracker.acts) {
            std::string need = a.activated() ? "done" : std::to_string(a.needed - a.qsos) + " more";
            std::string when = adif::displayDate(a.date) + (a.lastDate != a.date ? " to " + adif::displayDate(a.lastDate) : "");
            rows.push_back({a.park, when, a.station, std::to_string(a.qsos), need, std::to_string(a.p2p),
                            std::to_string(a.duplicates), std::to_string(a.invalid), join(a.bands), join(a.modes),
                            adif::displayTime(a.first), adif::displayTime(a.last)});
            sev.push_back(a.activated() ? 3 : (a.date == today || a.lastDate == today) ? 1 : -1);
            const adif::ModelGroup &g = r.model.groups[(size_t)a.groups.front()];
            tracker.starts.push_back(adif::groupStart(r.model, g));
        }
        [tracker.w setRows:rows severities:sev];
        // Headline: today's activations, else the latest one.
        std::string head;
        int headSev = -1;
        std::vector<const adif::Activation *> focus;
        for (const adif::Activation &a : tracker.acts)
            if (a.date == today || a.lastDate == today) focus.push_back(&a);
        bool isToday = !focus.empty();
        if (!isToday && !tracker.acts.empty()) focus.push_back(&tracker.acts.back());
        bool allDone = true;
        for (const adif::Activation *a : focus) {
            std::string when = wwff ? "(all days)" : isToday ? "today" : "on " + adif::displayDate(a->date);
            std::string more = std::to_string(a->needed - a->qsos);
            std::string line = a->park + " " + when + ": " + plural(a->qsos, sota ? "station" : "QSO") +
                               (a->activated() ? (sota ? ", points scored" : ", activated")
                                               : ", " + more + (sota ? " more for the summit's points" : " more to activate"));
            head += (head.empty() ? "" : "\n") + line;
            allDone &= a->activated();
        }
        headSev = allDone ? 3 : 1;
        if (tracker.acts.empty()) {
            const char *name = adif::programName(prog);
            [tracker.w setHeadline:[NSString stringWithFormat:@"No %s activations in this log", name] severity:-1];
            [tracker.w setStatus:wwff   ? @"The tracker counts records with MY_WWFF_REF, or MY_SIG WWFF and MY_SIG_INFO."
                                 : sota ? @"The tracker counts records with MY_SOTA_REF, or MY_SIG SOTA and MY_SIG_INFO."
                                        : @"The tracker counts records with MY_SIG POTA and MY_SIG_INFO (or MY_POTA_REF) set to "
                                          @"your park. New QSO carries them from one contact to the next."
                        severity:-1];
            return;
        }
        [tracker.w setHeadline:ADIFString(head) severity:headSev];
        [tracker.w setStatus:wwff ? @"WWFF: 44 QSOs per reference, gathered over any number of days; the same call counts "
                                    @"again on another band, mode or date (WWFF Global Rules 5.10, 4.6-4.7). Double-click a "
                                    @"row to go to its first record."
                             : sota ? @"SOTA: one QSO activates a summit; four different stations score its points (from "
                                      @"SOTA guides: check sota.org.uk). The QSOs column counts stations. Double-click a "
                                      @"row to go to its first record."
                                    : @"An activation is 10 QSOs from one park in one UTC day. Each CALL counts once per "
                                      @"band, mode and park-to-park park; repeats and records missing CALL, TIME_ON, BAND or "
                                      @"MODE don't count (POTA rules, 2026-10-04). Double-click a row to go to its first record."
                    severity:-1];
    } catch (...) {
    }
}

void openPotaExport(adif::Program p);
adif::Program trackerProgram() {
    NSInteger i = tracker.program ? tracker.program.indexOfSelectedItem : 0;
    return i == 1 ? adif::Program::WWFF : i == 2 ? adif::Program::SOTA : adif::Program::POTA;
}

// ── Worked Before: the logs-folder index ────────────────────────────────────

struct IndexedLog {
    std::string path, name;
    long long mtime = 0, size = 0;
    std::vector<adif::Contact> contacts;
};

struct {
    std::string folder;  // indexed folder
    std::string buildingFolder;
    std::vector<std::shared_ptr<const IndexedLog>> logs;
    std::unordered_map<std::string, std::vector<std::pair<size_t, size_t>>> byBase;  // base call -> (log, contact)
    size_t qsos = 0, skipped = 0;
    bool building = false, again = false;
    double builtAt = 0;
    std::string error;
    void (^listener)(void) = nil;
} idx;

std::string logsFolder() { return setting("logsFolder"); }

const size_t kMaxLogBytes = 64u << 20;
const size_t kMaxLogFiles = 5000;

void indexRebuild();

void indexFinished(std::string folder, std::vector<std::shared_ptr<const IndexedLog>> logs, size_t skipped, std::string error) {
    idx.building = false;
    if (folder == logsFolder()) {
        idx.folder = folder;
        idx.logs = std::move(logs);
        idx.skipped = skipped;
        idx.error = error;
        idx.byBase.clear();
        idx.qsos = 0;
        for (size_t i = 0; i < idx.logs.size(); ++i)
            for (size_t k = 0; k < idx.logs[i]->contacts.size(); ++k) {
                idx.byBase[idx.logs[i]->contacts[k].baseCall].emplace_back(i, k);
                ++idx.qsos;
            }
        idx.builtAt = [NSDate date].timeIntervalSince1970;
    }
    if (idx.again || folder != logsFolder()) {
        idx.again = false;
        indexRebuild();
        return;
    }
    if (idx.listener) idx.listener();
}

// Re-read changed .adi/.adif files under the folder on a background queue.
void indexRebuild() {
    std::string folder = logsFolder();
    if (folder.empty()) return;
    if (idx.building) {
        idx.again |= folder != idx.buildingFolder;
        return;
    }
    idx.building = true;
    idx.buildingFolder = folder;
    std::map<std::string, std::shared_ptr<const IndexedLog>> previous;
    if (idx.folder == folder)
        for (const auto &l : idx.logs) previous[l->path] = l;
    adif::LengthUnit unit = lengthUnit();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        std::vector<std::shared_ptr<const IndexedLog>> logs;
        size_t skipped = 0;
        std::string error;
        @autoreleasepool {
            NSURL *root = [NSURL fileURLWithPath:ADIFString(folder) isDirectory:YES];
            NSDirectoryEnumerator *en = [NSFileManager.defaultManager
                           enumeratorAtURL:root
                includingPropertiesForKeys:@[ NSURLIsRegularFileKey ]
                                   options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                              errorHandler:nil];
            if (!en) error = "cannot read the folder";
            for (NSURL *url in en) {
                NSString *ext = url.pathExtension.lowercaseString;
                if (![ext isEqualToString:@"adi"] && ![ext isEqualToString:@"adif"]) continue;
                if (logs.size() >= kMaxLogFiles) {
                    ++skipped;
                    continue;
                }
                std::string path = ADIFStd(url.path);
                struct stat st{};
                if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) continue;
                long long mtime = (long long)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec;
                auto it = previous.find(path);
                if (it != previous.end() && it->second->mtime == mtime && it->second->size == st.st_size) {
                    logs.push_back(it->second);
                    continue;
                }
                std::string data;
                if (!readFile(path, kMaxLogBytes, &data, nullptr)) {
                    ++skipped;
                    continue;
                }
                adif::LintOptions opt;
                opt.lengthUnit = unit;
                opt.buildModel = true;
                opt.maxDiagnostics = 0;
                adif::LintResult r = adif::lint(data, opt);
                auto log = std::make_shared<IndexedLog>();
                log->path = path;
                log->name = fileName(path);
                log->mtime = mtime;
                log->size = st.st_size;
                log->contacts = adif::contacts(data, r.model);
                logs.push_back(log);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            indexFinished(folder, logs, skipped, error);
        });
    });
}

// Index hits for a call (by base call), outside the active file.
std::vector<adif::WorkedHit> indexLookup(const std::string &call) {
    std::vector<adif::WorkedHit> hits;
    std::string base = adif::lookupCall(call);
    if (base.empty()) return hits;
    auto it = idx.byBase.find(base);
    if (it == idx.byBase.end()) return hits;
    std::string active = path();
    for (const auto &p : it->second) {
        const IndexedLog &log = *idx.logs[p.first];
        if (log.path == active) continue;
        hits.push_back({log.name, log.contacts[p.second]});
    }
    return hits;
}

std::string indexStatus() {
    std::string folder = logsFolder();
    if (folder.empty()) return "Choose the folder that holds your logs. Its .adi and .adif files (and those in its subfolders) are searched.";
    if (idx.building && idx.folder != folder) return "Reading the logs in " + ADIFStd(tilde(folder)) + "...";
    if (!idx.error.empty()) return "Could not read " + ADIFStd(tilde(folder)) + ": " + idx.error + ".";
    std::string s = "Searched " + plural(idx.qsos, "QSO") + " in " + plural(idx.logs.size(), "log") + " under " +
                    ADIFStd(tilde(folder)) + ".";
    if (idx.skipped) s += " Skipped " + plural(idx.skipped, "file") + " (unreadable, over 64 MB, or past 5000 files).";
    if (idx.building) s += " Updating...";
    return s;
}

struct {
    ADIFToolWindow *w = nil;
    NSTextField *folder = nil;
    NSSearchField *call = nil;
    std::vector<adif::WorkedHit> hits;
} worked;

void workedRefresh() {
    if (!worked.w) return;
    worked.folder.stringValue = logsFolder().empty() ? @"(none)" : tilde(logsFolder());
    std::string call = ADIFStd(worked.call.stringValue);
    while (!call.empty() && call.back() == ' ') call.pop_back();
    worked.hits = call.empty() ? std::vector<adif::WorkedHit>() : indexLookup(call);
    std::sort(worked.hits.begin(), worked.hits.end(), [](const adif::WorkedHit &a, const adif::WorkedHit &b) {
        return a.contact.date + a.contact.time > b.contact.date + b.contact.time;
    });
    std::vector<std::vector<std::string>> rows;
    for (const adif::WorkedHit &hit : worked.hits)
        rows.push_back({hit.log, adif::displayDate(hit.contact.date), adif::displayTime(hit.contact.time), hit.contact.call,
                        hit.contact.band, hit.contact.mode, hit.contact.myPark, hit.contact.theirPark});
    [worked.w setRows:rows severities:kNoSev];
    std::string status = indexStatus();
    if (!call.empty() && !idx.building)
        status = (worked.hits.empty() ? adif::lookupCall(call) + ": not in the other logs."
                                      : adif::workedSummary(adif::lookupCall(call), worked.hits)) +
                 "\n" + status;
    [worked.w setStatus:ADIFString(status) severity:-1];
}

// ── Bulk Edit and Time Shift ────────────────────────────────────────────────

enum { kActSet, kActReplace, kActCase, kActRemove, kActRename, kActShift, kActDistance };
enum { kScopeAll, kScopeSelection, kScopeTable };
// "Only where" operators, in the popup's order.
const adif::RecordFilter::Kind kFilterKinds[] = {
    adif::RecordFilter::Equals,  adif::RecordFilter::Contains, adif::RecordFilter::StartsWith, adif::RecordFilter::EndsWith,
    adif::RecordFilter::OneOf,   adif::RecordFilter::Pattern,  adif::RecordFilter::Regex,      adif::RecordFilter::Less,
    adif::RecordFilter::Greater, adif::RecordFilter::Between,  adif::RecordFilter::Missing,    adif::RecordFilter::Present};
const size_t kFilterKindCount = sizeof(kFilterKinds) / sizeof(kFilterKinds[0]);
enum { kShiftToUtc, kShiftFromUtc, kShiftFixed };

struct {
    ADIFToolWindow *w = nil;
    NSPopUpButton *action = nil, *scope = nil, *filterKind = nil, *shiftMode = nil, *textCase = nil;
    NSComboBox *field = nil, *newName = nil, *filterField = nil, *zone = nil;
    NSTextField *zoneInfo = nil;
    NSStackView *rowShiftMode = nil, *rowZone = nil;
    NSTextField *value = nil, *find = nil, *replace = nil, *days = nil, *hours = nil, *minutes = nil, *filterValue = nil;
    NSButton *onlyMissing = nil, *useFilter = nil, *filterNot = nil, *apply = nil, *preview = nil;
    NSStackView *rowField = nil, *rowSet = nil, *rowReplace = nil, *rowRename = nil, *rowShift = nil, *rowCase = nil;
    size_t previewCount = 0;
    intptr_t buffer = 0;
} bulk;

void bulkClear(NSString *why) {
    if (!bulk.w) return;
    bool had = bulk.previewCount > 0;
    bulk.previewCount = 0;
    [bulk.w setRows:kNoRows severities:kNoSev];
    bulk.apply.enabled = NO;
    bulk.apply.title = @"Apply Changes";
    [bulk.w setDefaultButton:bulk.preview];
    if (why && had) [bulk.w setStatus:why severity:-1];
}

// A zone by IANA name ("America/Chicago"), else by abbreviation ("CST"); nil if unknown.
NSTimeZone *zoneNamed(NSString *text) {
    NSString *n = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!n.length) return nil;
    return [NSTimeZone timeZoneWithName:n] ?: [NSTimeZone timeZoneWithAbbreviation:n.uppercaseString];
}

// "UTC-5:00 now (CDT)" for the zone typed, or a hint.
void bulkZoneInfo() {
    NSTimeZone *z = zoneNamed(bulk.zone.stringValue);
    if (!z) {
        bulk.zoneInfo.stringValue = @"Unknown zone: type a name like America/Chicago";
        bulk.zoneInfo.textColor = NSColor.systemRedColor;
        return;
    }
    NSInteger off = z.secondsFromGMT;
    NSString *abbr = [z abbreviation] ?: @"";
    bulk.zoneInfo.stringValue = [NSString stringWithFormat:@"UTC%c%ld:%02ld now%@; each QSO uses the offset on its own date",
                                                           off < 0 ? '-' : '+', (long)labs(off) / 3600, (long)labs(off) % 3600 / 60,
                                                           abbr.length ? [NSString stringWithFormat:@" (%@)", abbr] : @""];
    bulk.zoneInfo.textColor = NSColor.secondaryLabelColor;
}

void bulkLayout() {
    NSInteger a = bulk.action.indexOfSelectedItem;
    bool fixed = bulk.shiftMode.indexOfSelectedItem == kShiftFixed;
    bulk.rowField.hidden = a == kActShift || a == kActDistance;
    bulk.rowSet.hidden = a != kActSet;
    bulk.rowReplace.hidden = a != kActReplace;
    bulk.rowCase.hidden = a != kActCase;
    bulk.rowRename.hidden = a != kActRename;
    bulk.rowShiftMode.hidden = a != kActShift;
    bulk.rowZone.hidden = a != kActShift || fixed;
    bulk.rowShift.hidden = a != kActShift || !fixed;
    bulkZoneInfo();
    bool filtering = bulk.useFilter.state == NSControlStateValueOn;
    adif::RecordFilter::Kind kind = kFilterKinds[std::clamp<NSInteger>(bulk.filterKind.indexOfSelectedItem, 0, kFilterKindCount - 1)];
    bulk.filterValue.enabled = filtering && kind != adif::RecordFilter::Missing && kind != adif::RecordFilter::Present;
    bulk.filterField.enabled = bulk.filterKind.enabled = bulk.filterNot.enabled = filtering;
    switch (kind) {
        case adif::RecordFilter::OneOf: bulk.filterValue.placeholderString = @"A, B, C"; break;
        case adif::RecordFilter::Pattern: bulk.filterValue.placeholderString = @"e.g. K*/P (* any, ? one)"; break;
        case adif::RecordFilter::Regex: bulk.filterValue.placeholderString = @"e.g. ^73\\b"; break;
        case adif::RecordFilter::Between: bulk.filterValue.placeholderString = @"low, high"; break;
        case adif::RecordFilter::Less:
        case adif::RecordFilter::Greater: bulk.filterValue.placeholderString = @"number, date or text"; break;
        case adif::RecordFilter::Missing:
        case adif::RecordFilter::Present: bulk.filterValue.placeholderString = @""; break;
        default: bulk.filterValue.placeholderString = @"value"; break;
    }
    bulk.w.window.title = a == kActShift ? @"Time Shift" : @"Bulk Edit";
}

// The plan for the window's settings against the document now.
bool bulkPlan(NppHandle h, const adif::LintResult &r, adif::ChangePlan *plan, std::string *error) {
    std::string_view text = adifhost::text(h);
    if (!hasRecords(r)) {
        *error = "This document has no ADIF records.";
        return false;
    }
    if (r.structuralErrors) {
        *error = "The log has structural problems. Run Fix Lengths and fix the errors marked in red first.";
        return false;
    }
    std::vector<int> groups;
    switch (bulk.scope.indexOfSelectedItem) {
        case kScopeSelection: groups = selectionRecords(h, r.model); break;
        case kScopeTable:
            if (!tableSelection(&groups)) {
                *error = "Select records in the Log Table first (it must show this log).";
                return false;
            }
            break;
        default: groups = allRecords(r.model); break;
    }
    if (bulk.useFilter.state == NSControlStateValueOn) {
        adif::RecordFilter f;
        f.kind = kFilterKinds[std::clamp<NSInteger>(bulk.filterKind.indexOfSelectedItem, 0, kFilterKindCount - 1)];
        f.field = ADIFStd(bulk.filterField.stringValue);
        f.value = ADIFStd(bulk.filterValue.stringValue);
        f.invert = bulk.filterNot.state == NSControlStateValueOn;
        if (f.field.empty()) {
            *error = "Choose the field for \"Only where\".";
            return false;
        }
        if (std::string why = adif::filterProblem(f); !why.empty()) {
            *error = why;
            return false;
        }
        std::vector<adif::Record> recs = adif::records(text, r.model);
        std::map<int, const adif::Record *> byGroup;
        for (const adif::Record &rec : recs) byGroup[rec.group] = &rec;
        std::vector<int> kept;
        for (int gi : groups)
            if (byGroup.count(gi) && adif::matchesFilter(*byGroup[gi], f)) kept.push_back(gi);
        groups = kept;
    }
    if (groups.empty()) {
        *error = "No records match.";
        return false;
    }
    if (bulk.action.indexOfSelectedItem == kActDistance) {
        *plan = adif::planDistance(text, r.model, groups);
    } else if (bulk.action.indexOfSelectedItem == kActShift && bulk.shiftMode.indexOfSelectedItem == kShiftFixed) {
        if (!isInteger(bulk.days) || !isInteger(bulk.hours) || !isInteger(bulk.minutes)) {
            *error = "Days, hours and minutes must be whole numbers (negative moves earlier).";
            return false;
        }
        long long minutes = parseLong(bulk.days) * 1440LL + parseLong(bulk.hours) * 60LL + parseLong(bulk.minutes);
        *plan = adif::planTimeShift(text, r.model, groups, minutes);
    } else if (bulk.action.indexOfSelectedItem == kActShift) {
        // Between UTC and a time zone, with that zone's offset (daylight saving included) on each QSO's date.
        NSTimeZone *tz = zoneNamed(bulk.zone.stringValue);
        if (!tz) {
            *error = "Unknown time zone. Type a name such as America/Chicago or Europe/London.";
            return false;
        }
        setSetting("timeShiftZone", ADIFStd(tz.name));
        std::string zname = ADIFStd(tz.name);
        auto offsetAt = [tz](long long utc) -> long long {
            return [tz secondsFromGMTForDate:[NSDate dateWithTimeIntervalSince1970:(double)utc]];
        };
        auto when = [](long long t) {
            long long days = t >= 0 ? t / 86400 : (t - 86399) / 86400;
            return adif::displayDate(adif::formatAdifDate((long)days)) + " " +
                   adif::displayTime(adif::formatAdifTime((int)(t - days * 86400), false));
        };
        adif::ShiftFor shiftFor;
        if (bulk.shiftMode.indexOfSelectedItem == kShiftToUtc) {
            shiftFor = [=](long long start, long long *sec, std::string *why) {
                long long utc = 0;
                adif::LocalTime k = adif::localToUtc(start, offsetAt, &utc);
                if (k == adif::LocalTime::Unique) {
                    *sec = utc - start;
                    return true;
                }
                *why = when(start) + (k == adif::LocalTime::Skipped
                                          ? " didn't happen in " + zname + " (the clocks went forward)"
                                          : " happened twice in " + zname + " (the clocks went back); shift it by a fixed amount");
                return false;
            };
        } else {
            shiftFor = [=](long long start, long long *sec, std::string *) {
                *sec = offsetAt(start);
                return true;
            };
        }
        *plan = adif::planTimeShiftWith(text, r.model, groups, shiftFor);
    } else {
        adif::BulkEdit op;
        switch (bulk.action.indexOfSelectedItem) {
            case kActReplace: op.action = adif::BulkAction::Replace; break;
            case kActCase: op.action = adif::BulkAction::Case; break;
            case kActRemove: op.action = adif::BulkAction::Remove; break;
            case kActRename: op.action = adif::BulkAction::Rename; break;
            default: op.action = adif::BulkAction::Set; break;
        }
        static const adif::TextCase cases[] = {adif::TextCase::Upper, adif::TextCase::Lower, adif::TextCase::Title};
        op.textCase = cases[std::clamp<NSInteger>(bulk.textCase.indexOfSelectedItem, 0, 2)];
        op.field = ADIFStd(bulk.field.stringValue);
        if (op.action == adif::BulkAction::Replace) {
            op.find = ADIFStd(bulk.find.stringValue);
            op.value = ADIFStd(bulk.replace.stringValue);
        } else {
            op.value = ADIFStd(bulk.value.stringValue);
        }
        op.newName = ADIFStd(bulk.newName.stringValue);
        op.onlyMissing = bulk.onlyMissing.state == NSControlStateValueOn;
        *plan = adif::planBulkEdit(text, r.model, groups, op);
    }
    if (plan->changes.empty()) {
        *error = plan->skipReason.empty() || plan->skipped == 0
                     ? (plan->skipReason.empty() ? "Nothing to change in " + plural(groups.size(), "record") + "."
                                                 : plan->skipReason)
                     : "Nothing to change: " + plural(plan->skipped, "record") + " skipped because " + plan->skipReason + ".";
        return false;
    }
    return true;
}

void bulkPreview() {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        adif::ChangePlan plan;
        std::string error;
        bulkClear(nil);
        bulk.buffer = buffer();
        [bulk.w setTarget:logLine()];
        if (!bulkPlan(h, r, &plan, &error)) {
            [bulk.w setStatus:ADIFString(error) severity:2];
            return;
        }
        std::vector<std::vector<std::string>> rows;
        for (const adif::PlannedChange &c : plan.changes) {
            std::string now, next, field = c.field;
            switch (c.kind) {
                case adif::PlannedChange::Add: now = "(none)", next = c.after; break;
                case adif::PlannedChange::Change: now = c.before, next = c.after; break;
                case adif::PlannedChange::Remove: now = c.before, next = "(removed)"; break;
                case adif::PlannedChange::Rename: field = c.before, now = c.before, next = c.after; break;
            }
            rows.push_back({std::to_string(c.record), c.call, field, now, next});
        }
        [bulk.w setRows:rows severities:kNoSev];
        bulk.previewCount = plan.changes.size();
        // What the validator would say afterwards.
        std::string_view text = adifhost::text(h);
        std::string after = adif::applyTextEdits(text, adif::planEdits(text, r.model, plan.changes, lengthUnit(), utf8(h)));
        adif::LintOptions opt;
        opt.lengthUnit = lengthUnit();
        opt.utf8 = utf8(h);
        adif::LintResult ra = adif::lint(after, opt);
        std::string status = plural(plan.changes.size(), "change") + " in " + plural(plan.records, "record") + ".";
        if (plan.skipped) status += " " + plural(plan.skipped, "record") + " skipped: " + plan.skipReason + ".";
        int sev = -1;
        if (ra.errors > r.errors || ra.warnings > r.warnings) {
            status += " Afterwards the log would have " + plural(ra.errors, "error") + " and " + plural(ra.warnings, "warning") +
                      " (now " + std::to_string(r.errors) + " and " + std::to_string(r.warnings) + "): check the values.";
            sev = 1;
        } else {
            status += " No new problems. Untick any you don't want, then Apply.";
        }
        [bulk.w setStatus:ADIFString(status) severity:sev];
        bulk.apply.enabled = YES;
        bulk.apply.title = [NSString stringWithFormat:@"Apply %zu Change%@", plan.changes.size(), plan.changes.size() == 1 ? @"" : @"s"];
        [bulk.w setDefaultButton:bulk.apply];
    } catch (...) {
        [bulk.w setStatus:@"Something went wrong preparing the changes." severity:2];
    }
}

void bulkApply() {
    try {
        if (!bulk.previewCount) return;
        NppHandle h = scintilla();
        if (bulk.buffer != buffer()) {
            [bulk.w setStatus:@"Switch back to the log you previewed, then Apply." severity:2];
            return;
        }
        if (readOnly(h)) {
            [bulk.w setStatus:@"This document is read-only." severity:2];
            return;
        }
        adif::LintResult r = lint(h);  // a copy: the edit below changes the document
        adif::ChangePlan plan;
        std::string error;
        if (!bulkPlan(h, r, &plan, &error) || plan.changes.size() != bulk.previewCount) {
            bulkClear(nil);
            [bulk.w setStatus:@"The log changed since the preview. Preview again." severity:1];
            return;
        }
        std::vector<bool> ticked = [bulk.w ticked];
        std::vector<adif::PlannedChange> chosen;
        std::set<int> records;
        for (size_t i = 0; i < plan.changes.size(); ++i)
            if (i < ticked.size() && ticked[i]) {
                chosen.push_back(plan.changes[i]);
                records.insert(plan.changes[i].group);
            }
        if (chosen.empty()) {
            [bulk.w setStatus:@"Nothing is ticked." severity:1];
            return;
        }
        std::string_view text = adifhost::text(h);
        std::vector<adif::TextEdit> edits = adif::planEdits(text, r.model, chosen, lengthUnit(), utf8(h));
        // A changed QSO that was already uploaded must be sent again: its status Y becomes M.
        std::vector<int> changedData;
        for (const adif::PlannedChange &c : chosen) {
            bool data = c.kind == adif::PlannedChange::Rename ? !adif::isTrackingField(c.before) || !adif::isTrackingField(c.after)
                                                              : !adif::isTrackingField(c.field);
            if (data) changedData.push_back(c.group);
        }
        edits = adif::mergeEdits(edits, adif::markModified(text, r.model, changedData, lengthUnit(), utf8(h)));
        bulkClear(nil);
        adifhost::apply(h, edits);
        [bulk.w setStatus:ADIFString("Applied " + plural(chosen.size(), "change") + " to " + plural(records.size(), "record") +
                                     " (one undo step).")
                 severity:-1];
    } catch (...) {
        [bulk.w setStatus:@"Something went wrong applying the changes." severity:2];
    }
}

void openBulkEdit(bool shift, bool fromTable) {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        if (!bulk.w) {
            ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Bulk Edit" size:NSMakeSize(760, 620) headline:NO];
            bulk.w = w;
            bulk.action = ADIFPopup(@[ @"Set a field", @"Replace text in a field", @"Change case", @"Remove a field",
                                       @"Rename a field", @"Shift date and time", @"Fill DISTANCE from grid squares" ]);
            [w addOptionRow:@[ ADIFLabel(@"Action:"), bulk.action ]];
            bulk.field = ADIFComboBox(@[], 240);
            bulk.field.placeholderString = @"e.g. MY_GRIDSQUARE, or NAME, QTH";
            bulk.field.toolTip = @"One field, or several separated by commas (not for Rename).";
            bulk.rowField = [w addOptionRow:@[ ADIFLabel(@"Field:"), bulk.field ]];
            bulk.value = ADIFTextField(@"new value", 220);
            bulk.onlyMissing = ADIFCheckbox(@"Only where it is missing or empty", NO);
            bulk.rowSet = [w addOptionRow:@[ ADIFLabel(@"Value:"), bulk.value, bulk.onlyMissing ]];
            bulk.find = ADIFTextField(@"text to find", 160);
            bulk.replace = ADIFTextField(@"replacement", 160);
            bulk.rowReplace = [w addOptionRow:@[ ADIFLabel(@"Find:"), bulk.find, ADIFLabel(@"Replace with:"), bulk.replace,
                                                  ADIFLabel(@"(any case)") ]];
            bulk.textCase = ADIFPopup(@[ @"UPPER CASE", @"lower case", @"Title Case (names and places)" ]);
            bulk.textCase.toolTip = @"Title Case writes O'Brien, McDonald and Smith-Jones, keeps II, III and IV, and leaves words "
                                    @"with digits (3RD, W1AW) alone.";
            bulk.rowCase = [w addOptionRow:@[ ADIFLabel(@"Case:"), bulk.textCase ]];
            bulk.newName = ADIFComboBox(@[], 200);
            bulk.rowRename = [w addOptionRow:@[ ADIFLabel(@"New name:"), bulk.newName ]];
            bulk.shiftMode = ADIFPopup(@[ @"From local time to UTC", @"From UTC to local time", @"By a fixed amount" ]);
            bulk.shiftMode.toolTip = @"ADIF times are UTC. Use local time to UTC for a log written in local time; UTC to local "
                                     @"time undoes that.";
            bulk.rowShiftMode = [w addOptionRow:@[ ADIFLabel(@"Convert:"), bulk.shiftMode ]];
            NSMutableArray *zones = [NSTimeZone.knownTimeZoneNames mutableCopy];
            [zones sortUsingSelector:@selector(compare:)];
            bulk.zone = ADIFComboBox(zones, 200);
            bulk.zone.placeholderString = @"e.g. America/Chicago";
            bulk.zoneInfo = ADIFLabel(@"");
            bulk.zoneInfo.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            bulk.zoneInfo.lineBreakMode = NSLineBreakByTruncatingTail;
            [bulk.zoneInfo setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
            bulk.rowZone = [w addOptionRow:@[ ADIFLabel(@"Time zone:"), bulk.zone, bulk.zoneInfo ]];
            bulk.days = ADIFTextField(@"0", 50);
            bulk.hours = ADIFTextField(@"0", 50);
            bulk.minutes = ADIFTextField(@"0", 50);
            bulk.rowShift = [w addOptionRow:@[ ADIFLabel(@"Shift by:"), bulk.days, ADIFLabel(@"days"), bulk.hours,
                                                ADIFLabel(@"hours"), bulk.minutes, ADIFLabel(@"minutes (negative: earlier)") ]];
            bulk.rowShift.toolTip = @"Moves QSO_DATE and TIME_ON, and QSO_DATE_OFF and TIME_OFF, across midnight as needed. "
                                    @"Times keep their HHMM or HHMMSS form.";
            bulk.scope = ADIFPopup(@[ @"All records", @"Records in the editor selection", @"Records selected in the Log Table" ]);
            [w addOptionRow:@[ ADIFLabel(@"Records:"), bulk.scope ]];
            bulk.useFilter = ADIFCheckbox(@"Only where", NO);
            bulk.filterField = ADIFComboBox(@[], 140);
            bulk.filterField.placeholderString = @"field";
            bulk.filterNot = ADIFCheckbox(@"not", NO);
            bulk.filterNot.toolTip = @"The records that don't match: not is, not contains, not between...";
            bulk.filterKind = ADIFPopup(@[ @"is", @"contains", @"starts with", @"ends with", @"is one of", @"matches pattern",
                                           @"matches regular expression", @"is less than", @"is greater than", @"is between",
                                           @"is missing", @"is present" ]);
            bulk.filterKind.toolTip = @"Text ignores case. Less, greater and between compare numbers and dates by value. "
                                      @"A pattern matches the whole value (* any run, ? one character); a regular expression "
                                      @"is found anywhere (use ^ and $ to anchor it).";
            bulk.filterValue = ADIFTextField(@"value", 150);
            [w addOptionRow:@[ bulk.useFilter, bulk.filterField, bulk.filterNot, bulk.filterKind, bulk.filterValue ]];
            [w setColumns:std::vector<ADIFToolColumn>{{"record", "Record", 56}, {"call", "Call", 90}, {"field", "Field", 130}, {"now", "Now", 150},
                           {"new", "New", 200}}
                checkboxes:YES
                  sortable:NO];
            bulk.preview = [w addButton:@"Preview" trailing:NO action:^{ bulkPreview(); }];
            [w addButton:@"Tick All" trailing:NO action:^{ [bulk.w setAllTicked:YES]; }];
            [w addButton:@"Untick All" trailing:NO action:^{ [bulk.w setAllTicked:NO]; }];
            bulk.apply = [w addButton:@"Apply Changes" trailing:YES action:^{ bulkApply(); }];
            for (NSControl *c in @[ bulk.action, bulk.scope, bulk.filterKind, bulk.onlyMissing, bulk.useFilter, bulk.shiftMode, bulk.zone,
                                    bulk.textCase, bulk.filterNot ])
                ADIFOnAction(c, ^{
                    bulkLayout();
                    bulkClear(@"Settings changed. Preview again.");
                });
            [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification *n) {
                                                              NSView *v = n.object;
                                                              if ([v isKindOfClass:NSView.class] && v.window == bulk.w.window) {
                                                                  if (v == bulk.zone) dispatch_async(dispatch_get_main_queue(), ^{ bulkZoneInfo(); });
                                                                  bulkClear(@"Settings changed. Preview again.");
                                                              }
                                                          }];
            [[NSNotificationCenter defaultCenter] addObserverForName:NSComboBoxSelectionDidChangeNotification
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification *n) {
                                                              NSView *v = n.object;
                                                              if ([v isKindOfClass:NSView.class] && v.window == bulk.w.window) {
                                                                  if (v == bulk.zone) dispatch_async(dispatch_get_main_queue(), ^{ bulkZoneInfo(); });
                                                                  bulkClear(@"Settings changed. Preview again.");
                                                              }
                                                          }];
        }
        NSArray<NSString *> *names = nsList(fieldChoices(adifhost::text(h), r.model));
        for (NSComboBox *c in @[ bulk.field, bulk.newName, bulk.filterField ]) {
            [c removeAllItems];
            [c addItemsWithObjectValues:names];
        }
        if (!bulk.zone.stringValue.length) {
            std::string saved = setting("timeShiftZone");
            bulk.zone.stringValue = saved.empty() ? NSTimeZone.localTimeZone.name : ADIFString(saved);
        }
        if (shift) [bulk.action selectItemAtIndex:kActShift];
        else if (bulk.action.indexOfSelectedItem == kActShift) [bulk.action selectItemAtIndex:kActSet];
        if (fromTable) [bulk.scope selectItemAtIndex:kScopeTable];
        bulkLayout();
        bulkClear(nil);
        bulk.buffer = buffer();
        [bulk.w setTarget:logLine()];
        [bulk.w setStatus:shift ? @"ADIF dates and times are UTC. Convert a log written in local time to UTC (or back), "
                                  @"with daylight saving taken from each QSO's date, or move times by a fixed amount. "
                                  @"Preview shows each change before anything is written."
                                : @"Preview shows each change before anything is written. Apply is one undo step."
                 severity:-1];
        [bulk.w show];
    } catch (...) {
    }
}

// ── Remove Duplicates ───────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSTextField *window = nil;
    NSButton *fill = nil, *remove = nil, *find = nil;
    size_t found = 0;
    intptr_t buffer = 0;
} dupes;

adif::DupeOptions dupeOptions(NSTextField *f) {
    adif::DupeOptions o;
    long v = parseLong(f);
    o.windowMinutes = (int)std::clamp<long>(v, 0, 1440);
    return o;
}

void dupesClear(NSString *why) {
    if (!dupes.w) return;
    bool had = dupes.found > 0;
    dupes.found = 0;
    [dupes.w setRows:kNoRows severities:kNoSev];
    dupes.remove.enabled = NO;
    dupes.remove.title = @"Remove Duplicates";
    [dupes.w setDefaultButton:dupes.find];
    if (why && had) [dupes.w setStatus:why severity:-1];
}

void dupesFind() {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string_view text = adifhost::text(h);
        dupesClear(nil);
        dupes.buffer = buffer();
        [dupes.w setTarget:logLine()];
        std::string problem = structureProblem(r);
        if (!hasRecords(r) || !problem.empty()) {
            [dupes.w setStatus:ADIFString(hasRecords(r) ? problem : "This document has no ADIF records.") severity:2];
            return;
        }
        std::vector<adif::DupeSet> sets = adif::findDuplicates(text, r.model, dupeOptions(dupes.window));
        std::vector<adif::Record> recs = adif::records(text, r.model);
        std::map<int, const adif::Record *> byGroup;
        for (const adif::Record &rec : recs) byGroup[rec.group] = &rec;
        std::vector<std::vector<std::string>> rows;
        size_t records = 0;
        for (const adif::DupeSet &d : sets) {
            const adif::Record &k = *byGroup[d.keep];
            std::string removed, adds;
            for (int gi : d.remove) removed += (removed.empty() ? "" : ", ") + std::to_string(byGroup[gi]->number);
            for (const auto &f : d.fill) adds += (adds.empty() ? "" : ", ") + f.first;
            rows.push_back({std::to_string(k.number), removed, k.get("CALL"), adif::displayDate(k.get("QSO_DATE")),
                            adif::displayTime(k.get("TIME_ON")), adif::effectiveBand(k), adif::effectiveMode(k), adds});
            records += d.remove.size();
        }
        [dupes.w setRows:rows severities:kNoSev];
        dupes.found = sets.size();
        if (sets.empty()) {
            [dupes.w setStatus:@"No duplicates found. Lines repeated for each park of a park-to-park contact (different "
                               @"SIG_INFO), or with a different STATION_CALLSIGN or MY_SIG_INFO, are not duplicates."
                      severity:-1];
            return;
        }
        dupes.remove.enabled = YES;
        dupes.remove.title = [NSString stringWithFormat:@"Remove %zu Record%@", records, records == 1 ? @"" : @"s"];
        [dupes.w setDefaultButton:dupes.remove];
        [dupes.w setStatus:ADIFString(plural(sets.size(), "QSO") + " logged more than once: " + plural(records, "record") +
                                      " to remove. Each keeps the record with the most fields. Untick any to leave alone.")
                  severity:1];
    } catch (...) {
        [dupes.w setStatus:@"Something went wrong looking for duplicates." severity:2];
    }
}

void dupesRemove() {
    try {
        if (!dupes.found) return;
        NppHandle h = scintilla();
        if (dupes.buffer != buffer()) {
            [dupes.w setStatus:@"Switch back to the log you checked, then try again." severity:2];
            return;
        }
        if (readOnly(h)) {
            [dupes.w setStatus:@"This document is read-only." severity:2];
            return;
        }
        adif::LintResult r = lint(h);
        std::string_view text = adifhost::text(h);
        std::vector<adif::DupeSet> sets = adif::findDuplicates(text, r.model, dupeOptions(dupes.window));
        if (sets.size() != dupes.found || !structureProblem(r).empty()) {
            dupesClear(nil);
            [dupes.w setStatus:@"The log changed. Find Duplicates again." severity:1];
            return;
        }
        std::vector<bool> ticked = [dupes.w ticked];
        std::vector<adif::DupeSet> chosen;
        size_t removed = 0;
        for (size_t i = 0; i < sets.size(); ++i)
            if (i < ticked.size() && ticked[i]) {
                chosen.push_back(sets[i]);
                removed += sets[i].remove.size();
            }
        if (chosen.empty()) {
            [dupes.w setStatus:@"Nothing is ticked." severity:1];
            return;
        }
        bool fill = dupes.fill.state == NSControlStateValueOn;
        std::vector<adif::TextEdit> edits = adif::duplicateEdits(text, r.model, chosen, fill, lengthUnit(), utf8(h));
        if (fill) {  // a kept record that gains fields has changed since any upload
            std::vector<int> changedData;
            for (const adif::DupeSet &d : chosen)
                for (const auto &f : d.fill)
                    if (!adif::isTrackingField(f.first)) changedData.push_back(d.keep);
            edits = adif::mergeEdits(edits, adif::markModified(text, r.model, changedData, lengthUnit(), utf8(h)));
        }
        dupesClear(nil);
        adifhost::apply(h, edits);
        [dupes.w setStatus:ADIFString("Removed " + plural(removed, "duplicate record") + " (one undo step).") severity:-1];
    } catch (...) {
        [dupes.w setStatus:@"Something went wrong removing the duplicates." severity:2];
    }
}

// ── Compare and Merge Logs ──────────────────────────────────────────────────

enum { kShowDifferences, kShowOnlyThere, kShowOnlyHere, kShowDiffer, kShowSame, kShowAll };

struct {
    ADIFToolWindow *w = nil;
    NSTextField *from = nil;
    NSPopUpButton *show = nil;
    NSButton *replace = nil, *sort = nil, *apply = nil;
    std::string path, text;
    adif::LintResult other;
    std::vector<adif::CompareRow> rows;  // every QSO of both logs
    std::vector<size_t> shown;           // the table's rows: indexes into rows
    std::string counts;                  // "15 only in that log, ..."
    intptr_t buffer = 0;
    bool ready = false;
} cmp;

bool cmpReplace() { return cmp.replace.state == NSControlStateValueOn; }

bool cmpTickable(const adif::CompareRow &r) {
    return r.kind == adif::CompareKind::OnlyThere || !adif::copyChanges(r, cmpReplace()).empty();
}

std::string cmpWhat(const adif::CompareRow &r) {
    switch (r.kind) {
        case adif::CompareKind::OnlyThere: return "only in that log";
        case adif::CompareKind::OnlyHere: return "only in this log";
        case adif::CompareKind::Same: return "the same";
        case adif::CompareKind::Differ: break;
    }
    std::string out;
    for (const adif::FieldDiff &d : r.diffs)
        out += (out.empty() ? "" : "; ") + d.field + " " + (d.here.empty() ? "—" : d.here) + " | " + (d.there.empty() ? "—" : d.there);
    return out;
}

void cmpUpdateButton() {
    size_t n = 0;
    std::vector<bool> ticks = [cmp.w ticked];
    for (size_t i = 0; i < ticks.size() && i < cmp.shown.size(); ++i) n += ticks[i] && cmpTickable(cmp.rows[cmp.shown[i]]);
    cmp.apply.enabled = cmp.ready && n > 0;
    cmp.apply.title = n ? [NSString stringWithFormat:@"Apply %zu", n] : @"Apply";
}

// The table, as the Show popup filters it; ticks kept for rows still shown.
void cmpShow(bool keepTicks) {
    NSInteger show = cmp.show.indexOfSelectedItem;
    NppHandle h = scintilla();
    const adif::LintResult &r = lint(h);
    std::string_view text = adifhost::text(h);
    std::vector<std::vector<std::string>> rows;
    std::vector<int> sev;
    std::vector<std::string> keys;
    std::vector<bool> ticks, tickable;
    cmp.shown.clear();
    for (size_t i = 0; i < cmp.rows.size(); ++i) {
        const adif::CompareRow &c = cmp.rows[i];
        bool want = show == kShowAll || (show == kShowDifferences && c.kind != adif::CompareKind::Same) ||
                    (show == kShowOnlyThere && c.kind == adif::CompareKind::OnlyThere) ||
                    (show == kShowOnlyHere && c.kind == adif::CompareKind::OnlyHere) ||
                    (show == kShowDiffer && c.kind == adif::CompareKind::Differ) || (show == kShowSame && c.kind == adif::CompareKind::Same);
        if (!want) continue;
        bool mine = c.here >= 0;
        std::string_view src = mine ? text : std::string_view(cmp.text);
        const adif::DocModel &m = mine ? r.model : cmp.other.model;
        const adif::ModelGroup &g = m.groups[(size_t)(mine ? c.here : c.there)];
        auto get = [&](const char *f) { return std::string(adif::groupValue(src, m, g, f)); };
        std::string band = get("BAND"), mode = get("SUBMODE");
        if (band.empty()) band = adif::bandForFrequency(get("FREQ"));
        if (mode.empty()) mode = get("MODE");
        rows.push_back({c.here >= 0 ? std::to_string(adif::recordNumber(r.model, c.here)) : "",
                        c.there >= 0 ? std::to_string(adif::recordNumber(cmp.other.model, c.there)) : "", get("CALL"),
                        adif::displayDate(get("QSO_DATE")), adif::displayTime(get("TIME_ON")), band, mode, cmpWhat(c)});
        sev.push_back(c.kind == adif::CompareKind::OnlyThere ? 3 : c.kind == adif::CompareKind::Differ ? 1 : c.kind == adif::CompareKind::OnlyHere ? 0 : -1);
        keys.push_back(std::to_string(c.here) + "|" + std::to_string(c.there));
        bool t = cmpTickable(c);
        ticks.push_back(t);
        tickable.push_back(t);
        cmp.shown.push_back(i);
    }
    [cmp.w setRows:rows severities:sev keys:keys ticks:ticks keepTicks:keepTicks];
    [cmp.w setTickable:tickable];
    cmpUpdateButton();
}

void cmpPlan(bool keepTicks) {
    cmp.ready = false;
    cmp.rows.clear();
    [cmp.w setTarget:logLine()];
    cmp.from.stringValue = cmp.path.empty() ? @"(choose a log)" : tilde(cmp.path);
    if (cmp.path.empty()) {
        [cmp.w setRows:kNoRows severities:kNoSev];
        cmpUpdateButton();
        [cmp.w setStatus:@"Choose the log to compare this one with. QSOs only that log has can be added, and for QSOs both "
                         @"have, the fields this log lacks (a confirmation, a grid) can be copied over."
                  severity:-1];
        return;
    }
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        cmp.buffer = buffer();
        std::string error;
        auto fail = [&](const std::string &why) {
            [cmp.w setRows:kNoRows severities:kNoSev];
            cmpUpdateButton();
            [cmp.w setStatus:ADIFString(why) severity:2];
        };
        if (!readFile(cmp.path, kMaxLogBytes, &cmp.text, &error)) return fail("Could not read it: " + error + ".");
        if (cmp.path == path()) return fail("That is this log. Choose another one.");
        cmp.other = lintText(cmp.text);
        if (!hasRecords(cmp.other)) return fail("That file has no ADIF records.");
        if (!adif::canReformat(cmp.other))
            return fail("That log has structural problems (wrong lengths or broken tags). Open it, run Fix Lengths, save it, then "
                        "choose it again.");
        std::string problem = structureProblem(r);
        if (!problem.empty() && hasRecords(r)) return fail("This log: " + problem);
        cmp.rows = adif::compareLogs(adifhost::text(h), r.model, cmp.text, cmp.other.model, adif::DupeOptions());
        size_t there = 0, here = 0, differ = 0, same = 0;
        for (const adif::CompareRow &c : cmp.rows)
            (c.kind == adif::CompareKind::OnlyThere ? there : c.kind == adif::CompareKind::OnlyHere ? here
                                                     : c.kind == adif::CompareKind::Differ        ? differ
                                                                                                  : same)++;
        cmp.ready = true;
        cmpShow(keepTicks);
        std::string st = fileName(cmp.path) + ": " + plural(there, "QSO") + " only there, " + std::to_string(here) + " only here, " +
                         std::to_string(differ) + " in both with differences, " + std::to_string(same) + " the same. ";
        st += "Ticked QSOs only there are added; for ticked QSOs in both, the fields this log lacks are copied" +
              std::string(cmpReplace() ? ", and the ones it has differently replaced." : ".");
        int s = -1;
        std::string undefinedFields;
        for (const adif::UserFieldInfo &u : cmp.other.model.userFields) {
            bool known = false;
            for (const adif::UserFieldInfo &t : r.model.userFields) known |= adif::equalsNoCase(t.name, u.name);
            if (!known) undefinedFields += (undefinedFields.empty() ? "" : ", ") + u.name;
        }
        if (!undefinedFields.empty()) {
            st += " That log defines user fields this one doesn't (" + undefinedFields + "): add their USERDEF lines to this log's "
                  "header, or the validator will flag them.";
            s = 1;
        }
        [cmp.w setStatus:ADIFString(st) severity:s];
    } catch (...) {
        [cmp.w setStatus:@"Something went wrong reading that log." severity:2];
    }
}

void cmpApply() {
    try {
        if (!cmp.ready) return;
        NppHandle h = scintilla();
        if (cmp.buffer != buffer()) {
            [cmp.w setStatus:@"Switch back to the log you were comparing." severity:2];
            return;
        }
        if (readOnly(h)) {
            [cmp.w setStatus:@"This document is read-only." severity:2];
            return;
        }
        cmpPlan(true);  // against the log as it is now
        if (!cmp.ready) return;
        adif::LintResult r = lint(h);  // a copy: the edits below change the document
        std::string text(adifhost::text(h));
        std::vector<bool> ticks = [cmp.w ticked];
        std::vector<int> adds, changedData;
        std::vector<adif::CellChange> changes;
        std::set<int> updated;
        for (size_t i = 0; i < ticks.size() && i < cmp.shown.size(); ++i) {
            if (!ticks[i]) continue;
            const adif::CompareRow &c = cmp.rows[cmp.shown[i]];
            if (c.kind == adif::CompareKind::OnlyThere) adds.push_back(c.there);
            for (const adif::CellChange &ch : adif::copyChanges(c, cmpReplace())) {
                changes.push_back(ch);
                updated.insert(ch.group);
                if (!adif::isTrackingField(ch.field)) changedData.push_back(ch.group);
            }
        }
        if (adds.empty() && changes.empty()) {
            [cmp.w setStatus:@"Nothing ticked to apply." severity:1];
            return;
        }
        std::string eolText = eol(h);
        std::string merged = text;
        if (!changes.empty()) {
            std::vector<adif::TextEdit> edits = adif::cellEdits(text, r.model, changes, lengthUnit(), utf8(h));
            edits = adif::mergeEdits(edits, adif::markModified(text, r.model, changedData, lengthUnit(), utf8(h)));
            merged = adif::applyTextEdits(text, edits);
        }
        std::string note;
        if (!adds.empty()) {
            bool blank = merged.find_first_not_of(" \t\r\n") == std::string::npos;
            adif::LintResult mr = lintText(merged);
            std::string records = adif::mergedRecords(cmp.text, cmp.other.model, adds,
                                                      blank ? adif::Layout::RecordPerLine : adif::recordLayout(merged, mr.model), eolText,
                                                      lengthUnit(), utf8(h));
            if (blank) {
                merged = adif::newLogHeader(ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"), eolText) + records;
            } else {
                size_t start = 0;
                merged = adif::applyTextEdits(merged, {adif::appendRecord(merged, mr.model, records, eolText, &start)});
            }
            if (cmp.sort.state == NSControlStateValueOn) {
                adif::LintResult sr = lintText(merged);
                if (structureProblem(sr).empty()) {
                    bool changed = false;
                    merged = adif::sortedByTime(merged, sr.model, eolText, &changed);
                    if (changed) note = ", sorted by date and time";
                }
            }
        }
        adifhost::apply(h, {adif::minimalEdit(text, merged)});
        std::string done = "From " + fileName(cmp.path) + ": ";
        if (!adds.empty()) done += "added " + plural(adds.size(), "QSO");
        if (!updated.empty()) done += std::string(adds.empty() ? "" : ", ") + "updated " + plural(updated.size(), "record");
        cmpPlan(false);
        [cmp.w setStatus:ADIFString(done + note + " (one undo step).") severity:3];
    } catch (...) {
        [cmp.w setStatus:@"Something went wrong applying the changes." severity:2];
    }
}

// ── POTA export ─────────────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSPopUpButton *program = nil;
    adif::Program shown = adif::Program::POTA;
    NSTextField *station = nil, *folder = nil;
    NSButton *save = nil;
    std::vector<adif::PotaFile> files;
    std::string confirmReplace;  // the file list a second Save press replaces
    intptr_t buffer = 0;
} pota;

void potaPlan() {
    if (!pota.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        pota.buffer = buffer();
        pota.confirmReplace.clear();
        [pota.w setTarget:logLine()];
        std::string dir = setting("potaFolder");
        pota.folder.stringValue = dir.empty() ? @"(choose a folder)" : tilde(dir);
        NSInteger pi = pota.program.indexOfSelectedItem;
        adif::Program prog = pi == 1 ? adif::Program::WWFF : pi == 2 ? adif::Program::SOTA : adif::Program::POTA;
        pota.shown = prog;
        pota.files = adif::programExport(prog, adifhost::text(h), r.model, ADIFStd(pota.station.stringValue), ADIFLINT_VERSION,
                                         utcNow("%Y%m%d %H%M%S"), "\n", adif::LengthUnit::Bytes, true, utcNow("%Y%m%d"));
        std::vector<std::vector<std::string>> rows;
        std::vector<int> sev;
        bool noStation = false;
        for (const adif::PotaFile &f : pota.files) {
            std::string notes;
            for (const std::string &n : f.notes) notes += (notes.empty() ? "" : "; ") + n;
            rows.push_back({f.name, f.park, adif::displayDate(f.date), std::to_string(f.records), std::to_string(f.qsos), notes});
            size_t needed = prog == adif::Program::POTA ? 10 : prog == adif::Program::SOTA ? 4 : 0;
            sev.push_back(f.station.empty() ? 2 : f.qsos < needed ? 1 : -1);
            noStation |= f.station.empty();
        }
        [pota.w setRows:rows severities:sev];
        pota.save.enabled = !pota.files.empty();
        pota.save.title = [NSString stringWithFormat:@"Save %zu File%@", pota.files.size(), pota.files.size() == 1 ? @"" : @"s"];
        if (pota.files.empty()) {
            [pota.w setStatus:prog == adif::Program::WWFF   ? @"No WWFF activations in this log: records need MY_WWFF_REF, or MY_SIG WWFF and MY_SIG_INFO."
                              : prog == adif::Program::SOTA ? @"No SOTA activations in this log: records need MY_SOTA_REF, or MY_SIG SOTA and MY_SIG_INFO."
                                                            : @"No POTA activations in this log: records need MY_SIG POTA and MY_SIG_INFO, or MY_POTA_REF."
                      severity:2];
        } else if (r.structuralErrors) {
            [pota.w setStatus:@"The log has structural problems, so records may be read wrongly. Run Fix Lengths first."
                      severity:2];
        } else {
            std::string what = prog == adif::Program::WWFF
                                   ? "One file per reference and activation (consecutive UTC days), named callsign @ reference date as WWFF asks. "
                                   : prog == adif::Program::SOTA ? "One file per summit and UTC day. "
                                                                 : "One file per park and UTC day, named callsign@park-date as POTA asks. ";
            std::string where = prog == adif::Program::WWFF ? "Send them to your national WWFF log manager."
                                : prog == adif::Program::SOTA ? "Upload them at sotadata.org.uk."
                                                              : "Upload them at pota.app, My Log Uploads.";
            [pota.w setStatus:ADIFString(what +
                                         (noStation ? "Some records have no STATION_CALLSIGN or OPERATOR: enter your "
                                                      "callsign above. "
                                                    : "") +
                                         where)
                      severity:noStation ? 1 : -1];
        }
    } catch (...) {
    }
}

void potaSave() {
    try {
        if (pota.buffer != buffer()) {
            potaPlan();
            [pota.w setStatus:@"The log changed; check the list, then Save again." severity:1];
            return;
        }
        std::string dir = setting("potaFolder");
        if (dir.empty()) {
            dir = chooseOpen(@"Choose the folder for the activation logs", true);
            if (dir.empty()) return;
            setSetting("potaFolder", dir);
            pota.folder.stringValue = tilde(dir);
        }
        std::string station = ADIFStd(pota.station.stringValue);
        setSetting("potaStation", station);
        std::vector<bool> ticked = [pota.w ticked];
        std::vector<const adif::PotaFile *> chosen;
        for (size_t i = 0; i < pota.files.size(); ++i)
            if (i < ticked.size() && ticked[i]) chosen.push_back(&pota.files[i]);
        if (chosen.empty()) {
            [pota.w setStatus:@"Nothing is ticked." severity:1];
            return;
        }
        for (const adif::PotaFile *f : chosen)
            if (f->station.empty()) {
                [pota.w setStatus:@"Enter your callsign for the records without STATION_CALLSIGN or OPERATOR." severity:2];
                return;
            }
        std::string existing;
        for (const adif::PotaFile *f : chosen) {
            struct stat st{};
            if (stat((dir + "/" + f->name).c_str(), &st) == 0) existing += (existing.empty() ? "" : ", ") + f->name;
        }
        if (!existing.empty() && existing != pota.confirmReplace) {
            pota.confirmReplace = existing;
            [pota.w setStatus:ADIFString("Already in the folder: " + existing + ". Press Save again to replace them.")
                      severity:1];
            return;
        }
        size_t saved = 0;
        for (const adif::PotaFile *f : chosen) {
            std::string error;
            if (!writeFile(dir + "/" + f->name, f->text, &error)) {
                [pota.w setStatus:ADIFString("Could not save " + f->name + ": " + error) severity:2];
                return;
            }
            ++saved;
        }
        pota.confirmReplace.clear();
        [pota.w setStatus:ADIFString("Saved " + plural(saved, "file") + " to " + ADIFStd(tilde(dir)) +
                                     (pota.shown == adif::Program::WWFF   ? ". Send them to your national WWFF log manager."
                                      : pota.shown == adif::Program::SOTA ? ". Upload them at sotadata.org.uk."
                                                                          : ". Upload them at pota.app, My Log Uploads."))
                  severity:3];
    } catch (...) {
        [pota.w setStatus:@"Something went wrong saving the files." severity:2];
    }
}

// The station callsign most of the log's records use.
std::string usualStation(std::string_view text, const adif::DocModel &m) {
    std::map<std::string, size_t> n;
    for (const adif::Record &r : adif::records(text, m)) {
        std::string s = adif::stationCall(r);
        if (!s.empty()) ++n[s];
    }
    std::string best;
    size_t most = 0;
    for (const auto &kv : n)
        if (kv.second > most) most = kv.second, best = kv.first;
    return best;
}

// ── Spots: POTA and WWFF (hunting) ──────────────────────────────────────────

// References worked in this log or the Worked Before folder (without @location), upper case.
std::set<std::string> workedReferences() {
    std::set<std::string> out;
    auto add = [&](const adif::Contact &c) {
        for (const std::string &r : c.theirRefs) out.insert(r.substr(0, r.find('@')));
    };
    try {
        NppHandle h = scintilla();
        for (const adif::Contact &c : adif::contacts(adifhost::text(h), lint(h).model)) add(c);
    } catch (...) {
    }
    for (const auto &log : idx.logs)
        for (const adif::Contact &c : log->contacts) add(c);
    return out;
}

struct Spot {
    std::string time, activator, khz, mode, reference, park, location, spotter, comments, band;
    std::string key;  // spotId, so a refresh keeps the selection on the same spot
    std::string program, grid;    // Spothole: the program (GMA, WWBOTA...) and where the reference is
    std::vector<std::string> refs;  // Spothole: every reference of the spot
};

enum { kSpotsPota, kSpotsWwff, kSpotsSpothole };

struct {
    ADIFToolWindow *w = nil;
    NSSearchField *search = nil;
    NSPopUpButton *band = nil, *mode = nil, *program = nil, *activity = nil;
    NSButton *use = nil;
    adif::Program shown = adif::Program::POTA;  // the program of `all`
    bool spothole = false;                      // `all` came from Spothole
    std::vector<std::string> programs;          // Spothole's programs ADIF Lint asks for
    double lastSpothole = 0;                    // when Spothole was last asked
    std::vector<Spot> all;
    std::vector<size_t> rowSpot;  // model row -> index into all
    NSTimer *timer = nil;
    bool loading = false;
    std::string fetched;  // UTC time of the last good fetch
    void (^handler)(const std::vector<std::pair<std::string, std::string>> &) = nil;
} spots;

std::string jsonString(NSDictionary *d, NSString *key, size_t limit = 120) {
    id v = d[key];
    NSString *s = [v isKindOfClass:NSString.class] ? v : [v isKindOfClass:NSNumber.class] ? [v stringValue] : nil;
    std::string out = s ? ADIFStd(s) : std::string();
    std::string clean;
    for (char c : out)
        if (c >= 32 && c < 127) clean.push_back(c);  // printable ASCII only, as ADI needs
    if (clean.size() > limit) clean.resize(limit);
    return clean;
}

const char *const kSpotBands[] = {"160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m", "2m", "70cm"};

void spotsShow() {
    if (!spots.w) return;
    std::string band = spots.band.indexOfSelectedItem > 0 ? ADIFStd(spots.band.titleOfSelectedItem) : "";
    NSInteger modeIdx = spots.mode.indexOfSelectedItem;
    // What this log already has today (UTC): CALL on a band.
    std::set<std::string> today;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::string date = utcNow("%Y%m%d");
        for (const adif::Record &rec : adif::records(adifhost::text(h), r.model))
            if (rec.get("QSO_DATE") == date) today.insert(adif::lookupCall(rec.get("CALL")) + "|" + adif::effectiveBand(rec));
    } catch (...) {
    }
    std::set<std::string> refs = workedReferences();
    std::string program = spots.spothole && spots.activity.indexOfSelectedItem > 0 ? ADIFStd(spots.activity.titleOfSelectedItem) : "";
    std::vector<std::vector<std::string>> rows;
    std::vector<int> sev;
    std::vector<std::string> keys;
    spots.rowSpot.clear();
    for (size_t i = 0; i < spots.all.size(); ++i) {
        const Spot &sp = spots.all[i];
        if (!band.empty() && sp.band != band) continue;
        if (!program.empty() && sp.program != program) continue;
        std::string m = sp.mode;
        bool other = m != "SSB" && m != "CW" && m != "FT8" && m != "FT4";
        if ((modeIdx == 1 && m != "SSB") || (modeIdx == 2 && m != "CW") || (modeIdx == 3 && m != "FT8") ||
            (modeIdx == 4 && m != "FT4") || (modeIdx == 5 && !other))
            continue;
        bool workedToday = today.count(adif::lookupCall(sp.activator) + "|" + sp.band) > 0;
        bool workedRef = refs.count(sp.reference) > 0;
        for (const std::string &r : sp.refs) workedRef = workedRef || refs.count(r) > 0;
        std::string lotw = ADIFLotwLastUpload(sp.activator);
        rows.push_back({sp.time, sp.activator, sp.khz, sp.mode, sp.reference, sp.park, sp.location,
                        workedToday ? "today" : workedRef ? "worked" : "NEW", lotw, sp.comments});
        sev.push_back(workedToday ? 0 : workedRef ? -1 : 3);
        keys.push_back(sp.key);
        spots.rowSpot.push_back(i);
    }
    [spots.w setRows:rows severities:sev keys:keys ticks:kNoTicks keepTicks:NO];
    spots.use.enabled = [spots.w selectedRows].size() == 1;
    NSInteger source = spots.program.indexOfSelectedItem;
    bool wwff = spots.shown == adif::Program::WWFF || spots.spothole;
    std::string status = spots.loading ? std::string("Fetching spots from ") +
                                             (source == kSpotsSpothole ? "spothole.app..." : source == kSpotsWwff ? "spots.wwff.co..." : "pota.app...")
                         : spots.fetched.empty()
                             ? ""
                             : plural(rows.size(), "spot") + (rows.size() == spots.all.size() ? "" : " of " + std::to_string(spots.all.size())) +
                                   " at " + spots.fetched +
                                   (spots.spothole ? " UTC from Spothole (spothole.app; refreshed every 2 minutes; SOTA left out)."
                                                   : " UTC (refreshed every minute).") +
                                   " Double-click one, or select it and Use in New QSO. Green NEW: a " + (wwff ? "reference" : "park") +
                                   " not in your logs; blue: that station worked today on that band.";
    if (!status.empty()) [spots.w setStatus:ADIFString(status) severity:-1];
}

// Spothole's spots, in Spot form: dx_call, freq (Hz), mode, time_iso (UTC), activities (the first is the
// program), activity_refs (id, name, grid), dx_grid with dx_location_good, de_call, comment, id.
std::vector<Spot> spotholeSpots(NSArray<NSDictionary *> *list) {
    std::vector<Spot> all;
    for (NSDictionary *d in list) {
        Spot sp;
        sp.activator = jsonString(d, @"dx_call", 20);
        for (char &c : sp.activator) c = (char)std::toupper((unsigned char)c);
        id freq = d[@"freq"];
        double hz = [freq isKindOfClass:NSNumber.class] ? [freq doubleValue] : 0;
        if (sp.activator.empty() || hz <= 0) continue;
        char khz[32];
        std::snprintf(khz, sizeof khz, "%.3f", hz / 1000);
        sp.khz = khz;
        while (!sp.khz.empty() && sp.khz.back() == '0') sp.khz.pop_back();
        if (!sp.khz.empty() && sp.khz.back() == '.') sp.khz.pop_back();
        if (adif::khzToMHz(sp.khz).empty()) continue;
        std::string t = jsonString(d, @"time_iso", 40);  // "2026-10-10T16:27:47+00:00"
        sp.time = t.size() >= 16 ? t.substr(11, 5) : t;
        sp.mode = jsonString(d, @"mode", 12);
        for (char &c : sp.mode) c = (char)std::toupper((unsigned char)c);
        NSArray *acts = [d[@"activities"] isKindOfClass:NSArray.class] ? d[@"activities"] : @[];
        if (acts.count && [acts[0] isKindOfClass:NSString.class]) sp.program = ADIFStd(acts[0]);
        NSArray *refs = [d[@"activity_refs"] isKindOfClass:NSArray.class] ? d[@"activity_refs"] : @[];
        for (id r in refs) {
            if (![r isKindOfClass:NSDictionary.class]) continue;
            std::string ref = jsonString(r, @"id", 30);
            for (char &c : ref) c = (char)std::toupper((unsigned char)c);
            if (ref.empty()) continue;
            sp.refs.push_back(ref);
            if (sp.park.empty()) sp.park = jsonString(r, @"name");
            if (sp.grid.empty()) sp.grid = jsonString(r, @"grid", 10);
        }
        if (sp.grid.empty() && [d[@"dx_location_good"] isEqual:@YES]) sp.grid = jsonString(d, @"dx_grid", 10);
        sp.reference = sp.refs.empty() ? "" : sp.refs[0] + (sp.refs.size() > 1 ? " +" + std::to_string(sp.refs.size() - 1) : "");
        sp.location = sp.program;
        sp.spotter = jsonString(d, @"de_call", 20);
        sp.comments = jsonString(d, @"comment");
        sp.band = adif::bandForFrequency(adif::khzToMHz(sp.khz));
        sp.key = jsonString(d, @"id", 80);
        if (sp.key.empty()) sp.key = sp.activator + "|" + sp.reference + "|" + sp.khz + "|" + sp.mode;
        all.push_back(std::move(sp));
    }
    std::stable_sort(all.begin(), all.end(), [](const Spot &a, const Spot &b) { return a.time > b.time; });
    return all;
}

// Spothole: its programs once (outdoor ones with references; never SOTA, and not POTA or WWFF, read from
// their own sites), then one request for all of them, filtered here, as Spothole asks of clients.
void spotholeFetch(NSString *agent) {
    spots.lastSpothole = CFAbsoluteTimeGetCurrent();
    void (^fetchSpots)(void) = ^{
        std::string csv;
        for (const std::string &p : spots.programs) csv += (csv.empty() ? "" : ",") + p;
        ADIFFetchSpotholeSpots(agent, ADIFString(csv), ^(NSArray<NSDictionary *> *list, NSString *error) {
            spots.loading = false;
            if (error) {
                [spots.w setStatus:[@"Could not fetch spots from Spothole: " stringByAppendingString:error] severity:2];
                return;
            }
            if (spots.program.indexOfSelectedItem != kSpotsSpothole) return;  // you moved on meanwhile
            spots.all = spotholeSpots(list);
            spots.spothole = true;
            spots.fetched = utcNow("%H:%M");
            spotsShow();
        });
    };
    if (!spots.programs.empty()) return fetchSpots();
    ADIFFetchSpotholePrograms(agent, ^(NSArray<NSDictionary *> *programs, NSString *error) {
        if (error) {
            spots.loading = false;
            [spots.w setStatus:[@"Could not reach Spothole: " stringByAppendingString:error] severity:2];
            return;
        }
        for (NSDictionary *a in programs) {
            std::string name = jsonString(a, @"name", 40), type = jsonString(a, @"activity_type", 20);
            if (adif::spotholeProgramWanted(name, type, [a[@"has_refs"] isEqual:@YES])) spots.programs.push_back(name);
        }
        NSString *keep = spots.activity.indexOfSelectedItem > 0 ? spots.activity.titleOfSelectedItem : ADIFString(setting("spotsSpotholeProgram"));
        [spots.activity removeAllItems];
        [spots.activity addItemWithTitle:@"All programs"];
        for (const std::string &p : spots.programs) [spots.activity addItemWithTitle:ADIFString(p)];
        if (keep.length && [spots.activity itemWithTitle:keep]) [spots.activity selectItemWithTitle:keep];
        if (spots.programs.empty()) {
            spots.loading = false;
            [spots.w setStatus:@"Spothole lists no programs to show." severity:2];
            return;
        }
        fetchSpots();
    });
}

void spotsFetch() {
    if (spots.loading) return;
    spots.loading = true;
    if (spots.all.empty()) spotsShow();
    NSString *agent = [NSString stringWithFormat:@"ADIF Lint/%s (Nextpad++ plugin; https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint)",
                                                 ADIFLINT_VERSION];
    if (spots.program.indexOfSelectedItem == kSpotsSpothole) return spotholeFetch(agent);
    adif::Program program = spots.program.indexOfSelectedItem == kSpotsWwff ? adif::Program::WWFF : adif::Program::POTA;
    auto received = ^(NSArray<NSDictionary *> *list, NSString *error) {
        spots.loading = false;
        if (error) {
            [spots.w setStatus:[@"Could not fetch spots: " stringByAppendingString:error] severity:2];
            return;
        }
        if (program == adif::Program::WWFF) {
            // spots.wwff.co/static/spots.json: activator, frequency_khz, mode, reference, reference_name, remarks,
            // spotter, spot_time_formatted ("2026-10-08 00:30:18", UTC), id.
            std::vector<Spot> all;
            for (NSDictionary *d in list) {
                Spot sp;
                sp.activator = jsonString(d, @"activator", 20);
                sp.key = jsonString(d, @"id", 20);
                sp.khz = jsonString(d, @"frequency_khz", 12);
                if (sp.activator.empty() || adif::khzToMHz(sp.khz).empty()) continue;
                std::string t = jsonString(d, @"spot_time_formatted", 30);
                sp.time = t.size() >= 16 ? t.substr(11, 5) : t;
                sp.mode = jsonString(d, @"mode", 12);
                for (char &c : sp.mode) c = (char)std::toupper((unsigned char)c);
                sp.reference = jsonString(d, @"reference", 20);
                for (char &c : sp.reference) c = (char)std::toupper((unsigned char)c);
                sp.park = jsonString(d, @"reference_name");
                sp.spotter = jsonString(d, @"spotter", 20);
                sp.comments = jsonString(d, @"remarks");
                sp.band = adif::bandForFrequency(adif::khzToMHz(sp.khz));
                if (sp.key.empty()) sp.key = sp.activator + "|" + sp.reference + "|" + sp.khz + "|" + sp.mode;
                for (char &c : sp.activator) c = (char)std::toupper((unsigned char)c);
                all.push_back(std::move(sp));
            }
            std::stable_sort(all.begin(), all.end(), [](const Spot &a, const Spot &b) { return a.time > b.time; });
            spots.all = std::move(all);
            spots.shown = program;
            spots.spothole = false;
            spots.fetched = utcNow("%H:%M");
            spotsShow();
            return;
        }
        std::vector<Spot> all;
        for (NSDictionary *d in list) {
            Spot sp;
            sp.activator = jsonString(d, @"activator", 20);
            sp.key = jsonString(d, @"spotId", 20);
            sp.khz = jsonString(d, @"frequency", 12);
            if (sp.activator.empty() || adif::khzToMHz(sp.khz).empty()) continue;
            std::string t = jsonString(d, @"spotTime", 30);  // "2026-10-07T21:11:57" (UTC)
            sp.time = t.size() >= 16 ? t.substr(11, 5) : t;
            sp.mode = jsonString(d, @"mode", 12);
            for (char &c : sp.mode) c = (char)std::toupper((unsigned char)c);
            sp.reference = jsonString(d, @"reference", 20);
            sp.park = jsonString(d, @"name");
            sp.location = jsonString(d, @"locationDesc", 40);
            sp.spotter = jsonString(d, @"spotter", 20);
            sp.comments = jsonString(d, @"comments");
            sp.band = adif::bandForFrequency(adif::khzToMHz(sp.khz));
            if (sp.key.empty()) sp.key = sp.activator + "|" + sp.reference + "|" + sp.khz + "|" + sp.mode;
            for (char &c : sp.activator) c = (char)std::toupper((unsigned char)c);
            all.push_back(std::move(sp));
        }
        std::stable_sort(all.begin(), all.end(), [](const Spot &a, const Spot &b) { return a.time > b.time; });
        spots.all = std::move(all);
        spots.shown = program;
        spots.spothole = false;
        spots.fetched = utcNow("%H:%M");
        spotsShow();
    };
    if (program == adif::Program::WWFF) ADIFFetchWwffSpots(agent, received);
    else ADIFFetchPotaSpots(agent, received);
}

void spotsUse(NSInteger row) {
    if (row < 0 || (size_t)row >= spots.rowSpot.size() || !spots.handler) return;
    const Spot &sp = spots.all[spots.rowSpot[(size_t)row]];
    spots.handler(spots.spothole ? adif::spotholeSpotFields(sp.program, sp.activator, sp.khz, sp.mode, sp.refs, sp.grid)
                                 : adif::programSpotFields(spots.shown, sp.activator, sp.khz, sp.mode, sp.reference));
    [spots.w setStatus:ADIFString("Copied " + sp.activator + " at " + sp.reference + " (" + sp.khz + " kHz " + sp.mode +
                                  ") to New QSO.")
              severity:-1];
}

// ── Import CSV ──────────────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSTextField *from = nil;
    NSButton *sort = nil, *add = nil;
    std::string path;
    adif::CsvImport data;
    intptr_t buffer = 0;
} csvIn;

void csvPlan() {
    if (!csvIn.w) return;
    csvIn.add.enabled = NO;
    csvIn.add.title = @"Add QSOs";
    [csvIn.w setTarget:logLine()];
    csvIn.from.stringValue = csvIn.path.empty() ? @"(choose a CSV file)" : tilde(csvIn.path);
    [csvIn.w setRows:kNoRows severities:kNoSev];
    if (csvIn.path.empty()) {
        [csvIn.w setStatus:@"Choose a CSV file whose first row names the columns: ADIF field names, or names such as "
                           @"Callsign, Date, UTC, Frequency, Mode, RST Sent, RST Rcvd, Grid, Park, Notes."
                  severity:-1];
        return;
    }
    std::string text, error;
    if (!readFile(csvIn.path, kMaxLogBytes, &text, &error)) {
        [csvIn.w setStatus:ADIFString("Could not read it: " + error + ".") severity:2];
        return;
    }
    csvIn.data = adif::importCsv(text);
    csvIn.buffer = buffer();
    std::vector<std::vector<std::string>> rows;
    std::vector<int> sev;
    for (const auto &rec : csvIn.data.records) {
        adif::Record r;
        r.fields = rec;
        bool ok = !r.get("CALL").empty() && adif::parseAdifDate(r.get("QSO_DATE"), nullptr) &&
                  adif::parseAdifTime(r.get("TIME_ON"), nullptr) && !adif::effectiveBand(r).empty() && !adif::effectiveMode(r).empty();
        rows.push_back({r.get("CALL"), adif::displayDate(r.get("QSO_DATE")), adif::displayTime(r.get("TIME_ON")),
                        adif::effectiveBand(r), adif::effectiveMode(r), std::to_string(r.fields.size())});
        sev.push_back(ok ? -1 : 1);
    }
    [csvIn.w setRows:rows severities:sev];
    std::string used, left;
    for (const auto &c : csvIn.data.columns)
        if (c.second.empty()) left += (left.empty() ? "" : ", ") + c.first;
        else used += (used.empty() ? "" : ", ") + c.first + " \u2192 " + c.second;
    std::string st = plural(csvIn.data.records.size(), "row") + ". Columns: " + (used.empty() ? "none recognised" : used) + "." +
                     (left.empty() ? "" : " Left out: " + left + ".");
    for (size_t i = 0; i < csvIn.data.notes.size() && i < 3; ++i) st += " " + csvIn.data.notes[i] + ".";
    if (csvIn.data.notes.size() > 3) st += " And " + std::to_string(csvIn.data.notes.size() - 3) + " more.";
    st += " Orange rows lack CALL, a valid date and time, BAND or FREQ, or MODE: the validator will mark them.";
    [csvIn.w setStatus:ADIFString(st) severity:csvIn.data.notes.empty() ? -1 : 1];
    if (!csvIn.data.records.empty()) {
        csvIn.add.enabled = YES;
        csvIn.add.title = [NSString stringWithFormat:@"Add %zu QSO%@", csvIn.data.records.size(), csvIn.data.records.size() == 1 ? @"" : @"s"];
        [csvIn.w setDefaultButton:csvIn.add];
    }
}

void csvAdd() {
    try {
        NppHandle h = scintilla();
        if (csvIn.buffer != buffer() || readOnly(h)) {
            [csvIn.w setStatus:@"Switch back to the log you were adding to (and make sure it isn't read-only)." severity:2];
            return;
        }
        adif::LintResult r = lint(h);
        std::string_view text = adifhost::text(h);
        bool blank = text.find_first_not_of(" \t\r\n") == std::string_view::npos;
        std::string problem = structureProblem(r);
        if (!blank && !problem.empty()) {
            [csvIn.w setStatus:ADIFString("This log: " + problem) severity:2];
            return;
        }
        std::string eolText = eol(h);
        adif::Layout layout = blank ? adif::Layout::RecordPerLine : adif::recordLayout(text, r.model);
        std::string records;
        for (const auto &rec : csvIn.data.records) {
            if (!records.empty() && layout == adif::Layout::FieldPerLine) records += eolText;
            records += adif::buildRecord(rec, layout, eolText, lengthUnit(), utf8(h)).text;
        }
        std::string merged;
        size_t start = 0;
        if (blank) merged = adif::newLogHeader(ADIFLINT_VERSION, utcNow("%Y%m%d %H%M%S"), eolText) + records;
        else merged = adif::applyTextEdits(text, {adif::appendRecord(text, r.model, records, eolText, &start)});
        std::string note;
        if (csvIn.sort.state == NSControlStateValueOn) {
            adif::LintResult rm = lintText(merged);
            if (structureProblem(rm).empty()) {
                bool changed = false;
                merged = adif::sortedByTime(merged, rm.model, eolText, &changed);
                if (changed) note = " and sorted by date and time";
            }
        }
        size_t n = csvIn.data.records.size();
        adifhost::apply(h, {adif::TextEdit{0, text.size(), merged}});
        csvIn.add.enabled = NO;
        [csvIn.w setRows:kNoRows severities:kNoSev];
        [csvIn.w setStatus:ADIFString("Added " + plural(n, "QSO") + " from " + fileName(csvIn.path) + note + " (one undo step).")
                  severity:-1];
    } catch (...) {
        [csvIn.w setStatus:@"Something went wrong adding the QSOs." severity:2];
    }
}

// ── Export Cabrillo ─────────────────────────────────────────────────────────

struct {
    ADIFToolWindow *w = nil;
    NSComboBox *contest = nil;
    NSTextField *callsign = nil, *grid = nil, *location = nil;
    NSPopUpButton *op = nil, *power = nil;
    adif::CabrilloLog log;
} cab;

void cabPlan() {
    if (!cab.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        [cab.w setTarget:logLine()];
        adif::CabrilloOptions o;
        o.contest = ADIFStd(cab.contest.stringValue);
        o.callsign = ADIFStd(cab.callsign.stringValue);
        o.grid = ADIFStd(cab.grid.stringValue);
        o.location = ADIFStd(cab.location.stringValue);
        o.categoryOperator = cab.op.indexOfSelectedItem > 0 ? ADIFStd(cab.op.titleOfSelectedItem) : "";
        o.categoryPower = cab.power.indexOfSelectedItem > 0 ? ADIFStd(cab.power.titleOfSelectedItem) : "";
        o.createdBy = std::string("ADIF Lint ") + ADIFLINT_VERSION;
        std::set<std::string> ops;
        std::vector<adif::Record> recs = adif::records(adifhost::text(h), r.model);
        for (const adif::Record &rec : recs)
            if (!rec.get("OPERATOR").empty()) ops.insert(rec.get("OPERATOR"));
        for (const std::string &x : ops) o.operators += (o.operators.empty() ? "" : " ") + x;
        cab.log = adif::toCabrillo(recs, o);
        [cab.w setText:ADIFString(cab.log.text)];
        std::string st = plural(cab.log.qsos, "QSO line");
        if (cab.log.incomplete) st += "; " + plural(cab.log.incomplete, "line") + " show - for a missing report or exchange";
        if (cab.log.skipped) st += "; " + plural(cab.log.skipped, "record") + " left out (no CALL, date, time, band or mode)";
        st += ". The sent and received exchange come from STX_STRING or STX and SRX_STRING or SRX: check the contest's "
              "own Cabrillo template before you submit.";
        [cab.w setStatus:ADIFString(st) severity:cab.log.incomplete || cab.log.skipped ? 1 : -1];
    } catch (...) {
    }
}

// ── Sort and Organize ───────────────────────────────────────────────────────

const size_t kSortKeys = 3;

struct {
    ADIFToolWindow *w = nil;
    NSButton *doSort = nil, *doFields = nil, *apply = nil;
    NSComboBox *key[kSortKeys] = {nil, nil, nil};
    NSPopUpButton *dir[kSortKeys] = {nil, nil, nil};
    std::vector<std::string> fields;     // the field order shown
    std::map<std::string, size_t> uses;  // records using each field
} org;

std::vector<std::string> splitList(const std::string &list) {
    std::vector<std::string> out;
    std::string item;
    for (size_t i = 0; i <= list.size(); ++i) {
        if (i == list.size() || list[i] == ',') {
            if (!item.empty()) out.push_back(item);
            item.clear();
        } else {
            item.push_back(list[i]);
        }
    }
    return out;
}

// `preferred` first (the ones the log uses), then the log's other fields in the Log Table's order.
std::vector<std::string> orgFieldOrder(const std::vector<std::string> &preferred, const std::vector<std::string> &used) {
    std::vector<std::string> out;
    for (const std::string &f : preferred)
        if (std::find(used.begin(), used.end(), f) != used.end() && std::find(out.begin(), out.end(), f) == out.end())
            out.push_back(f);
    for (const std::string &f : used)
        if (std::find(out.begin(), out.end(), f) == out.end()) out.push_back(f);
    return out;
}

std::vector<adif::SortKey> orgKeys() {
    std::vector<adif::SortKey> keys;
    for (size_t i = 0; i < kSortKeys; ++i) {
        std::string f = ADIFStd(org.key[i].stringValue);
        while (!f.empty() && f.back() == ' ') f.pop_back();
        while (!f.empty() && f.front() == ' ') f.erase(0, 1);
        for (char &c : f) c = (char)std::toupper((unsigned char)c);
        if (!f.empty()) keys.push_back({f, org.dir[i].indexOfSelectedItem == 1});
    }
    return keys;
}

std::string orgKeysText(const std::vector<adif::SortKey> &keys) {
    std::string s;
    for (size_t i = 0; i < keys.size(); ++i)
        s += (i == 0 ? "" : i + 1 == keys.size() ? " and then " : ", then ") + keys[i].field + (keys[i].descending ? " (descending)" : "");
    return s;
}

void orgStatus() {
    if (!org.w) return;
    bool sort = org.doSort.state == NSControlStateValueOn, fields = org.doFields.state == NSControlStateValueOn;
    std::vector<adif::SortKey> keys = orgKeys();
    std::string st;
    if (sort && !keys.empty()) st += "Sorts the records by " + orgKeysText(keys) + ". ";
    if (fields) st += "Puts the fields of every record in the order below (select one and move it). ";
    if (st.empty()) st = "Tick what to do: sort the records, put their fields in order, or both. ";
    st += "Data is copied byte for byte; nothing changes until Apply (one undo step).";
    [org.w setStatus:ADIFString(st) severity:-1];
    org.apply.enabled = (sort && !keys.empty()) || fields;
}

void orgShow(const std::vector<std::string> &select) {
    std::vector<std::vector<std::string>> rows;
    for (size_t i = 0; i < org.fields.size(); ++i) {
        const std::string &f = org.fields[i];
        const adif::FieldDef *d = adif::findField(f);
        rows.push_back({std::to_string(i + 1), f, std::to_string(org.uses[f]), d && d->description ? d->description : ""});
    }
    [org.w setRows:rows severities:kNoSev keys:org.fields ticks:kNoTicks keepTicks:NO];
    for (const std::string &f : select) {
        auto it = std::find(org.fields.begin(), org.fields.end(), f);
        if (it != org.fields.end()) [org.w selectRow:(NSInteger)(it - org.fields.begin())];
    }
}

// Re-read the log's fields, keeping the order shown.
void orgRefresh() {
    if (!org.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::vector<adif::Record> recs = adif::records(adifhost::text(h), r.model);
        [org.w setTarget:logLine()];
        org.uses.clear();
        for (const adif::Record &rec : recs)
            for (const auto &kv : rec.fields) ++org.uses[kv.first];
        std::vector<std::string> used = adif::tableColumns(recs);
        org.fields = orgFieldOrder(org.fields, used);
        NSMutableArray *names = [NSMutableArray array];
        for (const std::string &f : used) [names addObject:ADIFString(f)];
        for (size_t i = 0; i < kSortKeys; ++i) {
            [org.key[i] removeAllItems];
            [org.key[i] addItemsWithObjectValues:names];
        }
        std::vector<std::string> selected;
        for (NSInteger row : [org.w selectedRows])
            if ((size_t)row < org.fields.size()) selected.push_back(org.fields[(size_t)row]);
        orgShow(selected);
    } catch (...) {
    }
    orgStatus();
}

void orgMove(int step) {
    std::vector<NSInteger> sel = [org.w selectedRows];
    if (sel.size() != 1 || (size_t)sel[0] >= org.fields.size()) {
        [org.w setStatus:@"Select one field to move." severity:1];
        return;
    }
    size_t i = (size_t)sel[0];
    size_t to = step < 0 ? (i == 0 ? 0 : i - 1) : std::min(i + 1, org.fields.size() - 1);
    std::string f = org.fields[i];
    org.fields.erase(org.fields.begin() + (std::ptrdiff_t)i);
    org.fields.insert(org.fields.begin() + (std::ptrdiff_t)to, f);
    orgShow({f});
    orgStatus();
}

void orgApply() {
    try {
        NppHandle h = scintilla();
        adif::LintResult r = lint(h);  // a copy: the edit changes the document
        if (!hasRecords(r)) {
            [org.w setStatus:@"This document has no ADIF records." severity:2];
            return;
        }
        std::string problem = structureProblem(r);
        if (!problem.empty()) {
            [org.w setStatus:ADIFString(problem) severity:2];
            return;
        }
        if (readOnly(h)) {
            [org.w setStatus:@"This document is read-only." severity:2];
            return;
        }
        bool sort = org.doSort.state == NSControlStateValueOn, fields = org.doFields.state == NSControlStateValueOn;
        std::vector<adif::SortKey> keys = orgKeys();
        for (const adif::SortKey &k : keys)
            if (!adif::findField(k.field) && !org.uses.count(k.field)) {
                [org.w setStatus:ADIFString(k.field + " is not an ADIF field or one this log uses.") severity:2];
                return;
            }
        std::string text(adifhost::text(h)), merged = text;
        size_t edited = 0, skipped = 0;
        if (fields) merged = adif::applyTextEdits(text, adif::fieldOrderEdits(text, r.model, org.fields, &edited, &skipped));
        bool moved = false;
        if (sort && !keys.empty()) {
            adif::LintResult mr = lintText(merged);
            merged = adif::sortedBy(merged, mr.model, keys, eol(h), &moved);
        }
        // Remember the choices for next time.
        std::string sortSetting, fieldSetting;
        for (const adif::SortKey &k : keys) sortSetting += (sortSetting.empty() ? "" : ",") + k.field + (k.descending ? ":d" : ":a");
        for (const std::string &f : org.fields) fieldSetting += (fieldSetting.empty() ? "" : ",") + f;
        setSetting("organizeSort", sortSetting);
        if (fields) setSetting("organizeFields", fieldSetting);  // only an order you chose to apply
        setSetting("organizeDo", std::string(sort ? "sort" : "") + (fields ? "fields" : ""));
        if (merged == text) {
            [org.w setStatus:@"Already in this order: nothing changed." severity:-1];
            return;
        }
        adifhost::apply(h, {adif::TextEdit{0, text.size(), merged}});
        std::string st;
        if (moved) st += "Sorted " + plural(adif::recordCount(r.model), "record") + " by " + orgKeysText(keys) + ". ";
        if (edited) st += "Put the fields of " + plural(edited, "record") + " in order. ";
        if (skipped) st += plural(skipped, "record") + " with a wrong length or text between fields left as they were. ";
        st += "One undo step.";
        [org.w setStatus:ADIFString(st) severity:skipped ? 1 : -1];
    } catch (...) {
        [org.w setStatus:@"Something went wrong sorting the log." severity:2];
    }
}

// Open the window. With `seeded`, the sort keys and field order come from the
// arguments (the Log Table's), else from the last time.
void openOrganize(bool seeded, const std::vector<adif::SortKey> &seedKeys, const std::vector<std::string> &seedFields) {
    if (!org.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Sort and Organize" size:NSMakeSize(760, 600) headline:NO];
        org.w = w;
        org.doSort = ADIFCheckbox(@"Sort the records by:", YES);
        for (size_t i = 0; i < kSortKeys; ++i) {
            org.key[i] = ADIFComboBox(@[], 180);
            org.key[i].placeholderString = i == 0 ? @"e.g. BAND" : @"(optional)";
            org.dir[i] = ADIFPopup(@[ @"Ascending", @"Descending" ]);
            ADIFOnAction(org.key[i], ^{ orgStatus(); });
            ADIFOnAction(org.dir[i], ^{ orgStatus(); });
            [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                              object:org.key[i]
                                                               queue:nil
                                                          usingBlock:^(NSNotification *n) { orgStatus(); }];
        }
        // The usual order in one click (the old Sort Records by Date and Time).
        NSButton *byTime = [NSButton buttonWithTitle:@"Date and Time" target:nil action:nil];
        byTime.toolTip = @"Sort by QSO_DATE, then TIME_ON";
        ADIFOnAction(byTime, ^{
            org.doSort.state = NSControlStateValueOn;
            const char *preset[] = {"QSO_DATE", "TIME_ON", ""};
            for (size_t i = 0; i < kSortKeys; ++i) {
                org.key[i].stringValue = i < 3 ? @(preset[i]) : @"";
                [org.dir[i] selectItemAtIndex:0];
            }
            orgStatus();
        });
        [w addOptionRow:@[ org.doSort, org.key[0], org.dir[0], byTime ]];
        [w addOptionRow:@[ ADIFLabel(@"then by:"), org.key[1], org.dir[1] ]];
        [w addOptionRow:@[ ADIFLabel(@"then by:"), org.key[2], org.dir[2] ]];
        org.doFields = ADIFCheckbox(@"Put the fields of every record in this order:", NO);
        ADIFOnAction(org.doSort, ^{ orgStatus(); });
        ADIFOnAction(org.doFields, ^{ orgStatus(); });
        [w addOptionRow:@[ org.doFields ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"pos", "#", 36}, {"field", "Field", 170}, {"records", "Records", 64},
                                                  {"about", "Description", 420}}
            checkboxes:NO
              sortable:NO];
        [w addButton:@"Move Up" trailing:NO action:^{ orgMove(-1); }];
        [w addButton:@"Move Down" trailing:NO action:^{ orgMove(1); }];
        [w addButton:@"Log Table Order" trailing:NO action:^{
            try {
                NppHandle h = scintilla();
                org.fields = adif::tableColumns(adif::records(adifhost::text(h), lint(h).model));
                orgShow({});
                orgStatus();
            } catch (...) {
            }
        }];
        org.apply = [w addButton:@"Apply" trailing:YES action:^{ orgApply(); }];
        [w setDefaultButton:org.apply];
    }
    std::vector<adif::SortKey> keys = seedKeys;
    if (!seeded) {
        keys.clear();
        std::string saved = setting("organizeSort");
        for (const std::string &k : splitList(saved.empty() ? "QSO_DATE:a,TIME_ON:a" : saved)) {
            size_t colon = k.find(':');
            keys.push_back({k.substr(0, colon), colon != std::string::npos && k.substr(colon + 1) == "d"});
        }
        std::string what = setting("organizeDo");
        org.doSort.state = what.empty() || what.find("sort") != std::string::npos ? NSControlStateValueOn : NSControlStateValueOff;
        org.doFields.state = what.find("fields") != std::string::npos ? NSControlStateValueOn : NSControlStateValueOff;
        org.fields = splitList(setting("organizeFields"));
    } else {
        org.doSort.state = keys.empty() ? NSControlStateValueOff : NSControlStateValueOn;
        org.doFields.state = NSControlStateValueOn;
        org.fields = seedFields;
    }
    for (size_t i = 0; i < kSortKeys; ++i) {
        org.key[i].stringValue = i < keys.size() ? ADIFString(keys[i].field) : @"";
        [org.dir[i] selectItemAtIndex:i < keys.size() && keys[i].descending ? 1 : 0];
    }
    orgRefresh();
    [org.w show];
}

// From the Log Table: its sort and its columns as shown (hidden ones after).
void openOrganizeFromTable() {
    std::vector<adif::SortKey> keys;
    std::string sort = setting("tableSort");
    size_t colon = sort.find(':');
    if (colon != std::string::npos && sort.substr(0, colon) != "#")
        keys.push_back({sort.substr(0, colon), sort.substr(colon + 1) == "d"});
    std::vector<std::string> fields;
    for (size_t c : [table.w columnOrder])
        if (c > 0 && c <= table.columns.size()) fields.push_back(table.columns[c - 1]);
    for (const std::string &f : table.all)
        if (std::find(fields.begin(), fields.end(), f) == fields.end()) fields.push_back(f);
    openOrganize(true, keys, fields);
}
}  // namespace

namespace logtools {

void cmdPotaSpots() {
    if (!spots.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Spots" size:NSMakeSize(1060, 520) headline:NO];
        spots.w = w;
        spots.program = ADIFPopup(@[ @"POTA", @"WWFF", @"More programs (Spothole)" ]);
        spots.program.toolTip = @"Parks on the Air spots from pota.app, World Wide Flora & Fauna spots from spots.wwff.co, or "
                                @"other programs' spots (GMA, WWBOTA, ZLOTA, IOTA, castles, lighthouses...) from spothole.app";
        if (setting("spotsProgram") == "WWFF") [spots.program selectItemAtIndex:kSpotsWwff];
        if (setting("spotsProgram") == "SPOTHOLE") [spots.program selectItemAtIndex:kSpotsSpothole];
        spots.activity = ADIFPopup(@[ @"All programs" ]);
        spots.activity.toolTip = @"Show one program's spots";
        spots.activity.hidden = spots.program.indexOfSelectedItem != kSpotsSpothole;
        ADIFOnAction(spots.activity, ^{
            setSetting("spotsSpotholeProgram", spots.activity.indexOfSelectedItem > 0 ? ADIFStd(spots.activity.titleOfSelectedItem) : "");
            spotsShow();
        });
        ADIFOnAction(spots.program, ^{
            NSInteger i = spots.program.indexOfSelectedItem;
            setSetting("spotsProgram", i == kSpotsSpothole ? "SPOTHOLE" : i == kSpotsWwff ? "WWFF" : "POTA");
            spots.activity.hidden = i != kSpotsSpothole;
            spots.all.clear();
            spots.fetched.clear();
            spots.spothole = false;
            spotsShow();
            // Spothole asks clients not to poll it faster than it reads its sources (2 minutes for POTA).
            if (i != kSpotsSpothole || CFAbsoluteTimeGetCurrent() - spots.lastSpothole >= 115) spotsFetch();
            else [spots.w setStatus:@"Spothole was asked less than 2 minutes ago; its spots come with the next refresh." severity:-1];
        });
        spots.search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        spots.search.placeholderString = @"Filter: call, park, state...";
        spots.search.sendsSearchStringImmediately = YES;
        [spots.search.widthAnchor constraintEqualToConstant:220].active = YES;
        ADIFOnAction(spots.search, ^{ [spots.w setFilter:spots.search.stringValue]; });
        NSMutableArray *bands = [NSMutableArray arrayWithObject:@"All bands"];
        for (const char *b : kSpotBands) [bands addObject:@(b)];
        spots.band = ADIFPopup(bands);
        spots.mode = ADIFPopup(@[ @"All modes", @"SSB", @"CW", @"FT8", @"FT4", @"Other" ]);
        ADIFOnAction(spots.band, ^{ spotsShow(); });
        ADIFOnAction(spots.mode, ^{ spotsShow(); });
        [w addOptionRow:@[ spots.program, spots.activity, spots.search, spots.band, spots.mode ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"time", "UTC", 50}, {"call", "Activator", 90}, {"khz", "kHz", 70},
                                                  {"mode", "Mode", 50}, {"park", "Reference", 84}, {"name", "Name", 230},
                                                  {"loc", "Area / Program", 96}, {"worked", "Worked", 56}, {"lotw", "LoTW", 84},
                                                  {"comments", "Comments", 200}}
            checkboxes:NO
              sortable:YES];
        w.onActivateRow = ^(NSInteger row) { spotsUse(row); };
        w.onSelectionChanged = ^{ spots.use.enabled = [spots.w selectedRows].size() == 1; };
        [w addButton:@"Refresh" trailing:NO action:^{ spotsFetch(); }];
        spots.use = [w addButton:@"Use in New QSO" trailing:YES action:^{
            std::vector<NSInteger> sel = [spots.w selectedRows];
            if (sel.size() == 1) spotsUse(sel[0]);
        }];
        spots.use.enabled = NO;
        [w setDefaultButton:spots.use];
        spots.timer = [NSTimer timerWithTimeInterval:60
                                             repeats:YES
                                               block:^(NSTimer *t) {
                                                   if (!spots.w.window.visible) return;
                                                   // Spothole every 2 minutes, as it asks; POTA and WWFF every minute.
                                                   if (spots.program.indexOfSelectedItem == kSpotsSpothole &&
                                                       CFAbsoluteTimeGetCurrent() - spots.lastSpothole < 115)
                                                       return;
                                                   spotsFetch();
                                               }];
        [[NSRunLoop mainRunLoop] addTimer:spots.timer forMode:NSRunLoopCommonModes];
    }
    [spots.w setTarget:logLine()];
    [spots.w show];
    spotsFetch();
}

void setSpotHandler(void (^handler)(const std::vector<std::pair<std::string, std::string>> &fields)) {
    spots.handler = handler;
}

void cmdLogTable() {
    if (!table.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Log Table" size:NSMakeSize(980, 560) headline:NO];
        table.w = w;
        table.search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        table.search.placeholderString = @"Filter: call, park, mode...";
        table.search.sendsSearchStringImmediately = YES;
        [table.search.widthAnchor constraintEqualToConstant:260].active = YES;
        table.count = ADIFLabel(@"");
        table.count.textColor = NSColor.secondaryLabelColor;
        [w addOptionRow:@[ table.search, table.count ]];
        ADIFOnAction(table.search, ^{
            [table.w setFilter:table.search.stringValue];
            tableUpdateCount();
        });
        w.onSelectionChanged = ^{
            std::vector<NSInteger> sel = [table.w selectedRows];
            if (sel.size() != 1 || table.buffer != buffer() || (size_t)sel[0] >= table.starts.size()) return;
            goTo(scintilla(), table.starts[(size_t)sel[0]], false);
        };
        w.onActivateRow = ^(NSInteger row) {
            if (table.buffer == buffer() && (size_t)row < table.starts.size()) goTo(scintilla(), table.starts[(size_t)row], true);
        };
        w.onEditCell = ^(NSInteger row, size_t column, NSString *text) { tableEdit(row, column, text); };
        // A spreadsheet: keyboard editing, copy and paste, fill down, rows and columns.
        w.spreadsheet = YES;
        w.onCopy = ^{ tableCopy(); };
        w.onPaste = ^(NSString *text) { tablePaste(text); };
        w.onFillDown = ^{ tableFillDown(); };
        w.onClearCells = ^{ tableClearCells(); };
        w.onDeleteRows = ^{ tableDeleteRows(); };
        w.onHeaderMenuOpen = ^(NSInteger column) {
            table.menuColumn = column;
            std::string field = tableField(column);
            table.removeItem.title = field.empty() ? @"Remove Field from Every Record"
                                                   : ADIFString("Remove " + field + " from Every Record");
            table.removeItem.enabled = !field.empty();
        };
        table.addName = ADIFComboBox(@[], 200);
        table.addName.placeholderString = @"e.g. RST_SENT";
        NSButton *addOk = [NSButton buttonWithTitle:@"Add Column" target:nil action:nil];
        NSButton *addCancel = [NSButton buttonWithTitle:@"Cancel" target:nil action:nil];
        ADIFOnAction(addOk, ^{ tableAddField(); });
        ADIFOnAction(addCancel, ^{ table.addRow.hidden = YES; });
        table.addRow = [w addOptionRow:@[ ADIFLabel(@"Add field:"), table.addName, addOk, addCancel ]];
        table.addRow.hidden = YES;
        NSMenu *rowMenu = [[NSMenu alloc] initWithTitle:@"Log Table"];
        NSString *back = [NSString stringWithFormat:@"%C", (unichar)NSBackspaceCharacter];
        auto rowItem = [&](NSString *title, NSString *key, NSEventModifierFlags mods, void (^block)(void)) {
            NSMenuItem *item = [rowMenu addItemWithTitle:title action:nil keyEquivalent:key];
            item.keyEquivalentModifierMask = mods;
            ADIFBlockMenuItem(item, block);
        };
        rowItem(@"Copy", @"c", NSEventModifierFlagCommand, ^{ tableCopy(); });
        rowItem(@"Paste", @"v", NSEventModifierFlagCommand, ^{
            NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
            if (text) tablePaste(text);
        });
        rowItem(@"Fill Down", @"d", NSEventModifierFlagCommand, ^{ tableFillDown(); });
        rowItem(@"Clear Cells", back, 0, ^{ tableClearCells(); });
        rowItem(@"Delete Rows", back, NSEventModifierFlagCommand, ^{ tableDeleteRows(); });
        [rowMenu addItem:NSMenuItem.separatorItem];
        rowItem(@"Add Row", @"", 0, ^{ tableAddRow(); });
        rowItem(@"Add Field...", @"", 0, ^{ tableShowAddField(); });
        rowItem(@"Remove This Column's Field from Every Record", @"", 0, ^{ tableRemoveField(-1); });
        [w setRowMenu:rowMenu];
        w.onSortChanged = ^(NSInteger column, BOOL ascending) {
            std::string field = column == 0 ? "#" : column > 0 && (size_t)column <= table.columns.size() ? table.columns[(size_t)column - 1] : "";
            setSetting("tableSort", field.empty() ? "" : field + (ascending ? ":a" : ":d"));
        };
        // Bands by frequency, dates and times in time order, numbers by value: the order Sort and Organize writes.
        w.compareCells = ^int(size_t column, const std::string &a, const std::string &b) {
            if (column == 0 || column > table.columns.size()) return adif::naturalCompare(a, b);
            return adif::compareFieldValues(table.columns[column - 1], a, b);
        };
        table.menu = [[NSMenu alloc] initWithTitle:@"Columns"];
        table.menu.autoenablesItems = NO;  // the Remove item is enabled for a column's heading only
        [w setHeaderMenu:table.menu];
        [w addButton:@"Bulk Edit Selected..." trailing:NO action:^{ openBulkEdit(false, true); }];
        [w addButton:@"Organize Log..." trailing:NO action:^{ openOrganizeFromTable(); }];
        [w addButton:@"Add Row" trailing:NO action:^{ tableAddRow(); }];
        [w addButton:@"Export CSV..." trailing:NO action:^{
            std::vector<adif::Record> shown;
            for (NSInteger row : [table.w shownRows])
                if ((size_t)row < table.recs.size()) shown.push_back(table.recs[(size_t)row]);
            exportCsv(shown, table.columns, table.w);
        }];
    }
    table.columns.clear();
    tableRefresh();
    [table.w show];
}

void cmdSummary() {
    if (!summary.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Log Summary" size:NSMakeSize(640, 640) headline:NO];
        summary.w = w;
        [w addButton:@"Copy" trailing:NO action:^{
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:summary.w.text forType:NSPasteboardTypeString];
            [summary.w setStatus:@"Copied." severity:-1];
        }];
    }
    summaryRefresh();
    [summary.w show];
}

void cmdActivationTracker() {
    if (!tracker.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Activation Tracker" size:NSMakeSize(940, 480) headline:YES];
        tracker.w = w;
        tracker.program = ADIFPopup(@[ @"POTA", @"WWFF", @"SOTA" ]);
        std::string saved = setting("trackerProgram");
        [tracker.program selectItemAtIndex:saved == "WWFF" ? 1 : saved == "SOTA" ? 2 : 0];
        ADIFOnAction(tracker.program, ^{
            setSetting("trackerProgram", adif::programName(trackerProgram()));
            trackerRefresh();
        });
        [w addOptionRow:@[ ADIFLabel(@"Program:"), tracker.program ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"park", "Reference", 96}, {"date", "UTC Date", 84}, {"station", "Station", 72}, {"qsos", "QSOs", 44},
                       {"need", "Needed", 60}, {"p2p", "P2P", 36}, {"dupes", "Dupes", 46}, {"rejected", "Rejected", 62},
                       {"bands", "Bands", 104}, {"modes", "Modes", 92}, {"first", "First", 56}, {"last", "Last", 56}}
            checkboxes:NO
              sortable:YES];
        w.onActivateRow = ^(NSInteger row) {
            if ((size_t)row < tracker.starts.size()) goTo(scintilla(), tracker.starts[(size_t)row], true);
        };
        [w addButton:@"Export Logs..." trailing:NO action:^{ openPotaExport(trackerProgram()); }];
    }
    trackerRefresh();
    [tracker.w show];
}

void cmdWorkedBefore() {
    if (!worked.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Worked Before" size:NSMakeSize(880, 480) headline:NO];
        worked.w = w;
        worked.folder = ADIFLabel(@"");
        worked.folder.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [worked.folder.widthAnchor constraintLessThanOrEqualToConstant:460].active = YES;
        NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
        ADIFOnAction(choose, ^{
            std::string dir = chooseOpen(@"Choose the folder that holds your ADIF logs", true);
            if (dir.empty()) return;
            setSetting("logsFolder", dir);
            indexRebuild();
            workedRefresh();
        });
        NSButton *rescan = [NSButton buttonWithTitle:@"Rescan" target:nil action:nil];
        ADIFOnAction(rescan, ^{
            indexRebuild();
            workedRefresh();
        });
        [w addOptionRow:@[ ADIFLabel(@"Logs folder:"), worked.folder, choose, rescan ]];
        worked.call = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        worked.call.placeholderString = @"Callsign";
        worked.call.sendsSearchStringImmediately = NO;
        [worked.call.widthAnchor constraintEqualToConstant:200].active = YES;
        ADIFOnAction(worked.call, ^{ workedRefresh(); });
        [w addOptionRow:@[ ADIFLabel(@"Call:"), worked.call, ADIFLabel(@"(portable forms match: VE3/K1ABC/P finds K1ABC)") ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"log", "Log", 200}, {"date", "Date", 84}, {"time", "Time", 64}, {"call", "Call", 100}, {"band", "Band", 50},
                       {"mode", "Mode", 60}, {"mypark", "My Park", 90}, {"park", "Their Park", 90}}
            checkboxes:NO
              sortable:YES];
    }
    [worked.w setTarget:logLine()];
    indexRebuild();
    workedRefresh();
    [worked.w show];
    [worked.w.window makeFirstResponder:worked.call];
}

void cmdBulkEdit() { openBulkEdit(false, false); }
void cmdTimeShift() { openBulkEdit(true, false); }

void cmdOrganize() { openOrganize(false, {}, {}); }

void cmdRemoveDuplicates() {
    if (!dupes.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Remove Duplicates" size:NSMakeSize(860, 480) headline:NO];
        dupes.w = w;
        dupes.window = ADIFTextField(@"2", 44);
        dupes.window.stringValue = @"2";
        [w addOptionRow:@[ ADIFLabel(@"Same CALL, band and mode, starting within"), dupes.window, ADIFLabel(@"minutes") ]];
        dupes.fill = ADIFCheckbox(@"Copy fields only the removed record has (e.g. GRIDSQUARE) to the one kept", YES);
        [w addOptionRow:@[ dupes.fill ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"keep", "Keep", 50}, {"remove", "Remove", 80}, {"call", "Call", 90}, {"date", "Date", 84},
                       {"time", "Time", 64}, {"band", "Band", 50}, {"mode", "Mode", 60}, {"adds", "Adds", 200}}
            checkboxes:YES
              sortable:NO];
        dupes.find = [w addButton:@"Find Duplicates" trailing:NO action:^{ dupesFind(); }];
        dupes.remove = [w addButton:@"Remove Duplicates" trailing:YES action:^{ dupesRemove(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                          object:dupes.window
                                                           queue:nil
                                                      usingBlock:^(NSNotification *n) { dupesClear(@"Settings changed. Find again."); }];
    }
    dupesFind();
    [dupes.w show];
}

void cmdCompareLogs() {
    if (!cmp.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Compare and Merge Logs" size:NSMakeSize(940, 560) headline:NO];
        cmp.w = w;
        cmp.from = ADIFLabel(@"");
        cmp.from.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cmp.from.widthAnchor constraintLessThanOrEqualToConstant:520].active = YES;
        NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
        ADIFOnAction(choose, ^{
            std::string p = chooseOpen(@"Choose the ADIF log to compare with", false);
            if (p.empty()) return;
            cmp.path = p;
            cmpPlan(false);
        });
        [w addOptionRow:@[ ADIFLabel(@"With:"), cmp.from, choose ]];
        cmp.show = ADIFPopup(@[ @"Differences", @"Only in that log", @"Only in this log", @"In both, different", @"The same", @"Everything" ]);
        ADIFOnAction(cmp.show, ^{
            if (cmp.ready) cmpShow(true);
        });
        cmp.replace = ADIFCheckbox(@"Also replace values that differ", NO);
        ADIFOnAction(cmp.replace, ^{ cmpPlan(true); });
        cmp.sort = ADIFCheckbox(@"Sort by date and time afterwards", YES);
        [w addOptionRow:@[ ADIFLabel(@"Show:"), cmp.show, cmp.replace, cmp.sort ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"here", "Here", 50}, {"there", "There", 50}, {"call", "Call", 84}, {"date", "Date", 80},
                                                  {"time", "Time", 56}, {"band", "Band", 50}, {"mode", "Mode", 56},
                                                  {"what", "Difference (here | there)", 360}}
            checkboxes:YES
              sortable:NO];
        w.onTicksChanged = ^{ cmpUpdateButton(); };
        w.onActivateRow = ^(NSInteger row) {  // every difference, and the record in this log
            if (row < 0 || (size_t)row >= cmp.shown.size()) return;
            const adif::CompareRow &c = cmp.rows[cmp.shown[(size_t)row]];
            if (c.here >= 0) {
                NppHandle h = scintilla();
                const adif::LintResult &r = lint(h);
                if ((size_t)c.here < r.model.groups.size()) goTo(h, adif::groupStart(r.model, r.model.groups[(size_t)c.here]), false);
            }
            [cmp.w setStatus:ADIFString(cmpWhat(c)) severity:-1];
        };
        [w addButton:@"Tick All" trailing:NO action:^{
            [cmp.w setAllTicked:YES];
            cmpUpdateButton();
        }];
        [w addButton:@"Untick All" trailing:NO action:^{
            [cmp.w setAllTicked:NO];
            cmpUpdateButton();
        }];
        cmp.apply = [w addButton:@"Apply" trailing:YES action:^{ cmpApply(); }];
        [w setDefaultButton:cmp.apply];
    }
    cmpPlan(false);
    [cmp.w show];
}

void cmdImportWsjtxLog() {
    std::string p = monitor::wsjtxLogPath();
    bool there = [[NSFileManager defaultManager] fileExistsAtPath:ADIFString(p)];
    if (there) cmp.path = p;
    cmdCompareLogs();
    if (!there)
        [cmp.w setStatus:ADIFString("WSJT-X's log isn't at " + ADIFStd(ADIFString(p).stringByAbbreviatingWithTildeInPath) +
                                    " (WSJT-X keeps it there on a Mac). Choose... the wsjtx_log.adi to compare with.")
                severity:1];
}

// ── Export CSV ──

namespace {

struct CsvOut {
    ADIFToolWindow *w = nil;
    NSButton *save = nil;
    std::vector<adif::Record> recs;
    std::vector<std::string> columns;
};
CsvOut csvOut;

// The log's records as the CSV will have them: a column per field, the first 200 rows shown.
void csvOutPlan() {
    if (!csvOut.w) return;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        [csvOut.w setTarget:[@"Log: " stringByAppendingString:ADIFString(documentName())]];
        csvOut.recs = adif::records(adifhost::text(h), r.model);
        csvOut.columns = adif::tableColumns(csvOut.recs);
        std::vector<ADIFToolColumn> cols;
        for (size_t i = 0; i < csvOut.columns.size(); ++i) cols.push_back({std::to_string(i), csvOut.columns[i], 90});
        [csvOut.w setColumns:cols checkboxes:NO sortable:NO];
        std::vector<std::vector<std::string>> rows;
        for (size_t i = 0; i < csvOut.recs.size() && i < 200; ++i) {
            std::vector<std::string> row;
            for (const std::string &c : csvOut.columns) row.push_back(csvOut.recs[i].get(c));
            rows.push_back(std::move(row));
        }
        [csvOut.w setRows:rows severities:std::vector<int>()];
        csvOut.save.enabled = !csvOut.recs.empty();
        [csvOut.w setStatus:csvOut.recs.empty()
                                ? @"This document has no ADIF records to export."
                                : ADIFString(plural(csvOut.recs.size(), "record") + ", " + plural(csvOut.columns.size(), "column") +
                                             (csvOut.recs.size() > 200 ? " (the first 200 shown)" : "") +
                                             ": a column per field, for Numbers or Excel. The Log Table's Export CSV saves "
                                             "its own rows and columns.")
                      severity:-1];
    } catch (...) {
    }
}

}  // namespace

void cmdExportCsv() {
    if (!csvOut.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Export CSV" size:NSMakeSize(860, 480) headline:NO];
        csvOut.w = w;
        [w addOptionRow:@[ ADIFLabel(@"Export:"), families::popup(families::kExport, families::kExportCsv) ]];
        csvOut.save = [w addButton:@"Save CSV..." trailing:YES action:^{ exportCsv(csvOut.recs, csvOut.columns, csvOut.w); }];
        [w setDefaultButton:csvOut.save];
    }
    csvOutPlan();
    [csvOut.w show];
}

void cmdImportCsv() {
    if (!csvIn.w) {
        ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Import CSV" size:NSMakeSize(860, 520) headline:NO];
        csvIn.w = w;
        [w addOptionRow:@[ ADIFLabel(@"Import from:"), families::popup(families::kImport, families::kImportCsv) ]];
        csvIn.from = ADIFLabel(@"");
        csvIn.from.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [csvIn.from.widthAnchor constraintLessThanOrEqualToConstant:480].active = YES;
        NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
        ADIFOnAction(choose, ^{
            std::string p = chooseOpen(@"Choose the CSV file to add from", false, @[ @"csv", @"txt", @"tsv" ]);
            if (p.empty()) return;
            csvIn.path = p;
            csvPlan();
        });
        [w addOptionRow:@[ ADIFLabel(@"From:"), csvIn.from, choose ]];
        csvIn.sort = ADIFCheckbox(@"Sort by date and time afterwards", YES);
        [w addOptionRow:@[ csvIn.sort ]];
        [w setColumns:std::vector<ADIFToolColumn>{{"call", "Call", 90}, {"date", "Date", 84}, {"time", "Time", 64},
                                                  {"band", "Band", 50}, {"mode", "Mode", 60}, {"fields", "Fields", 50}}
            checkboxes:NO
              sortable:NO];
        csvIn.add = [w addButton:@"Add QSOs" trailing:YES action:^{ csvAdd(); }];
    }
    csvPlan();
    [csvIn.w show];
}

void cmdExportCabrillo() {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        std::vector<adif::Record> recs = adif::records(adifhost::text(h), r.model);
        if (!cab.w) {
            ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Export Cabrillo" size:NSMakeSize(900, 600) headline:NO];
            cab.w = w;
            [w addOptionRow:@[ ADIFLabel(@"Export:"), families::popup(families::kExport, families::kExportCabrillo) ]];
            cab.contest = ADIFComboBox(@[], 220);
            cab.contest.placeholderString = @"e.g. ARRL-SS-CW";
            cab.callsign = ADIFTextField(@"your call", 110);
            [w addOptionRow:@[ ADIFLabel(@"Contest:"), cab.contest, ADIFLabel(@"Callsign:"), cab.callsign ]];
            cab.op = ADIFPopup(@[ @"(operator)", @"SINGLE-OP", @"MULTI-OP", @"CHECKLOG" ]);
            cab.power = ADIFPopup(@[ @"(power)", @"HIGH", @"LOW", @"QRP" ]);
            cab.grid = ADIFTextField(@"grid", 80);
            cab.location = ADIFTextField(@"ARRL section or DX", 130);
            [w addOptionRow:@[ ADIFLabel(@"Category:"), cab.op, cab.power, ADIFLabel(@"Grid:"), cab.grid, ADIFLabel(@"Location:"), cab.location ]];
            for (NSControl *c in @[ cab.op, cab.power, cab.contest ]) ADIFOnAction(c, ^{ cabPlan(); });
            [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(NSNotification *n) {
                                                              NSView *v = n.object;
                                                              if ([v isKindOfClass:NSView.class] && v.window == cab.w.window) cabPlan();
                                                          }];
            [w addButton:@"Save..." trailing:YES action:^{
                std::string name = stem(path().empty() ? std::string("log") : documentName()) + ".log";
                std::string dest = chooseSave(ADIFString(name), @[ @"log", @"cbr" ]);
                if (dest.empty()) return;
                std::string error;
                if (!writeFile(dest, cab.log.text, &error)) [cab.w setStatus:ADIFString("Could not save: " + error) severity:2];
                else [cab.w setStatus:ADIFString("Saved " + plural(cab.log.qsos, "QSO") + " to " + fileName(dest) + ".") severity:-1];
            }];
        }
        std::set<std::string> contests;
        std::string grid;
        for (const adif::Record &rec : recs) {
            if (!rec.get("CONTEST_ID").empty()) contests.insert(rec.get("CONTEST_ID"));
            if (grid.empty()) grid = rec.get("MY_GRIDSQUARE");
        }
        [cab.contest removeAllItems];
        for (const std::string &c : contests) [cab.contest addItemWithObjectValue:ADIFString(c)];
        if (!cab.contest.stringValue.length && !contests.empty()) cab.contest.stringValue = ADIFString(*contests.begin());
        if (!cab.callsign.stringValue.length) {
            std::string usual = usualStation(adifhost::text(h), r.model);
            cab.callsign.stringValue = ADIFString(usual.empty() ? setting("stationCall") : usual);
        }
        if (!cab.grid.stringValue.length) cab.grid.stringValue = ADIFString(grid.substr(0, std::min<size_t>(grid.size(), 6)));
        cabPlan();
        [cab.w show];
    } catch (...) {
    }
}

void cmdExportPota() { openPotaExport(tracker.program ? trackerProgram() : adif::Program::POTA); }
void openActivationExport(adif::Program p) { openPotaExport(p); }

void documentChanged() {
    static int64_t token = 0;
    int64_t mine = ++token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (mine != token) return;
        if (tableVisible()) tableRefresh();
        if (summary.w && summary.w.window.visible) summaryRefresh();
        if (tracker.w && tracker.w.window.visible) trackerRefresh();
        bulkClear(@"The log changed. Preview again.");
        dupesClear(@"The log changed. Find Duplicates again.");
        if (cmp.w && cmp.w.window.visible && cmp.ready) cmpPlan(true);
        if (pota.w && pota.w.window.visible) potaPlan();
        if (spots.w && spots.w.window.visible && !spots.all.empty()) spotsShow();
        if (org.w && org.w.window.visible) orgRefresh();
        if (csvOut.w && csvOut.w.window.visible) csvOutPlan();
    });
}

void bufferActivated() { documentChanged(); }

std::string workedBefore(const std::string &call) {
    if (logsFolder().empty()) return "";
    if (idx.folder != logsFolder() || [NSDate date].timeIntervalSince1970 - idx.builtAt > 120) indexRebuild();
    if (idx.folder != logsFolder()) return "";
    std::vector<adif::WorkedHit> hits = indexLookup(call);
    return adif::workedSummary(adif::lookupCall(call), hits);
}

// Contacts naming `ref`: this log (unsaved changes included) and the indexed folder (the active file left out).
static std::vector<adif::WorkedHit> referenceHits(const std::string &ref) {
    std::vector<adif::WorkedHit> hits;
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        for (adif::Contact &c : adif::contacts(adifhost::text(h), r.model)) hits.push_back({documentName(), std::move(c)});
    } catch (...) {
    }
    std::string active = path();
    for (const auto &log : idx.logs)
        if (log->path != active)
            for (const adif::Contact &c : log->contacts)
                if (!c.theirRefs.empty()) hits.push_back({log->name, c});
    return hits;
}

std::string referenceLine(const std::string &ref) {
    if (ref.empty()) return "";
    if (!logsFolder().empty() && idx.folder != logsFolder()) indexRebuild();
    return adif::referenceSummary(ref, adif::referenceHistory(ref, referenceHits(ref)));
}

void setIndexListener(void (^listener)(void)) {
    idx.listener = listener;
}

}  // namespace logtools

namespace {

void openPotaExport(adif::Program program) {
    try {
        NppHandle h = scintilla();
        const adif::LintResult &r = lint(h);
        if (!pota.w) {
            ADIFToolWindow *w = [[ADIFToolWindow alloc] initWithTitle:@"Export Activation Logs" size:NSMakeSize(900, 500) headline:NO];
            pota.w = w;
            [w addOptionRow:@[ ADIFLabel(@"Export:"), families::popup(families::kExport, families::kExportActivations) ]];
            pota.program = ADIFPopup(@[ @"POTA", @"WWFF", @"SOTA" ]);
            ADIFOnAction(pota.program, ^{ potaPlan(); });
            [w addOptionRow:@[ ADIFLabel(@"Program:"), pota.program ]];
            pota.station = ADIFTextField(@"e.g. K1ABC", 120);
            [w addOptionRow:@[ ADIFLabel(@"Callsign for records without STATION_CALLSIGN or OPERATOR:"), pota.station ]];
            pota.folder = ADIFLabel(@"");
            pota.folder.lineBreakMode = NSLineBreakByTruncatingMiddle;
            [pota.folder.widthAnchor constraintLessThanOrEqualToConstant:460].active = YES;
            NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:nil action:nil];
            ADIFOnAction(choose, ^{
                std::string dir = chooseOpen(@"Choose the folder for the activation logs", true);
                if (dir.empty()) return;
                setSetting("potaFolder", dir);
                potaPlan();
            });
            [w addOptionRow:@[ ADIFLabel(@"Save to:"), pota.folder, choose ]];
            [w setColumns:std::vector<ADIFToolColumn>{{"file", "File", 250}, {"park", "Reference", 100}, {"date", "UTC Date", 84}, {"records", "Records", 60},
                           {"qsos", "QSOs", 48}, {"notes", "Notes", 300}}
                checkboxes:YES
                  sortable:NO];
            pota.save = [w addButton:@"Save Files" trailing:YES action:^{ potaSave(); }];
            [w setDefaultButton:pota.save];
            [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidChangeNotification
                                                              object:pota.station
                                                               queue:nil
                                                          usingBlock:^(NSNotification *n) { potaPlan(); }];
        }
        [pota.program selectItemAtIndex:program == adif::Program::WWFF ? 1 : program == adif::Program::SOTA ? 2 : 0];
        std::string station = setting("potaStation");
        if (station.empty()) station = setting("stationCall");  // Settings: Your Station
        std::string usual = usualStation(adifhost::text(h), r.model);
        pota.station.stringValue = ADIFString(usual.empty() ? station : usual);
        potaPlan();
        [pota.w show];
    } catch (...) {
    }
}

}  // namespace
