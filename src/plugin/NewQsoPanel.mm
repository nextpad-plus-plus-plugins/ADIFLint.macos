#import "NewQsoPanel.h"
#import "ToolWindow.h"

#include <ctime>

// Problems in their colour; plain text dimmed.
static NSColor *severityColor(int severity) { return severity < 0 ? NSColor.secondaryLabelColor : ADIFSeverityColor(severity); }

// A scroll view's document view must be flipped for content to start at the top.
@interface ADIFFlippedView : NSView
@end
@implementation ADIFFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

@implementation ADIFNewQsoPanel {
    NSPanel *_window;
    NSTextField *_target, *_summary, *_note;
    NSScrollView *_scroll;
    ADIFFlippedView *_document;
    NSGridView *_grid;
    NSLayoutConstraint *_scrollHeight;
    NSButton *_currentTime, *_log, *_close, *_fields, *_spots, *_contest;
    NSTextField *_lookupInfo;
    NSStackView *_lookupRow;
    NSPopUpButton *_lookup, *_station;
    NSTimer *_timer;
    std::vector<ADIFQsoRow> _rows;
    NSMutableArray<NSTextField *> *_controls;  // NSTextField or NSComboBox, per row
    NSMutableArray<NSTextField *> *_status;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _timeDigits = 6;
    _controls = [NSMutableArray array];
    _status = [NSMutableArray array];

    _window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 480)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                   NSWindowStyleMaskResizable
                                           backing:NSBackingStoreBuffered
                                             defer:YES];
    _window.title = @"New QSO";
    _window.floatingPanel = YES;
    _window.hidesOnDeactivate = YES;
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    _window.autorecalculatesKeyViewLoop = YES;
    _window.contentMinSize = NSMakeSize(420, 260);
    [_window center];
    NSView *root = _window.contentView;

    _target = [NSTextField labelWithString:@""];
    _target.textColor = NSColor.secondaryLabelColor;
    _target.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _target.translatesAutoresizingMaskIntoConstraints = NO;
    [_target setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.drawsBackground = NO;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _document = [[ADIFFlippedView alloc] initWithFrame:NSZeroRect];
    _document.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.documentView = _document;

    _currentTime = [NSButton checkboxWithTitle:@"Use the current UTC date and time when logging" target:self
                                        action:@selector(currentTimeChanged:)];
    _currentTime.state = NSControlStateValueOn;
    _currentTime.translatesAutoresizingMaskIntoConstraints = NO;

    _note = [NSTextField wrappingLabelWithString:@""];
    _note.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _note.textColor = NSColor.secondaryLabelColor;
    _note.maximumNumberOfLines = 3;
    _note.translatesAutoresizingMaskIntoConstraints = NO;
    [_note setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];

    _summary = [NSTextField wrappingLabelWithString:@""];
    _summary.maximumNumberOfLines = 4;
    _summary.translatesAutoresizingMaskIntoConstraints = NO;
    [_summary setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];

    _log = [NSButton buttonWithTitle:@"Log QSO" target:self action:@selector(logPressed:)];
    _log.keyEquivalent = @"\r";
    _log.translatesAutoresizingMaskIntoConstraints = NO;
    _close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closePressed:)];
    _close.keyEquivalent = @"\033";
    _close.translatesAutoresizingMaskIntoConstraints = NO;
    _fields = [NSButton buttonWithTitle:@"Fields..." target:self action:@selector(fieldsPressed:)];
    _fields.toolTip = @"Choose and order the fields this window asks for";
    _fields.translatesAutoresizingMaskIntoConstraints = NO;
    _spots = [NSButton buttonWithTitle:@"Spots..." target:self action:@selector(spotsPressed:)];
    _spots.toolTip = @"Activators spotted now (POTA, WWFF, and GMA, WWBOTA, IOTA and more from Spothole): pick one to fill CALL, "
                     @"FREQ, MODE and their reference";
    _spots.translatesAutoresizingMaskIntoConstraints = NO;
    _contest = [NSButton buttonWithTitle:@"Contest..." target:self action:@selector(contestPressed:)];
    _contest.toolTip = @"ARRL Field Day, Winter Field Day or serial numbers: the exchange to ask for, the contest's fields and "
                       @"its duplicate rule";
    _contest.translatesAutoresizingMaskIntoConstraints = NO;

    _lookup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_lookup addItemsWithTitles:@[ @"Off", @"Country data", @"QRZ.com", @"HamQTH" ]];
    _lookup.target = self;
    _lookup.action = @selector(lookupChanged:);
    _lookup.toolTip = @"Look the call up as you type and fill the fields that are still empty: country and zones from the "
                      @"call's prefix, or name, QTH, state, grid and more from a callbook (accounts in Settings)";
    // Its own line under the popup, two lines at most: country, distance and the park's history fit.
    _lookupInfo = [NSTextField wrappingLabelWithString:@""];
    _lookupInfo.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _lookupInfo.textColor = NSColor.secondaryLabelColor;
    _lookupInfo.maximumNumberOfLines = 2;
    _lookupInfo.cell.truncatesLastVisibleLine = YES;
    _lookupInfo.identifier = @"qso.lookupInfo";
    _lookupInfo.translatesAutoresizingMaskIntoConstraints = NO;
    _station = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _station.target = self;
    _station.action = @selector(stationChanged:);
    _station.toolTip = @"Your station's fields for the QSOs you log: from the log's last record, or a station profile";
    [self setStations:@[] selected:0];
    _lookupRow = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:@"Look up:"], _lookup,
                                                    [NSTextField labelWithString:@"Station:"], _station ]];
    _lookupRow.spacing = 8;
    _lookupRow.alignment = NSLayoutAttributeCenterY;
    _lookupRow.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *v in @[ _target, _scroll, _currentTime, _lookupRow, _lookupInfo, _note, _summary, _log, _close, _fields, _spots, _contest ])
        [root addSubview:v];
    const CGFloat m = 12;
    _scrollHeight = [_scroll.heightAnchor constraintEqualToConstant:300];
    _scrollHeight.priority = NSLayoutPriorityDefaultHigh - 1;
    [NSLayoutConstraint activateConstraints:@[
        [_target.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
        [_target.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_target.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [_scroll.topAnchor constraintEqualToAnchor:_target.bottomAnchor constant:8],
        [_scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        _scrollHeight,
        [_scroll.heightAnchor constraintGreaterThanOrEqualToConstant:120],
        [_document.leadingAnchor constraintEqualToAnchor:_scroll.contentView.leadingAnchor],
        [_document.trailingAnchor constraintEqualToAnchor:_scroll.contentView.trailingAnchor],
        [_document.topAnchor constraintEqualToAnchor:_scroll.contentView.topAnchor],
        [_currentTime.topAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:8],
        [_currentTime.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_lookupRow.topAnchor constraintEqualToAnchor:_currentTime.bottomAnchor constant:6],
        [_lookupRow.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_lookupRow.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-m],
        [_lookupInfo.topAnchor constraintEqualToAnchor:_lookupRow.bottomAnchor constant:4],
        [_lookupInfo.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_lookupInfo.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [_note.topAnchor constraintEqualToAnchor:_lookupInfo.bottomAnchor constant:6],
        [_note.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_note.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [_summary.topAnchor constraintEqualToAnchor:_note.bottomAnchor constant:6],
        [_summary.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_summary.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [_summary.heightAnchor constraintGreaterThanOrEqualToConstant:34],  // room for a two-line message
        [_log.topAnchor constraintEqualToAnchor:_summary.bottomAnchor constant:8],
        [_log.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [_log.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-m],
        [_close.trailingAnchor constraintEqualToAnchor:_log.leadingAnchor constant:-8],
        [_close.centerYAnchor constraintEqualToAnchor:_log.centerYAnchor],
        [_fields.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [_fields.centerYAnchor constraintEqualToAnchor:_log.centerYAnchor],
        [_spots.leadingAnchor constraintEqualToAnchor:_fields.trailingAnchor constant:8],
        [_spots.centerYAnchor constraintEqualToAnchor:_log.centerYAnchor],
        [_contest.leadingAnchor constraintEqualToAnchor:_spots.trailingAnchor constant:8],
        [_contest.centerYAnchor constraintEqualToAnchor:_log.centerYAnchor],
        [_contest.trailingAnchor constraintLessThanOrEqualToAnchor:_close.leadingAnchor constant:-8],
    ]];
    return self;
}

- (NSPanel *)window {
    return _window;
}

- (BOOL)useCurrentTime {
    return _currentTime.state == NSControlStateValueOn;
}

- (NSInteger)indexOf:(const std::string &)name {
    for (size_t i = 0; i < _rows.size(); ++i)
        if (_rows[i].name == name) return (NSInteger)i;
    return -1;
}

- (NSTextField *)makeControlForRow:(const ADIFQsoRow &)row {
    NSTextField *control;
    if (!row.choices.empty()) {
        NSComboBox *c = [[NSComboBox alloc] initWithFrame:NSZeroRect];
        c.completes = YES;
        c.numberOfVisibleItems = 14;
        for (const std::string &v : row.choices) [c addItemWithObjectValue:ADIFString(v)];
        c.delegate = self;
        control = c;
    } else {
        control = [NSTextField textFieldWithString:@""];
        control.delegate = self;
    }
    control.stringValue = ADIFString(row.value);
    control.placeholderString = row.required ? @"required" : @"";
    control.toolTip = ADIFString(row.description);
    control.font = [NSFont monospacedSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [control.widthAnchor constraintGreaterThanOrEqualToConstant:190].active = YES;
    return control;
}

- (void)setRows:(const std::vector<ADIFQsoRow> &)rows {
    _rows = rows;
    [_grid removeFromSuperview];
    [_controls removeAllObjects];
    [_status removeAllObjects];
    NSMutableArray<NSArray<NSView *> *> *cells = [NSMutableArray array];
    for (const ADIFQsoRow &row : rows) {
        NSTextField *label = [NSTextField labelWithString:ADIFString(row.name)];
        label.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
        label.alignment = NSTextAlignmentRight;
        label.toolTip = ADIFString(row.description);
        NSTextField *control = [self makeControlForRow:row];
        NSTextField *status = [NSTextField labelWithString:@""];
        status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        status.lineBreakMode = NSLineBreakByTruncatingTail;
        [status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_controls addObject:control];
        [_status addObject:status];
        [cells addObject:@[ label, control, status ]];
    }
    _grid = [NSGridView gridViewWithViews:cells];
    _grid.translatesAutoresizingMaskIntoConstraints = NO;
    _grid.rowSpacing = 6;
    _grid.columnSpacing = 8;
    _grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    if (_grid.numberOfColumns == 3) {
        [_grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        [_grid columnAtIndex:2].width = 150;
    }
    [_document addSubview:_grid];
    [NSLayoutConstraint activateConstraints:@[
        [_grid.topAnchor constraintEqualToAnchor:_document.topAnchor constant:4],
        [_grid.leadingAnchor constraintEqualToAnchor:_document.leadingAnchor],
        [_grid.trailingAnchor constraintLessThanOrEqualToAnchor:_document.trailingAnchor],
        [_grid.bottomAnchor constraintEqualToAnchor:_document.bottomAnchor constant:-4],
    ]];
    _scrollHeight.constant = MIN(520.0, 30.0 * rows.size() + 8);
    [self updateTimeEditability];
    // Fit the window to the rows (keeping any width the user gave it).
    NSView *root = _window.contentView;
    [root layoutSubtreeIfNeeded];
    NSSize fit = root.fittingSize;
    [_window setContentSize:NSMakeSize(MAX(NSWidth(root.frame), fit.width), fit.height)];
}

- (std::vector<std::pair<std::string, std::string>>)values {
    std::vector<std::pair<std::string, std::string>> out;
    for (size_t i = 0; i < _rows.size(); ++i)
        out.emplace_back(_rows[i].name, _controls[i].stringValue.UTF8String ?: "");
    return out;
}

- (std::string)valueForField:(const std::string &)name {
    NSInteger i = [self indexOf:name];
    return i < 0 ? std::string() : std::string(_controls[(NSUInteger)i].stringValue.UTF8String ?: "");
}

- (void)setValue:(const std::string &)value forField:(const std::string &)name {
    NSInteger i = [self indexOf:name];
    if (i >= 0) _controls[(NSUInteger)i].stringValue = ADIFString(value);
}

- (void)setChoices:(const std::vector<std::string> &)choices forField:(const std::string &)name {
    NSInteger i = [self indexOf:name];
    if (i < 0 || ![_controls[(NSUInteger)i] isKindOfClass:NSComboBox.class]) return;
    NSComboBox *c = (NSComboBox *)_controls[(NSUInteger)i];
    NSString *keep = c.stringValue;
    [c removeAllItems];
    for (const std::string &v : choices) [c addItemWithObjectValue:ADIFString(v)];
    c.stringValue = keep;
}

- (void)setRowStatus:(const std::vector<std::pair<int, std::string>> &)status {
    for (size_t i = 0; i < _status.count && i < status.size(); ++i) {
        _status[i].stringValue = ADIFString(status[i].second);
        _status[i].toolTip = ADIFString(status[i].second);
        _status[i].textColor = severityColor(status[i].first);
    }
}

- (void)setSummary:(const std::string &)text severity:(int)severity {
    _summary.stringValue = ADIFString(text);
    _summary.textColor = severityColor(severity);
}

- (void)setNote:(NSString *)note {
    _note.stringValue = note ?: @"";
}

- (void)fieldsPressed:(id)sender {
    if (self.onCustomize) self.onCustomize();
}

- (void)spotsPressed:(id)sender {
    if (self.onSpots) self.onSpots();
}

- (void)contestPressed:(id)sender {
    if (self.onContest) self.onContest();
}

- (void)lookupChanged:(id)sender {
    if (self.onLookupChanged) self.onLookupChanged(self.lookupSource);
}

- (NSInteger)lookupSource {
    return _lookup.indexOfSelectedItem;
}

- (void)setLookupSource:(NSInteger)source {
    [_lookup selectItemAtIndex:source >= 0 && source < 4 ? source : 0];
}

- (void)setLookupInfo:(NSString *)text severity:(int)severity {
    _lookupInfo.stringValue = text ?: @"";
    _lookupInfo.toolTip = text;
    _lookupInfo.textColor = severityColor(severity);
}

- (BOOL)hasField:(const std::string &)name {
    return [self indexOf:name] >= 0;
}

- (void)setStations:(NSArray<NSString *> *)names selected:(NSInteger)index {
    [_station removeAllItems];
    [_station addItemWithTitle:@"From the log"];
    for (NSString *n in names) [_station addItemWithTitle:n];
    [_station.menu addItem:[NSMenuItem separatorItem]];
    [_station addItemWithTitle:@"Edit Profiles..."];
    [_station selectItemAtIndex:index >= 0 && index <= (NSInteger)names.count ? index : 0];
}

- (void)stationChanged:(NSPopUpButton *)sender {
    NSInteger i = sender.indexOfSelectedItem;
    BOOL edit = i == sender.numberOfItems - 1;
    if (self.onStationChosen) self.onStationChosen(edit ? -1 : i);
}

- (void)setTarget:(const std::string &)documentName {
    _target.stringValue = [@"Logging to: " stringByAppendingString:ADIFString(documentName)];
}

// ── Time ────────────────────────────────────────────────────────────────────

- (void)refreshTime {
    std::time_t now = std::time(nullptr);
    std::tm utc{};
    gmtime_r(&now, &utc);
    char date[16], tod[16];
    std::strftime(date, sizeof date, "%Y%m%d", &utc);
    std::strftime(tod, sizeof tod, _timeDigits == 4 ? "%H%M" : "%H%M%S", &utc);
    [self setValue:date forField:"QSO_DATE"];
    [self setValue:tod forField:"TIME_ON"];
}

- (void)updateTimeEditability {
    BOOL editable = !self.useCurrentTime;
    for (const char *name : {"QSO_DATE", "TIME_ON"}) {
        NSInteger i = [self indexOf:name];
        if (i >= 0) {
            _controls[(NSUInteger)i].editable = editable;
            _controls[(NSUInteger)i].enabled = editable;
        }
    }
    [_timer invalidate];
    _timer = nil;
    if (!editable) {
        [self refreshTime];
        _timer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}

- (void)tick:(NSTimer *)timer {
    if (!_window.visible) return;
    [self refreshTime];
}

- (void)currentTimeChanged:(id)sender {
    [self updateTimeEditability];
    if (self.onChange) self.onChange();
}

// ── Editing ─────────────────────────────────────────────────────────────────

- (void)controlTextDidChange:(NSNotification *)notification {
    if (self.onChange) self.onChange();
}

- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    // The combo box's string updates after this notification.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onChange) self.onChange();
    });
}

- (void)focusField:(const std::string &)name {
    NSInteger i = [self indexOf:name];
    if (i >= 0) [_window makeFirstResponder:_controls[(NSUInteger)i]];
}

- (void)show {
    [self updateTimeEditability];
    [_window makeKeyAndOrderFront:nil];
}

- (void)logPressed:(id)sender {
    [_window makeFirstResponder:nil];  // commit the field being edited
    if (self.useCurrentTime) [self refreshTime];
    if (self.onLog) self.onLog();
}

- (void)closePressed:(id)sender {
    [_window performClose:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    [_timer invalidate];
    _timer = nil;
}

@end
