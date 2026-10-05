# Using Rhemion

## Dictate

| Action | Default |
|---|---|
| Dictate (push-to-talk) | Hold **Right Command**, speak, release |
| Keep recording hands-free | Double-tap the dictation key; tap once to stop |
| Stop hands-free automatically | After 30 s of silence a 10 s countdown ring appears, then recording stops |
| Cancel the current recording | Double-tap **Esc** while recording |
| Erase the text just inserted | Double-tap **Esc** right after it appears (within 8 s) |
| Insert the last dictation again | **⌥⌘R** |
| Add a word to the dictionary | Select it, press **⌥⌘W** |
| Undo the last dictionary replacement | **⇧⌥⌘L** (within 8 s) |
| Open Rhemion | Menu bar icon › **Open Rhemion…** (⌘0), or click the Dock icon |
| Close Rhemion's windows | **⌘Q**. Rhemion keeps running in the menu bar |
| Quit Rhemion | **⌥⌘Q**, or menu bar icon › **Quit Rhemion** |

Where to change them:

- **Settings › General**: the push-to-talk key (several keys can be added).
- **Settings › Shortcuts**: Recall, Dictionary add, Undo replacement (each can have several shortcuts).
- **Settings › Recording**: the double-Esc timing, the 8-second reversal window, and the hands-free silence and countdown times.

## Recording indicator

While Rhemion listens, an amber indicator appears at the notch, or as a small pill below the menu bar on Macs without a notch. It grows with your voice, turns into a spinner while the text is recognized, shows a short mark when it is done, and a countdown ring before hands-free recording stops on its own. Settings › General › Recording indicator: Auto, Notch or Floating.

## How text is inserted

Settings › General › **Text insertion**:

- **Direct** (default): Rhemion inserts the text into the focused field through Accessibility. In web pages and fields that do not support this, it pastes instead.
- **Clipboard**: Rhemion always pastes. Afterwards it puts the previous clipboard content back, unless another app has changed the clipboard in the meantime.

Password fields are not filled.

## Language

Settings › General › **Recognition language**: Auto, Russian or English.

## Dictionary

Open **Dictionary** in the Rhemion window. Each line is "Spoken as → Replace with"; several spoken variants can lead to one word. Changes apply from the next dictation.

## Journal

Open **Journal** in the Rhemion window: your dictations, newest first, with search. Copy a transcript, replay it (speed 1–2×) while its audio is kept, or delete it.

Settings › Journal › **Cleanup** can remove old audio, or whole entries, after a period you choose. It is off by default.

### Export

Transcripts can be exported to a folder of Markdown files, one per month, which is handy for a notes app such as Obsidian. Export is off by default. In Settings › Journal › **Export mode** choose Auto, Manual or Scheduled; Rhemion then asks for the folder. Off stops exporting; if Rhemion's files are in the folder, it asks whether to keep or delete them.

## Storage, Clear Data, Uninstall

**Settings › Advanced › Storage** shows what Rhemion keeps and how much space it uses.

- **Clear Data…**: choose what to remove (recordings, unused models, the model in use, logs, cache, journal, dictionary, exported transcripts, or Reset all settings). Presets: Free Up Space, Erase Personal Data, Start Over.
- **Uninstall…**: remove Rhemion; choose which of your data to keep.

## Launch at login

On by default; Settings › General › **Launch at login**.
