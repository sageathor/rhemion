<!--
Format of this file (parsed to build a "What's new" view; keep it strict):

  # Rhemion release notes
  ## <semver> — <YYYY-MM-DD>
  ### New
  - ...
  ### Improvements
  - ...
  ### Settings
  - ...
  ### Fixes
  - ...
  ### Under the hood
  - ...

Rules:
- English, no emoji, written for the person using the app (what they notice), not internals.
- Newest version first. The heading line is exactly the one shown in the format above, with an em dash between version and date.
- Sections only from the list above, in that order: New, Improvements, Settings, Fixes, Under the hood. Omit empty ones.
- One bullet = one sentence. An optional area prefix is allowed ("Settings: ...", "Journal: ...", "Dictionary: ...", "Clear Data: ...", "Uninstall: ...").
- 4 to 12 bullets per version, the most noticeable first.
- Keep private paths, names of other apps and personal data out.
- The top entry must match the VERSION file. Tag v<version> only after the release is verified.
-->


# Rhemion release notes

## 3.1.0 — 2026-10-11

### New
- Your dictation goes only into the field where you started it; if you have moved elsewhere by the time the text is ready, it waits in the Journal instead of landing in the wrong place.
- Pin to this window (⌥⌘P or the menu bar) sends every dictation to the pinned window, even while you work in another app.
- Journal only: hold Shift while pressing the dictation key to save a thought to the Journal without inserting it anywhere.
- Journal: entries that were not inserted, canceled, erased or not recognised are marked, and Insert again puts the text back into the field it was meant for.
- A dictation canceled with Esc twice is kept in the Journal for 24 hours, so a cancel by mistake can be brought back.
- If recognition fails or Rhemion stops in the middle of a dictation, the recording is kept, and Recognize again in the Journal turns it into text.
- Settings › Shortcuts lists every keyboard action in the order you use it, with switches for hands-free and Esc twice and a list of apps that keep Esc twice for themselves; Keyboard Shortcuts… (⌘/) in the menu bar opens it.

### Improvements
- Text pasted into web pages and other apps appears about three times faster.
- The recording indicator shows how a dictation ended: the waves go out when the text is in, a ring holds when it is kept in the Journal, and the orb empties in red when nothing was recognised.
- Paste uses the V key of your current keyboard layout, so it works on Dvorak and other layouts.

### Fixes
- A dictation pasted into a busy web page no longer pastes your previous clipboard content instead of the text.
- Tapping the dictation key twice to finish hands-free recording no longer starts a new recording.

## 3.0.1 — 2026-10-07

### New
- Dictionary: adding a word with ⌥⌘W now also fixes the selected word in the text, or copies the fix when the field can't be edited.
- On macOS 26 the app icon follows your appearance: a dark mark on a light tile in Light mode, a white mark on graphite in Dark mode.
- Opening Rhemion from the Dock, Finder or Spotlight now opens its window; at login it still starts quietly in the menu bar.

### Improvements
- Clear Data: clearing the cache keeps the prepared speech model, so dictation is ready right away instead of preparing for half a minute.
- A speech model that can't be loaded is now reported as such, with Download again, instead of showing Ready.
- If you copy something at the moment a dictation is pasted, your copy is kept and nothing is pasted over it.
- A password copied from a password manager is no longer put back on the clipboard after a dictation.

### Fixes
- The recording indicator no longer drifts away from the notch after a display change or a screen recording.
- Clear Data never shows a step as done when it failed.
- When Rhemion is quit from Terminal or crashes, its helper process now exits too.

## 3.0.0 — 2026-10-05

First release.
