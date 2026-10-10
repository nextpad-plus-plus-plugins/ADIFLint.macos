// What ADIFLint.mm (the editor glue) offers the other plugin files: the active
// document, its lint result, edits as one undo step, and saved settings.
#pragma once

#include "NppPluginInterfaceMac.h"
#include "adif_edit.h"
#include "adif_lint.h"

#include <string>
#include <string_view>
#include <vector>

namespace adifhost {

NppHandle scintilla();  // the active view
intptr_t sci(NppHandle h, uint32_t msg, uintptr_t wp = 0, intptr_t lp = 0);
intptr_t buffer();                // the active buffer id
std::string path();               // the active document's full path ("" when untitled)
std::string documentName();       // its file name, or "an untitled document"
std::string_view text(NppHandle h);
bool utf8(NppHandle h);
adif::LengthUnit lengthUnit();
std::string eol(NppHandle h);
std::string utcNow(const char *strftimeFormat);

// The lint result (with model) for the active document, re-linted if it changed.
const adif::LintResult &lint(NppHandle h);
// Treat the active buffer as ADIF (any extension) and re-check it now.
void validate(NppHandle h);
// Apply sorted, non-overlapping edits as one undo step, then re-check.
void apply(NppHandle h, const std::vector<adif::TextEdit> &edits);
bool readOnly(NppHandle h);
void fixLengths();  // Fix Lengths on the active document (the menu command)
void showTip(NppHandle h, const std::string &text);  // a call tip at the caret
void goTo(NppHandle h, size_t pos, bool focus);  // caret to pos, scrolled into view; focus: make the editor key

// The plugin config folder (where ADIFLint.ini is); "" when the host has none.
std::string configDir();

// Settings kept in ADIFLint.ini next to the plugin's own.
std::string setting(const std::string &key);
void setSetting(const std::string &key, const std::string &value);

void openSettings(long source);  // the Settings window, at a source's section (-1: top)

// Open a file in Nextpad++ (it opens asynchronously); with newQso, New QSO opens on it
// once it is the active document. False when the host refused.
bool openFile(const std::string &path, bool newQso);
// The paths of the files open in Nextpad++ (untitled tabs aren't listed). *known is
// false when the host doesn't say (an older Nextpad++): then nothing can be ruled out.
std::vector<std::string> openFiles(bool *known);
void openNewQso();      // New QSO on the active document
void stationChanged();  // the station profile or activation changed: New QSO follows

}  // namespace adifhost
