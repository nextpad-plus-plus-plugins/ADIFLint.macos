#import "EnrichPanel.h"

#import "Lookup.h"

static NSString *ns(const std::string &s) {
    NSString *r = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return r ?: [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSISOLatin1StringEncoding];
}

static NSColor *severityColor(int severity) {
    switch (severity) {
        case 2: return NSColor.systemRedColor;
        case 1: return NSColor.systemOrangeColor;
        case 0: return NSColor.systemBlueColor;
        default: return NSColor.secondaryLabelColor;
    }
}

// The fields the window offers, and which sources provide them: bit (1 << ADIFSource):
// 0 QRZ.com, 1 HamQTH, 8 Country Data.
struct FieldOption {
    NSString *label;
    std::vector<std::string> fields;
    unsigned sources;
    bool on;
};
static const std::vector<FieldOption> &fieldOptions() {
    static const std::vector<FieldOption> options = {
        {@"Name", {"NAME"}, 0b011, true},
        {@"City (QTH)", {"QTH"}, 0b011, true},
        {@"State", {"STATE"}, 0b011, true},
        {@"County", {"CNTY"}, 0b011, true},
        {@"Grid square", {"GRIDSQUARE"}, 0b011, true},
        {@"Country and DXCC", {"DXCC", "COUNTRY"}, 0b100000011, true},
        {@"CQ zone", {"CQZ"}, 0b100000011, true},
        {@"ITU zone", {"ITUZ"}, 0b100000011, true},
        {@"IOTA", {"IOTA"}, 0b011, true},
        {@"Continent", {"CONT"}, 0b100000010, true},
        {@"Latitude and longitude", {"LAT", "LON"}, 0b011, false},
    };
    return options;
}

@implementation ADIFEnrichPanel {
    NSPanel *_window;
    NSTextField *_target, *_account, *_status, *_credit;
    NSPopUpButton *_sourcePopup;
    NSInteger _source;
    NSButton *_settings, *_selectionOnly, *_skipAway, *_find, *_cancel, *_apply, *_all, *_none, *_close;
    NSMutableArray<NSButton *> *_fieldBoxes;
    NSProgressIndicator *_progress;
    NSTableView *_table;
    std::vector<ADIFEnrichRow> _rows;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 680, 640)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                   NSWindowStyleMaskResizable
                                           backing:NSBackingStoreBuffered
                                             defer:YES];
    _window.title = @"Enrich Log";
    _window.floatingPanel = YES;
    _window.hidesOnDeactivate = YES;
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    _window.contentMinSize = NSMakeSize(560, 520);
    [_window center];
    NSView *root = _window.contentView;

    _target = [NSTextField labelWithString:@""];
    _target.textColor = NSColor.secondaryLabelColor;
    _target.lineBreakMode = NSLineBreakByTruncatingMiddle;

    _account = [NSTextField labelWithString:@""];
    _account.lineBreakMode = NSLineBreakByTruncatingTail;
    [_account setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    _settings = [NSButton buttonWithTitle:@"Settings..." target:self action:@selector(openSettings:)];
    _settings.toolTip = @"Accounts and API keys, kept in your Keychain";
    NSStackView *sourceRow = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:@"Account:"], _account, _settings ]];
    _sourcePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    struct { NSString *title; NSInteger source; } sources[] = {
        {@"QRZ.com", ADIFSourceQRZ}, {@"HamQTH", ADIFSourceHamQTH}, {@"Country Data (offline)", ADIFSourceCountryData}};
    for (auto &s : sources) {
        [_sourcePopup addItemWithTitle:s.title];
        _sourcePopup.lastItem.tag = s.source;
    }
    _sourcePopup.target = self;
    _sourcePopup.action = @selector(sourceChosen:);
    NSStackView *fromRow = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:@"Enrich from:"], _sourcePopup ]];

    NSTextField *fieldsLabel = [NSTextField labelWithString:@"Add these fields to records that don't have them:"];
    _fieldBoxes = [NSMutableArray array];
    NSMutableArray<NSArray<NSView *> *> *gridRows = [NSMutableArray array];
    NSMutableArray<NSView *> *row = [NSMutableArray array];
    for (size_t i = 0; i < fieldOptions().size(); ++i) {
        NSButton *b = [NSButton checkboxWithTitle:fieldOptions()[i].label target:nil action:nil];
        b.state = fieldOptions()[i].on ? NSControlStateValueOn : NSControlStateValueOff;
        b.tag = (NSInteger)i;
        [_fieldBoxes addObject:b];
        [row addObject:b];
        if (row.count == 3) {
            [gridRows addObject:[row copy]];
            [row removeAllObjects];
        }
    }
    if (row.count) {
        while (row.count < 3) [row addObject:[NSGridCell emptyContentView]];
        [gridRows addObject:row];
    }
    NSGridView *fieldGrid = [NSGridView gridViewWithViews:gridRows];
    fieldGrid.rowSpacing = 4;
    fieldGrid.columnSpacing = 16;

    _selectionOnly = [NSButton checkboxWithTitle:@"Only the records in the selection" target:nil action:nil];
    _skipAway = [NSButton checkboxWithTitle:@"No callbook location for portable calls (K1ABC/P) or park-to-park records"
                                     target:nil
                                     action:nil];
    _skipAway.state = NSControlStateValueOn;
    _skipAway.toolTip = @"A callbook gives a station's home address. For /P calls and records with SIG_INFO, POTA_REF, "
                        @"SOTA_REF or WWFF_REF the station was elsewhere, so only the name is added. LoTW data describes "
                        @"each QSO, so it is always used.";

    _find = [NSButton buttonWithTitle:@"Find Data" target:self action:@selector(find:)];
    _find.keyEquivalent = @"\r";
    _cancel = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(cancel:)];
    _progress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _progress.style = NSProgressIndicatorStyleBar;
    _progress.indeterminate = NO;
    _progress.minValue = 0;
    _progress.maxValue = 1;
    [_progress.widthAnchor constraintGreaterThanOrEqualToConstant:160].active = YES;
    NSStackView *findRow = [NSStackView stackViewWithViews:@[ _find, _cancel, _progress ]];

    _status = [NSTextField wrappingLabelWithString:@""];
    _status.maximumNumberOfLines = 3;
    [_status setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _table.dataSource = self;
    _table.delegate = self;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.rowHeight = 20;
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    if (@available(macOS 11.0, *)) _table.style = NSTableViewStyleFullWidth;
    struct { NSString *ident, *title; CGFloat width; } cols[] = {
        {@"use", @"", 24}, {@"record", @"Record", 56}, {@"call", @"Call", 90}, {@"field", @"Field", 110},
        {@"current", @"Now", 110}, {@"value", @"New", 200}};
    for (auto &c : cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c.ident];
        col.title = c.title;
        col.width = c.width;
        col.minWidth = c.width < 30 ? c.width : 40;
        [_table addTableColumn:col];
    }
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = _table;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;

    _all = [NSButton buttonWithTitle:@"Tick All" target:self action:@selector(tickAll:)];
    _none = [NSButton buttonWithTitle:@"Untick All" target:self action:@selector(tickNone:)];
    _credit = [NSTextField labelWithString:@""];
    _credit.textColor = NSColor.secondaryLabelColor;
    _close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closePressed:)];
    _close.keyEquivalent = @"\033";
    _apply = [NSButton buttonWithTitle:@"Apply Changes" target:self action:@selector(apply:)];
    NSStackView *bottom = [NSStackView stackViewWithViews:@[ _all, _none, _credit ]];
    [bottom addView:_close inGravity:NSStackViewGravityTrailing];
    [bottom addView:_apply inGravity:NSStackViewGravityTrailing];

    NSArray<NSView *> *views =
        @[ _target, fromRow, sourceRow, fieldsLabel, fieldGrid, _selectionOnly, _skipAway, findRow, _status, scroll, bottom ];
    for (NSView *v in views) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:v];
    }
    const CGFloat m = 14;
    NSMutableArray *c = [NSMutableArray array];
    NSView *above = nil;
    for (NSView *v in views) {
        [c addObject:[v.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:v == fieldGrid ? m + 12 : m]];
        if (v != fieldGrid && v != findRow && v != _selectionOnly && v != _skipAway && v != fromRow)
            [c addObject:[v.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m]];
        [c addObject:above ? [v.topAnchor constraintEqualToAnchor:above.bottomAnchor constant:(v == scroll || v == fieldGrid) ? 6 : 10]
                           : [v.topAnchor constraintEqualToAnchor:root.topAnchor constant:m]];
        above = v;
    }
    [c addObject:[bottom.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-m]];
    [c addObject:[scroll.heightAnchor constraintGreaterThanOrEqualToConstant:140]];
    [NSLayoutConstraint activateConstraints:c];

    [self setBusy:NO];
    [self updateForSource];
    return self;
}

- (NSPanel *)window {
    return _window;
}

- (NSInteger)source {
    return _source;
}

- (void)sourceChosen:(NSPopUpButton *)sender {
    NSInteger chosen = sender.selectedTag;
    [sender selectItemWithTag:_source];  // stays until the source really changes
    if (chosen != _source && self.onChooseSource) self.onChooseSource(chosen);
}

- (void)setSource:(NSInteger)source title:(NSString *)title {
    _source = source;
    _window.title = title;
    [_sourcePopup selectItemWithTag:source];
    [self updateForSource];
    [self setRows:std::vector<ADIFEnrichRow>()];
    [self setStatus:@"" severity:-1];
    [self setCredit:@""];
}

- (BOOL)selectionOnly {
    return _selectionOnly.state == NSControlStateValueOn;
}

- (BOOL)skipAwayFromHome {
    return _skipAway.state == NSControlStateValueOn;
}

- (void)updateForSource {
    unsigned bit = 1u << (unsigned)self.source;
    for (NSButton *b in _fieldBoxes) {
        b.enabled = (fieldOptions()[(size_t)b.tag].sources & bit) != 0;
        b.toolTip = b.enabled ? nil : [NSString stringWithFormat:@"%@ does not provide this.", ADIFSourceName((ADIFSource)self.source)];
    }
    // Only callbooks give a home address; the prefix describes each QSO.
    _skipAway.enabled = self.source == 0 || self.source == 1;
}

- (std::vector<std::string>)selectedFields {
    std::vector<std::string> out;
    for (NSButton *b in _fieldBoxes)
        if (b.enabled && b.state == NSControlStateValueOn)
            for (const std::string &f : fieldOptions()[(size_t)b.tag].fields) out.push_back(f);
    return out;
}

- (void)setAccount:(NSString *)text {
    _account.stringValue = text ?: @"";
}

- (void)setTarget:(const std::string &)documentName {
    _target.stringValue = [@"Log: " stringByAppendingString:ns(documentName)];
}

- (void)setBusy:(BOOL)busy {
    _find.enabled = !busy;
    _cancel.enabled = busy;
    _settings.enabled = !busy;
    _apply.enabled = !busy && !_rows.empty();
    _progress.doubleValue = 0;
    _progress.hidden = !busy;  // only while looking up
}

- (void)setProgress:(double)fraction {
    _progress.doubleValue = fraction;
}

- (void)setStatus:(NSString *)text severity:(int)severity {
    _status.stringValue = text ?: @"";
    _status.textColor = severityColor(severity);
}

- (void)setCredit:(NSString *)text {
    _credit.stringValue = text ?: @"";
}

- (void)setRows:(const std::vector<ADIFEnrichRow> &)rows {
    _rows = rows;
    [_table reloadData];
    [self updateApply];
}

- (std::vector<bool>)accepted {
    std::vector<bool> out;
    for (const ADIFEnrichRow &r : _rows) out.push_back(r.accepted);
    return out;
}

- (void)updateApply {
    size_t n = 0;
    for (const ADIFEnrichRow &r : _rows) n += r.accepted;
    _apply.title = n ? [NSString stringWithFormat:@"Apply %zu Change%@", n, n == 1 ? @"" : @"s"] : @"Apply Changes";
    _apply.enabled = n > 0 && _find.enabled;
    _apply.keyEquivalent = n ? @"\r" : @"";
    _find.keyEquivalent = n ? @"" : @"\r";
}

- (void)show {
    [_window makeKeyAndOrderFront:nil];
}

// ── Table ───────────────────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_rows.size();
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    const ADIFEnrichRow &r = _rows[(size_t)row];
    NSString *ident = column.identifier;
    if ([ident isEqualToString:@"use"]) {
        NSButton *b = [tableView makeViewWithIdentifier:@"use.cell" owner:self];
        if (!b) {
            b = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleRow:)];
            b.identifier = @"use.cell";
        }
        b.state = r.accepted ? NSControlStateValueOn : NSControlStateValueOff;
        return b;
    }
    NSTextField *f = [tableView makeViewWithIdentifier:@"text.cell" owner:self];
    if (!f) {
        f = [NSTextField labelWithString:@""];
        f.identifier = @"text.cell";
        f.lineBreakMode = NSLineBreakByTruncatingTail;
        f.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
    }
    f.textColor = NSColor.labelColor;
    if ([ident isEqualToString:@"record"]) f.stringValue = [NSString stringWithFormat:@"%d", r.record];
    else if ([ident isEqualToString:@"call"]) f.stringValue = ns(r.call);
    else if ([ident isEqualToString:@"field"]) f.stringValue = ns(r.field);
    else if ([ident isEqualToString:@"current"]) {
        f.stringValue = r.current.empty() ? @"(none)" : ns(r.current);
        f.textColor = r.current.empty() ? NSColor.tertiaryLabelColor : NSColor.systemOrangeColor;
    } else {
        f.stringValue = ns(r.value);
    }
    f.toolTip = ns(r.note);
    return f;
}

- (void)toggleRow:(NSButton *)sender {
    NSInteger row = [_table rowForView:sender];
    if (row < 0 || (size_t)row >= _rows.size()) return;
    _rows[(size_t)row].accepted = sender.state == NSControlStateValueOn;
    [self updateApply];
}

- (void)tickAll:(id)sender {
    for (ADIFEnrichRow &r : _rows) r.accepted = true;
    [_table reloadData];
    [self updateApply];
}

- (void)tickNone:(id)sender {
    for (ADIFEnrichRow &r : _rows) r.accepted = false;
    [_table reloadData];
    [self updateApply];
}

// ── Actions ─────────────────────────────────────────────────────────────────

- (void)openSettings:(id)sender {
    if (self.onOpenSettings) self.onOpenSettings();
}

- (void)find:(id)sender {
    if (self.onFind) self.onFind();
}

- (void)cancel:(id)sender {
    if (self.onCancel) self.onCancel();
}

- (void)apply:(id)sender {
    if (self.onApply) self.onApply();
}

- (void)closePressed:(id)sender {
    [_window performClose:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (self.onCancel) self.onCancel();
}

@end
