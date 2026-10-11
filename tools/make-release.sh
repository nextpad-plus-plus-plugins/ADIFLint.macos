#!/bin/sh
# Builds the release zip that Nextpad++'s Plugins Admin installs, and prints the
# two SHA-256 values and the entry for nppPluginList's pl.macos-arm64.json.
#
#   tools/make-release.sh [OWNER/REPO]        (default ssamjung2/Nextpad_plus_plus_ADIFLint)
#
# The zip holds one folder, ADIFLint/, with the dylib, the country file, the licence notices
# and the toolbar icons:
# Plugins Admin unpacks the whole zip into its plugins folder (ditto -xk) and
# then loads ADIFLint/ADIFLint.dylib. No macOS metadata (._ files) goes in.
# id is the zip's SHA-256 and dylib-id the dylib's, as nppPluginList's
# tools/update-macos-arm64-catalog.py computes them (checked 2026-10-08).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
repo=${1:-ssamjung2/Nextpad_plus_plus_ADIFLint}
version=$(sed -n 's/^project(ADIFLint VERSION \([0-9.]*\) .*/\1/p' "$root/CMakeLists.txt")
plugin=$(sed -n 's/^#define ADIFLINT_VERSION "\(.*\)"/\1/p' "$root/src/plugin/ADIFLint.mm")
if [ -z "$version" ] || [ "$version" != "$plugin" ]; then
    echo "version mismatch: CMakeLists.txt '$version', ADIFLint.mm '$plugin'" >&2
    exit 1
fi

build="$root/build"
cmake -S "$root" -B "$build" -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build "$build" --target ADIFLint -j > /dev/null

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/ADIFLint"
cp "$build/ADIFLint.dylib" "$root/data/cty.csv" "$root/data/cty-copyright.txt" "$root/data/zones-license.txt" "$root"/data/toolbar/*.png "$stage/ADIFLint/"
dylib="$stage/ADIFLint/ADIFLint.dylib"
# Ad-hoc, as the install step signs it (Nextpad++ disables library validation).
codesign --force --sign - "$dylib"
codesign --verify "$dylib"

archs=$(lipo -archs "$dylib")
for a in arm64 x86_64; do
    case " $archs " in *" $a "*) ;; *) echo "the dylib has no $a slice ($archs)" >&2; exit 1 ;; esac
done
otool -l "$dylib" | grep -q "current version $version" || {
    echo "the dylib's current_version is not $version" >&2
    exit 1
}

dist="$root/dist"
mkdir -p "$dist"
zip="$dist/ADIFLintv$version.zip"
rm -f "$zip"
(cd "$stage" && ditto -c -k --norsrc --noextattr --noqtn --keepParent ADIFLint "$zip")
if unzip -Z1 "$zip" | grep -v '^ADIFLint/' > /dev/null; then
    echo "the zip has files outside ADIFLint/:" >&2
    unzip -Z1 "$zip" >&2
    exit 1
fi

zipsha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
dylibsha=$(shasum -a 256 "$dylib" | cut -d' ' -f1)
printf '%s  %s\n%s  %s\n' "$zipsha" "ADIFLintv$version.zip" "$dylibsha" "ADIFLint/ADIFLint.dylib" > "$dist/SHA256SUMS"

echo "Built $zip ($archs)"
unzip -Z1 "$zip" | sed 's/^/  /'
echo
cat "$dist/SHA256SUMS"
echo
echo "Entry for pl.macos-arm64.json (the maintainer may rebuild, re-sign and change the hashes):"
cat << EOF
{
  "folder-name": "ADIFLint",
  "display-name": "ADIF Lint",
  "version": "$version",
  "id": "$zipsha",
  "dylib-id": "$dylibsha",
  "dylib-built": "$(date -u +%Y-%m-%d)",
  "repository": "https://github.com/$repo/releases/download/v$version/ADIFLintv$version.zip",
  "description": "Validate and repair ADIF (.adi) ham radio logs as you type; New QSO logging, POTA/WWFF/SOTA tools, callbook enrich, and uploads to QRZ, LoTW, Club Log and eQSL.",
  "author": "Andrew Blessing (KW9D)",
  "homepage": "https://github.com/$repo",
  "npp-min-version": "1.1.2"
}
EOF
