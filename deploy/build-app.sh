#!/usr/bin/env bash
# Build + sign Rhemion.app. Isolated from the default SwiftPM build products:
#  - builds BOTH RhemionApp and its own rhemion-runtime into a SEPARATE scratch path, never the
#    default .build/release;
#  - bundles that freshly-built runtime as Contents/Helpers, so the app always ships the runtime
#    built from the same sources;
#  - signs the helper first (its fixed runtime id), then the app WITHOUT --deep.
# Bump the build number to force a fresh CDHash: ./build-app.sh 2
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
NATIVE="$ROOT/native"
SCRATCH="$NATIVE/.build-app"
APP="$ROOT/Rhemion.app"
IDENTITY="Rhemion Dev"
APP_ID="com.sageathor.rhemion.app"
RUNTIME_ID="com.sageathor.rhemion.runtime"
BUILD="${1:-$(date +%s)}"
# Version comes from VERSION (e.g. 3.0.0-beta.5). CFBundleShortVersionString must be plain numbers,
# so the pre-release suffix is stripped; the full string goes in the custom RhemionVersion key.
FULL_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
SHORT_VERSION="${FULL_VERSION%%-*}"

echo "── build RhemionApp + rhemion-runtime (scratch=$SCRATCH) ──"
( cd "$NATIVE" && swift build -c release --product RhemionApp --scratch-path "$SCRATCH" )
( cd "$NATIVE" && swift build -c release --product rhemion-runtime --scratch-path "$SCRATCH" )
APP_BIN="$SCRATCH/release/RhemionApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/Fonts"
cp "$APP_BIN" "$APP/Contents/MacOS/RhemionApp"
# Bundle Mulish faces (the exact weights the design uses) so the UI renders true Mulish weights, not
# synthesized-heavy fallbacks. ATSApplicationFontsPath (Info.plist below) auto-registers them at launch.
cp "$ROOT"/deploy/fonts/*.ttf "$APP/Contents/Resources/Fonts/"

# Licenses of what ships inside the app: Rhemion (MIT), Mulish (OFL), FluidAudio (Apache-2.0) and the
# third-party licenses FluidAudio carries. The speech model is downloaded at runtime, not bundled.
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
cp "$ROOT/LICENSE"              "$LICENSES/Rhemion-LICENSE.txt"
cp "$ROOT/deploy/fonts/OFL.txt" "$LICENSES/Mulish-OFL.txt"
FLUID="$SCRATCH/checkouts/FluidAudio"
cp "$FLUID/LICENSE" "$LICENSES/FluidAudio-LICENSE.txt"
for f in "$FLUID"/ThirdPartyLicenses/*; do cp "$f" "$LICENSES/FluidAudio-$(basename "$f")"; done

# App icon: one icon (no light/dark choice); the compiled .icns is the bundle's icon for Finder/Dock/Cmd-Tab.
cp "$ROOT"/deploy/icons/AppIcon.icns     "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT"/deploy/icons/MenuBarGlyph.png "$APP/Contents/Resources/MenuBarGlyph.png"  # monochrome tray glyph (template)

# Runtime helper: the app's OWN runtime, built above into the isolated scratch path (NOT the default
# .build/release). Building it here keeps the bundled runtime in step with the app sources.
RUNTIME_SRC="$SCRATCH/release/rhemion-runtime"
if [ -x "$RUNTIME_SRC" ]; then
  cp "$RUNTIME_SRC" "$APP/Contents/Helpers/rhemion-runtime"
  echo "bundled runtime helper"
else
  echo "WARN: $RUNTIME_SRC not found — the app needs it; the runtime build above must have failed."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${APP_ID}</string>
  <key>CFBundleName</key><string>Rhemion</string>
  <key>CFBundleExecutable</key><string>RhemionApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>RhemionVersion</key><string>${FULL_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <!-- Bundled Mulish faces in Contents/Resources/Fonts are registered at launch (design font). -->

  <!-- In case macOS attributes the spawned runtime's mic use to this parent app. -->
  <key>NSMicrophoneUsageDescription</key><string>Rhemion transcribes your speech locally; audio never leaves your Mac.</string>
</dict>
</plist>
PLIST

# Sign helper FIRST (fixed runtime id keeps its TCC identity), then the app WITHOUT --deep so we
# don't casually re-sign/clobber the helper's signature.
if [ -x "$APP/Contents/Helpers/rhemion-runtime" ]; then
  codesign --force --sign "$IDENTITY" --identifier "$RUNTIME_ID" "$APP/Contents/Helpers/rhemion-runtime"
fi
codesign --force --sign "$IDENTITY" --identifier "$APP_ID" "$APP"

echo "── signature ──"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -iE "Identifier=|Authority=" | sed 's/^/  /'
echo "built $APP (CFBundleVersion=$BUILD)"
