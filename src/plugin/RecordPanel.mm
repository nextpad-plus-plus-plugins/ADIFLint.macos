#import "RecordPanel.h"
#import "ToolWindow.h"

#include "adif_tools.h"

#include <algorithm>

static NSString *const kPosColumn = @"pos";
static NSString *const kFieldColumn = @"field";
static NSString *const kValueColumn = @"value";
static NSString *const kNoteColumn = @"note";
static NSString *const kLineBreakGlyph = @"⏎";  // ⏎

// Problems in their colour; plain text dimmed.
static NSColor *severityColor(int severity) { return severity < 0 ? NSColor.secondaryLabelColor : ADIFSeverityColor(severity); }

static NSButton *symbolButton(NSString *symbol, NSString *fallback, NSString *tip, id target, SEL action) {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
    NSButton *b = image ? [NSButton buttonWithImage:image target:target action:action]
                        : [NSButton buttonWithTitle:fallback target:target action:action];
    b.bezelStyle = NSBezelStyleRecessed;
    b.toolTip = tip;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

@implementation ADIFRecordPanel {
    ADIFPanelSnapshot _snapshot;
    std::vector<size_t> _order;  // table row -> snapshot row, as sorted
    bool _settingSort;           // a sort set by the caller, not a heading click
    NSView *_root;
    NSTextField *_title, *_health;
    NSButton *_previous, *_next, *_add, *_remove;
    NSTableView *_table;
    NSTextField *_footer;
    // Add Field dialog
    NSComboBox *_addName, *_addValue;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 420)];

    _title = [NSTextField labelWithString:@""];
    _title.font = [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize + 1];
    _title.lineBreakMode = NSLineBreakByTruncatingTail;
    _title.translatesAutoresizingMaskIntoConstraints = NO;
    [_title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                     forOrientation:NSLayoutConstraintOrientationHorizontal];

    // The log in one line (small, so it never reads as the title).
    _health = [NSTextField labelWithString:@""];
    _health.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _health.lineBreakMode = NSLineBreakByTruncatingTail;
    _health.translatesAutoresizingMaskIntoConstraints = NO;
    [_health setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    _previous = symbolButton(@"chevron.up", @"▲", @"Previous record", self, @selector(previousRecord:));
    _next = symbolButton(@"chevron.down", @"▼", @"Next record", self, @selector(nextRecord:));
    _add = symbolButton(@"plus", @"+", @"Add a field to this record", self, @selector(addField:));
    _remove = symbolButton(@"minus", @"-", @"Remove the selected field", self, @selector(removeField:));

    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _table.dataSource = self;
    _table.delegate = self;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.rowHeight = 24;
    _table.allowsMultipleSelection = NO;
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _table.target = self;
    _table.doubleAction = @selector(revealRow:);
    _table.menu = [[NSMenu alloc] initWithTitle:@""];
    _table.menu.delegate = self;  // right-click: the problem's repair
    if (@available(macOS 11.0, *)) _table.style = NSTableViewStyleFullWidth;
    struct { NSString *ident, *title, *tip; CGFloat width; } cols[] = {
        {kPosColumn, @"#", @"Position in the record: sort by it for the file's order", 30},
        {kFieldColumn, @"Field", @"Sort by field name", 130},
        {kValueColumn, @"Value", @"Sort by value", 150},
        {kNoteColumn, @"Problem", @"Sort by problem: errors first", 160}};
    for (auto &c : cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c.ident];
        col.title = c.title;
        col.headerToolTip = c.tip;
        col.width = c.width;
        col.minWidth = c.ident == kPosColumn ? 26 : 60;
        // Click a heading to sort the rows shown; the record itself is not changed.
        col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:c.ident ascending:YES];
        [_table addTableColumn:col];
    }

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = _table;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    _footer = [NSTextField wrappingLabelWithString:@""];
    _footer.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _footer.maximumNumberOfLines = 4;
    _footer.translatesAutoresizingMaskIntoConstraints = NO;
    [_footer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                      forOrientation:NSLayoutConstraintOrientationHorizontal];

    for (NSView *v in @[ _title, _health, _previous, _next, scroll, _footer, _add, _remove ]) [_root addSubview:v];
    const CGFloat m = 6;
    [NSLayoutConstraint activateConstraints:@[
        [_title.topAnchor constraintEqualToAnchor:_root.topAnchor constant:m],
        [_title.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor constant:m],
        [_title.trailingAnchor constraintLessThanOrEqualToAnchor:_previous.leadingAnchor constant:-m],
        [_next.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor constant:-m],
        [_next.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
        [_previous.trailingAnchor constraintEqualToAnchor:_next.leadingAnchor constant:-2],
        [_previous.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
        [_health.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:2],
        [_health.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor constant:m],
        [_health.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor constant:-m],
        [scroll.topAnchor constraintEqualToAnchor:_health.bottomAnchor constant:m - 2],
        [scroll.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor constant:m],
        [scroll.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor constant:-m],
        [_footer.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:m],
        [_footer.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor constant:m],
        [_footer.trailingAnchor constraintEqualToAnchor:_root.trailingAnchor constant:-m],
        [_add.topAnchor constraintEqualToAnchor:_footer.bottomAnchor constant:m],
        [_add.leadingAnchor constraintEqualToAnchor:_root.leadingAnchor constant:m],
        [_remove.leadingAnchor constraintEqualToAnchor:_add.trailingAnchor constant:2],
        [_remove.centerYAnchor constraintEqualToAnchor:_add.centerYAnchor],
        [_add.bottomAnchor constraintEqualToAnchor:_root.bottomAnchor constant:-m],
        [scroll.heightAnchor constraintGreaterThanOrEqualToConstant:80],
    ]];
    [self update:ADIFPanelSnapshot{}];
    return self;
}

- (NSView *)view {
    return _root;
}

+ (NSString *)displayString:(const std::string &)value {
    NSString *s = ADIFString(value);
    s = [s stringByReplacingOccurrencesOfString:@"\r\n" withString:kLineBreakGlyph];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:kLineBreakGlyph];
    return [s stringByReplacingOccurrencesOfString:@"\r" withString:kLineBreakGlyph];
}

+ (std::string)valueFromDisplay:(NSString *)display {
    // ADIF line breaks are CR LF (§III.A MultilineString).
    NSString *s = [display stringByReplacingOccurrencesOfString:kLineBreakGlyph withString:@"\r\n"];
    return s.UTF8String ?: "";
}

- (void)update:(const ADIFPanelSnapshot &)snapshot {
    _snapshot = snapshot;
    _title.stringValue = ADIFString(snapshot.title);
    _health.stringValue = ADIFString(snapshot.health);
    _health.textColor = snapshot.healthSeverity >= 0 ? severityColor(snapshot.healthSeverity) : NSColor.secondaryLabelColor;
    _health.toolTip = ADIFString(snapshot.health);
    _footer.stringValue = ADIFString(snapshot.footer);
    _footer.textColor = severityColor(snapshot.footerSeverity);
    _footer.hidden = snapshot.footer.empty();
    _previous.enabled = snapshot.canPrevious;
    _next.enabled = snapshot.canNext;
    _add.enabled = snapshot.hasGroup;
    [self sortRows];
    [_table reloadData];
    NSInteger shown = [self tableRowFor:snapshot.selectedRow];
    if (shown >= 0) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)shown] byExtendingSelection:NO];
        [_table scrollRowToVisible:shown];
    } else {
        [_table deselectAll:nil];
    }
    _remove.enabled = snapshot.hasGroup && _table.selectedRow >= 0;
}

// ── Sorting (the rows shown, not the record) ────────────────────────────────

- (void)sortRows {
    _order.resize(_snapshot.rows.size());
    for (size_t i = 0; i < _order.size(); ++i) _order[i] = i;
    NSSortDescriptor *sort = _table.sortDescriptors.firstObject;
    if (!sort || [sort.key isEqualToString:kPosColumn]) {
        if (sort && !sort.ascending) std::reverse(_order.begin(), _order.end());
        return;
    }
    NSString *column = sort.key;
    bool asc = sort.ascending;
    std::stable_sort(_order.begin(), _order.end(), [&](size_t x, size_t y) {
        const ADIFPanelRow &a = _snapshot.rows[x], &b = _snapshot.rows[y];
        int c = 0;
        if ([column isEqualToString:kFieldColumn]) c = adif::naturalCompare(a.name, b.name);
        else if ([column isEqualToString:kValueColumn]) {
            if (a.value.empty() != b.value.empty()) return b.value.empty();  // empty values last either way
            c = adif::naturalCompare(a.value, b.value);
        } else {  // problems: errors, warnings, notes, then none
            if (a.severity != b.severity) c = a.severity > b.severity ? -1 : 1;
            else c = adif::naturalCompare(a.note, b.note);
        }
        return asc ? c < 0 : c > 0;
    });
}

// The table row showing a snapshot row, or -1.
- (NSInteger)tableRowFor:(NSInteger)snapshotRow {
    for (size_t i = 0; i < _order.size(); ++i)
        if ((NSInteger)_order[i] == snapshotRow) return (NSInteger)i;
    return -1;
}

// The snapshot row a table row shows, or -1.
- (NSInteger)snapshotRowFor:(NSInteger)tableRow {
    return tableRow >= 0 && (size_t)tableRow < _order.size() ? (NSInteger)_order[(size_t)tableRow] : -1;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    NSInteger selected = [self snapshotRowFor:_table.selectedRow];
    [self sortRows];
    [_table reloadData];
    NSInteger shown = [self tableRowFor:selected];
    if (shown >= 0) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)shown] byExtendingSelection:NO];
    NSSortDescriptor *sort = _table.sortDescriptors.firstObject;
    if (!_settingSort && self.onSortChanged) self.onSortChanged(sort ? sort.key : kPosColumn, sort ? sort.ascending : YES);
}

- (void)setSortColumn:(NSString *)column ascending:(BOOL)ascending {
    if (!([column isEqualToString:kPosColumn] || [column isEqualToString:kFieldColumn] ||
          [column isEqualToString:kValueColumn] || [column isEqualToString:kNoteColumn]))
        return;
    _settingSort = true;
    _table.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:column ascending:ascending] ];
    _settingSort = false;
}

// ── Table ───────────────────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_order.size();
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSInteger model = [self snapshotRowFor:row];
    if (model < 0) return nil;
    const ADIFPanelRow &r = _snapshot.rows[(size_t)model];
    NSString *ident = column.identifier;
    if ([ident isEqualToString:kPosColumn]) {
        NSTextField *f = [tableView makeViewWithIdentifier:@"pos.cell" owner:self];
        if (!f) {
            f = [NSTextField labelWithString:@""];
            f.identifier = @"pos.cell";
            f.alignment = NSTextAlignmentRight;
            f.textColor = NSColor.secondaryLabelColor;
            f.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        }
        f.stringValue = [NSString stringWithFormat:@"%ld", (long)model + 1];
        return f;
    }
    if ([ident isEqualToString:kFieldColumn]) {
        NSTextField *f = [tableView makeViewWithIdentifier:@"field.cell" owner:self];
        if (!f) {
            f = [NSTextField labelWithString:@""];
            f.identifier = @"field.cell";
            f.lineBreakMode = NSLineBreakByTruncatingTail;
            f.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightMedium];
        }
        f.stringValue = ADIFString(r.name);
        f.toolTip = ADIFString(r.tooltip);
        return f;
    }
    if ([ident isEqualToString:kNoteColumn]) {
        NSTextField *f = [tableView makeViewWithIdentifier:@"note.cell" owner:self];
        if (!f) {
            f = [NSTextField labelWithString:@""];
            f.identifier = @"note.cell";
            f.lineBreakMode = NSLineBreakByTruncatingTail;
            f.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        }
        f.stringValue = ADIFString(r.note);
        f.textColor = severityColor(r.severity);
        f.toolTip = ADIFString(r.tooltip);
        return f;
    }
    // Value: a combo box when there are values to offer, else a text field.
    NSString *display = [ADIFRecordPanel displayString:r.value];
    if (!r.choices.empty()) {
        NSComboBox *c = [tableView makeViewWithIdentifier:@"value.combo" owner:self];
        if (!c) {
            c = [[NSComboBox alloc] initWithFrame:NSZeroRect];
            c.identifier = @"value.combo";
            c.completes = YES;
            c.numberOfVisibleItems = 14;
            c.controlSize = NSControlSizeSmall;
            c.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
            c.delegate = self;
        }
        [c removeAllItems];
        for (const std::string &v : r.choices) [c addItemWithObjectValue:ADIFString(v)];
        c.stringValue = display;
        c.toolTip = ADIFString(r.tooltip);
        return c;
    }
    NSTextField *t = [tableView makeViewWithIdentifier:@"value.text" owner:self];
    if (!t) {
        t = [NSTextField textFieldWithString:@""];
        t.identifier = @"value.text";
        t.bordered = NO;
        t.drawsBackground = NO;
        t.lineBreakMode = NSLineBreakByTruncatingTail;
        t.font = [NSFont monospacedSystemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightRegular];
        t.delegate = self;
    }
    t.stringValue = display;
    t.toolTip = ADIFString(r.tooltip);
    return t;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    _remove.enabled = _snapshot.hasGroup && _table.selectedRow >= 0;
}

- (void)commit:(NSControl *)control value:(NSString *)value {
    NSInteger row = [self snapshotRowFor:[_table rowForView:control]];
    if (row < 0 || row >= (NSInteger)_snapshot.rows.size() || !value) return;
    if ([ADIFRecordPanel valueFromDisplay:value] == _snapshot.rows[(size_t)row].value) return;  // unchanged
    if (self.onEditValue) self.onEditValue(row, value);
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSControl *c = notification.object;
    if (c == _addName || c == _addValue) return;
    [self commit:c value:c.stringValue];
}

- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    NSComboBox *c = notification.object;
    if (c == _addName) {
        [self refreshAddValues];
        return;
    }
    if (c == _addValue) return;
    // The combo box's string updates after this notification; use the selected item.
    id item = c.objectValueOfSelectedItem;
    if ([item isKindOfClass:NSString.class]) [self commit:c value:item];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _addName) [self refreshAddValues];
}

// ── Buttons ─────────────────────────────────────────────────────────────────

- (void)previousRecord:(id)sender {
    if (self.onGoToRecord) self.onGoToRecord(-1);
}

- (void)nextRecord:(id)sender {
    if (self.onGoToRecord) self.onGoToRecord(1);
}

- (void)revealRow:(id)sender {
    NSInteger row = [self snapshotRowFor:_table.clickedRow];
    if (row >= 0 && self.onRevealRow) self.onRevealRow(row);
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger row = [self snapshotRowFor:_table.clickedRow];
    if (row >= 0 && !_snapshot.rows[(size_t)row].repair.empty()) {
        NSMenuItem *item = [menu addItemWithTitle:[@"Repair: " stringByAppendingString:ADIFString(_snapshot.rows[(size_t)row].repair)]
                                           action:@selector(repairRow:)
                                    keyEquivalent:@""];
        item.target = self;
        item.tag = row;
    }
    if (!_snapshot.footerRepair.empty()) {
        NSMenuItem *item = [menu addItemWithTitle:[@"Repair Record: " stringByAppendingString:ADIFString(_snapshot.footerRepair)]
                                           action:@selector(repairRow:)
                                    keyEquivalent:@""];
        item.target = self;
        item.tag = -1;
    }
    if (menu.numberOfItems == 0) [menu addItemWithTitle:@"No automatic repair here" action:nil keyEquivalent:@""].enabled = NO;
}

- (void)repairRow:(NSMenuItem *)sender {
    if (self.onRepairRow) self.onRepairRow(sender.tag);
}

- (void)removeField:(id)sender {
    NSInteger row = [self snapshotRowFor:_table.selectedRow];
    if (row >= 0 && self.onRemoveField) self.onRemoveField(row);
}

- (void)refreshAddValues {
    NSArray<NSString *> *values = self.valuesForField ? self.valuesForField(_addName.stringValue) : @[];
    [_addValue removeAllItems];
    [_addValue addItemsWithObjectValues:values ?: @[]];
}

- (void)addField:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Add a field";
    alert.informativeText = @"The data length is set for you.";
    [alert addButtonWithTitle:@"Add"];
    [alert addButtonWithTitle:@"Cancel"];

    _addName = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 30, 280, 26)];
    _addName.placeholderString = @"Field name, e.g. RST_SENT";
    _addName.completes = YES;
    _addName.numberOfVisibleItems = 14;
    for (const std::string &n : _snapshot.addableNames) [_addName addItemWithObjectValue:ADIFString(n)];
    _addName.delegate = self;
    _addValue = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 280, 26)];
    _addValue.placeholderString = @"Value";
    _addValue.completes = YES;
    _addValue.numberOfVisibleItems = 14;
    _addValue.delegate = self;
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 58)];
    [box addSubview:_addName];
    [box addSubview:_addValue];
    alert.accessoryView = box;
    alert.window.initialFirstResponder = _addName;

    NSModalResponse response = [alert runModal];
    NSString *name = [_addName.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *value = _addValue.stringValue;
    _addName = nil;
    _addValue = nil;
    if (response == NSAlertFirstButtonReturn && name.length && self.onAddField) self.onAddField(name, value);
}

@end
