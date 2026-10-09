# Changelog

All notable changes to ADIF Lint are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is 0.x, a
minor version may change behaviour.

Versions before 0.8.0 were development builds and were not published.

## [Unreleased]

### Fixed

- WWFF export files are named as WWFF asks, `KW9D @ KFF-1234 20261006.adi`: spaces around
  the `@`, a `/` in the call written as `-`, and an activation over consecutive UTC days in
  one file named for its first day (it was one file per day, `KW9D@KFF-1234 20261006.adi`).

## [0.9.0] - 2026-10-09

### Added

- The **Log Table edits like a spreadsheet**. Click a cell and type, or press Return; Tab,
  Shift-Tab and Return move on, Esc cancels, and Left and Right move the active cell.
  Command-C copies the selected rows as tab-separated text with a heading row of field
  names (for Numbers or Excel); Command-V pastes cells, by field name when the text has
  that heading row, with rows past the end becoming new QSOs. Command-D fills down, Delete
  clears a field, Command-Delete deletes rows, **Add Row** appends a QSO with today's UTC
  date and time and the station's fields, and the heading menu can **Add Field…** as a new
  column or **Remove** a field from every record. A right-click menu on the rows offers
  the same. Each change is one undo step in the `.adi` file.
- **Sort and Organize…**: sort the records by up to three fields (ascending or descending;
  bands by frequency, dates and times in time order, numbers by value), and give every
  record the same field order without changing any data. One undo step; the choices are
  remembered. The Log Table's **Organize Log…** starts from its sort and columns, and the
  table now sorts bands by frequency and empty cells last. `adiflint --sort-by` and
  `--field-order` do the same from the command line.
- **Import from LoTW…, Import from QRZ.com Logbook…, Import from eQSL…**, grouped with
  Import CSV: download your QSOs from the site, add the ones the log lacks, and add the
  confirmation and its details to the ones it has, after a review (one undo step). LoTW
  returns every QSO you uploaded, confirmed or not; QRZ.com Logbook every record; eQSL its
  InBox, whose QSOs the log lacks are offered but not ticked, since they are the other
  station's records.
- [User guide](docs/USER_GUIDE.md), [CONTRIBUTING.md](CONTRIBUTING.md) and
  [SECURITY.md](SECURITY.md); the README is rewritten as an overview, with this changelog
  kept separately.

### Changed

- The **Record Panel** can be sorted: click a heading to order its rows by field name,
  value or problem (errors first), or **#** (a new column, the field's position) for the
  record's own order. Only the view changes, and the choice is remembered.
- The confirmation sources leave Enrich: **Enrich from LoTW Confirmations…**, **QRZ.com
  Logbook Confirmations…** and **eQSL Confirmations…** are replaced by the Import commands.
  Enrich keeps QRZ.com, HamQTH and Country Data.
- A confirmation from eQSL or QRZ.com Logbook upgrades a status that says it hasn't
  happened (EQSL_QSL_RCVD N, R, Q or I becomes Y; APP_QRZLOG_STATUS becomes C), as LoTW's
  already did.
- Using a spot runs New QSO's lookup, so the country and the park's history show at once.
- The About box describes the current features and links to the project page.

### Removed

- The radio connection: **From Radio**, **Follow the radio** and Settings → Radio
  (Hamlib `rigctld` and flrig). The old radio settings are dropped from `ADIFLint.ini`.

## [0.8.0] - 2026-10-08

First public release.

### Added

- **New QSO lookup as you type.** Country data (offline) fills DXCC, COUNTRY, CQZ, ITUZ
  and CONT from the call's prefix; QRZ.com or HamQTH add name, QTH, state and grid from
  your callbook account. A line under it shows distance and bearing from MY_GRIDSQUARE
  and what your logs say about the park, reference or summit.
- **WWFF spots** beside POTA spots, from spots.wwff.co, and a Worked column marking each
  spot NEW, worked or today.
- **WWFF and SOTA** in the Activation Tracker and the export: WWFF counts 44 QSOs per
  reference over all activations; SOTA counts distinct stations per summit and day.
  Files are named as each program asks (`KW9D@KFF-1234 20261006.adi`,
  `KW9D_W7A-AE-001_20261006.adi`).
- **Confirmations from QRZ.com Logbook and eQSL**, as two new Enrich sources.
- **Offline country data** from AD1C's Big CTY file (MIT licence), installed with the
  plugin, with **Update** in Settings to download the newest release.
- **Import CSV**, **Export Cabrillo** (Cabrillo 3.0) and **Fill DISTANCE from grid
  squares** in Bulk Edit.
- **Log Table** editing (double-click a value), column choice (right-click the headings)
  and a remembered sort.
- **Parks worked** (a hunter's tally) in the Log Summary.
- **TQSL certificate password**, kept in the Keychain and passed to TQSL with `-p`.
- **Command-line log tools**: `--sort`, `--dedupe`, `--csv`, `--from-csv`, `--summary`,
  `--cabrillo` and `--export pota|wwff|sota`.
- `tools/make-release.sh`, which builds the release zip and prints the plugin-list entry.

### Changed

- Menu items renamed: **POTA Spots…** is now **Spots (POTA, WWFF)…**, **POTA Activation
  Tracker…** is **Activation Tracker (POTA, WWFF, SOTA)…**, and **Export POTA Logs…** is
  **Export Activation Logs…**.
- **Time Shift** converts between UTC and a named time zone in either direction, using the
  offset in force on each QSO's date; skipped and repeated local times are listed and left
  alone. The fixed-amount shift remains.
- An uploaded QSO that you change becomes M (modified since upload), as ADIF prescribes,
  and is sent again; QRZ.com receives it with OPTION=REPLACE.
- The Log Table shows dates and times as 2026-10-06 and 22:30.

### Fixed

- The Log Table moved the editor's caret to the selected record whenever the log was
  re-checked while you typed.
- Table selections followed the row position instead of the record, so a refreshed spot
  list could fill New QSO with a different activator.
- Records without STATION_CALLSIGN split an activation in two and produced two export
  files with the same name.
- A park listed twice in MY_POTA_REF put the record in the export file twice.
- New QSO warned about a duplicate when working the same activator at another park
  (park-to-park), and treated `N0CX/P` and `N0CX` as different calls.
- Upload windows re-ticked QSOs you had unticked whenever the log changed.
- Table sorting treated `INF`, `NAN` and `0x…` as numbers.
- TQSL could run with no time limit; it is now stopped after 10 minutes.
- A CW spot left an earlier USB SUBMODE from the radio in New QSO.

## [0.7.0] - 2026-10-07

### Added

- **Log tools:** Log Table, Log Summary, POTA Activation Tracker, Export POTA Logs (one
  file per park and UTC day), Worked Before across a folder of logs, Bulk Edit, Time Shift
  by a fixed amount, Sort Records by Date and Time, Remove Duplicates, Merge Another Log
  and Export CSV. Every change is one undo step, and Bulk Edit and Time Shift preview
  every change first.
- **Radio in New QSO:** From Radio and Follow the radio, through Hamlib `rigctld` or flrig,
  read-only.
- **POTA Spots**, filling New QSO from an activator's spot.
- **Worked before** in New QSO, from the logs folder.
- **Uploads** to QRZ.com Logbook, LoTW (through TQSL), Club Log and eQSL. Each lists what
  would be sent and sends nothing until you press Upload; accepted QSOs get the ADIF
  upload-status field and date.
- Settings → Radio, with Test.

## [0.6.0] - 2026-10-07

### Added

- **New QSO Fields…**: choose and order the fields New QSO asks for, with each field's
  type and the description from the ADIF 3.1.7 specification, searchable by name or
  description. Station fields you hide are still copied from the last record unless you
  turn that off.

### Changed

- Field descriptions are generated from the ADIF specification's HTML, not its data
  export, so descriptions and notes no longer run together.

## [0.5.0] - 2026-10-07

### Added

- **Settings…**: one section per service, with Save, Test Sign-In and Remove. Accounts are
  kept only in the macOS Keychain.

### Changed

- Enrich is one menu item per source: Enrich from QRZ.com…, from HamQTH… and from LoTW
  Confirmations….
- The QRZ.com sign-in is sent as a POST, so the password is not in a URL, and messages
  QRZ.com sends back are shown.

### Fixed

- New QSO left a large empty area below its fields.

## [0.4.0] - 2026-10-06

### Added

- **Enrich Log**: add missing NAME, QTH, STATE, CNTY, GRIDSQUARE, DXCC and COUNTRY, zones,
  IOTA and continent from QRZ.com XML, HamQTH or LoTW confirmations, reviewed before
  anything changes. Portable and park-to-park records get only the name from a callbook.

## [0.3.0] - 2026-10-06

### Added

- **New QSO…**: a window for logging contacts one after another. Station fields carry
  over from the last record, date and time are UTC, duplicates are flagged, and each
  record is appended with correct lengths in the log's own layout.

## [0.2.0] - 2026-10-06

### Added

- Syntax colouring, Reformat (one record or one field per line), autocomplete of field
  names and values with automatic lengths, and the docked Record Panel.
- `adiflint --reformat records|fields OUT`.

## [0.1.0] - 2026-10-06

### Added

- Validation of `.adi` files as you type against ADIF 3.1.7, with marks you can hover to
  read, Next Problem and Previous Problem, and Validate Now.
- **Fix Lengths**, as one undo step, and **Count Lengths in Characters**.
- The `adiflint` command-line tool.

[Unreleased]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/releases/tag/v0.8.0
