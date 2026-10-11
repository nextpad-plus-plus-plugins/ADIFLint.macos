#!/bin/sh
# Refreshes the README's and user guide's screenshots in docs/images from the host harness:
# its usual window snapshots, plus the map and Log Table on a generated sample log
# (ADIFLINT_DOCS=1; no real log). Each is saved at the screen's 1x size.
#
#   tools/docs-screenshots.sh            (after cmake --build build)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
shots=$(mktemp -d)
trap 'rm -rf "$shots"' EXIT
ADIFLINT_DOCS=1 ADIFLINT_SNAPSHOT_DIR="$shots" "$root/build/host_harness" "$root/build/ADIFLint.dylib" "$root/tests/fixtures/lookup" > "$shots/log.txt" 2>&1 || {
    tail -20 "$shots/log.txt" >&2
    exit 1
}

# snapshot name -> docs/images name
while read -r from to; do
    src="$shots/$from.png"
    [ -f "$src" ] || { echo "no snapshot $from" >&2; exit 1; }
    w=$(sips -g pixelWidth "$src" | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$src" | awk '/pixelHeight/ {print $2}')
    max=$(( (w > h ? w : h) / 2 ))
    sips -Z "$max" "$src" --out "$root/docs/images/$to.png" > /dev/null
    echo "docs/images/$to.png"
done << 'EOF'
docs-map-globe map-globe
docs-map-zones map-zones
docs-map-europe map-europe
docs-map-states map-states
docs-map-colour-blind map-colour-blind
docs-log-table log-table
check-log check-log
new-qso-lookup new-qso-lookup
new-qso-spot new-qso-spot
pota-spots spots
monitor monitor
qsl-sync qsl-sync
start-activation start-activation
activation-tracker activation-tracker
upload-qrz upload-qrz
import-qrz import-qrz
bulk-edit bulk-edit
compare compare
EOF
