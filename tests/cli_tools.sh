#!/bin/sh
# The adiflint log tools on the official ADIF test file: each output must lint
# without errors, and CSV must come back as the same number of records.
#   cli_tools.sh ADIFLINT OFFICIAL_ADI WORK_DIR
set -e
lint="$1"; adi="$2"; dir="$3"
rm -rf "$dir" && mkdir -p "$dir/pota"
"$lint" --summary "$adi" > "$dir/summary.txt" 2>/dev/null
grep -q "^Records" "$dir/summary.txt"
"$lint" --sort "$dir/sorted.adi" "$adi" 2>/dev/null
"$lint" --quiet "$dir/sorted.adi" > /dev/null 2>&1
"$lint" --sort-by BAND,CALL:desc,QSO_DATE "$dir/sortby.adi" "$adi" 2>/dev/null
"$lint" --quiet "$dir/sortby.adi" > /dev/null 2>&1
"$lint" --field-order CALL,QSO_DATE,TIME_ON "$dir/fields.adi" "$adi" 2>/dev/null
"$lint" --quiet "$dir/fields.adi" > /dev/null 2>&1
[ "$(wc -c < "$dir/fields.adi")" -eq "$(wc -c < "$adi")" ] || { echo "field order changed the size"; exit 1; }
"$lint" --dedupe "$dir/dedupe.adi" "$adi" 2>/dev/null
"$lint" --quiet "$dir/dedupe.adi" > /dev/null 2>&1
"$lint" --csv "$dir/log.csv" "$adi" 2>/dev/null
"$lint" --from-csv "$dir/back.adi" "$dir/log.csv" 2>/dev/null
n1=$("$lint" "$adi" 2>&1 >/dev/null | sed -n 's/.*: \([0-9]*\) record(s).*/\1/p')
n2=$("$lint" "$dir/back.adi" 2>&1 >/dev/null | sed -n 's/.*: \([0-9]*\) record(s).*/\1/p')
[ "$n1" = "$n2" ] || { echo "CSV round trip: $n1 records became $n2"; exit 1; }
"$lint" --cabrillo "$dir/log.cbr" --contest TEST --call K1ABC "$adi" 2>/dev/null
head -1 "$dir/log.cbr" | grep -q "START-OF-LOG: 3.0"
tail -1 "$dir/log.cbr" | grep -q "END-OF-LOG:"
# --fix-all repairs what has a known repair; diagnostics carry their code.
printf 'fixall\n<ADIF_VER:5>3.1.7 <EOH>\n<CALL:4>k1ab <QSO_DATE:10>2026-10-06 <TIME_ON:5>12:00 <FREQ:5>14074 <BAND:3>20m <MODE:3>USB <EOR>\n' > "$dir/broken.adi"
"$lint" "$dir/broken.adi" 2>/dev/null | grep -q "\[mode-is-submode\]" || { echo "no diagnostic code printed"; exit 1; }
"$lint" --fix-all "$dir/repaired.adi" "$dir/broken.adi" 2>/dev/null
grep -q "<CALL:4>K1AB <QSO_DATE:8>20261006 <TIME_ON:4>1200 <FREQ:6>14.074 <BAND:3>20m <MODE:3>SSB <SUBMODE:3>USB <EOR>" "$dir/repaired.adi" ||
    { echo "--fix-all did not repair:"; cat "$dir/repaired.adi"; exit 1; }
"$lint" --quiet "$dir/repaired.adi" > /dev/null 2>&1
"$lint" --fix-all "$dir/official-fixed.adi" "$adi" 2>/dev/null
"$lint" --quiet "$dir/official-fixed.adi" > /dev/null 2>&1
echo "cli tools ok ($n1 records)"
