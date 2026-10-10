#import "SettingsPanel.h"

#import "Lookup.h"

// Flipped, so the sections start at the top of the scroll view.
@interface ADIFSettingsDocument : NSView
@end
@implementation ADIFSettingsDocument
- (BOOL)isFlipped {
    return YES;
}
@end

@implementation ADIFSettingsPanel {
    NSPanel *_window;
    NSMutableArray<NSTextField *> *_user;    // per source; hidden for API-key sources
    NSMutableArray<NSSecureTextField *> *_secret;
    NSMutableArray<NSTextField *> *_status;
    NSTextField *_countryStatus;
    NSButton *_countryUpdate;
    NSScrollView *_scroll;
    NSTextField *_welcome, *_stationCall, *_stationGrid, *_logsFolder, *_stationStatus;
    NSArray<NSButton *> *_editorBoxes;
}

static NSTextField *sectionTitle(NSString *text) {
    NSTextField *title = [NSTextField labelWithString:text];
    title.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize + 1];
    return title;
}

static NSStackView *sectionStack(NSArray<NSView *> *views, NSString *identifier) {
    NSStackView *section = [NSStackView stackViewWithViews:views];
    section.orientation = NSUserInterfaceLayoutOrientationVertical;
    section.alignment = NSLayoutAttributeLeading;
    section.spacing = 8;
    [section setCustomSpacing:4 afterView:views.firstObject];
    section.identifier = identifier;
    return section;
}

// Fixed text width: wrapping labels need it to work out their height.
static const CGFloat kTextWidth = 520;

static NSTextField *wrapping(NSString *text, CGFloat size, NSColor *color) {
    NSTextField *t = [NSTextField wrappingLabelWithString:text ?: @""];
    t.font = [NSFont systemFontOfSize:size];
    t.textColor = color;
    t.preferredMaxLayoutWidth = kTextWidth;
    [t.widthAnchor constraintEqualToConstant:kTextWidth].active = YES;
    return t;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _user = [NSMutableArray array];
    _secret = [NSMutableArray array];
    _status = [NSMutableArray array];
    _window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kTextWidth + 40, 400)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                           backing:NSBackingStoreBuffered
                                             defer:YES];
    _window.title = @"ADIF Lint Settings";
    _window.floatingPanel = YES;
    _window.hidesOnDeactivate = YES;
    _window.releasedWhenClosed = NO;
    _window.delegate = self;

    NSMutableArray<NSView *> *views = [NSMutableArray array];
    _welcome = wrapping(@"Welcome to ADIF Lint. Enter your callsign and grid below: New QSO and the exports use them for "
                        @"a log that doesn't have them yet. Accounts for QRZ.com, LoTW, eQSL and Club Log are further "
                        @"down, when you want them.",
                        NSFont.systemFontSize, NSColor.labelColor);
    _welcome.hidden = YES;
    [views addObject:_welcome];
    for (NSView *section in @[ [self stationSection], [self editorSection], [self keyboardSection], [self countrySection] ]) {
        [views addObject:section];
        NSBox *line = [[NSBox alloc] init];
        line.boxType = NSBoxSeparator;
        [line.widthAnchor constraintEqualToConstant:kTextWidth].active = YES;
        [views addObject:line];
    }
    [views addObject:wrapping(@"Accounts and API keys for the online services. They are saved in your macOS Keychain "
                              @"(items named \"ADIF Lint: ...\"), never in a file, and a saved password is never shown "
                              @"here.",
                              NSFont.systemFontSize, NSColor.labelColor)];
    for (NSInteger s = 0; s < ADIFSourceCount; ++s) {
        NSBox *line = [[NSBox alloc] init];
        line.boxType = NSBoxSeparator;
        [line.widthAnchor constraintEqualToConstant:kTextWidth].active = YES;
        [views addObject:line];
        [views addObject:[self sectionFor:(ADIFSource)s]];
    }
    // Plain stack views size themselves from their content (an NSBox does not).
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.edgeInsets = NSEdgeInsetsMake(18, 20, 20, 20);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    // The sections scroll when the screen is too short for all of them.
    NSView *document = [[ADIFSettingsDocument alloc] initWithFrame:NSZeroRect];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:stack];
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.drawsBackground = NO;
    _scroll.documentView = document;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *root = _window.contentView;
    [root addSubview:_scroll];
    NSSize fit = stack.fittingSize;
    CGFloat screen = NSScreen.mainScreen ? NSHeight(NSScreen.mainScreen.visibleFrame) - 80 : 760;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor],
        [document.leadingAnchor constraintEqualToAnchor:_scroll.contentView.leadingAnchor],
        [document.trailingAnchor constraintEqualToAnchor:_scroll.contentView.trailingAnchor],
        [document.topAnchor constraintEqualToAnchor:_scroll.contentView.topAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];
    [_window setContentSize:NSMakeSize(fit.width, MIN(fit.height, MAX(screen, 400)))];
    _window.contentMinSize = NSMakeSize(fit.width, 300);
    _window.contentMaxSize = NSMakeSize(fit.width, fit.height);
    _window.styleMask |= NSWindowStyleMaskResizable;
    [_window center];
    [self refresh];
    return self;
}

- (NSView *)stationSection {
    _stationCall = [NSTextField textFieldWithString:@""];
    _stationCall.placeholderString = @"e.g. KW9D";
    _stationGrid = [NSTextField textFieldWithString:@""];
    _stationGrid.placeholderString = @"e.g. EN52";
    for (NSTextField *f in @[ _stationCall, _stationGrid ]) [f.widthAnchor constraintEqualToConstant:140].active = YES;
    _logsFolder = [NSTextField labelWithString:@""];
    _logsFolder.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_logsFolder.widthAnchor constraintLessThanOrEqualToConstant:300].active = YES;
    NSButton *choose = [NSButton buttonWithTitle:@"Choose..." target:self action:@selector(chooseFolder:)];
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[ [NSTextField labelWithString:@"Callsign:"], _stationCall ],
        @[ [NSTextField labelWithString:@"Grid:"], _stationGrid ],
        @[ [NSTextField labelWithString:@"Logs folder:"], [NSStackView stackViewWithViews:@[ _logsFolder, choose ]] ],
    ]];
    grid.rowSpacing = 6;
    grid.columnSpacing = 8;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:0].width = 80;
    NSButton *save = [NSButton buttonWithTitle:@"Save" target:self action:@selector(saveStation:)];
    NSButton *profiles = [NSButton buttonWithTitle:@"Station Profiles..." target:self action:@selector(stationProfiles:)];
    profiles.toolTip = @"Named sets of your station's fields (home, portable, a club station) for New QSO and activations";
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ save, profiles ]];
    _stationStatus = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    NSTextField *help = wrapping(@"Used when a log doesn't say: New QSO fills STATION_CALLSIGN and MY_GRIDSQUARE from them "
                                 @"in a new log, and the exports use the callsign. Worked Before searches the logs folder.",
                                 NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    return sectionStack(@[ sectionTitle(@"Your Station"), help, grid, buttons, _stationStatus ], @"settings.station");
}

- (void)stationProfiles:(id)sender {
    if (self.onStationProfiles) self.onStationProfiles();
}

- (void)chooseFolder:(id)sender {
    if (self.onChooseLogsFolder) self.onChooseLogsFolder();
}

- (void)saveStation:(id)sender {
    if (self.onStationSave) self.onStationSave(_stationCall.stringValue, _stationGrid.stringValue);
}

- (void)setStationCall:(NSString *)call grid:(NSString *)grid logsFolder:(NSString *)folder {
    _stationCall.stringValue = call ?: @"";
    _stationGrid.stringValue = grid ?: @"";
    _logsFolder.stringValue = folder.length ? folder.stringByAbbreviatingWithTildeInPath : @"(none)";
}

- (void)setStationStatus:(NSString *)text ok:(BOOL)ok {
    _stationStatus.stringValue = text ?: @"";
    _stationStatus.textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
}

- (NSView *)editorSection {
    NSArray<NSString *> *titles = @[
        @"Check .adi files while typing (problem marks)", @"Colour ADIF syntax",
        @"Autocomplete field names and values, with lengths", @"Count lengths in characters, not bytes (for UTF-8 logs)"
    ];
    NSMutableArray<NSButton *> *boxes = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; ++i) {
        NSButton *b = [NSButton checkboxWithTitle:titles[i] target:self action:@selector(editorOption:)];
        b.tag = (NSInteger)i;
        [boxes addObject:b];
    }
    _editorBoxes = boxes;
    NSMutableArray<NSView *> *views = [NSMutableArray arrayWithObject:sectionTitle(@"Editor")];
    [views addObjectsFromArray:boxes];
    return sectionStack(views, @"settings.editor");
}

- (void)editorOption:(NSButton *)sender {
    if (self.onEditorOption) self.onEditorOption(sender.tag, sender.state == NSControlStateValueOn);
}

- (void)setEditorValidate:(BOOL)validate colour:(BOOL)colour autocomplete:(BOOL)autocomplete characters:(BOOL)characters {
    BOOL on[] = {validate, colour, autocomplete, characters};
    for (NSUInteger i = 0; i < _editorBoxes.count && i < 4; ++i)
        _editorBoxes[i].state = on[i] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (NSView *)keyboardSection {
    NSTextField *help = wrapping(
        @"Nextpad++ binds plugin commands in its own Shortcut Mapper: Edit > Shortcut Mapper..., the Plugin commands tab. "
        @"Suggestions: New QSO Control-Option-N, Log Table Control-Option-T, Check Log Control-Option-C, Next Problem "
        @"Control-Option-Down, Previous Problem Control-Option-Up, Spots Control-Option-S (pick others if Nextpad++ "
        @"already uses one).",
        NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    return sectionStack(@[ sectionTitle(@"Keyboard Shortcuts"), help ], @"settings.keyboard");
}

- (void)showWelcome {
    _welcome.hidden = NO;
    [self refresh];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_stationCall];
    [_welcome scrollRectToVisible:_welcome.bounds];
}

- (NSView *)countrySection {
    NSTextField *title = [NSTextField labelWithString:@"Country Data"];
    title.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize + 1];
    NSTextField *help = wrapping(@"DXCC entity, CQ and ITU zones and continent from a call's prefix, offline, for Enrich from "
                                 @"Country Data and New QSO. From Jim Reisert AD1C's country files (country-files.com, "
                                 @"MIT licence), updated every few weeks. Update downloads the newest release.",
                                 NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    _countryUpdate = [NSButton buttonWithTitle:@"Update" target:self action:@selector(countryUpdate:)];
    _countryStatus = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);
    NSStackView *section = [NSStackView stackViewWithViews:@[ title, help, _countryUpdate, _countryStatus ]];
    section.orientation = NSUserInterfaceLayoutOrientationVertical;
    section.alignment = NSLayoutAttributeLeading;
    section.spacing = 8;
    [section setCustomSpacing:4 afterView:title];
    section.identifier = @"settings.country";
    return section;
}

- (void)countryUpdate:(id)sender {
    _countryUpdate.enabled = NO;
    [self setCountryStatus:@"Downloading the newest country file..." ok:YES];
    if (self.onCountryUpdate) self.onCountryUpdate();
}

- (void)setCountryStatus:(NSString *)text ok:(BOOL)ok {
    _countryUpdate.enabled = YES;
    _countryStatus.stringValue = text ?: @"";
    _countryStatus.textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
}

- (NSView *)sectionFor:(ADIFSource)source {
    NSTextField *title = [NSTextField labelWithString:ADIFSourceName(source)];
    title.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize + 1];
    NSTextField *help = wrapping(ADIFSourceCredentialHelp(source), NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);

    BOOL apiKey = ADIFSourceCredentialKind(source) == ADIFCredentialAPIKey;
    NSTextField *user = [NSTextField textFieldWithString:@""];
    user.placeholderString = ADIFSourceUserLabel(source);
    NSSecureTextField *secret = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    secret.placeholderString = ADIFSourceSecretLabel(source);
    for (NSTextField *f in @[ user, secret ]) [f.widthAnchor constraintEqualToConstant:300].active = YES;
    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[ [NSTextField labelWithString:[ADIFSourceUserLabel(source) stringByAppendingString:@":"]], user ],
        @[ [NSTextField labelWithString:[ADIFSourceSecretLabel(source) stringByAppendingString:@":"]], secret ],
    ]];
    grid.rowSpacing = 6;
    grid.columnSpacing = 8;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:0].width = 80;
    [grid rowAtIndex:0].hidden = apiKey;

    NSButton *save = [NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)];
    NSButton *test = [NSButton buttonWithTitle:@"Test Sign-In" target:self action:@selector(test:)];
    test.hidden = !ADIFSourceCanTest(source);
    NSButton *remove = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(remove:)];
    for (NSButton *b in @[ save, test, remove ]) b.tag = source;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ save, test, remove ]];
    buttons.spacing = 8;
    NSTextField *status = wrapping(@"", NSFont.smallSystemFontSize, NSColor.secondaryLabelColor);

    NSStackView *section = [NSStackView stackViewWithViews:@[ title, help, grid, buttons, status ]];
    section.orientation = NSUserInterfaceLayoutOrientationVertical;
    section.alignment = NSLayoutAttributeLeading;
    section.spacing = 8;
    [section setCustomSpacing:4 afterView:title];
    section.identifier = [NSString stringWithFormat:@"settings.source.%ld", (long)source];

    [_user addObject:user];
    [_secret addObject:secret];
    [_status addObject:status];
    return section;
}

- (NSPanel *)window {
    return _window;
}

- (void)setStatus:(NSString *)text ok:(BOOL)ok forSource:(NSInteger)s {
    _status[(NSUInteger)s].stringValue = text ?: @"";
    _status[(NSUInteger)s].textColor = ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;
}

- (void)refresh {
    for (NSInteger s = 0; s < ADIFSourceCount; ++s) {
        NSString *account = ADIFSavedAccount((ADIFSource)s);
        BOOL secret = ADIFHasSecret((ADIFSource)s);
        BOOL apiKey = ADIFSourceCredentialKind((ADIFSource)s) == ADIFCredentialAPIKey;
        _user[(NSUInteger)s].stringValue = apiKey ? @"" : (account ?: @"");
        _secret[(NSUInteger)s].stringValue = @"";
        _secret[(NSUInteger)s].placeholderString =
            secret ? @"Saved in your Keychain (type to replace)" : ADIFSourceSecretLabel((ADIFSource)s);
        [self setStatus:secret ? @"Saved." : @"Not set." ok:YES forSource:s];
    }
}

- (void)showSource:(NSInteger)source {
    [self refresh];
    [_window makeKeyAndOrderFront:nil];
    if (source == -3) {  // country data
        [_countryUpdate scrollRectToVisible:_countryUpdate.bounds];
        return;
    }
    if (source >= 0 && source < ADIFSourceCount) {
        BOOL apiKey = ADIFSourceCredentialKind((ADIFSource)source) == ADIFCredentialAPIKey;
        NSTextField *first = apiKey || _user[(NSUInteger)source].stringValue.length ? _secret[(NSUInteger)source]
                                                                                     : _user[(NSUInteger)source];
        [_window makeFirstResponder:first];
        [first scrollRectToVisible:first.bounds];
    }
}

- (void)save:(NSButton *)sender {
    NSInteger s = sender.tag;
    NSString *user = [_user[(NSUInteger)s].stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *secret = _secret[(NSUInteger)s].stringValue;
    NSString *error = nil;
    if (!ADIFSaveCredential((ADIFSource)s, user, secret, &error)) {
        [self setStatus:error ?: @"Could not save." ok:NO forSource:s];
        return;
    }
    _secret[(NSUInteger)s].stringValue = @"";  // do not keep the secret in the window
    _secret[(NSUInteger)s].placeholderString = @"Saved in your Keychain (type to replace)";
    [self setStatus:@"Saved in your Keychain." ok:YES forSource:s];
    if (self.onChanged) self.onChanged(s);
}

- (void)test:(NSButton *)sender {
    NSInteger s = sender.tag;
    sender.enabled = NO;
    [self setStatus:@"Signing in..." ok:YES forSource:s];
    ADIFTestCredential((ADIFSource)s, ^(BOOL ok, NSString *message) {
        sender.enabled = YES;
        [self setStatus:message ok:ok forSource:s];
    });
}

- (void)remove:(NSButton *)sender {
    NSInteger s = sender.tag;
    ADIFDeleteCredential((ADIFSource)s);
    [self refresh];
    [self setStatus:@"Removed from your Keychain." ok:YES forSource:s];
    if (self.onChanged) self.onChanged(s);
}

@end
