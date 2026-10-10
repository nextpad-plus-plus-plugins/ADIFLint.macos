// Print QSL Labels (Export... → QSL labels): a label per station for the cards
// to send, saved as a PDF to print on an Avery sheet, then QSL_SENT Y on request.
// The ADIF work is in src/core/adif_labels.
#pragma once

namespace labels {

void cmdQslLabels();
void documentChanged();  // the log changed or another became active

}  // namespace labels
