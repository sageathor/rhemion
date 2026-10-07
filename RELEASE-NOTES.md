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
  ### No longer broken
  - ...
  ### Under the hood
  - ...

Rules:
- English, no emoji, written for the person using the app (what they notice), not internals.
- Newest version first. The heading line is exactly the one shown in the format above, with an em dash between version and date.
- Sections only from the list above, in that order: New, Improvements, Settings, No longer broken, Under the hood. Omit empty ones.
- One bullet = one sentence. An optional area prefix is allowed ("Settings: ...", "Journal: ...", "Dictionary: ...", "Clear Data: ...", "Uninstall: ...").
- 4 to 12 bullets per version, the most noticeable first.
- Keep private paths, names of other apps and personal data out.
- The top entry must match the VERSION file. Tag v<version> only after the release is verified.
-->


# Rhemion release notes

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

### No longer broken
- The recording indicator no longer drifts away from the notch after a display change or a screen recording.
- Clear Data never shows a step as done when it failed.
- When Rhemion is quit from Terminal or crashes, its helper process now exits too.

## 3.0.0 — 2026-10-05

First release.
