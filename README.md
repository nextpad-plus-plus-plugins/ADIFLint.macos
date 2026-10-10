# ADIF Lint for Nextpad++ (macOS)

ADIF Lint is a [Nextpad++](https://nextpad.org) plugin for amateur-radio logs in
[ADIF 3.1.7](https://www.adif.org/317/ADIF_317.htm) ADI format (`.adi`, `.adif`). It checks
a log as you type and repairs its data lengths, and it adds what you need around a log:
logging contacts, tools for POTA, WWFF and SOTA activations, importing your QSOs and
confirmations from LoTW, QRZ.com and eQSL, filling in missing details from callbooks, and
uploading to QRZ.com, LoTW, Club Log and eQSL.

Hand-editing an ADI file is risky: every field is written `<NAME:LENGTH>data`, so
changing `W1AW` to `W1AW/P` without changing `4` to `6` silently truncates the call, and a
length that is too long swallows the next field. Most programs that import the file
don't report either mistake. ADIF Lint marks them as you type and fixes them in one step.

ADIF Lint is free software under the [GNU GPL v3](LICENSE). It is an independent project,
not affiliated with or endorsed by the Nextpad++ or Notepad++ projects.

| New QSO, filled from a POTA spot | Log Table |
|---|---|
| ![New QSO window filled from a POTA spot: station fields carried over, the park in SIG_INFO, and a lookup line with the country and "US-12593: a new park!"](docs/images/new-qso-spot.png) | ![Log Table: records with readable dates and times, sortable and editable like a spreadsheet, with Add Row and Organize Log buttons](docs/images/log-table.png) |
| **Activation Tracker** | **Upload to QRZ.com Logbook** |
| ![Activation Tracker: a POTA park-day with 10 QSOs, activated](docs/images/activation-tracker.png) | ![Upload window: QSOs to send, one that can't be sent in red, nothing sent until Upload](docs/images/upload-qrz.png) |

*Screenshots from the test suite, with sample data.*

## Features

**Checking and repairing**
- Problems marked as you type, checked against the ADIF 3.1.7 specification: data lengths,
  structure, field names, data types, enumerations (BAND, MODE and SUBMODE, QSL statuses,
  STATE for the DXCC entity…), FREQ against BAND, user-defined and `APP_` fields. Hover a
  mark to read why.
- **Check Log** lists every problem with its repair, and repairs the ones you tick in one
  undo step: MODE `USB` or `FT4` written as the mode (becomes MODE SSB, SUBMODE USB),
  dates and times typed as `2026-10-06` and `22:30`, a FREQ written in kHz, BAND missing
  or not matching FREQ, TX_PWR written as `30W`, lowercase calls and states, a satellite QSO
  without `PROP_MODE SAT`, a POTA record without STATION_CALLSIGN, a repeated field, a
  missing final `<EOR>`. It also flags QSO dates in the future, which POTA refuses. The Record Panel
  offers the same repairs on a right-click.
- **Fix Lengths** corrects every wrong `<FIELD:LENGTH>` in one undo step.
- The **Record Panel** shows the whole log in a line under its title: problems, QSOs waiting
  for each upload service the log uses, and today's POTA activation ("US-7929 today: 8 of
  10").
- Syntax colouring, **Reformat** (one record or one field per line, without touching any
  data), autocomplete of field names and values with automatic lengths, and a docked
  **Record Panel** for editing the record at the caret, sortable by field, value or
  problem.

**Logging**
- **New QSO**: log contacts one after another, with your station's fields carried over,
  UTC date and time, live checks and duplicate warnings that follow POTA's park-to-park
  rule.
- Callsign lookup as you type: country, zones and continent offline, or name, QTH and grid
  from QRZ.com or HamQTH, with distance and bearing and what your logs say about the park.
- POTA and WWFF spots, marked NEW when the park or reference isn't in your logs; pick one
  to fill New QSO.
- **Monitor**: QSOs logged in WSJT-X, JTDX, JS8Call, N1MM Logger+, GridTracker (to DXKeeper,
  HRD, N1MM or Log4OM) or another program that sends ADIF over UDP are added to the log you
  choose as you log them: into the open log, into the file when it's closed, or queued
  while it's in another tab. It can also watch WSJT-X's log file. It only listens, and only
  on this Mac unless you allow other computers.
- **Station profiles** (home, portable, a club station) and **Start Activation**: choose
  the program, the park or parks (a two-fer too), WWFF reference or summit and a profile,
  and ADIF Lint starts a log named as the program asks and opens New QSO on it, writing
  MY_SIG, MY_POTA_REF and your station's fields in every QSO and showing the progress
  ("US-7929 today: 8 of 10"). **Finish** opens Check Log and the export.

**Log tools**
- A sortable, filterable **Log Table** that edits like a spreadsheet: type into cells,
  copy and paste to and from Numbers or Excel, fill down, add and delete rows, and add or
  remove a field as a column. Plus a **Log Summary** and **Worked Before** across a folder
  of logs.
- **Activation Tracker** for POTA, WWFF and SOTA, each with its own rule, and **Export
  Activation Logs** with each program's file names.
- **Sort and Organize**: sort the records by any fields (e.g. band, then call, then date),
  each ascending or descending, and give every record the same field order, without
  changing any data. The Log Table's **Organize Log…** starts from the table's sort and
  columns.
- **Bulk Edit**, **Time Shift** (local time to UTC and back, daylight saving included),
  **Remove Duplicates** and **Compare and Merge Logs** (QSOs only one log has, and what the
  same QSO says differently in each), each previewed before it changes anything.
- **Import CSV**, **Export CSV** and **Export Cabrillo**.

**Online services**
- **Import** your QSOs from LoTW, QRZ.com Logbook or eQSL: QSOs the log lacks are added,
  and the ones it has gain the site's confirmation and the details that come with it,
  after you review every change.
- **Enrich** missing fields from QRZ.com, HamQTH or offline country data.
- **QSL Sync** shows each service at a glance: QSOs to upload, uploaded, confirmed, and the
  last download. Before a LoTW upload, each QSO's station fields are checked against your
  TQSL Station Location the way TQSL checks them.
- **Upload** to QRZ.com Logbook, LoTW (through TQSL), Club Log and eQSL. Each window lists
  exactly what would be sent, nothing is sent until you press Upload, and the ADIF
  upload-status fields are kept up to date.
- Accounts are kept only in your macOS Keychain.

**Command line**
- `adiflint` runs the same checks and log tools in a terminal.

Every window and option is described in the [user guide](docs/USER_GUIDE.md).

## Requirements

- macOS 11 or later, on Apple silicon or Intel (the plugin is universal).
- Nextpad++ for Mac 1.1.2 or later.
- Optional: TQSL for LoTW uploads, and accounts with the online services you use.

## Install

**From a release.** Download `ADIFLintvX.Y.Z.zip` from
[Releases](https://github.com/ssamjung2/Nextpad_plus_plus_ADIFLint/releases), unzip it,
move the `ADIFLint` folder into `~/Library/Application Support/Nextpad++/plugins/`, and
restart Nextpad++. The release is ad-hoc signed, not notarized. If Nextpad++ won't load it
after a browser download, clear the download's quarantine flag:

```bash
xattr -dr com.apple.quarantine ~/Library/Application\ Support/Nextpad++/plugins/ADIFLint
```

**From Plugins Admin.** ADIF Lint is not yet in the Nextpad++ plugin list. Once it is, it
will install from **Plugins → Plugins Admin**.

**From source.** With the Xcode command-line tools and CMake 3.20 or later:

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
```

```bash
cmake --build build -j
```

```bash
cmake --install build
```

The install step copies the plugin into the folder above. It writes a new file and renames
it into place, so it is safe while Nextpad++ is running; restart Nextpad++ to load it.

To uninstall, quit Nextpad++ and delete the `ADIFLint` folder.

## Getting started

1. Open an `.adi` file. Problems are marked within half a second; rest the mouse on a mark
   to read it.
2. **Plugins → ADIF Lint → Check Log…** lists every problem and repairs what it can;
   **Fix Lengths** repairs the data lengths.
3. **New QSO…** starts logging. The first time, Settings asks for your callsign and grid.
4. To use an online service, add your account in **Settings…** first.

The source repository has [`examples/try-me.adi`](examples/try-me.adi), with one of each
kind of mistake.

## Menu

All commands are under **Plugins → ADIF Lint**. Nextpad++ ignores plugin default
shortcuts, so assign your own in Nextpad++'s **Edit → Shortcut Mapper…** (Plugin commands
tab); Settings suggests some.

| Command | Does |
|---|---|
| New QSO… | Log contacts one after another |
| Spots (POTA, WWFF)… | Activators spotted now; pick one to fill New QSO |
| Start Activation… | A POTA, WWFF or SOTA activation: a new log, your station profile and the activation's fields in every QSO; Finish checks and exports |
| Log Table… | The log as a spreadsheet: sort, filter, edit, copy and paste, add and delete rows and columns |
| Check Log… | Every problem in one list, with its repair; repair the ticked ones in one step |
| Fix Lengths | Correct every data length |
| Next Problem / Previous Problem | Move between marks |
| Bulk Edit… | Set, replace, remove or rename a field, or fill DISTANCE, with a preview |
| Time Shift… | Convert times between UTC and a time zone, or shift by a fixed amount |
| Sort and Organize… | Sort the records (by date and time in one click, or by any fields), and put every record's fields in one order |
| Remove Duplicates… | Find QSOs logged twice and remove them after review |
| Compare and Merge Logs… | Compare with another log: add the QSOs only it has, copy the fields this log lacks |
| Log Summary… | Counts by band, mode, day, entity and park; confirmations and uploads |
| Activation Tracker (POTA, WWFF, SOTA)… | Activations counted by each program's rule |
| Worked Before… | Search a folder of logs for a call |
| Import… | From LoTW, QRZ.com Logbook or eQSL (your QSOs and confirmations), a CSV file, or WSJT-X's log |
| Export… | Activation logs for POTA, WWFF or SOTA, CSV, or a Cabrillo contest log |
| QSL Sync (Upload, Confirmations)… | Each service at a glance; upload to QRZ.com Logbook, LoTW (TQSL), Club Log or eQSL (list what would be sent, upload when you say so, mark it uploaded) and download confirmations |
| Enrich… | Fill missing station details from QRZ.com or HamQTH, or DXCC, zones and continent from country data (offline) |
| Monitor (WSJT-X, N1MM, Loggers)… | Add the QSOs WSJT-X, JS8Call, N1MM Logger+, GridTracker and other programs log to a log you choose, as they log them |
| Record Panel | Show or hide the docked record table |
| Reformat: One Record per Line / One Field per Line | Re-lay the file without touching data |
| Check .adi Files While Typing | Problem marks as you type (on by default) |
| Settings… | Your station, editor options, country data, and accounts for the online services |
| About ADIF Lint… | Version, licence and links |

Import…, Export… and Enrich… open the window you used last; the popup at its top switches to
the others. QSL Sync opens each upload window. The toolbar gets buttons for New QSO, Log Table, Check Log and
Spots.

Every command that changes the log is one undo step, and nothing is saved until you save
the file.

## Privacy and network

ADIF Lint only goes online when you use a command that needs it, and every request uses
HTTPS.

| Service | Address | When | What is sent |
|---|---|---|---|
| QRZ.com XML | `xmldata.qrz.com` | Enrich (QRZ.com); New QSO lookup set to QRZ.com; Test Sign-In | Your username and password (POST), then the calls looked up |
| HamQTH | `www.hamqth.com` | Enrich (HamQTH); New QSO lookup set to HamQTH; Test Sign-In | Your username and password, then the calls looked up |
| LoTW | `lotw.arrl.org` | Import (LoTW); Test Sign-In | Your username and password and the log's date range |
| QRZ.com Logbook | `logbook.qrz.com` | Upload and Import (QRZ.com Logbook); Test Sign-In | Your API key, the log's date range and the QSOs you upload |
| Club Log | `clublog.org` | Upload (Club Log) | Your email, Application Password, API key and the QSOs you upload |
| eQSL | `www.eqsl.cc` | Upload and Import (eQSL) | Your username and password, the log's date range and the QSOs you upload |
| POTA | `api.pota.app` | The Spots window (POTA), every minute while it is open | Nothing but the request |
| WWFF | `spots.wwff.co` | The Spots window (WWFF), every minute while it is open | Nothing but the request |
| Country files | `www.country-files.com` | Settings → Country Data → Update | Nothing but the request |

- **Credentials** are stored only in your macOS Keychain ("ADIF Lint: …" items), never in
  a file, and a saved password is never shown again. HamQTH's sign-in, LoTW's report API
  and eQSL's DownloadInBox take the login in the HTTPS address, as those services document
  it.
- **TQSL** runs on your Mac for LoTW uploads. A certificate password you save is passed on
  its command line, where other programs on your Mac could see it while TQSL runs.
- **Monitor** listens and never sends: on the UDP and TCP ports you tick, on `127.0.0.1`
  only unless you tick Accept from other computers. It writes only to the log you chose and
  to its queue file in the plugin config folder.
- **Settings** are kept in `ADIFLint.ini` in Nextpad++'s plugin config folder
  (`~/Library/Application Support/Nextpad++/plugins/Config/`).

See [SECURITY.md](SECURITY.md) to report a security problem.

## Command line

`build/adiflint` checks files from a terminal and prints `file:line:column: severity:
message`; the exit status is 1 when there are errors.

```bash
build/adiflint examples/try-me.adi
```

It can also fix lengths, repair every problem with a known repair (`--fix-all`), reformat, sort (by date and time or by any fields), put fields in
order, remove duplicates, convert to and from CSV, print the summary, and write Cabrillo or
activation files. `build/adiflint --help` lists the
options, and the [user guide](docs/USER_GUIDE.md#command-line) describes them.

## Building and testing

```bash
cd build && ctest --output-on-failure
```

The tests check every validation rule against the ADIF specification and the official
ADIF test file, fuzz the parsers, and drive the built plugin through every window against
a simulated Nextpad++, with saved sample replies in place of the online services.
[CONTRIBUTING.md](CONTRIBUTING.md) covers the build, the tests, the project layout
and the release steps.

## Limits

- Nextpad++ doesn't let plugins supply a lexer or write to the status bar, so colours are
  painted for the lines on screen, and summaries appear in a tip at the caret.
- Only the active document is checked.
- The online services were tested against saved sample replies, not the live services.
- No SOTA spots: the SOTA API's terms don't allow software written with AI tools without
  the SOTA team's approval. SOTA tracking and export work offline.
- Club Log offers no documented way to download QSOs or confirmations, so there is no
  Import from Club Log. eQSL documents only its InBox (the eQSLs others sent you), so Import
  from eQSL offers the QSOs your log lacks without ticking them: they are the other
  station's records.
- ADX (XML) files are not handled.

The [user guide](docs/USER_GUIDE.md#limits) lists the rest.

## Documentation

- [User guide](docs/USER_GUIDE.md): every window, option and rule.
- [Changelog](CHANGELOG.md): what changed in each version.
- [Contributing](CONTRIBUTING.md): building, testing and releasing.
- [Security](SECURITY.md): reporting a problem, and how your data is handled.

## Licence and credits

ADIF Lint is licensed under the [GNU General Public License v3](LICENSE), the licence of
Nextpad++ and its plugins.

- The validation tables and field descriptions are generated from the
  [ADIF 3.1.7 specification](https://www.adif.org/317/ADIF_317.htm) and its JSON export,
  published by the ADIF Development Group for developers.
- `data/cty.csv` is Jim Reisert AD1C's [Big CTY](https://www.country-files.com/) country
  file, under the MIT licence ([`data/cty-copyright.txt`](data/cty-copyright.txt)).
- `third_party/` holds the Nextpad++ plugin header (GPL v3) and the Scintilla headers
  (Scintilla licence); see [`third_party/README.md`](third_party/README.md).
- HamQTH data is credited in the Enrich window, as HamQTH asks.

Nextpad++ and Notepad++ are the names of their respective projects. QRZ.com, LoTW, Club
Log, eQSL, POTA, WWFF and SOTA are the names of their services and programs; ADIF Lint is
not affiliated with any of them.
