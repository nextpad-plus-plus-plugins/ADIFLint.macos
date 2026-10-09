// Check Log: every problem in the log in one list, with the known repairs
// (MODE USB → MODE SSB, SUBMODE USB; 2026-10-06 → 20261006...) applied together
// as one undo step.
#pragma once

namespace checklog {

void cmdCheckLog();
void documentChanged();  // the active document changed or another became active

}  // namespace checklog
