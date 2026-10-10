# ADIF Lint user guide

Everything ADIF Lint does, window by window. Every command is on the **Plugins → ADIF
Lint** menu, and New QSO, Log Table, Check Log and Spots also have toolbar buttons.
**Import…**, **Export…** and **Enrich…** open the window you used last (**QSL Sync…** opens
each upload window); the
popup at the top of each switches to the others, in the same place. Every change a command makes to your log is one undo step, and nothing is
saved to disk until you save the file.

- [Checking and repairing a log](#checking-and-repairing-a-log)
- [Logging with New QSO](#logging-with-new-qso)
- [Station profiles and activations](#station-profiles-and-activations)
- [Monitor: QSOs from WSJT-X and other programs](#monitor-qsos-from-wsjt-x-and-other-programs)
- [Spots](#spots)
- [Log Table, Summary and Worked Before](#log-table-summary-and-worked-before)
- [Activations: POTA, WWFF and SOTA](#activations-pota-wwff-and-sota)
- [Editing the whole log](#editing-the-whole-log)
- [Importing and exporting](#importing-and-exporting)
- [Importing from LoTW, QRZ.com Logbook and eQSL](#importing-from-lotw-qrzcom-logbook-and-eqsl)
- [Uploading](#uploading)
- [Enrich](#enrich)
- [Settings](#settings)
- [Command line](#command-line)
- [Limits](#limits)

## Checking and repairing a log

ADIF Lint checks `.adi` and `.adif` files as you type, against the
[ADIF 3.1.7 specification](https://www.adif.org/317/ADIF_317.htm) (2026-03-22).

- **Marks:** red squiggles for errors, orange for warnings, blue dots for notes. Rest the
  mouse on a mark to read why. **Next Problem** and **Previous Problem** move between
  marks and show the message.
- **Check Log…** checks the current document whatever its extension, and lists every
  problem in the log, with the record, line, field and, where
  one is known, the repair. Click a row to see it in the editor. The rows with a repair
  start ticked; **Repair N Ticked** applies them all as one undo step, and the list then
  shows what is left (a repair can reveal another). **Show** narrows the list to problems
  with a repair, errors, warnings or notes, and the filter box to words. Records with a
  wrong length wait for **Fix Lengths** (a button in the window), since their boundaries
  are unclear until then. The repairs:

  | Problem | Repair |
  |---|---|
  | MODE is really a submode (`USB`, `LSB`, `FT4`, `JS8`, `PSK31`…) | MODE its mode, SUBMODE the value (`SSB` + `USB`, `MFSK` + `FT4`) |
  | SUBMODE belongs to another MODE (`FT8` with `FT4`) | MODE set to the submode's mode |
  | SUBMODE without MODE | MODE added |
  | Date typed `2026-10-06` (or with `/` or `.`), time typed `22:30` or `22:30:15` | `20261006`, `2230`, `223015` |
  | FREQ outside BAND | FREQ in MHz when it was written in kHz (`14074` → `14.074`), else BAND from FREQ |
  | No BAND, but FREQ (POTA reads BAND only) | BAND added |
  | Lowercase CALL, STATION_CALLSIGN, OPERATOR, STATE or MY_STATE | Upper case |
  | SAT_NAME without PROP_MODE SAT (LoTW needs both) | PROP_MODE SAT |
  | A POTA record without STATION_CALLSIGN or OPERATOR | The log's usual STATION_CALLSIGN |
  | The same field twice with the same value | The second copy removed |
  | The last record has no `<EOR>` | `<EOR>` added |
  | TX_PWR or RX_PWR with a unit (`30W`, `5 w`, `1.5kW`, as WSJT-X writes what you type) | The number of watts (`30`, `5`, `1500`) |
  | A placeholder for "no value" (`none`, `n/a`, `-`, `?`, `unknown`) in a field that isn't free text, such as IOTA `none` | The field removed (it said nothing) |
  | A Field Day class in ARRL_SECT (`1D`, `12F`), when CLASS is empty | Moved to CLASS |
  | A retired code the specification names a replacement for (STATE `DF` for Mexico City) | The new code (`CMX`) |
  | STATE or CNTY not on the country's ADIF list | Removed, only if you tick it: it starts unticked, and `--fix-all` leaves it |
  | A byte-order mark at the start | Removed |

  With **One row for a problem repeated in many records** ticked (the default), the same
  problem in many records is one row ("1407 +338", "(339 records)"), and repairing it
  repairs them all.

  Problems without a repair need your judgement: a QSO date after today (POTA refuses
  future dates), PROP_MODE SAT without SAT_NAME, the same field twice with different
  values, an invalid value with no obvious meaning.
- **Record Panel** right-click: **Repair** applies the repair of the problem on that row
  (or **Repair Record** for one on the record as a whole).
- **Fix Lengths** rewrites every wrong `<FIELD:LENGTH>` to match its data. For example,
  `<CALL:4>W1AW/P` becomes `<CALL:6>W1AW/P`.
- **Reformat: One Record per Line / One Field per Line** re-lays the file. Only the
  whitespace between fields changes: every data specifier and comment is copied byte for
  byte, and the header is kept. It refuses while any length is wrong.
- **Colour ADIF syntax** (Settings → Editor, on by default): field names blue; `<`, `:LENGTH` and `>` grey;
  `<EOH>` and `<EOR>` purple; comments (header text, notes between records) green. Data
  keeps the theme's text colour.
- **Autocomplete field names and values** (Settings → Editor, on by default):
  - type `<` for a list of field names: QSO fields in records, header fields in the
    header, plus the file's own `USERDEFn` and `APP_` fields;
  - enumerated fields (BAND, MODE, SUBMODE for the record's MODE, STATE for its DXCC, QSL
    statuses, Y/N…) then offer their values, and picking one writes the value and its
    length;
  - for a free-text field, type the data; the length is filled in when you press Enter,
    type the next `<`, or move the caret away.
- **Record Panel** docks a table of the header or record at the caret, with each field's
  position (#) and problem. Edit a value in place (enumerated fields are drop-downs) and
  the length is set for you; **+** adds a field, **−** removes one, ▲ and ▼ step between
  records, and double-clicking a row selects that field's data in the editor. Click a
  heading to sort the rows by field name, value or problem (errors first); click **#** to
  return to the record's own order. Sorting only changes the view, not the record, and the
  choice is remembered.
- **Check .adi Files While Typing** (on by default, also in Settings → Editor) turns the
  marks on or off.
- The **Record Panel**'s second line sums up the whole log: its problems, the QSOs waiting
  for each upload service the log has used ("to upload: QRZ 4, LoTW 12"), and today's POTA
  activation ("US-7929 today: 8 of 10").

### What is checked

Every rule comes from the ADIF 3.1.7 specification. Every field, data type, enumeration
value, band edge and import-only flag is generated from ADIF's official JSON export, not
typed by hand.

- **Structure** (§IV.A): data specifier syntax, data lengths (too short, too long, past
  the end of file, including the line break), leading zeros in lengths (import-only),
  header and `<EOH>` rules, `<EOR>` on every record, a field repeated in one header or
  record, a stray `<`, and a field missing its `<`.
- **Fields:** unknown names, header fields in records and the reverse, import-only fields,
  `_INTL` fields (which ADI cannot carry), and type indicators that don't match the field.
- **Data types** (§II.B): Date, Time, Number (no `+`, no `,`), Integer, PositiveInteger,
  Boolean, String and MultilineString characters (ASCII only, CR LF line breaks),
  GridSquare, GridSquareExt, GridSquareList, Location, IOTA, POTA, SOTA, WWFF, CreditList,
  SponsoredAwardList, and minimum and maximum values (CQZ, ITUZ, AGE, K_INDEX…).
- **Enumerations:** BAND, MODE, QSL statuses, DXCC, ARRL section, continent, propagation
  mode and the rest, plus deprecated values with the specification's advice (for example
  `MODE C4FM` → `DIGITALVOICE` with `SUBMODE C4FM`).
- **Between fields:** SUBMODE must belong to MODE; FREQ must lie in BAND, and FREQ_RX in
  BAND_RX (band edges included). STATE and CNTY are checked against the record's own DXCC
  entity, for the 66 entities ADIF lists subdivisions for: Hungary's are counties (`BP`
  Budapest, `PE` Pest…), Italy's provinces, Brazil's states. A value not on that list is a
  warning that names the country and its codes; callbooks often put something else there
  (QRZ.com Logbook copies the other station's profile, such as `H` for Hungary). Other
  entities' values, and STATE without a DXCC, are not checked.
- **User fields:** `USERDEFn` definitions in the header, with their enumerations
  `{S,M,L}` or ranges `{5:20}`, and `APP_PROGRAMID_FIELDNAME` fields, whose type the first
  occurrence fixes.
- **Notes:** records lacking ADIF's guideline minimum (QSO_DATE, TIME_ON, CALL, BAND or
  FREQ, MODE), and CONTEST_ID and SUBMODE values not in ADIF's lists.
- **What services expect** (beyond the specification): BAND present when FREQ is (POTA
  reads only BAND), callsigns and states in upper case, no QSO dates in the future (POTA,
  [ADIF for POTA reference](https://docs.pota.app/docs/activator_reference/ADIF_for_POTA_reference.html),
  modified 2026-07-08), STATION_CALLSIGN or OPERATOR in POTA activation records, and
  PROP_MODE SAT with SAT_NAME for satellite QSOs
  ([LoTW](https://lotw.arrl.org/lotw-help/satellite-qsos/), checked 2026-10-09). These are
  notes, or warnings for a future date and a SAT_NAME without PROP_MODE SAT.

### Bytes or characters?

ADI files are ASCII only (§II.B), where a length counts bytes and characters equally.
Some programs write UTF-8 anyway (`Jürg` is 4 characters but 5 bytes), and they disagree
on which to count. ADIF Lint warns about non-ASCII text, and when a length is wrong it
also says whether the length would be right in the other unit. Turn on **Count Lengths in
Characters** for files whose program counted characters; Fix Lengths uses whichever unit
is selected.

## Logging with New QSO

**New QSO…** opens a window for logging contacts one after another.

- **Fields:** the window keeps the log's field order, then adds CALL, QSO_DATE, TIME_ON,
  BAND, FREQ, MODE, SUBMODE, RST_SENT and RST_RCVD if the log doesn't have them.
- **Carry-over:** your station's fields come from the last record (STATION_CALLSIGN,
  OPERATOR, the MY_ fields such as MY_SIG_INFO and MY_STATE, BAND, FREQ, MODE and
  SUBMODE). Per-contact fields start empty each time.
- **Date and time:** QSO_DATE and TIME_ON are the current UTC time when you log. Untick
  the box to type them, for example when entering a paper log.
- **As you type:** BAND follows FREQ, the SUBMODE list follows MODE, reports default to 59
  (phone) or 599 (CW, RTTY), and every field is checked. CALL, QSO_DATE, TIME_ON, MODE, and
  BAND or FREQ are required.
- **Duplicates:** a contact already in the log on the same band, mode and UTC day gets a
  warning. Following POTA's rule, the same activator at another park (SIG_INFO or
  POTA_REF) is a new contact, and portable forms of a call (`K1ABC/P`) count as the same
  station.
- **Log QSO** (Return) appends the record with correct lengths, in the log's own layout,
  then clears the window for the next contact. In an empty document it starts a new log
  with a header.
- **Worked before:** with a logs folder chosen in Worked Before, the window also says when
  the call is in your other logs ("K1ABC: 4 QSOs in 2 other logs; last 2026-09-30 14:05 on
  20m SSB").

### Choosing the fields

**Fields…** chooses and orders the fields the window asks for. Your fields are on the
left; every field you can add is on the right with its type and the first paragraph of
its description in the ADIF specification (hover a row for the full text).

- Search matches names and descriptions ("park" finds POTA_REF), exact name matches first.
- Add the selected fields (several at once) or double-click one; remove fields, and
  reorder them with Move Up and Move Down.
- CALL, QSO_DATE, TIME_ON and MODE always stay, and so does BAND or FREQ.
- **Use the Log's Fields** returns to the automatic list.
- With "Also copy this station's details…" ticked (the default), station fields you
  don't list are still copied from the last record: STATION_CALLSIGN, OPERATOR,
  OWNER_CALLSIGN, TX_PWR and the MY_ fields. The window names them, for example "Also
  written, from the last record: MY_SIG_INFO US-7929".

### Looking up the call

**Look up** fills the fields a new call leaves empty, as you type:

- **Country data** (the default, offline): DXCC, COUNTRY, CQZ, ITUZ and CONT from the
  call's prefix.
- **QRZ.com** or **HamQTH**: name, QTH, state, grid and more from your callbook account.
  For a portable or park station, the home address is shown but not written.

The line under it shows what was found, the distance and bearing from MY_GRIDSQUARE to
the station's grid ("7,086 km at 42°", also written to DISTANCE when the window has that
field), and, for a park, reference or summit in SIG_INFO, POTA_REF, WWFF_REF or SOTA_REF,
what your logs say about it ("US-1234: a new park!", "KFF-5255: worked 2 times before,
last 2026-10-03 (a.adi)"). Changing the call takes back what the last lookup filled,
unless you edited it.

## Station profiles and activations

**Station profiles** are named sets of your station's own fields: callsign, operator,
grid, state, county, rig, antenna, power and the TQSL Station Location its LoTW uploads
use. Open them from Settings (Your Station → **Station Profiles…**), New QSO's
**Station** popup, or Start Activation. Double-click a cell to edit it; the grid must be
a Maidenhead locator and the power a number of watts. They are kept in
`ADIFLint-profiles.adi` in the plugin config folder.

New QSO's **Station** popup chooses what it writes for your station: **From the log** (the
log's last record, as before) or a profile, whose fields fill their rows and are written
in every QSO even when not shown.

**Start Activation…**:

- **Program** POTA, WWFF or SOTA, and the **References**: one or more parks for POTA (a
  two-fer: `US-7929, US-1234`), one WWFF reference, one summit. The table shows what your
  logs say about each.
- **Station**: Your Station (Settings) or a profile.
- **Log to** a new log file in the folder you choose, named as the program names logs
  (`KW9D@US-7929+US-1234-20261009.adi`, `KW9D @ KFF-1234 20261009.adi`,
  `KW9D_W7A-AE-001_20261009.adi`), or the log that's open. A file that already exists is
  opened, not replaced.
- **Start** opens New QSO on that log. Every QSO gets the activation's fields (POTA:
  MY_SIG POTA, MY_SIG_INFO and MY_POTA_REF with the parks; WWFF: MY_SIG WWFF, MY_SIG_INFO
  and MY_WWFF_REF; SOTA: MY_SOTA_REF) and your station's, and New QSO's top line shows the
  progress: "US-7929 today: 8 of 10", "KFF-1234: 30 of 44", "W7A/AE-001: 3 of 4 stations".
- **Finish…** (with the activation's log in front) ends the activation, opens Check Log
  and Export Activation Logs for the program, and says what's next. For POTA, **Open
  pota.app Uploads** opens the page where each park's file is uploaded
  ([POTA: submitting logs](https://docs.pota.app/docs/activator_reference/submitting_logs.html),
  checked 2026-10-09).

## Monitor: QSOs from WSJT-X and other programs

**Monitor (WSJT-X, N1MM, Loggers)…** adds the QSOs other programs log to a log you choose,
as they log them. It listens for the message a program sends when you log a contact, or
watches a log file a program adds to. It only listens: it never sends anything, and it
takes messages only from this Mac unless you tick **Accept from other computers**.

**Add QSOs to**: **Choose…** an `.adi` log, or **Use the Open Log**. Where each QSO goes:

- The log is the document in front: added at its end, one undo step per message, with the
  caret left where it is.
- The log isn't open in Nextpad++: added to the file.
- The log is open in another tab: kept in a queue (`ADIFLint-queue.adi` in the plugin
  config folder) and added when you switch to it, or with **Add N Queued QSOs**. The queue
  survives quitting Nextpad++.

A QSO the log already has (same call, band and mode, starting within 2 minutes) isn't
added again. A log with broken structure (wrong lengths, a record without `<EOR>`) isn't
touched: the QSOs wait in the queue until it's repaired. A message without a call, date,
time, mode, or band or frequency is listed as **Not logged** and left out.

The sources, each ticked on or off with its port (the defaults are the ports these
programs use):

| Source | Port | What arrives |
|---|---|---|
| WSJT-X, JTDX, JS8Call (UDP Server) | 2237 | WSJT-X and JTDX send *QSO Logged* and *Logged ADIF* when you log a QSO; the Monitor keeps the ADIF one. JS8Call sends its API's `LOG.QSO` message. |
| ADIF over UDP | 2333 | An ADIF record per QSO: JS8Call's N1MM option, GridTracker logging to N1MM or Log4OM, and other programs that send ADIF |
| N1MM Logger+ contacts (XML) | 12060 | N1MM Logger+'s contacts as they're added, and its edits and deletions of them (off at first) |
| Logger commands over TCP | 52001 | What GridTracker sends to DXKeeper or HRD Logbook (off at first) |

**Watch files**: **Watch WSJT-X's Log** watches `~/Library/Application Support/WSJT-X/wsjtx_log.adi`,
the log WSJT-X keeps on a Mac (WSJT-X User Guide v3.2.0-rc1, pages 45 and 120), and **Add
File…** any other log a program adds to. QSOs added to the file from now on are captured,
not the ones already in it (**Import… → WSJT-X log file** adds those). Watching the file
works however many other programs use WSJT-X's messages.

**Start** listens and **Stop** stops; **Start when Nextpad++ starts** starts it every time.
The headline says what it listens to, and the table lists every QSO that arrived and what
became of it. Double-click one added to the open log to go to its record; **Copy as ADIF**
copies the selected ones.

### Setting up the other programs

- **WSJT-X** and **JTDX**: Settings → Reporting → **UDP Server** `127.0.0.1`, port `2237`
  (WSJT-X User Guide v3.2.0-rc1, section 6.5). If GridTracker or JTAlert already listens on
  that port, the Monitor says the port is in use. Then watch WSJT-X's log file instead, or
  share the messages through a multicast group: type the same group address in WSJT-X's UDP
  Server and the Monitor's **multicast group** (one from 239.255.0.0 to 239.255.255.255, the
  local range of RFC 2365), and choose the loopback interface among WSJT-X's Outgoing
  interfaces. The other programs must join the group too.
- **JS8Call**: Settings → Reporting: tick **Enable UDP Server API** and set the UDP Server
  to `127.0.0.1` and the Monitor's WSJT-X port. Or, under N1MM Logger, tick **Enable
  sending logged contacts to N1MM logging software** with port `2333`, and use the ADIF
  source.
- **N1MM Logger+** runs on Windows: in Config → Config Ports… → Broadcast Data, tick
  **Contacts** and give this Mac's address and port, such as `192.168.1.20:12060`, then tick
  **Accept from other computers** here
  ([N1MM: External UDP Broadcasts](https://n1mmwp.hamdocs.com/appendices/external-udp-broadcasts/),
  read 2026-10-10).
- **GridTracker**: log to DXKeeper with address `127.0.0.1` and port `52000` (GridTracker
  sends DXKeeper's log command to that port + 1, 52001), or to HRD Logbook with port
  `52001`, and tick the TCP source. Logging to N1MM or Log4OM with port `2333` uses the ADIF
  source instead.
- **Ham Radio Deluxe** runs on Windows. Its Logbook's QSO Forwarding sends each QSO over
  UDP: point it at this Mac's address and port `2333`, and tick **Accept from other
  computers**. HRD doesn't publish the message's format and the Monitor reads ADIF records,
  so check that your first QSO arrives.

**Accept from other computers** lets programs on other computers, or in a Windows virtual
machine, reach the Monitor: it then listens on every network interface. Anyone on your
network could then add QSOs to the chosen log, so use it only on a network you trust.
macOS may ask whether Nextpad++ may accept incoming connections.

## Spots

**Spots (POTA, WWFF)…** (or **Spots…** in New QSO) lists the activators spotted now, from
`api.pota.app` or `spots.wwff.co`, refreshed every minute while the window is open, with
band and mode filters and a search box.

- Double-click a spot (or select it and press **Use in New QSO**) to fill CALL, FREQ,
  BAND, MODE and the reference: SIG (POTA or WWFF) and SIG_INFO, plus POTA_REF or
  WWFF_REF. SSB becomes LSB below 10 MHz (except 60 m) and USB above; FT4 becomes MFSK
  with SUBMODE FT4.
- If New QSO shows none of SIG_INFO, POTA_REF and WWFF_REF, SIG and SIG_INFO rows are
  added so the reference is logged.
- The **Worked** column says **NEW** (green) for a park or reference that isn't in this
  log or your logs folder, **worked** for one that is, and **today** (blue) for a station
  already worked today on that band.

## Log Table, Summary and Worked Before

**Log Table…** shows every record in a table with a filter box, in its own window, and
edits like a spreadsheet. Dates and times read as 2026-10-06 and 22:30. The `.adi` file
stays the document: every change is written into it as one undo step (Command-Z in the
editor), each field with its length, and an uploaded QSO whose data changes becomes M (see
[Uploading](#uploading)).

- Click a heading to sort; the sort is remembered. Bands sort by frequency (160m before
  20m), dates and times in time order, numbers by value, and empty cells last.
- Selecting a row shows that record in the editor; double-clicking the # goes there.
- Right-click the headings to choose the columns shown; drag a heading to move a column.

Editing:

- **Click a cell** to make it the active cell (highlighted); Left and Right move it along
  the row. **Type** to replace its value, or press **Return** (or double-click) to edit
  it. While editing, **Tab** and **Shift-Tab** save and move to the next or previous
  cell, **Return** saves and moves down, and **Esc** cancels.
- An empty value removes the field from the record. Dates and times may be typed as shown
  (2026-10-06, 22:30) or as ADIF writes them (20261006, 2230).
- **Delete** removes the active column's field from the selected rows; **Command-Delete**
  deletes the selected rows.
- **Command-D** (Fill Down) copies the first selected row's value in the active column to
  the other selected rows.
- **Command-C** copies the selected rows as tab-separated text, with a heading row of field
  names, ready for Numbers or Excel. **Command-V** pastes: text with a heading row of field
  names puts each column into its field; other text fills cells from the active cell
  rightwards, starting at the first selected row. Rows pasted past the end of the log (or
  with no row selected) become new QSOs.
- **Add Row** appends a QSO with today's UTC date and time and the station fields New QSO
  would carry over from the last record, and starts editing its CALL.
- Right-click the headings and choose **Add Field…** to add a column for any ADIF field
  (one no record has yet starts empty, ready to fill in or paste into), or **Remove
  *FIELD* from Every Record** to delete the field under the pointer from the whole log.
- Right-click a row for the same commands: Copy, Paste, Fill Down, Clear Cells, Delete
  Rows, Add Row, Add Field… and Remove This Column's Field from Every Record.
- Editing needs the log the table shows to be the active document, writable, and free of
  structural errors (run Fix Lengths first if needed); otherwise the table says why and
  changes nothing.

Buttons:

- **Organize Log…** opens [Sort and Organize](#sort-and-organize) with the table's sort
  and its columns as shown, so the file can take the order you see.
- **Bulk Edit Selected…** edits the selected rows, and **Export CSV…** saves the rows
  shown. The table follows your edits, in the table or in the editor.

**Log Summary…** reports records, calls, date range, QSOs per band, mode and UTC day,
DXCC entities, states, grids, parks activated and parks worked (a hunter's tally), and how
many QSOs are confirmed and uploaded to each service. **Copy** puts it on the clipboard.

**Worked Before…** searches every `.adi` and `.adif` file in a folder you choose (and its
subfolders) for a call, matching portable forms (`VE3/K1ABC/P` finds K1ABC). The folder
is read in the background; files that changed are read again when you use it after a
couple of minutes.

## Activations: POTA, WWFF and SOTA

**Activation Tracker (POTA, WWFF, SOTA)…** counts activations with each program's rule.
Choose the program at the top; it is remembered.

- **POTA** ([rules](https://docs.pota.app/docs/rules.html), modified 2026-10-04): 10 QSOs
  from one park in one UTC day. A repeat of the same CALL, band, mode and park-to-park
  park doesn't count; records missing CALL, TIME_ON, BAND or MODE, or working your own
  call, are rejected. Parks come from MY_POTA_REF, or MY_SIG=POTA with MY_SIG_INFO.
- **WWFF** (WWFF Global Rules v5.10, 2025-09-03): 44 QSOs per reference, counted over all
  your activations of it; the same call on another band, mode or day counts again.
  References come from MY_WWFF_REF, or MY_SIG=WWFF with MY_SIG_INFO.
- **SOTA:** one QSO activates a summit, and four different stations score its points.
  This rule is taken from SOTA's published guides; check it at sota.org.uk. The QSOs
  column counts stations. Summits come from MY_SOTA_REF, or MY_SIG=SOTA with MY_SIG_INFO.

Records without STATION_CALLSIGN or OPERATOR count for the log's usual station. The
headline shows today's activation ("US-7929 today: 7 QSOs, 3 more to activate") and
updates as you log. **Export Logs…** opens the export for that program.

**Export Activation Logs…** writes one file per park (reference, summit) and UTC day.
Each file is listed with its QSO count and notes (too few QSOs, duplicates the program
will drop) before anything is saved, and an existing file is replaced only when you press
Save a second time. Records without STATION_CALLSIGN or OPERATOR get the callsign you
enter, and a `/` in a callsign becomes `_` in the file name.

- **POTA**, named as POTA asks for emailed logs
  ([submitting logs](https://docs.pota.app/docs/activator_reference/submitting_logs.html)):
  `KW9D@US-7929-20261006.adi`, with the state added for a park spanning several
  (`W8MSC@US-4239-20181231-US-MI.adi`). A two-fer gives one file per park, each with
  MY_SIG=POTA and that park in MY_SIG_INFO, since POTA wants a separate log per park.
- **WWFF:** `KW9D @ KFF-1234 20261006.adi`, the name WWFF asks for
  ([confirming and sending a log](https://wwff.co/rules-faq/confirming-and-sending-log/),
  checked 2026-10-09): a `/` in the call becomes `-` (`KW9D-P`), and an activation over
  consecutive UTC days is one file named for its first day. MY_WWFF_REF is set. Send them
  to your national WWFF log manager.
- **SOTA:** `KW9D_W7A-AE-001_20261006.adi`, with MY_SOTA_REF set. SOTA has no file-name
  rule; this name is ADIF Lint's own.

## Editing the whole log

Bulk Edit and Time Shift work on all records, the records in the editor selection, or the
rows selected in the Log Table, optionally only where another field is, contains, lacks
or has a value. **Preview** lists every change (untick any) and says whether the log would
have more errors afterwards; nothing changes until **Apply**.

- **Bulk Edit…** sets, replaces text in, removes or renames a field. A rename that would
  duplicate a field in a record skips that record. **Fill DISTANCE from grid squares**
  writes DISTANCE (km, great circle between the centres of MY_GRIDSQUARE and GRIDSQUARE)
  where both grids are known.
- **Time Shift…** moves QSO_DATE and TIME_ON (and QSO_DATE_OFF and TIME_OFF):
  - **From local time to UTC**, for a log written in local time (ADIF times are UTC), or
    **From UTC to local time** to undo that. The zone is a name such as America/Chicago
    (your Mac's zone at first, then the last one used), and each QSO gets the offset in
    force on its own date, daylight saving included, from macOS's time zone database. A
    local time the clocks skipped or repeated is listed by record and left alone, since its
    UTC time is unknown or ambiguous.
  - **By a fixed amount** of days, hours and minutes, for a clock that was wrong.
  - Dates follow across midnight, month and year ends, and times keep HHMM or HHMMSS.
- **Sort and Organize…**: see [below](#sort-and-organize). Its **Date and Time** button
  sets the usual order (QSO_DATE, then TIME_ON) in one click.
- **Remove Duplicates…** finds QSOs logged more than once: the same CALL, band and mode
  starting within 2 minutes (adjustable), and no different STATION_CALLSIGN, MY_SIG_INFO,
  SIG_INFO or POTA reference, so park-to-park lines repeated for each park of a two-fer
  stay. It keeps the record with the most fields and can copy fields only the removed one
  had. Untick any set before removing.
- **Compare and Merge Logs…** compares this log with another file QSO by QSO: the same
  call, band and mode starting within 2 minutes, with no different station or park, is the
  same QSO. **Show** lists the differences (the default), the QSOs only in that log or only
  in this one, those in both that differ, the same ones, or everything. The difference
  column reads `FIELD here | there` (`—` where a record lacks the field); values that differ
  only in case, a time written `1200` or `120000`, or a number's digits (`14.074` and
  `14.074000`) count as the same. Double-click a row to read all its differences and go to
  the record. Ticked QSOs only in that log are added (in this log's layout, with lengths
  counted this log's way); for ticked QSOs in both, the fields this log lacks are copied,
  and with **Also replace values that differ** the ones it has differently too. **Apply**
  does it in one undo step and sorts by date and time if you like; a QSO already uploaded
  to QRZ.com or Club Log is marked modified when its data changes. It warns about USERDEF
  fields this log's header lacks.

### Sort and Organize

**Sort and Organize…** rewrites the order of the log, not its data: every data specifier
is copied byte for byte. Tick one or both parts, then **Apply** (one undo step). Your
choices are remembered.

- **Sort the records by** up to three fields, each **Ascending** or **Descending**: for
  example BAND, then CALL, then QSO_DATE. Bands sort by frequency (160m before 20m), dates
  and times in time order (HHMM and HHMMSS together), numbers by value, and other text
  with digit runs by value and case ignored (`K2AB` before `K10AB`). A record without a
  value for a field goes after the ones with one, either way; records that tie keep their
  order. A comment between records moves with the record after it.
- **Put the fields of every record in this order**: the list shows the fields the log
  uses and how many records use each. Select one and **Move Up** or **Move Down**; **Log
  Table Order** starts again from the Log Table's column order. Each record gets the
  fields it has in this order, the others after them; the whitespace between fields stays
  where it was, so the layout (one record or one field per line) is kept. The header is
  not changed, and a record with a wrong length is left as it is and counted.
- Neither part changes QSO data, so uploaded QSOs don't become M.

## Importing and exporting

**Import…** and **Export…** each open one window with a popup for what to import or export.

- **Import… → CSV file** adds the rows of a CSV file (comma, semicolon or tab separated, the
  first row naming the columns), then sorts by date and time if you like. The window lists
  every row and the column mapping before anything is added.
  - Columns named as ADIF fields are used as they are; common names are mapped too
    (Callsign, Date, UTC, Frequency, "Freq (kHz)", RST Sent, RST Rcvd, Grid, Park, Summit,
    Notes, Power…).
  - Dates must be year first (2026-10-06, 2026/10/06 or 20261006), since 06/10 could be
    either month; times may be 22:30, 2230 or 22:30:15; a frequency in kHz becomes MHz;
    the apostrophe Export CSV puts before a formula is taken off.
- **Import… → WSJT-X log file** opens Compare and Merge Logs on WSJT-X's own log
  (`~/Library/Application Support/WSJT-X/wsjtx_log.adi`), to add the QSOs this log doesn't
  have. The Monitor adds new ones as you log them.
- **Export… → CSV** shows the log as it will be saved, then **Save CSV…** writes it (RFC
  4180, a column per field used). A value a
  spreadsheet would run as a formula (`=…`, `@…`) gets a leading apostrophe; numbers like
  `-10` are left alone.
- **Export… → Activation logs**: see [Activations](#activations-pota-wwff-and-sota).
- **Export… → Cabrillo** writes a Cabrillo 3.0 contest log
  ([WWROF specification](https://wwrof.org/cabrillo/)): the header from the contest,
  callsign, category, grid and location you enter, and a QSO line per record with the
  frequency in kHz (or the band for 50 MHz and up), mode CW, PH, FM, RY or DG, date, time,
  and the reports and exchange from STX_STRING or STX and SRX_STRING or SRX. A line missing
  an exchange shows `-`, and the window says how many do. Check the contest's own template
  before submitting.

## Importing from LoTW, QRZ.com Logbook and eQSL

**Import… → LoTW, QRZ.com Logbook or eQSL** download the QSOs a site holds for you
and compare them with the open log. Choose **QSOs on the log's dates** (all of them for an
empty log) or **All your QSOs**, press **Download**, and review the list. Nothing changes
until **Apply**, which is one undo step.

- **add**: a QSO the log doesn't have. It becomes a new record in the log's layout, and the
  log is then sorted by date and time if you like.
- **update**: a QSO the log has. The record gains the site's status and confirmation and
  the details that come with it: only fields it lacks, except that a confirmation upgrades
  a status that says it hasn't happened (LOTW_QSL_RCVD or EQSL_QSL_RCVD N, R, Q or I
  becomes Y; APP_QRZLOG_STATUS becomes C).
- **in log**: nothing to add. These rows are listed when you tick **Also list QSOs already
  in the log**.
- Downloaded QSOs are matched the way LoTW matches QSLs: the same call and band, start
  times within 30 minutes, and the same mode or mode group (CW, phone, data). Each
  downloaded QSO matches at most one record: the same mode first, then the closest time.
- A record whose QSO data changes (for example, a state that comes with a confirmation)
  and was already uploaded gets QRZ.com and Club Log status M, as with any edit.

What each site gives:

- **LoTW** (your LoTW website login): every QSO you uploaded, confirmed or not
  ([LoTW query interface](https://lotw.arrl.org/lotw-help/developer-query-qsos-qsls/)). A new
  record gets the call, date, time, band, frequency, mode, propagation mode and satellite,
  STATION_CALLSIGN and your MY_ details as you uploaded them, LOTW_QSL_SENT=Y with the date
  LoTW received the QSO, and, when it is confirmed, LOTW_QSL_RCVD=Y, LOTW_QSLRDATE and the
  other station's DXCC, country, continent, zones, IOTA, grid, state and county. A matched
  record gains the same status, confirmation and details.
- **QRZ.com Logbook** (your logbook API key; QRZ.com requires an XML subscription or higher
  to download): every record in your logbook, or those on the log's dates, 250 at a time
  ([QRZ Logbook API](https://www.qrz.com/docs/logbook/QRZLogbookAPI.html)). A new record is
  the ADIF you uploaded, without QRZ.com's own APP_QRZLOG fields, with
  QRZCOM_QSO_UPLOAD_STATUS=Y. A matched record gains QRZCOM_QSO_UPLOAD_STATUS=Y and, when
  QRZ.com shows it confirmed, APP_QRZLOG_STATUS=C, APP_QRZLOG_QSLDATE,
  QRZCOM_QSO_DOWNLOAD_STATUS=Y and today's date.
- **eQSL** (your eQSL login): eQSL documents only its InBox for programs, the eQSLs other
  stations sent you, written from their side
  ([DownloadInBox](https://www.eqsl.cc/qslcard/DownloadInBox.txt)). A matched record gains
  EQSL_QSL_RCVD=Y, EQSL_QSLRDATE and the grid the other station sent. A QSO your log lacks
  is offered with the call, date, time, band, mode, propagation mode, the report you
  received (their RST_SENT) and the confirmation, but not ticked: eQSL warns that the InBox
  is not your log, so check such a QSO before adding it.
- Club Log documents no way for programs to download QSOs or confirmations, so there is no
  Import from Club Log.

## Uploading

**QSL Sync (Upload, Confirmations)…** shows each service for the open log: whether its
account is saved, the QSOs to upload (and how many changed since an upload), uploaded, that
can't be sent, and confirmed (LOTW_QSL_RCVD or EQSL_QSL_RCVD Y or V, or QRZ.com Logbook's
confirmed status as Import writes it), the newest upload date in the log, and when you last
downloaded from it. Select a service, then **Upload…** (or double-click it) or **Download
Confirmations…**, which opens its Import window. Club Log has no confirmations to download.

The upload windows (QRZ.com Logbook, LoTW (TQSL), Club Log, eQSL) list the QSOs not yet
sent, by the ADIF status field, with the ones that can't be sent (no MODE…) in red.
**Nothing is sent until you press Upload.** Each QSO's result is shown, and the accepted
ones get the status field Y and today's date: QRZCOM_QSO_UPLOAD_STATUS and _DATE,
LOTW_QSL_SENT and LOTW_QSLSDATE, CLUBLOG_QSO_UPLOAD_STATUS and _DATE, EQSL_QSL_SENT and
EQSL_QSLSDATE. **Copy ADIF** copies exactly what would be sent, and QSOs you untick stay
unticked while you edit the log.

- **ADIF statuses:** a QRZ.com or Club Log status of N means "do not upload" and is
  skipped; M (modified since upload) is sent again; a QSL status of I is skipped.
- **Changing an uploaded QSO:** its QRZCOM_QSO_UPLOAD_STATUS and CLUBLOG_QSO_UPLOAD_STATUS
  of Y become M, as ADIF prescribes, so the next upload sends the change (to QRZ.com with
  OPTION=REPLACE). Bulk Edit, Time Shift, Enrich, Import, Remove Duplicates and the Log Table do
  this in the same undo step; typing, autocomplete and the Record Panel do it once the log
  reads cleanly again, as its own undo step. Changes to QSL and upload fields themselves
  don't count.
- **QRZ.com Logbook:** one INSERT per QSO with your logbook API key
  ([QRZ Logbook API](https://www.qrz.com/docs/logbook/QRZLogbookAPI.html)). A QSO the
  logbook already has counts as sent; a key error stops the run.
- **LoTW:** runs TQSL (`/Applications/TrustedQSL/tqsl.app`, or choose it) as
  `tqsl -x -d -u -a compliant -l "<Station Location>" file`, which signs with that Station
  Location's certificate and uploads. A certificate password saved in Settings is passed
  with `-p`. Only exit code 0 marks records: for 8 or 9 TQSL doesn't say which QSOs it
  skipped, so nothing is marked and its report is shown. TQSL is stopped if it hasn't
  finished in 10 minutes.
- **LoTW pre-flight:** the Station Location popup lists the locations in TQSL's
  `station_data` (in `~/.tqsl`, TQSL's folder on a Mac, or `$TQSLDIR`); a station profile's
  TQSL location is used when none is chosen. Each QSO's station fields are compared with
  the location the way TQSL compares them, and TQSL refuses one that disagrees: the call
  (STATION_CALLSIGN, else OPERATOR), MY_DXCC, MY_GRIDSQUARE (a 4-character grid matches a
  longer one that starts with it), MY_STATE and MY_CNTY for the entities TQSL knows them
  for (US, Canada, Russia, China, Australia, Japan, Finland), and the zones. Those QSOs are
  listed as can't send, with the field that disagrees and another location they match, so
  you can upload them with that one. A field the location or the QSO leaves empty never
  counts. (TQSL source, read 2026-10-10; a value written as TQSL's label rather than its
  code, such as a state's full name, is flagged though TQSL would take it.)
- **Club Log:** one batch upload to `putlogs.php` with your account email, an Application
  Password and an API key. Club Log gives each program its own key: request one at
  clublog.org/requestapikey.php, and never publish it. Club Log blocks programs that
  repeat failed requests, so the first error stops the run.
- **eQSL:** one QSO per request to ImportADIF
  ([eQSL interface](https://www.eqsl.cc/qslcard/ImportADIF.txt)), with an optional QTH
  Nickname for users with several accounts. A QSO eQSL already has counts as sent; a
  sign-in error stops the run.

## Enrich

**Enrich…**, from QRZ.com, HamQTH or Country Data (chosen in **Enrich from**), adds fields a record lacks: NAME, QTH,
STATE, CNTY, GRIDSQUARE, DXCC and COUNTRY, CQZ, ITUZ, IOTA, CONT and, optionally, LAT and
LON. Every proposed change is listed for review; nothing changes until you press
**Apply**. Confirmations from LoTW, QRZ.com Logbook and eQSL come in through
[Import](#importing-from-lotw-qrzcom-logbook-and-eqsl).

- **QRZ.com** (XML interface): grid, county and zones need a QRZ XML Logbook Data
  subscription; without one QRZ returns only a few fields, and the window says so.
  Coordinates QRZ only estimated from the entity or state are not used.
- **HamQTH:** a free account; its data is credited in the window.
- **Country Data:** offline, from the call's prefix: DXCC, COUNTRY, CQZ, ITUZ and CONT.
  Portable calls use the prefix part (`VE3/K1ABC` is Canada; `/P`, `/M`, `/QRP` and a
  call-area digit are ignored), and `/MM` and `/AM` get no entity.

Rules for every source:

- Only fields a record lacks are filled; existing values are never replaced.
- COUNTRY comes from ADIF's own DXCC entity table ("UNITED STATES OF AMERICA"), so it
  matches LoTW and ADIF.
- Callbooks give a station's home data. For portable calls (`K1ABC/P`, `VE3/K1ABC`) and
  records with SIG_INFO, POTA_REF, SOTA_REF or WWFF_REF, where the station was elsewhere,
  only the name is added (untick the option to change that). Country data comes from the
  call itself, so it is always used.
- Accented names are transliterated to ASCII ("Jürg" → "Jurg"), since ADI is ASCII.
- If you edit a record after Find Data, its changes are skipped rather than applied to the
  wrong place.

## Settings

**Settings…** has these sections. The first time ADIF Lint runs, it opens with a welcome.

- **Your Station:** your callsign and grid, used where a log doesn't say: New QSO fills
  STATION_CALLSIGN and MY_GRIDSQUARE from them in a new log, distances are measured from the
  grid, and the activation and Cabrillo exports offer the callsign. Also the logs folder
  Worked Before searches.
- **Editor:** checking while typing, syntax colouring, autocomplete, and counting lengths
  in characters instead of bytes.
- **Keyboard Shortcuts:** where to assign them (Nextpad++'s Edit → Shortcut Mapper…, Plugin
  commands tab) and suggested keys.
- **Country Data:** the AD1C country file in use. **Update** downloads the newest Big CTY
  release from country-files.com into the plugin config folder.
- **Accounts**, one section each: QRZ.com and HamQTH (username and password, for Enrich
  and New QSO's lookup); LoTW (your LoTW website login, for Import); QRZ.com Logbook (API
  key); Club Log (email and Application Password) and Club
  Log API key; eQSL (username and password); and the TQSL certificate password. **Save**
  stores them, **Test Sign-In** tries them where the service allows it (for QRZ.com it also
  shows the XML subscription end date), and **Remove** deletes them.

Where things are kept:

- **Credentials** only in your macOS Keychain, as items named "ADIF Lint: QRZ.com",
  "ADIF Lint: LoTW" and so on; never in a file. A saved password is never shown again.
- **Settings** (menu toggles, New QSO fields and lookup, folders, table columns and sort,
  the last time zone and program) in `ADIFLint.ini`, and a downloaded country file in
  `ADIFLint-cty.csv`, both in Nextpad++'s plugin config folder
  (`~/Library/Application Support/Nextpad++/plugins/Config/`). They survive plugin updates.
- **The installed country file** beside the plugin, in
  `~/Library/Application Support/Nextpad++/plugins/ADIFLint/`.

All requests use HTTPS. The QRZ.com sign-in is sent as a POST, so the password isn't in
a URL. HamQTH's sign-in, LoTW's report API and eQSL's DownloadInBox take the login as
parameters of their HTTPS address, as those services document it.

## Command line

`adiflint` runs the same checks without the editor:

```bash
build/adiflint examples/try-me.adi
```

Output is `file:line:column: severity: message [code]`, and the exit status is 1 when
there are errors. The code (`mode-is-submode`, `date-format`, `freq-band`…) names the kind
of problem, for scripts.

| Option | Does |
|---|---|
| `--fix OUT` | Write a copy with corrected lengths |
| `--fix-all OUT` | Write a copy with corrected lengths and every known repair (Check Log's); exit 1 if errors are left |
| `--reformat records\|fields OUT` | Write a copy with one record (or field) per line |
| `--chars` | Count lengths in characters instead of bytes |
| `--quiet` | Show errors only |
| `--sort OUT` | Write a copy sorted by date and time |
| `--sort-by KEYS OUT` | Write a copy sorted by fields, e.g. `BAND,CALL:desc,QSO_DATE` |
| `--field-order FIELDS OUT` | Write a copy with every record's fields in this order, e.g. `CALL,QSO_DATE,TIME_ON` |
| `--dedupe OUT` | Write a copy without repeated QSOs |
| `--csv OUT` | Write the log as CSV |
| `--from-csv OUT` | The input is a CSV file: write it as an ADIF log |
| `--summary` | Print the Log Summary |
| `--cabrillo OUT --contest ID --call CALL` | Write a Cabrillo 3.0 log |
| `--export pota\|wwff\|sota DIR [--call CALL]` | Write the activation upload files into DIR |

The log tools work on one file and never change it.

## Limits

- Nextpad++ ignores plugin default shortcuts, so ADIF Lint declares none. Assign your
  own in Nextpad++'s Edit → Shortcut Mapper…; it stores them in `shortcuts.xml` under
  `<PluginCommands>`, keyed by `moduleName="ADIF Lint"` and the command's position, so a
  version that changes the menu (0.10) moves them: check them after updating.
- Plugins can't write to the status bar, so summaries appear in a tip at the caret.
- Plugins can't supply a lexer, so colours are painted for the lines on screen as you
  scroll; while you type, they catch up when you pause.
- With Nextpad++'s own word completion on, its list can flash briefly before ADIF Lint's
  list takes its place. The autocomplete value lists are alphabetical (bands too), because
  Scintilla's list order is a setting the host relies on; the Record Panel's drop-downs
  keep the natural order.
- Only the active document is checked; the host gives plugins no access to other tabs.
- CNTY is checked only for entities whose subdivisions ADIF lists (US counties are not
  listed). DARC_DOK and COUNTRY are not checked against a list, and SOTA references get a
  loose check because the specification's definition is loose.
- Trailing spaces inside data are legal, so a length that includes one is not flagged.
- Enrich, Import, the uploads and spots were tested against saved sample replies and a
  stand-in TQSL, not the live services. The POTA spot format was checked against the live
  feed on 2026-10-07.
- TQSL must have the Station Location set up. A certificate password saved in Settings is
  passed on TQSL's command line (the only way TQSL takes it in batch mode), where other
  programs on your Mac could see it while TQSL runs.
- No SOTA spots: the SOTA API's terms don't allow software written with AI tools without
  the SOTA team's approval. SOTA tracking and export work offline.
- Imported QSOs are matched like LoTW (same call and band, mode or mode group, within 30
  minutes), so two QSOs with the same station on the same band within half an hour can be
  paired the wrong way round; check the list before Apply. QRZ.com doesn't document how
  FETCH encodes its ADIF or that '_' in a call stands for '/'; both are handled as other
  loggers handle them.
- The country file installed with the plugin is the 2026-09-15 release; press Update in
  Settings for the newest. Prefix rules give the usual entity; special cases are right
  only when the file lists the exact call.
- POTA's file-name rule is the one its documentation gives for emailed logs.
- ADX (XML) files are not handled.
