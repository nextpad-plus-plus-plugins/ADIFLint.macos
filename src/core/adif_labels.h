// QSL labels: which QSOs need a card, one label per station listing its QSOs,
// the label sheets, and marking the cards sent.
//
// ADIF 3.1.7: QSL_SENT R (requested), Q (queued), Y (sent); QSLSDATE the date
// sent; QSL_VIA the manager or bureau to route the card through.
// Avery 5160 (US Letter, 3 x 10, 2.625 x 1 in, 0.5 in top, 3/16 in sides, 2.75 in
// across): as several published template guides give it (checked 2026-10-10).
// Avery 5163 (2 x 5, 4 x 2 in) and L7163 (A4, 2 x 7, 99.1 x 38.1 mm): margins
// from the sheet's size, the labels centred; every value can be changed, and a
// plain-paper test print is the check.
#pragma once

#include "adif_lint.h"
#include "adif_tools.h"

#include <string>
#include <string_view>
#include <vector>

namespace adif {

struct LabelQso {
    int group = -1;
    std::string date, time, band, mode, rst;  // as printed: 2026-10-09, 1230, 20m, SSB, 59
};

struct QslLabel {
    std::string call, via;  // CALL, and QSL_VIA when the record has it
    std::vector<LabelQso> qsos;
};

// Records whose card is to be sent: QSL_SENT R or Q.
std::vector<int> qslWanted(std::string_view text, const DocModel &m);

// Labels for these records: one per station (CALL, and QSL_VIA), its QSOs in
// date order, `perLabel` QSOs at most on one label (more make another label).
std::vector<QslLabel> qslLabels(std::string_view text, const DocModel &m, const std::vector<int> &groups, size_t perLabel);

// A label's lines: "To: K1ABC via W1XX", a QSO per line ("2026-10-09 1230Z 20m SSB 59"), then
// the closing ("TNX QSO 73 de KW9D").
std::vector<std::string> labelLines(const QslLabel &label, std::string_view myCall, std::string_view closing);

struct LabelSheet {
    std::string name;
    double pageWidth = 0, pageHeight = 0;  // points (1/72 in)
    int columns = 0, rows = 0;
    double width = 0, height = 0;          // one label
    double top = 0, left = 0;              // first label's corner from the page's top left
    double across = 0, down = 0;           // from one label's corner to the next
    size_t perLabel = 0;                   // QSOs that fit
};
const std::vector<LabelSheet> &labelSheets();  // Avery 5160, 5163, L7163
// Where label `index` (0-based, row by row) sits on its page: top-left corner in points.
void labelPosition(const LabelSheet &s, size_t index, double *x, double *y);

// QSL_SENT Y and QSLSDATE `today` (YYYYMMDD) for these records.
std::vector<CellChange> qslSentChanges(const std::vector<int> &groups, std::string_view today);

}  // namespace adif
