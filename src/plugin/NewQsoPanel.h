// The New QSO window: one row per field, a status column, Log QSO and Close.
//
// AppKit only, like RecordPanel: ADIFLint.mm supplies the rows, checks the
// values whenever they change, and appends the record when Log QSO is pressed.
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>
#include <utility>
#include <vector>

struct ADIFQsoRow {
    std::string name;                  // upper case
    std::string value;
    std::string description;           // tooltip
    std::vector<std::string> choices;  // values to offer (empty: free text)
    bool required = false;
};

@interface ADIFNewQsoPanel : NSObject <NSWindowDelegate, NSTextFieldDelegate, NSComboBoxDelegate>

@property(nonatomic, readonly) NSPanel *window;
@property(nonatomic, copy) void (^onChange)(void);  // any value edited
@property(nonatomic, copy) void (^onLog)(void);     // Log QSO pressed
@property(nonatomic, copy) void (^onCustomize)(void);  // Fields... pressed
@property(nonatomic, copy) void (^onSpots)(void);      // Spots... pressed
@property(nonatomic, copy) void (^onContest)(void);    // Contest... pressed
// Look up the call as you type: 0 off, 1 country data (offline), 2 QRZ.com, 3 HamQTH.
@property(nonatomic) NSInteger lookupSource;
@property(nonatomic, copy) void (^onLookupChanged)(NSInteger source);
// The Station popup: index 0 is the log's own station fields, then the profiles,
// then "Edit Profiles..." (onStationChosen gets -1 for that).
@property(nonatomic, copy) void (^onStationChosen)(NSInteger index);
- (void)setStations:(NSArray<NSString *> *)names selected:(NSInteger)index;
@property(nonatomic, readonly) BOOL useCurrentTime; // fill QSO_DATE/TIME_ON at the moment of logging
@property(nonatomic) NSInteger timeDigits;          // 4 (HHMM) or 6 (HHMMSS)

- (void)setRows:(const std::vector<ADIFQsoRow> &)rows;
- (std::vector<std::pair<std::string, std::string>>)values;  // in row order
- (std::string)valueForField:(const std::string &)name;
- (void)setValue:(const std::string &)value forField:(const std::string &)name;
- (void)setChoices:(const std::vector<std::string> &)choices forField:(const std::string &)name;
// Per row, in row order: severity (-1 none, 0 note, 1 warning, 2 error) and message.
- (void)setRowStatus:(const std::vector<std::pair<int, std::string>> &)status;
- (void)setSummary:(const std::string &)text severity:(int)severity;
- (void)setTarget:(const std::string &)documentName;
- (void)setNote:(NSString *)note;  // e.g. station fields copied from the last record
- (void)setLookupInfo:(NSString *)text severity:(int)severity;   // what the lookup found, distance, park history
- (BOOL)hasField:(const std::string &)name;
- (void)refreshTime;  // put the current UTC date and time in QSO_DATE/TIME_ON
- (void)focusField:(const std::string &)name;
- (void)show;

@end
