# Changelog

All notable changes to ADIF Lint are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is 0.x, a
minor version may change behaviour.

Versions before 0.8.0 were development builds and were not published.

## [Unreleased]

### Added

- **Monitor (WSJT-X, N1MM, Loggers)…**: QSOs other programs log are added to the log you
  choose as they're logged. It listens for WSJT-X's and JTDX's QSO Logged and Logged ADIF
  messages (2237, with an optional multicast group), JS8Call's `LOG.QSO`, ADIF records over
  UDP (2333), N1MM Logger+'s contact broadcasts with their edits and deletions (12060), and
  GridTracker's DXKeeper and HRD Logbook commands over TCP (52001), and can watch WSJT-X's
  log file or any log a program appends to. QSOs go into the open log (one undo step
  each), into the file when it isn't open, or into a queue while it's open in another tab;
  a QSO the log already has isn't added again. It only listens, on this Mac unless you
  allow other computers.
- **Import… → WSJT-X log file** compares and merges WSJT-X's own log.
- **Compare and Merge Logs…** (replacing Merge Another Log): two logs compared QSO by QSO,
  listing QSOs only one has and the fields the same QSO has differently; add the ticked
  QSOs and copy the fields this log lacks (or replace differing ones), in one undo step.
- **QSL Sync (Upload, Confirmations)…** (replacing Upload…): each service's QSOs to upload,
  changed, uploaded, unsendable and confirmed, the last upload and download, with Upload
  and Download Confirmations.
- **Spots → More programs (Spothole)**: spots from dozens of programs (GMA, WWBOTA, ZLOTA,
  IOTA, HEMA, castles, lighthouses...) through spothole.app, with a program filter, every 2
  minutes as Spothole asks; SOTA is left out. Using a spot fills SIG and SIG_INFO (and IOTA,
  and GRIDSQUARE when known). Any program's references in SIG_INFO, and IOTA, now count as
  worked, and show on the Map under Other programs (Parks keeps to POTA and WWFF). The menu
  item is now Spots (POTA, WWFF, More)….
- **Contest…** in New QSO: ARRL Field Day, Winter Field Day or serial numbers. New QSO asks
  for the other station's exchange (CLASS and ARRL_SECT, or SRX), writes CONTEST_ID, the
  exchanges (STX_STRING, SRX_STRING, MY_ARRL_SECT) or the next STX, and warns of duplicates
  by the Field Day rule (once per band and mode: CW, Phone, Digital) and of a band, mode or
  repeater the rules don't count (ARRL Field Day 2026; Winter Field Day 2027: no 12, 17, 30
  or 60 m, no WSJT modes, direct contacts only). Export Cabrillo writes Field Day lines
  without reports.
- **Map (Grids, DXCC, Parks)…**: the log on a world map, offline (Natural Earth's land,
  lakes, rivers, borders and state lines, public domain): worked and confirmed grid
  squares, DXCC, hunted parks and your grid. Zoom (pinch, wheel, double-click, buttons) and drag around, with
  field and square names as you zoom in; point at anything to read it, click it to list
  its QSOs, double-click one to go to its record. Band and mode filters, PNG export.
- **Export… → QSL labels (PDF)**: a label per station for the cards to send (QSL_SENT R or
  Q), on Avery 5160, 5163 or L7163 sheets, then Mark as Sent (QSL_SENT Y and QSLSDATE).
- **LoTW Users** (Settings, off by default): ARRL's weekly list of LoTW users, shown in New
  QSO's lookup line, a Spots column and an optional Log Table column.
- **LoTW pre-flight**: the upload window checks each QSO's call, DXCC, grid, state, county
  and zones against the TQSL Station Location as TQSL does, and names a location that
  matches the ones it would refuse. Station Locations are read from TQSL's folder
  (`~/.tqsl` or `$TQSLDIR`); a station profile's TQSL location is used when none is chosen.

- **Station profiles**: named sets of your station's fields (callsign, operator, grid,
  state, county, rig, antenna, power, TQSL location), edited in their own window and chosen
  in New QSO's new **Station** popup.
- **Start Activation…**: a POTA (two-fers too), WWFF or SOTA activation in a new log named
  as the program asks, or the open log. New QSO opens on it, writes the activation's fields
  and your profile in every QSO, and shows the progress ("US-7929 today: 8 of 10").
  **Finish** opens Check Log and the export, and for POTA a button opens pota.app's upload
  page.

- **Check Log…**: every problem in one list, with its record, line, field and repair; the
  ticked repairs are applied together as one undo step. Repairs: a MODE that is really a
  submode (`USB`, `FT4`, `JS8`, `PSK31`… become MODE SSB, MFSK or PSK with that SUBMODE),
  a SUBMODE under the wrong MODE or without one, dates and times typed `2026-10-06` and
  `22:30`, FREQ written in kHz or outside BAND, BAND missing, lowercase calls and states,
  SAT_NAME without PROP_MODE SAT, a POTA record without STATION_CALLSIGN, a repeated
  field with the same value, a missing final `<EOR>`, a byte-order mark.
- New checks for what services expect: BAND when only FREQ is given (POTA reads BAND),
  upper-case calls and states, QSO dates in the future (POTA refuses them), PROP_MODE SAT
  with SAT_NAME (LoTW), and STATION_CALLSIGN or OPERATOR in POTA activation records.
- The **Record Panel** offers a problem's repair on a right-click.
- `adiflint --fix-all OUT` applies every repair, and each diagnostic line ends with its
  code (`[mode-is-submode]`).
- **Toolbar buttons** for New QSO, Log Table, Check Log and Spots, with light and dark
  icons.
- The **Record Panel** sums up the whole log under its title: problems, QSOs waiting for each
  upload service the log uses, and today's POTA activation.
- **Settings** gains **Your Station** (callsign and grid for logs that don't name them, used
  by New QSO, distances and the exports, and the logs folder), **Editor** (the options that
  were menu items) and **Keyboard Shortcuts** (where to assign them, with suggestions). The
  first run opens Settings with a welcome.
- **Export… → CSV** shows the log as it will be saved before **Save CSV…**.
- **More of ADIF 3.1.7 checked** (every rule verified against the specification text,
  2026-10-10; see [docs/ADIF_CONFORMANCE.md](docs/ADIF_CONFORMANCE.md)):
  - codes ADIF deleted are valid only for QSOs in their dates (§II.C): ARRL sections (`ON`
    until 2012-09-01, `GTA` and `NT` until 2023, `GH`, `NB`, `NS`, `TER` from 2023), the
    Kosovo region and Russian and Austrian districts; a single named replacement valid on
    the QSO's date is the repair (`GTA` → `GH`). Autocomplete no longer offers them.
  - REGION must belong to the record's DXCC entity (§III.B.21).
  - VUCC_GRIDS and MY_VUCC_GRIDS: two or four adjacent locators of 4 or 6 characters,
    agreeing with GRIDSQUARE (§III.A.1).
  - GRIDSQUARE_EXT after an 8-character GRIDSQUARE; one longer than 4 characters is cut
    to 4, as importers ignore the rest.
  - LAT and MY_LAT start with N or S, LON and MY_LON with E or W.
  - USACA_COUNTIES (two or more `state,county`) and CNTY_ALT (`NZ_Regions:...` items, each
    list name once, codes from ADIF's table).
  - QSL dates need the status that makes them valid (QSLRDATE when QSL_RCVD is Y, I or V;
    QSLSDATE when QSL_SENT is Y, Q or I; LoTW, eQSL and DCL alike; a missing status is N).
  - A note, once per file, when STATE, CNTY, MY_STATE or MY_CNTY lacks its DXCC (§I.E),
    and when a file has a header but no records (§IV.A.2).

### Changed

- **A shorter menu**: 27 commands instead of 39. **Import…**, **Export…** and **Enrich…**
  each open the window used last, with a popup at its top for the others (Import from:
  LoTW, QRZ.com Logbook, eQSL, CSV file, WSJT-X log file); the upload windows open from QSL
  Sync and switch with the same popup. Check Log replaces **Validate Now**; Sort
  and Organize's **Date and Time** button replaces **Sort Records by Date and Time**;
  colouring, autocomplete and counting characters moved to Settings → Editor, and
  "Validate .adi Files While Typing" is now **Check .adi Files While Typing**. Nextpad++
  keeps plugin shortcuts by menu position, so check any you assigned (Edit → Shortcut
  Mapper…).
- Sort and Organize remembers a field order only when you apply one.
- A STATE or CNTY that isn't on its country's ADIF list is a warning, not an error, and says
  which country and lists its codes (Hungary's are counties such as `BP` and `PE`). These
  usually come from callbooks: QRZ.com Logbook copies the other station's profile, such as
  `H` for Hungary. Check Log offers to remove one, unticked.
- Check Log groups a problem repeated in many records into one row (an option, on by
  default), and repairing the row repairs every record. New repairs: a placeholder such as
  IOTA `none` or GRIDSQUARE `-` is removed; a Field Day class in ARRL_SECT (`1D`) moves to
  CLASS; a retired code the specification names a replacement for (STATE `DF` for Mexico
  City) becomes the new one (`CMX`).
- Check Log names the field of every problem and shows a tick box only where there is a
  repair. The Record Panel's "to upload" counts a service only once something was sent to it
  (Y or M), not when a downloaded log merely says N.
- Check Log repairs TX_PWR and RX_PWR written with a unit (`30W` becomes `30`, `1.5kW`
  `1500`), as WSJT-X writes whatever you type in its power box.

### Fixed

- WWFF export files are named as WWFF asks, `KW9D @ KFF-1234 20261006.adi`: spaces around
  the `@`, a `/` in the call written as `-`, and an activation over consecutive UTC days in
  one file named for its first day (it was one file per day, `KW9D@KFF-1234 20261006.adi`).
- The LoTW window looked for TQSL's Station Locations only in
  `~/Library/Application Support/TrustedQSL`; TQSL keeps them in `~/.tqsl` on a Mac.
- Messages cited §II.B for data types, the section number in older ADIF versions; in ADIF
  3.1.7 it is §III.A.
- ANT_AZ and ANT_EL outside 0-360 and -90-90 were errors; the specification calls them
  import-only, to be normalized on export, so they are warnings with the normalized value
  as the repair (370 → 10, 100 → 80).
- `USERDEF01` was flagged for its leading zero; n only has to be a positive integer.
- An APP_ field that first appears without a type (so a MultilineString) and later with
  another type is now reported, as the specification forbids changing it.
- A latitude of 90 degrees with minutes, or a longitude of 180 with minutes, was accepted.

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
