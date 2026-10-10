// Network work: QRZ.com XML and HamQTH callbook clients, the LoTW confirmation
// report, POTA spots, uploads to QRZ.com Logbook, Club Log and eQSL, and
// Keychain storage for every service's credentials.
//
// Credentials are kept in the login Keychain (generic password items named
// "ADIF Lint: <source>"), never in ADIFLint.ini. All requests use HTTPS.
//
// Tests set ADIFLINT_FAKE_LOOKUP_DIR: responses are then read from
// <dir>/qrz/<CALL>.xml, <dir>/hamqth/<CALL>.xml and <dir>/lotw/lotwreport.adi
// instead of the network, and credentials live in memory instead of the
// Keychain (every source starts with a "TEST" account).
#pragma once

#import <Foundation/Foundation.h>

#include "adif_import.h"

#include <map>
#include <string>

typedef NS_ENUM(NSInteger, ADIFSource) {
    ADIFSourceQRZ = 0,         // callbook (Enrich)
    ADIFSourceHamQTH = 1,      // callbook (Enrich)
    ADIFSourceLoTW = 2,        // your QSOs and confirmations (Import)
    ADIFSourceQRZLogbook = 3,  // upload: the logbook's API key
    ADIFSourceClubLog = 4,     // upload: account email and Application Password
    ADIFSourceClubLogKey = 5,  // upload: Club Log API key for this program
    ADIFSourceEQSL = 6,        // upload: eQSL username and password
    ADIFSourceTqsl = 7,        // upload: the TQSL callsign certificate's password, if it has one
    ADIFSourceCountryData = 8, // Enrich only: AD1C's country file, offline (no account)
};
static const NSInteger ADIFSourceCount = 8;  // the sources with an account in Settings

// What a source signs in with.
typedef NS_ENUM(NSInteger, ADIFCredentialKind) {
    ADIFCredentialAccount,  // username + password
    ADIFCredentialAPIKey,   // a single key
};

NSString *ADIFSourceName(ADIFSource source);         // "QRZ.com", "HamQTH", "LoTW"
ADIFCredentialKind ADIFSourceCredentialKind(ADIFSource source);
NSString *ADIFSourceCredentialHelp(ADIFSource source);  // what to enter, for the Settings window
NSString *ADIFSourceUserLabel(ADIFSource source);       // "Username" or "Email"
NSString *ADIFSourceSecretLabel(ADIFSource source);     // "Password" or "API key"
BOOL ADIFSourceCanTest(ADIFSource source);              // a sign-in test exists
BOOL ADIFLookupFakeMode(void);

// Keychain: one credential per source.
NSString *ADIFSavedAccount(ADIFSource source);  // username (or "API key"); nil if none saved
BOOL ADIFHasSecret(ADIFSource source);
BOOL ADIFSaveCredential(ADIFSource source, NSString *user, NSString *secret, NSString **error);
BOOL ADIFDeleteCredential(ADIFSource source);

// Try the saved credential against the service. Completion on the main queue.
void ADIFTestCredential(ADIFSource source, void (^done)(BOOL ok, NSString *message));

typedef void (^ADIFCallbookDone)(BOOL found, const std::map<std::string, std::string> &raw, NSString *error, BOOL fatal);

// One client per Enrich run: keeps the session and a cache of answers.
@interface ADIFCallbookClient : NSObject
- (instancetype)initWithSource:(ADIFSource)source agent:(NSString *)agent;
// Completion runs on the main queue. `fatal` means stop (bad login, service down).
- (void)lookup:(NSString *)call completion:(ADIFCallbookDone)done;
@property(nonatomic, readonly) NSString *notice;  // a message from the service to show the user
@end

// Current POTA activator spots from https://api.pota.app/spot/activator (a JSON
// array of objects). In test mode, <ADIFLINT_FAKE_LOOKUP_DIR>/pota/spots.json.
// Completion on the main queue: the objects (NSDictionary only) or an error.
void ADIFFetchPotaSpots(NSString *agent, void (^done)(NSArray<NSDictionary *> *spots, NSString *error));

// ── Uploads (completion on the main queue) ──────────────────────────────────

// QRZ.com Logbook: one INSERT with the saved API key. `reply` is the body ("RESULT=OK&LOGID=...").
void ADIFQrzLogbookInsert(NSString *agent, NSString *adi, BOOL replace, void (^done)(NSString *reply, NSString *error));
// TQSL's certificate password, or nil (for tqsl -p).
NSString *ADIFTqslPassword(void);

// Club Log putlogs.php: the saved email, Application Password and API key; `status` is the HTTP code.
void ADIFClubLogUpload(NSString *agent, NSString *callsign, NSString *adiFile, NSString *fileName,
                       void (^done)(NSInteger status, NSString *message, NSString *error));
// eQSL ImportADIF.cfm: the saved username and password; `reply` is the returned page.
void ADIFEqslUpload(NSString *agent, NSString *adiFile, NSString *fileName, void (^done)(NSString *reply, NSString *error));

// ── Imports, spots and data downloads (completion on the main queue) ────────

// Your QSOs from a site, as one ADIF text, for QSO dates `from` to `to`
// (YYYYMMDD; empty for all): LoTW (uploaded QSOs, confirmed or not), QRZ.com
// Logbook (every record) or the eQSL InBox (eQSLs others sent you). Test mode:
// <fake dir>/lotw/lotwreport.adi, qrzlog/fetch.txt, eqsl/inbox.adi.
void ADIFDownloadSiteQsos(adif::ImportSite site, NSString *from, NSString *to, void (^done)(NSString *adif, NSString *error));
// WWFF spots from https://spots.wwff.co/static/spots.json (WWFF asks for no more than
// one fetch every 30 seconds). Test mode: <fake dir>/wwff/spots.json.
void ADIFFetchWwffSpots(NSString *agent, void (^done)(NSArray<NSDictionary *> *spots, NSString *error));
// Spothole (spothole.app, API v3): spots from many programs at once. Its conditions of use
// (spothole.app/help/usage/clients#terms, read 2026-10-10): identify the software, poll at a
// sensible rate (it reads POTA every 2 minutes, so no faster than that), expect downtime,
// check for API changes now and then. No QRZ.com or HamQTH login is ever sent to it.
// The programs it knows (GET /api/v3/options, "activities"). Test mode: <fake dir>/spothole/options.json.
void ADIFFetchSpotholePrograms(NSString *agent, void (^done)(NSArray<NSDictionary *> *programs, NSString *error));
// Spots of these programs (comma-separated names), not QRT, from the last hour (GET /api/v3/spots).
// Test mode: <fake dir>/spothole/spots.json.
void ADIFFetchSpotholeSpots(NSString *agent, NSString *programs, void (^done)(NSArray<NSDictionary *> *spots, NSString *error));
// ARRL's LoTW user activity list, https://lotw.arrl.org/lotw-user-activity.csv (about 6 MB).
// Test mode: <fake dir>/lotw/lotw-user-activity.csv.
void ADIFDownloadLotwUsers(NSString *agent, void (^done)(NSData *body, NSString *error));
// The newest Big CTY cty.csv from www.country-files.com: the release list's first
// bigcty-*.zip, unzipped. `release` is its name ("bigcty-20260915").
// Test mode: <fake dir>/cty/cty.csv.
void ADIFDownloadCountryData(NSString *agent, void (^done)(NSString *ctyCsv, NSString *release, NSString *error));
