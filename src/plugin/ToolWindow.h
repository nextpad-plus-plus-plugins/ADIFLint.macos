// A general window for the log tools: a "Log:" line, rows of options, an
// optional headline, a status line, a table (sortable, filterable, with
// optional tick boxes) or a read-only text report, and a row of buttons.
// AppKit only; LogTools.mm builds each tool from it and does the ADIF work.
//
// Rows are given and reported by their index in the vector passed to
// setRows (the "model row"), whatever the current sort and filter.
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>
#include <vector>

struct ADIFToolColumn {
    std::string ident, title;
    CGFloat width = 80;
};

// Severity colours: -1 plain, 0 blue (note), 1 orange (warning), 2 red (error), 3 green (done).
NSColor *ADIFSeverityColor(int severity);
NSString *ADIFString(const std::string &s);  // UTF-8, falling back to Latin-1
std::string ADIFStd(NSString *s);
// Table order: plain numbers by value, other text with digit runs by value, ignoring case.
int ADIFNaturalCompare(const std::string &a, const std::string &b);

// Small controls for option rows.
NSTextField *ADIFLabel(NSString *text);
NSTextField *ADIFTextField(NSString *placeholder, CGFloat width);
NSPopUpButton *ADIFPopup(NSArray<NSString *> *items);
NSButton *ADIFCheckbox(NSString *title, BOOL on);
NSComboBox *ADIFComboBox(NSArray<NSString *> *items, CGFloat width);
// Run `block` when the control sends its action (popup choice, checkbox click,
// search text...). The control keeps the block alive.
void ADIFOnAction(NSControl *control, void (^block)(void));
// The same for a menu item.
void ADIFBlockMenuItem(NSMenuItem *item, void (^block)(void));

@interface ADIFToolWindow : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate, NSMenuDelegate>

@property(nonatomic, readonly) NSPanel *window;
@property(nonatomic, copy) void (^onActivateRow)(NSInteger row);  // double-click
@property(nonatomic, copy) void (^onSelectionChanged)(void);  // the user changed the selection (never for restores)
@property(nonatomic, copy) void (^onTicksChanged)(void);
@property(nonatomic, copy) void (^onClose)(void);
// A cell of an editable column was edited (model row, column index, new text).
@property(nonatomic, copy) void (^onEditCell)(NSInteger row, size_t column, NSString *text);
// The user sorted by a column (-1: unsorted).
@property(nonatomic, copy) void (^onSortChanged)(NSInteger column, BOOL ascending);
// How to order two cells of a column when sorting (-1, 0, 1); empty cells then go
// last either way. Unset: ADIFNaturalCompare.
@property(nonatomic, copy) int (^compareCells)(size_t column, const std::string &a, const std::string &b);

// `headline`: reserve a line of large text above the status.
- (instancetype)initWithTitle:(NSString *)title size:(NSSize)size headline:(BOOL)headline;

- (void)setTarget:(NSString *)text;  // e.g. "Log: US-7929.adi"
- (NSStackView *)addOptionRow:(NSArray<NSView *> *)views;  // hide the returned row to remove it from the layout
- (NSButton *)addButton:(NSString *)title trailing:(BOOL)trailing action:(void (^)(void))action;
- (void)setDefaultButton:(NSButton *)button;  // Return presses it

- (void)setHeadline:(NSString *)text severity:(int)severity;
- (void)setStatus:(NSString *)text severity:(int)severity;

- (void)setColumns:(const std::vector<ADIFToolColumn> &)columns checkboxes:(BOOL)checkboxes sortable:(BOOL)sortable;
// Replaces the rows; tick boxes start ticked and the selection is cleared.
// `severities` (optional) colours each row's text.
- (void)setRows:(const std::vector<std::vector<std::string>> &)rows severities:(const std::vector<int> &)severities;
// The same with `keys` (one per row) naming what each row shows, so the
// selection stays on the same thing when rows come and go. `ticks` (optional)
// gives new rows' tick boxes; with keepTicks a row whose key was shown before
// keeps the tick the user gave it.
- (void)setRows:(const std::vector<std::vector<std::string>> &)rows
     severities:(const std::vector<int> &)severities
           keys:(const std::vector<std::string> &)keys
          ticks:(const std::vector<bool> &)ticks
      keepTicks:(BOOL)keepTicks;
- (void)setFilter:(NSString *)text;  // show rows with a cell containing the text (case-insensitive)
- (std::vector<NSInteger>)shownRows;     // model rows in display order
- (std::vector<NSInteger>)selectedRows;  // model rows
- (std::vector<bool>)ticked;             // per model row
- (void)setAllTicked:(BOOL)ticked;
- (void)setTicked:(const std::vector<bool> &)ticked;  // per model row
// Per model row: false hides that row's tick box (nothing to tick) and unticks it. Call after setRows.
- (void)setTickable:(const std::vector<bool> &)tickable;
- (void)setCell:(const std::string &)text row:(NSInteger)row column:(size_t)column;  // model row; keeps ticks and sort
- (void)setRowSeverity:(int)severity row:(NSInteger)row;
- (void)selectRow:(NSInteger)row;        // model row; scrolls to it
// Columns whose cells can be edited (double-click one); double-click elsewhere activates the row.
- (void)setEditableColumns:(const std::vector<size_t> &)columns;
- (void)setSortColumn:(NSInteger)column ascending:(BOOL)ascending;  // -1: unsorted
- (void)setHeaderMenu:(NSMenu *)menu;  // the column headings' right-click menu
- (std::vector<size_t>)columnOrder;     // the columns as shown, left to right (headings can be dragged)

// ── Spreadsheet mode (the Log Table) ──
// An active cell in the selected rows (click a cell, or Left and Right arrows);
// Return or typing edits it, Tab and Shift-Tab move along the row while editing,
// Return moves down, Esc cancels; Copy, Paste, Delete (clear), Command-Delete
// (delete rows) and Command-D (fill down) go to the blocks below.
@property(nonatomic) BOOL spreadsheet;
@property(nonatomic, copy) void (^onCopy)(void);
@property(nonatomic, copy) void (^onPaste)(NSString *text);
@property(nonatomic, copy) void (^onClearCells)(void);
@property(nonatomic, copy) void (^onDeleteRows)(void);
@property(nonatomic, copy) void (^onFillDown)(void);
// The heading menu is about to open over this column (-1: none).
@property(nonatomic, copy) void (^onHeaderMenuOpen)(NSInteger column);
@property(nonatomic) NSInteger activeColumn;            // a column index, -1 for none
- (void)beginEditingRow:(NSInteger)row column:(size_t)column;  // model row, editable column
- (void)selectRows:(const std::vector<NSInteger> &)rows;       // model rows
- (void)setRowMenu:(NSMenu *)menu;                             // the rows' right-click menu

// Show a monospaced, read-only report instead of the table.
- (void)setText:(NSString *)text;
- (NSString *)text;

- (void)show;

@end
