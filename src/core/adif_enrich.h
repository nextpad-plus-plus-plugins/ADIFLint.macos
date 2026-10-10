// Enriching a log with data from callbooks (QRZ.com XML, HamQTH) and country
// data, and the rules Import (adif_import.h) shares: which changes to offer and
// how to edit. Pure C++17: the plugin fetches and parses the responses, this
// code turns them into ADIF fields, decides what to offer, and builds the edits.
//
// Sources and their fields (checked 2026-10-07):
//   QRZ.com XML interface 1.34, https://www.qrz.com/XML/current_spec.html
//   HamQTH XML API 2.8, https://www.hamqth.com/developers.php
//   LoTW mode groups (CW, phone, data), https://lotw.arrl.org/lotw-help/key-concepts/
#pragma once

#include "adif_edit.h"
#include "adif_lint.h"

#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace adif {

using FieldMap = std::map<std::string, std::string>;  // ADIF field name (upper case) -> value

// Callbook responses as element name -> text (names as in the XML, any case).
// Values must already be ASCII; anything else is dropped (ADI is ASCII only).
FieldMap mapQrz(const std::map<std::string, std::string> &raw);
FieldMap mapHamQth(const std::map<std::string, std::string> &raw);

// The callsign to look up: "VE3/K1ABC/P" -> "K1ABC".
std::string lookupCall(std::string_view call);
// A prefix or suffix ("K1ABC/P", "VE3/K1ABC"): the station may not be at home.
bool isPortableCall(std::string_view call);
// Fields that describe where the station is: grid, state, county, QTH, lat/lon,
// DXCC, country, zones, IOTA, continent.
bool isLocationField(std::string_view field);
// Decimal degrees -> ADIF Location "XDDD MM.MMM" (§III.A), e.g. 34.23456 -> "N034 14.074".
std::string adifLocation(double degrees, bool latitude);

// QSO_DATE + TIME_ON -> minutes since 1970, or -1 when malformed.
long qsoMinutes(std::string_view date, std::string_view time);
// LoTW's mode groups: 0 CW, 1 phone (SSB, AM, FM, DIGITALVOICE), 2 everything else (data).
int modeGroup(std::string_view mode);

struct EnrichChange {
    int group = -1;         // index into DocModel::groups
    int record = 0;         // 1-based record number, for display
    std::string call;
    std::string field;      // upper case
    std::string current;    // the record's value now; empty when the field is missing
    std::string value;      // the value to write
    bool replace = false;   // the field exists and would change
    bool accepted = true;   // ticked in the review
    std::string note;       // why it is offered, for the review
};

struct EnrichOptions {
    std::vector<std::string> fields;      // ADIF fields that may be filled
    bool perQsoData = false;              // the data describes this QSO (an import, the prefix), not the station's home
    bool skipLocationAwayFromHome = true; // callbooks: no location for portable calls or park-to-park records
    bool proposeReplacements = false;     // also offer (unticked) values that differ from the record's
};

// True when the record's station was probably not at home: a portable call, or
// SIG_INFO / POTA_REF / SOTA_REF / WWFF_REF set (e.g. park-to-park).
bool awayFromHome(std::string_view text, const DocModel &m, const ModelGroup &g);

// Offer changes for one record (DocModel group) from the data found for it.
void proposeChanges(std::string_view text, const DocModel &m, int group, const FieldMap &data, const EnrichOptions &opt,
                    const std::string &note, std::vector<EnrichChange> &out);

// Edits for the accepted changes, against the text the model came from: new
// fields go in one insertion at each record's end (matching its separator),
// replacements are rewritten in place. Sorted and non-overlapping.
std::vector<TextEdit> enrichmentEdits(std::string_view text, const DocModel &m, const std::vector<EnrichChange> &changes,
                                      LengthUnit unit, bool utf8);

}  // namespace adif
