#import "QsoFieldsPanel.h"
#import "ToolWindow.h"

#include <algorithm>
#include <map>

// Kept in step with adif::isRequiredQsoField (CALL, QSO_DATE, TIME_ON, MODE).
static bool required(const std::string &n) { return n == "CALL" || n == "QSO_DATE" || n == "TIME_ON" || n == "MODE"; }

static NSTextField *heading(NSString *text) {
    NSTextField *t = [NSTextField labelWithString:text];
    t.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    return t;
}

static NSTableView *makeTable(id owner, NSArray<NSArray *> *columns) {
    NSTableView *t = [[NSTableView alloc] initWithFrame:NSZeroRect];
    t.dataSource = owner;
    t.delegate = owner;
    t.usesAlternatingRowBackgroundColors = YES;
    t.rowHeight = 20;
    t.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    if (@available(macOS 11.0, *)) t.style = NSTableViewStyleFullWidth;
    for (NSArray *c in columns) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[1];
        col.width = [c[2] doubleValue];
        col.minWidth = 50;
        [t addTableColumn:col];
    }
    return t;
}

static NSScrollView *scrolling(NSTableView *t) {
    NSScrollView *s = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    s.documentView = t;
    s.hasVerticalScroller = YES;
    s.autohidesScrollers = YES;
    s.borderType = NSBezelBorder;
    return s;
}

@implementation ADIFQsoFieldsPanel {
    NSPanel *_window;
    NSTableView *_table;      // the New QSO fields, in order
    NSTableView *_available;  // fields that can be added
    NSSearchField *_search;
    NSButton *_up, *_down, *_remove, *_add, *_carry;
    NSTextField *_count;
    std::vector<std::string> _fields;
    std::map<std::string, ADIFFieldChoice> _info;
    std::vector<std::string> _shown;  // available rows after the search filter
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 940, 600)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                           backing:NSBackingStoreBuffered
                                             defer:YES];
    _window.title = @"New QSO Fields";
    _window.floatingPanel = YES;
    _window.hidesOnDeactivate = YES;
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    _window.contentMinSize = NSMakeSize(820, 480);
    NSView *root = _window.contentView;

    NSTextField *intro = [NSTextField wrappingLabelWithString:
                                          @"Choose the fields New QSO asks for, and their order. CALL, QSO_DATE, TIME_ON and "
                                          @"MODE are always included, and BAND or FREQ. Descriptions are from the ADIF 3.1.7 "
                                          @"specification; hover a row for the full text."];

    // Left: the chosen fields.
    NSTextField *leftTitle = heading(@"In the New QSO window");
    _table = makeTable(self, @[ @[ @"name", @"Field", @130 ], @[ @"brief", @"Description", @220 ] ]);
    NSScrollView *leftScroll = scrolling(_table);
    _up = [NSButton buttonWithTitle:@"Move Up" target:self action:@selector(moveUp:)];
    _down = [NSButton buttonWithTitle:@"Move Down" target:self action:@selector(moveDown:)];
    _remove = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(removeField:)];
    NSStackView *leftButtons = [NSStackView stackViewWithViews:@[ _up, _down, _remove ]];

    // Right: everything that can be added, searchable.
    NSTextField *rightTitle = heading(@"Fields you can add");
    _search = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _search.placeholderString = @"Search names and descriptions, e.g. park, power, grid";
    _search.delegate = self;
    _search.sendsSearchStringImmediately = YES;
    _available = makeTable(self, @[ @[ @"name", @"Field", @150 ], @[ @"type", @"Type", @120 ], @[ @"brief", @"Description", @300 ] ]);
    _available.allowsMultipleSelection = YES;
    _available.target = self;
    _available.doubleAction = @selector(addDoubleClicked:);
    NSScrollView *rightScroll = scrolling(_available);
    _add = [NSButton buttonWithTitle:@"Add to New QSO" target:self action:@selector(addSelected:)];
    _count = [NSTextField labelWithString:@""];
    _count.textColor = NSColor.secondaryLabelColor;
    _count.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    NSStackView *rightButtons = [NSStackView stackViewWithViews:@[ _add, _count ]];

    _carry = [NSButton checkboxWithTitle:@"Also copy this station's details from the last record when they aren't listed"
                                  target:nil
                                  action:nil];
    _carry.toolTip = @"STATION_CALLSIGN, OPERATOR, OWNER_CALLSIGN, TX_PWR and the MY_ fields (MY_SIG_INFO, MY_STATE, ...): "
                     @"written with each new QSO, and listed in the New QSO window.";

    NSButton *automatic = [NSButton buttonWithTitle:@"Use the Log's Fields" target:self action:@selector(useAutomatic:)];
    automatic.toolTip = @"Ask for the fields of the log's last record, plus CALL, QSO_DATE, TIME_ON, BAND, FREQ, MODE, SUBMODE "
                        @"and the reports.";
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\033";
    NSButton *save = [NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)];
    save.keyEquivalent = @"\r";
    NSStackView *bottom = [NSStackView stackViewWithViews:@[ automatic ]];
    [bottom addView:cancel inGravity:NSStackViewGravityTrailing];
    [bottom addView:save inGravity:NSStackViewGravityTrailing];

    for (NSView *v in @[ intro, leftTitle, leftScroll, leftButtons, rightTitle, _search, rightScroll, rightButtons, _carry, bottom ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:v];
    }
    const CGFloat m = 16, gap = 20;
    [NSLayoutConstraint activateConstraints:@[
        [intro.topAnchor constraintEqualToAnchor:root.topAnchor constant:m],
        [intro.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [intro.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],

        [leftTitle.topAnchor constraintEqualToAnchor:intro.bottomAnchor constant:14],
        [leftTitle.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [leftScroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [leftScroll.widthAnchor constraintEqualToConstant:370],
        [leftScroll.topAnchor constraintEqualToAnchor:_search.topAnchor],  // lines up with the search field
        [leftButtons.topAnchor constraintEqualToAnchor:leftScroll.bottomAnchor constant:8],
        [leftButtons.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],

        [rightTitle.topAnchor constraintEqualToAnchor:leftTitle.topAnchor],
        [rightTitle.leadingAnchor constraintEqualToAnchor:leftScroll.trailingAnchor constant:gap],
        [_search.topAnchor constraintEqualToAnchor:rightTitle.bottomAnchor constant:8],
        [_search.leadingAnchor constraintEqualToAnchor:rightTitle.leadingAnchor],
        [_search.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [rightScroll.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:8],
        [rightScroll.leadingAnchor constraintEqualToAnchor:rightTitle.leadingAnchor],
        [rightScroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [rightScroll.bottomAnchor constraintEqualToAnchor:leftScroll.bottomAnchor],
        [rightButtons.topAnchor constraintEqualToAnchor:rightScroll.bottomAnchor constant:8],
        [rightButtons.leadingAnchor constraintEqualToAnchor:rightTitle.leadingAnchor],

        [_carry.topAnchor constraintEqualToAnchor:leftButtons.bottomAnchor constant:14],
        [_carry.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [bottom.topAnchor constraintEqualToAnchor:_carry.bottomAnchor constant:14],
        [bottom.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:m],
        [bottom.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-m],
        [bottom.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-m],
        [leftScroll.heightAnchor constraintGreaterThanOrEqualToConstant:260],
    ]];
    [_window center];
    return self;
}

- (NSPanel *)window {
    return _window;
}

- (void)showFields:(const std::vector<std::string> &)fields
       carryHidden:(BOOL)carryHidden
           choices:(const std::vector<ADIFFieldChoice> &)choices {
    _fields = fields;
    _info.clear();
    for (const ADIFFieldChoice &c : choices) _info[c.name] = c;
    _search.stringValue = @"";
    _carry.state = carryHidden ? NSControlStateValueOn : NSControlStateValueOff;
    [self reload];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_search];
}

// Rebuild the available list: fields not chosen yet that match the search,
// best matches first (exact name, name prefix, name contains, description).
- (void)filterAvailable {
    _shown.clear();
    NSString *q = [_search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    std::vector<std::pair<int, std::string>> ranked;
    for (const auto &kv : _info) {
        if (std::find(_fields.begin(), _fields.end(), kv.first) != _fields.end()) continue;
        int rank = 0;
        if (q.length) {
            NSString *name = ADIFString(kv.first);
            NSRange r = [name rangeOfString:q options:NSCaseInsensitiveSearch];
            if (r.location == 0 && r.length == name.length) rank = 0;
            else if (r.location == 0) rank = 1;
            else if (r.location != NSNotFound) rank = 2;
            else if ([[NSString stringWithFormat:@"%@ %@", ADIFString(kv.second.brief), ADIFString(kv.second.details)]
                         rangeOfString:q
                               options:NSCaseInsensitiveSearch]
                         .location != NSNotFound)
                rank = 3;
            else continue;
        }
        ranked.emplace_back(rank, kv.first);
    }
    std::stable_sort(ranked.begin(), ranked.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
    for (const auto &r : ranked) _shown.push_back(r.second);
    _count.stringValue = [NSString stringWithFormat:@"%zu field%@", _shown.size(), _shown.size() == 1 ? @"" : @"s"];
}

- (void)reload {
    [self filterAvailable];
    [_table reloadData];
    [_available reloadData];
    [self updateButtons];
}

// BAND and FREQ: at least one stays.
- (bool)removable:(size_t)i {
    const std::string &n = _fields[i];
    if (required(n)) return false;
    if (n == "BAND" || n == "FREQ") {
        const char *other = n == "BAND" ? "FREQ" : "BAND";
        return std::find(_fields.begin(), _fields.end(), other) != _fields.end();
    }
    return true;
}

- (void)updateButtons {
    NSInteger row = _table.selectedRow;
    bool sel = row >= 0 && (size_t)row < _fields.size();
    _up.enabled = sel && row > 0;
    _down.enabled = sel && (size_t)row + 1 < _fields.size();
    _remove.enabled = sel && [self removable:(size_t)row];
    _add.enabled = _available.selectedRowIndexes.count > 0;
}

// ── Tables ──────────────────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)(tableView == _table ? _fields.size() : _shown.size());
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTextField *f = [tableView makeViewWithIdentifier:column.identifier owner:self];
    if (!f) {
        f = [NSTextField labelWithString:@""];
        f.identifier = column.identifier;
        f.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    const std::string &name = tableView == _table ? _fields[(size_t)row] : _shown[(size_t)row];
    auto it = _info.find(name);
    ADIFFieldChoice info = it == _info.end() ? ADIFFieldChoice{name, "", "", "", false} : it->second;
    NSString *ident = column.identifier;
    if ([ident isEqualToString:@"name"]) {
        f.stringValue = ADIFString(name);
        f.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
        f.textColor = NSColor.labelColor;
    } else if ([ident isEqualToString:@"type"]) {
        std::string type = info.type;
        if (info.hasValues && type != "Enumeration" && type != "Boolean") type += ", list";
        f.stringValue = ADIFString(type);
        f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        f.textColor = NSColor.secondaryLabelColor;
    } else {
        std::string text = info.brief;
        if (tableView == _table && required(name)) text = "Required. " + text;
        f.stringValue = ADIFString(text);
        f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        f.textColor = NSColor.secondaryLabelColor;
    }
    NSString *tip = ADIFString(info.details.empty() ? info.brief : info.details);
    if (!info.type.empty()) tip = [NSString stringWithFormat:@"%@\n\nType: %@%@", tip, ADIFString(info.type),
                                                               info.hasValues ? @" (New QSO offers a list of values)" : @""];
    f.toolTip = tip;
    return f;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateButtons];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _search) {
        [self filterAvailable];
        [_available reloadData];
        [self updateButtons];
    }
}

// ── Actions ─────────────────────────────────────────────────────────────────

- (void)select:(NSInteger)row {
    [self reload];
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_table scrollRowToVisible:row];
    [self updateButtons];
}

- (void)moveUp:(id)sender {
    NSInteger row = _table.selectedRow;
    if (row <= 0) return;
    std::swap(_fields[(size_t)row], _fields[(size_t)row - 1]);
    [self select:row - 1];
}

- (void)moveDown:(id)sender {
    NSInteger row = _table.selectedRow;
    if (row < 0 || (size_t)row + 1 >= _fields.size()) return;
    std::swap(_fields[(size_t)row], _fields[(size_t)row + 1]);
    [self select:row + 1];
}

- (void)removeField:(id)sender {
    NSInteger row = _table.selectedRow;
    if (row < 0 || ![self removable:(size_t)row]) return;
    _fields.erase(_fields.begin() + row);
    [self reload];
    if (!_fields.empty()) [self select:std::min<NSInteger>(row, (NSInteger)_fields.size() - 1)];
}

// Add the given available rows after the selected field (else at the end).
- (void)addRows:(NSIndexSet *)rows {
    std::vector<std::string> names;
    for (NSUInteger i = rows.firstIndex; i != NSNotFound; i = [rows indexGreaterThanIndex:i])
        if (i < _shown.size()) names.push_back(_shown[i]);
    if (names.empty()) return;
    NSInteger sel = _table.selectedRow;
    size_t pos = sel >= 0 ? (size_t)sel + 1 : _fields.size();
    _fields.insert(_fields.begin() + (long)pos, names.begin(), names.end());
    [self select:(NSInteger)(pos + names.size() - 1)];
}

- (void)addSelected:(id)sender {
    [self addRows:_available.selectedRowIndexes];
}

- (void)addDoubleClicked:(id)sender {
    if (_available.clickedRow >= 0) [self addRows:[NSIndexSet indexSetWithIndex:(NSUInteger)_available.clickedRow]];
}

- (void)useAutomatic:(id)sender {
    if (self.onSave) self.onSave(std::vector<std::string>(), YES, _carry.state == NSControlStateValueOn);
    [_window orderOut:nil];
}

- (void)cancel:(id)sender {
    [_window orderOut:nil];
}

- (void)save:(id)sender {
    if (self.onSave) self.onSave(_fields, NO, _carry.state == NSControlStateValueOn);
    [_window orderOut:nil];
}

@end
