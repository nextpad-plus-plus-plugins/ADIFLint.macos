// The Import..., Export... and Upload... menu items. Each opens the window of
// its family used last; a popup at the top of every family window switches to a
// sibling (Import from: LoTW, QRZ.com Logbook, eQSL, CSV file, WSJT-X log), which opens
// where this one was.
#pragma once

#import <Cocoa/Cocoa.h>

namespace families {

enum Family { kImport, kExport, kUpload };

// Members, in popup order.
enum { kImportLotw, kImportQrzLogbook, kImportEqsl, kImportCsv, kImportWsjtx };
enum { kExportActivations, kExportCsv, kExportCabrillo, kExportLabels };
enum { kUploadQrz, kUploadLotw, kUploadClubLog, kUploadEqsl };

// The popup for the first option row of a family window; `current` is this window's member.
NSPopUpButton *popup(Family f, NSInteger current);

void cmdImport();
void cmdExport();

}  // namespace families
