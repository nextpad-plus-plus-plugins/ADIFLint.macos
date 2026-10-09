// The Enrich window for one source (QRZ.com, HamQTH or Country Data, chosen in its
// "Enrich from" popup): the account in use, which fields to fill, progress,
// and a review table of proposed changes. AppKit only; ADIFLint.mm runs the
// lookups and applies the accepted changes.
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>

struct ADIFEnrichRow {
    bool accepted = true;
    int record = 0;
    std::string call, field, current, value;
    bool replace = false;
    std::string note;
};

@interface ADIFEnrichPanel : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>

@property(nonatomic, readonly) NSPanel *window;
@property(nonatomic, copy) void (^onOpenSettings)(void);
@property(nonatomic, copy) void (^onChooseSource)(NSInteger source);  // the "Enrich from" popup (an ADIFSource)
@property(nonatomic, copy) void (^onFind)(void);
@property(nonatomic, copy) void (^onCancel)(void);
@property(nonatomic, copy) void (^onApply)(void);

@property(nonatomic, readonly) NSInteger source;  // ADIFSource
- (void)setSource:(NSInteger)source title:(NSString *)title;  // clears any previous results
@property(nonatomic, readonly) BOOL selectionOnly;
@property(nonatomic, readonly) BOOL skipAwayFromHome;

- (std::vector<std::string>)selectedFields;  // ADIF fields ticked and offered by the source
- (void)setAccount:(NSString *)text;
- (void)setTarget:(const std::string &)documentName;
- (void)setBusy:(BOOL)busy;
- (void)setProgress:(double)fraction;  // 0...1
- (void)setStatus:(NSString *)text severity:(int)severity;  // -1 plain, 0 note, 1 warning, 2 error
- (void)setCredit:(NSString *)text;
- (void)setRows:(const std::vector<ADIFEnrichRow> &)rows;
- (std::vector<bool>)accepted;
- (void)show;

@end
