#!/usr/bin/env bash
# Rhemion 3.0 — uninstaller. Removes what a drag-to-Trash leaves behind:
# the app bundle, per-user config/state, recordings, preferences, and TCC grants.
#
# Run it (quarantine-safe, no chmod needed):
#   bash uninstall.sh
#
# Modes (interactive by default — it will ask):
#   --keep-data     remove the app + reset TCC + app data (settings/logs/prefs/cache/temp),
#                   KEEP your content: dictionary, transcripts, recordings, legacy data, model
#   --purge         also erase your content (dictionary, journal, recordings); the downloaded
#                   model stays unless --purge-model is given
#   --purge-model   also remove the downloaded parakeet speech model (see warning below)
#   --yes           don't prompt (assume yes to the chosen mode)
#   --app <path>    explicit path to Rhemion.app (otherwise auto-detected)
#
# NOTE: the FluidAudio model cache is SHARED with other apps that use FluidAudio.
# This script only ever removes Rhemion's OWN parakeet model folders inside it
# (parakeet-tdt-0.6b-v3 / -v2), never the cache itself, and only with --purge-model.
# Exported transcripts (the Markdown files in the folder you chose for export) are YOUR notes and
# are never touched. Nor is the state directory of the earlier 2.0 generation
# (~/.local/state/rhemion, no "-v3" suffix): this script never looks at it, in any mode.
# NOT `set -e`: an uninstaller must be best-effort — one failed removal (e.g. the app in /Applications
# needs admin rights) must never abort the rest of the cleanup. We report failures and keep going.
set -uo pipefail

# --- test-mode plumbing (RHEMION_TEST_HOME) ---
# Every path below is derived from HOME_DIR, and every system-wide side effect (killing processes,
# resetting TCC, touching `defaults`, driving Finder) goes through sys() — see below. This lets
# deploy/tests/uninstall-test.sh exercise the whole script against a fake home directory without
# ever touching the real machine. Without RHEMION_TEST_HOME set, HOME_DIR is just $HOME and sys()
# runs commands for real — this script must NEVER be run directly against a real Mac for testing.
HOME_DIR="${RHEMION_TEST_HOME:-$HOME}"
TEST_MODE=""
if [ -n "${RHEMION_TEST_HOME:-}" ]; then
  TEST_MODE=1
  # Belt and braces: refuse to run in "test mode" against anything that isn't an obvious throwaway
  # temp directory. A typo'd RHEMION_TEST_HOME must never end up pointed at the real $HOME.
  real_home="$(cd "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")"
  test_home="$(cd "$HOME_DIR" 2>/dev/null && pwd -P || printf '%s' "$HOME_DIR")"
  if [ "$test_home" = "$real_home" ]; then
    echo "REFUSING: RHEMION_TEST_HOME resolves to the real \$HOME ($real_home)." >&2
    exit 2
  fi
  case "$test_home" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) ;;
    *)
      echo "REFUSING: RHEMION_TEST_HOME ($test_home) is not under a temp directory (mktemp -d)." >&2
      exit 2
      ;;
  esac
fi

# sys() — the ONE place every system-wide effect goes through (pkill, tccutil, defaults,
# osascript/Finder). In test mode it only prints what it would have run and returns success;
# for real it just execs the command. File removals under HOME_DIR are NOT routed through this —
# those stay real even in test mode, since they operate on the fake home, not the real machine.
sys() {
  if [ -n "$TEST_MODE" ]; then
    echo "  would: $*"
    return 0
  fi
  "$@"
}

APP_ID="com.sageathor.rhemion.app"
RUNTIME_ID="com.sageathor.rhemion.runtime"   # the bundled helper; it has its own Microphone entry
APP_NAME="Rhemion"

# Per-user footprint (literal paths — never derived, so an empty var can't widen an rm).
STATE_DIR="$HOME_DIR/.local/state/rhemion-v3"
DATA_DIR="$HOME_DIR/Library/Application Support/Rhemion"
PREFS="$HOME_DIR/Library/Preferences/${APP_ID}.plist"
CACHES="$HOME_DIR/Library/Caches/${APP_ID}"
# CoreML's compiled-model cache for the runtime helper (named after the executable, not the bundle id).
RUNTIME_CACHE="$HOME_DIR/Library/Caches/rhemion-runtime"
SAVED_STATE="$HOME_DIR/Library/Saved Application State/${APP_ID}.savedState"
MODEL_CACHE="$HOME_DIR/Library/Application Support/FluidAudio/Models"
# Rhemion's OWN downloaded models inside the shared FluidAudio cache — the only things in
# MODEL_CACHE this script will ever remove (never the cache directory itself, never sibling
# models belonging to other FluidAudio apps such as silero-vad or another app's own model).
PARAKEET_MODELS="parakeet-tdt-0.6b-v3 parakeet-tdt-0.6b-v2"
# The app's own runtime temp folder (mirrors AppPaths.resolvedTemporaryDirectory() +
# StorageLayout.tmpRoot: realpath(system temp)/<bundle id>). This is OUTSIDE HOME_DIR — the system
# temp dir is per-user but not under $HOME — so it can't be derived from HOME_DIR like everything
# else above. Computing the path is harmless (read-only); only its removal is a real effect, and
# that's routed through sys() below, so test mode never touches the real machine's temp dir.
TMP_ROOT="$(realpath "${TMPDIR:-/tmp}" 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}")/${APP_ID}"

MODE=""          # keep-data | purge
PURGE_MODEL=0
ASSUME_YES=0
APP_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-data) MODE="keep-data" ;;
    --purge)     MODE="purge" ;;
    --purge-model) PURGE_MODEL=1 ;;
    --yes|-y)    ASSUME_YES=1 ;;
    --app)       shift; APP_PATH="${1:-}" ;;
    -h|--help)   sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

confirm() { # confirm "question"
  [ "$ASSUME_YES" = "1" ] && return 0
  local a; read -r -p "$1 [y/N] " a || true
  [ "$a" = "y" ] || [ "$a" = "Y" ]
}

rm_path() { # rm_path "label" "path"  — safe + tolerant: only touches a non-empty, existing path, and a
  # failure (permissions) is reported, never fatal.
  local label="$1" p="$2"
  if [ -n "$p" ] && [ -e "$p" ]; then
    if rm -rf "$p" 2>/dev/null; then echo "  removed  $label: $p"
    else echo "  FAILED   $label: $p (permission?) — remove manually"; fi
  else
    echo "  (absent) $label: $p"
  fi
}

# The app bundle is moved to the Trash via Finder — never `rm -rf`, so the same admin-password
# dialog Finder always shows for a protected /Applications item appears here too, and nothing
# about the bundle's own permissions can make this script destroy files it doesn't fully own.
remove_app() { # remove_app "path"
  local app="$1"
  [ -n "$app" ] || { echo "  (absent) app: (not found)"; return; }
  [ -e "$app" ] || { echo "  (absent) app: $app"; return; }
  echo "  asking Finder to move it to the Trash…"
  # In test mode sys() never execs osascript at all (just prints "would: ..."), so there's nothing to
  # suppress and doing so would hide that line from the test; in real mode Finder's own AppleScript
  # result (an alias path) is noise, so it's silenced as before.
  local finder_ok
  if [ -n "$TEST_MODE" ]; then
    sys /usr/bin/osascript -e "tell application \"Finder\" to delete (POSIX file \"$app\")"
    finder_ok=$?
  else
    sys /usr/bin/osascript -e "tell application \"Finder\" to delete (POSIX file \"$app\")" >/dev/null 2>&1
    finder_ok=$?
  fi
  if [ "$finder_ok" -eq 0 ]; then
    echo "  moved to Trash via Finder: $app  (empty the Trash to finish)"
  else
    echo "  COULD NOT move $app to the Trash automatically."
    echo "  → Move Rhemion to the Trash yourself."
  fi
}

echo "== Rhemion 3.0 uninstaller =="

# --- locate the app bundle ---
if [ -z "$APP_PATH" ]; then
  # Prefer Spotlight; fall back to common locations. Skipped in test mode: a test always passes
  # --app explicitly, and this must never accidentally resolve to the real installed app.
  if [ -z "$TEST_MODE" ]; then
    APP_PATH="$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == '$APP_ID'" 2>/dev/null | head -1 || true)"
    if [ -z "$APP_PATH" ]; then
      for cand in "/Applications/$APP_NAME.app" "$HOME_DIR/Applications/$APP_NAME.app" "$HOME_DIR/Downloads/$APP_NAME.app"; do
        [ -d "$cand" ] && APP_PATH="$cand" && break
      done
    fi
  fi
fi
if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
  echo "app bundle: $APP_PATH"
else
  echo "app bundle: not found (already removed, or run with --app <path>)"
  APP_PATH=""
fi

# --- choose mode ---
if [ -z "$MODE" ]; then
  echo
  echo "Choose:"
  echo "  1) Uninstall, KEEP my data (dictionary, transcripts, recordings, model)"
  echo "  2) Uninstall and ERASE my data (dictionary, transcripts, recordings)"
  echo "     The speech model is kept unless you run with --purge-model."
  echo "     Exported transcripts in your export folder are never touched."
  read -r -p "1 or 2? " choice || true
  case "$choice" in
    1) MODE="keep-data" ;;
    2) MODE="purge" ;;
    *) echo "aborted."; exit 1 ;;
  esac
fi

echo
echo "Mode: $MODE"
confirm "Proceed?" || { echo "aborted."; exit 1; }

# --- stop running processes ---
echo "stopping Rhemion…"
sys /usr/bin/pkill -f "$APP_NAME.app/Contents/MacOS/RhemionApp" 2>/dev/null || true
sys /usr/bin/pkill -f "$APP_NAME.app/Contents/Helpers/rhemion-runtime" 2>/dev/null || true
sleep 1
sys /usr/bin/pkill -9 -f "$APP_NAME.app/Contents/MacOS/RhemionApp" 2>/dev/null || true
sys /usr/bin/pkill -9 -f "$APP_NAME.app/Contents/Helpers/rhemion-runtime" 2>/dev/null || true

# (The app bundle is removed LAST — see remove_app below — so the always-succeeding per-user cleanup
#  happens first, and any admin-password prompt for /Applications comes at the very end.)

# --- reset TCC (Accessibility + Microphone) for the app, Microphone for its helper ---
# Exit codes are printed as-is, no masking with && / || — an honest "did this actually reset
# anything" signal, since tccutil's own output is not to be relied on.
# NOTE: in test mode sys() never execs tccutil — it only echoes "would: ..." and returns 0 without
# running anything — so the exit code printed below is NOT meaningful in test mode (it is always 0
# regardless of what a real tccutil would have done); it only reflects reality when running for real.
echo "resetting TCC grants…"
sys /usr/bin/tccutil reset Accessibility "$APP_ID" 2>/dev/null
echo "  tccutil reset Accessibility: exit $?"
sys /usr/bin/tccutil reset Microphone "$APP_ID" 2>/dev/null
echo "  tccutil reset Microphone: exit $?"
sys /usr/bin/tccutil reset Microphone "$RUNTIME_ID" 2>/dev/null
echo "  tccutil reset Microphone (helper): exit $? (non-zero = no entry)"

# --- app data (StorageLayout.applicationData — settings/logs/prefs/cache/saved-state/temp) ---
# Removed in EVERY mode: this is the app's own bookkeeping, not your content. Mirrors exactly what
# the in-app uninstaller's "Uninstall, keep my data" option removes (see StorageLayout.swift
# items(.applicationData) — the authoritative list this block mirrors file-for-file).
echo "removing app data (settings/logs/prefs/cache)…"
rm_path "settings"            "$STATE_DIR/active/settings.json"
rm_path "settings lock"       "$STATE_DIR/active/settings.json.lock"
rm_path "app log"             "$STATE_DIR/app.log"
rm_path "runtime log"         "$STATE_DIR/runtime.log"
# Rotated copies of those two logs (LogRotation: app.log.1, runtime.log.2, …).
for rotated in "$STATE_DIR"/app.log.[0-9]* "$STATE_DIR"/runtime.log.[0-9]*; do
  [ -e "$rotated" ] && rm_path "rotated log" "$rotated"
done
rm_path "runtime socket"      "$STATE_DIR/runtime.sock"
rm_path "export-last-run"     "$STATE_DIR/export-last-run"
rm_path "history-retention-last-run" "$STATE_DIR/history-retention-last-run"
# Stray atomic temps of those two markers (left by a crash between write and rename).
for stray in "$STATE_DIR"/.history-retention-*.tmp "$STATE_DIR"/.export-last-run-*.tmp; do
  [ -e "$stray" ] && rm_path "stray temp" "$stray"
done
if sys /usr/bin/defaults delete "$APP_ID" 2>/dev/null; then echo "  cleared defaults ($APP_ID)"; fi
rm_path "preferences"         "$PREFS"
rm_path "caches"              "$CACHES"
rm_path "runtime model cache" "$RUNTIME_CACHE"
rm_path "saved state"         "$SAVED_STATE"
echo "  runtime temp: $TMP_ROOT"
sys rm -rf "$TMP_ROOT" 2>/dev/null

# --- your content (dictionary, transcripts, recordings, legacy data, export registry) ---
# Kept in --keep-data (the whole point of that mode); erased only in --purge. Note this script never
# removes the vault export registry itself (export-manifest.json under STATE_DIR) via any name-level
# rm_path above — in --purge it goes away only as part of the whole-STATE_DIR sweep below, which is
# fine: the registry is meaningless once the state dir it points from is gone.
if [ "$MODE" = "purge" ]; then
  echo "erasing your content…"
  rm_path "state (dictionary/transcripts/legacy data)" "$STATE_DIR"
  rm_path "recordings"                                 "$DATA_DIR"
else
  echo "keeping your content (dictionary, transcripts, recordings, legacy data)."
fi

# --- Rhemion's own downloaded model (opt-in only; never the shared cache) ---
if [ "$MODE" = "purge" ]; then
  if [ "$PURGE_MODEL" = "1" ] || { [ -d "$MODEL_CACHE" ] && confirm "Also delete the downloaded speech-recognition model (parakeet)? Other FluidAudio apps' models (e.g. silero-vad) are left alone."; }; then
    echo "removing downloaded model…"
    for m in $PARAKEET_MODELS; do
      rm_path "model: $m" "$MODEL_CACHE/$m"
    done
  else
    [ -d "$MODEL_CACHE" ] && echo "  kept model cache: $MODEL_CACHE (parakeet folders untouched)"
  fi
fi

# --- remove the app bundle LAST (may need admin rights for /Applications) ---
echo "removing the app…"
remove_app "$APP_PATH"

# --- login item note (SMAppService can't be unregistered from outside the app) ---
echo
echo "Login item: remove \"Rhemion\" in System Settings → General → Login Items (a script can't)."
echo "Note: transcripts exported to your export folder are your own notes and were NOT touched."
echo
echo "Done."
