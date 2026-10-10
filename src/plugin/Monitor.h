// Monitor: QSOs other programs log, captured as they announce them on this Mac
// (WSJT-X, JTDX and JS8Call over UDP; plain ADIF over UDP from WSJT-X's secondary
// server, Log4OM, fldigi or HRD's QSO forwarding; N1MM Logger+ XML; GridTracker's
// DXKeeper and HRD log commands over TCP) or appended to a log file they keep, and
// added to the log you choose. It only listens: it never sends anything.
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>

namespace monitor {

void cmdMonitor();           // the Monitor window
void startIfWanted();        // NPPN_READY: start when "Start when Nextpad++ starts" is on
void documentActivated();    // NPPN_BUFFERACTIVATED: queued QSOs go into the chosen log once it's active
void shutdown();             // NPPN_SHUTDOWN: close every socket and file watch
std::string wsjtxLogPath();  // WSJT-X's own log, wsjtx_log.adi

}  // namespace monitor
