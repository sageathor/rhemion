#!/usr/bin/env bash
# Package Rhemion.app for a GitHub release: release/Rhemion-<version>.zip + its .sha256.
# Build first (bash deploy/build-app.sh <build-number>); this script only checks and packages.
#
#   bash deploy/package-release.sh            # VERSION must be a plain release (e.g. 3.0.0)
#   bash deploy/package-release.sh --test     # allow a pre-release VERSION (e.g. 3.0.0-beta.5) for trial runs
#
# Checks: both executables are signed with the stable identity (never ad-hoc), the signature verifies
# strictly, the ZIP is made with ditto (plain zip can break the signature), and a copy unpacked from the
# ZIP verifies again.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/Rhemion.app"
IDENTITY="Rhemion Dev"
OUT="$ROOT/release"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

fail() { echo "FAIL: $*" >&2; exit 1; }

if [ "${1:-}" != "--test" ] && [[ "$VERSION" == *-* ]]; then
  fail "VERSION is a pre-release ($VERSION); set it to the release version or pass --test"
fi
[ -d "$APP" ] || fail "$APP not found — run deploy/build-app.sh first"

BUNDLED="$(/usr/libexec/PlistBuddy -c 'Print :RhemionVersion' "$APP/Contents/Info.plist")"
[ "$BUNDLED" = "$VERSION" ] || fail "the app was built as $BUNDLED but VERSION is $VERSION — rebuild"

check_signature() {   # $1 = app bundle
  local app="$1" exe
  for exe in "$app/Contents/MacOS/RhemionApp" "$app/Contents/Helpers/rhemion-runtime" "$app"; do
    local info; info="$(codesign -dv --verbose=2 "$exe" 2>&1)"
    grep -q "Signature=adhoc" <<<"$info" && fail "ad-hoc signature: $exe"
    grep -q "Authority=$IDENTITY" <<<"$info" || fail "not signed by \"$IDENTITY\": $exe"
  done
  codesign --verify --strict "$app/Contents/Helpers/rhemion-runtime" || fail "helper signature does not verify"
  codesign --verify --strict "$app" || fail "app signature does not verify"
}

echo "── checking $APP ($VERSION) ──"
check_signature "$APP"

mkdir -p "$OUT"
ZIP="$OUT/Rhemion-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
( cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

echo "── checking a copy unpacked from the ZIP ──"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
check_signature "$TMP/Rhemion.app"
( cd "$OUT" && shasum -a 256 -c "$(basename "$ZIP").sha256" >/dev/null ) || fail "checksum does not match"

echo "── done ──"
echo "  $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  $(cat "$ZIP.sha256")"
