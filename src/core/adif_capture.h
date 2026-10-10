// QSOs other programs announce over the network or append to a file: the
// payloads, parsed into ADIF fields. No sockets here; Monitor.mm listens.
//
// Formats (checked 2026-10-09/10):
//   WSJT-X UDP (WSJT-X, JTDX, JS8Call): Network/NetworkMessage.hpp, github.com/WSJTX/wsjtx
//     967c85a. Big endian; header quint32 magic 0xadbccbda, quint32 schema; then quint32
//     type and utf8 Id. utf8 = quint32 length + bytes (0xffffffff: null). QDateTime =
//     qint64 Julian day, quint32 ms since midnight, quint8 timespec (2: + qint32 offset).
//     Type 5 "QSO Logged": DateTimeOff, DX call, DX grid, quint64 Tx Hz, Mode, Report sent,
//     Report received, Tx power, Comments, Name, DateTimeOn, Operator call, My call,
//     My grid, Exchange sent, Exchange received, ADIF Propagation mode.
//     Type 12 "Logged ADIF": utf8 ADIF text, a valid ADIF file with one record.
//   ADIF over UDP or TCP: WSJT-X's "Secondary UDP Server" (a bare record + " <eor>"),
//     GridTracker logging to N1MM (bare ADIF) or Log4OM ("ADD " + ADIF); fldigi 4.2.05+
//     and HRD QSO Forwarding by second-hand accounts (HRD's format is undocumented).
//   N1MM Logger+ XML (n1mmwp.hamdocs.com, External UDP Broadcasts): <contactinfo>,
//     <contactreplace>, <contactdelete>; rxfreq/txfreq in 10 Hz units; ID a GUID in hex.
//   JS8Call's API (mainwindow.cpp acceptQSO, github.com/js8call/js8call master, read
//     2026-10-10): JSON {"type":"LOG.QSO","value":"<ADIF record>","params":{...}} over UDP
//     or TCP; its N1MM broadcast sends the ADIF record + " <eor>" over UDP.
//   Commands to loggers over TCP, as GridTracker sends them (package.nw/lib/adif.js,
//     gitlab.com/gridtracker.org/gridtracker master, read 2026-10-10): DXKeeper
//     "<command:3>log<parameters:N><CALL:4>K1AB ... <EOR>\r\n"; HRD Logbook
//     "ver\rdb add {CALL="K1AB" FREQ="14074000" ...}\rexit\r", FREQ with its point removed.
#pragma once

#include "adif_edit.h"
#include "adif_lint.h"
#include "adif_profiles.h"

#include <string>
#include <string_view>
#include <vector>

namespace adif {

struct CapturedQso {
    enum class Kind { Add, Replace, Delete };
    Kind kind = Kind::Add;
    std::string source;   // "WSJT-X", "N1MM Logger+", "ADIF over UDP"...
    std::string id;       // the sender's own id for the QSO (N1MM's GUID), or ""
    FieldList fields;     // upper-case names, values as they should be written
    std::string problem;  // why it can't be logged (no CALL...), or ""
    int wsjtxType = 0;    // 5 or 12 for WSJT-X messages
    std::string client;   // WSJT-X: the sender's Id ("WSJT-X", "JTDX", a --rig-name...)
};

// A WSJT-X message: QSO Logged (5) and Logged ADIF (12) become QSOs; any other type, or
// bytes too short, give none. *isWsjtx: the magic number was there.
std::vector<CapturedQso> parseWsjtxMessage(std::string_view bytes, bool *isWsjtx = nullptr);

// ADIF text: one or more records, a header optional, text before the first '<' ignored
// ("ADD <call:4>..."), <EOR> in any case. A trailing record without <EOR> is used too.
std::vector<CapturedQso> parseAdifPayload(std::string_view text, std::string_view source);

// N1MM Logger+ XML; an ID becomes APP_N1MM_ID so a later replace or delete finds the QSO.
std::vector<CapturedQso> parseN1mmXml(std::string_view text);

// JS8Call's JSON API message: LOG.QSO gives its ADIF record; other types give none.
std::vector<CapturedQso> parseJs8Json(std::string_view text);

// A command sent to a logger over TCP (DXKeeper or HRD form), or plain ADIF.
std::vector<CapturedQso> parseLoggerCommand(std::string_view text);

// Whatever arrived: WSJT-X binary, JS8Call JSON, N1MM XML, a logger command or ADIF, by its first bytes.
std::vector<CapturedQso> parseCapture(std::string_view bytes, std::string_view sourceHint);

// What a logger expects: names upper case, CALL upper case, FREQ in MHz, BAND from FREQ
// when missing, a MODE that is really a submode split (FT4 → MFSK + FT4, USB → SSB +
// USB), dates and times as digits, empty values dropped. Sets *problem when CALL,
// QSO_DATE, TIME_ON or BAND/FREQ is missing.
void normalizeCaptured(FieldList &fields, std::string *problem);

// ── Writing captured QSOs into a log ──

struct CaptureFormat {
    std::string eol = "\n";
    LengthUnit unit = LengthUnit::Characters;
    bool utf8 = true;
    std::string programVersion, timestamp;  // for the header of a new log
};
enum class CaptureResult { Added, Replaced, Deleted, Duplicate, NotFound };
struct CaptureOutcome {
    CaptureResult result = CaptureResult::Added;
    int record = 0;  // the record added, replaced, deleted or already there (1-based)
};

// Why records can't be added to this log ("" when they can): broken structure, a
// record without <EOR>, text that isn't ADIF. Blank text can take them (it gets a header).
std::string captureRefusal(std::string_view text, const LintResult &r);
// Apply captured QSOs to a log's text, in order: adds (not a QSO the log already has:
// same CALL, band and mode within 2 minutes), and N1MM's replaces and deletes found by
// APP_N1MM_ID (a replace keeps the record's other fields; one not found is added).
// False, with *why, when the log can't take them; the text is then unchanged.
bool applyCaptured(std::string &text, const std::vector<CapturedQso> &qsos, const CaptureFormat &fmt,
                   std::vector<CaptureOutcome> *outcomes, std::string *why);
// The one edit turning `before` into `after`: their common start and end are kept.
TextEdit minimalEdit(std::string_view before, std::string_view after);

// The Monitor's queue (QSOs waiting for their log), kept as an ADIF file: APP_ADIFLINT_ACTION
// (REPLACE, DELETE) and APP_ADIFLINT_SOURCE ride along and are taken off again.
std::string queueText(const std::vector<CapturedQso> &qsos, std::string_view programVersion, std::string_view timestamp);
std::vector<CapturedQso> parseQueue(std::string_view text);

// A WSJT-X utf8 string or a QSO Logged message, for tests and for senders.
std::string wsjtxString(std::string_view s);
std::string wsjtxLoggedAdif(std::string_view id, std::string_view adif);
std::string wsjtxQsoLogged(std::string_view id, const FieldList &qso);  // from ADIF fields (QSO_DATE, TIME_ON...)

}  // namespace adif
