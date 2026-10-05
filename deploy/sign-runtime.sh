#!/usr/bin/env bash
# Sign the runtime binary with the stable "Rhemion Dev" identity so its code signature — and thus
# its macOS TCC microphone grant — stays constant across rebuilds. Without a stable signature,
# `swift build`'s ad-hoc signing changes the CDHash every build and macOS silently revokes mic
# access, so capture records digital silence. See deploy/create-signing-cert.sh for the why.
#
# Usage: deploy/sign-runtime.sh [path-to-binary]   (defaults to the release build)
# Run after every `swift build -c release` during development.
set -euo pipefail

IDENTITY_NAME="Rhemion Dev"
IDENTIFIER="com.sageathor.rhemion.runtime"   # fixed identifier -> stable designated requirement
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/native/.build/release/rhemion-runtime}"

if [ ! -x "$BIN" ]; then
  echo "sign-runtime: binary not found at $BIN (build it first)" >&2
  exit 1
fi

if ! security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "sign-runtime: identity '$IDENTITY_NAME' not found." >&2
  echo "Run deploy/create-signing-cert.sh once to create it." >&2
  exit 1
fi

codesign --force --sign "$IDENTITY_NAME" --identifier "$IDENTIFIER" --timestamp=none "$BIN"
echo "Signed $BIN"
codesign -dvv "$BIN" 2>&1 | grep -E "^Identifier|^Authority" || true
