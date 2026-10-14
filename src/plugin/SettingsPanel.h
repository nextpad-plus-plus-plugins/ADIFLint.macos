// ADIF Lint Settings: your station, editor options, keyboard shortcuts, the
// country data, and accounts and API keys for the online services, stored in
// the macOS Keychain (see Lookup.h).
// AppKit and Foundation only.
#pragma once

#import <Cocoa/Cocoa.h>

@interface ADIFSettingsPanel : NSObject <NSWindowDelegate>

@property(nonatomic, readonly) NSPanel *window;
// A credential was saved or removed for this source.
@property(nonatomic, copy) void (^onChanged)(NSInteger source);

// The country data section: Update downloads AD1C's newest country file.
@property(nonatomic, copy) void (^onCountryUpdate)(void);
- (void)setCountryStatus:(NSString *)text ok:(BOOL)ok;

// LoTW Users: show who uploads to LoTW (a checkbox), Update, and a status line.
@property(nonatomic, copy) void (^onLotwUsersToggled)(BOOL on);
@property(nonatomic, copy) void (^onLotwUsersUpdate)(void);
- (void)setLotwUsersOn:(BOOL)on status:(NSString *)text ok:(BOOL)ok;

// IOTA Groups: Download fetches IOTA's group list for the Map's IOTA overlay, and a status line.
@property(nonatomic, copy) void (^onIotaUpdate)(void);
- (void)setIotaStatus:(NSString *)text ok:(BOOL)ok;

// Your station: the callsign and grid New QSO and the exports use when a log has none,
// and the folder of logs Worked Before searches.
@property(nonatomic, copy) void (^onStationSave)(NSString *call, NSString *grid);
@property(nonatomic, copy) void (^onChooseLogsFolder)(void);
@property(nonatomic, copy) void (^onStationProfiles)(void);  // Station Profiles... pressed
- (void)setStationCall:(NSString *)call grid:(NSString *)grid logsFolder:(NSString *)folder;
- (void)setStationStatus:(NSString *)text ok:(BOOL)ok;

// Editor options, by index: 0 validate while typing, 1 colour, 2 autocomplete, 3 count characters.
@property(nonatomic, copy) void (^onEditorOption)(NSInteger option, BOOL on);
- (void)setEditorValidate:(BOOL)validate colour:(BOOL)colour autocomplete:(BOOL)autocomplete characters:(BOOL)characters;

- (void)showWelcome;                   // first run: a welcome, and Your Station at the top
- (void)showSource:(NSInteger)source;  // show the window with that source's first field focused (-3: country data)
- (void)refresh;                       // reload what is saved

@end
