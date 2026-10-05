# Privacy

Rhemion is built so that what you say stays on your Mac.

## What happens to your voice

- Audio is captured only while you dictate: while the key is held, or while hands-free recording is on.
- Recognition runs on your Mac. Audio and text are not sent anywhere.
- The recognized text is inserted into the focused field. When Rhemion pastes it, it puts the previous clipboard content back afterwards, unless another app has changed the clipboard in the meantime. The pasted text is marked so that clipboard managers can skip it.

## What is stored, and where

| Data | Location | Removed by |
|---|---|---|
| Settings and dictionary | `~/.local/state/rhemion-v3/active/` | Clear Data, Uninstall |
| Journal: transcripts | `~/.local/state/rhemion-v3/log/` | Clear Data, Uninstall, Journal cleanup |
| Journal: audio | `~/Library/Application Support/Rhemion/history/` | Clear Data, Uninstall, Journal cleanup |
| Speech model | `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/` | Clear Data, Uninstall (your choice) |
| Logs | `~/.local/state/rhemion-v3/app.log`, `runtime.log` (kept 7 days, 15 MB at most) | Automatically; Clear Data, Uninstall |
| Caches | `~/Library/Caches/` and the temporary folder, under Rhemion's names | Clear Data, Uninstall |
| Exported transcripts | A folder you choose. Export is off until you turn it on and pick the folder. | Only if you ask: Settings › Journal › Export, or Clear Data |

Logs record technical events: start and stop, timings, text length in bytes, microphone names, errors. They do not record what you said, and they never contain audio.

## Network

- Rhemion goes online only to download the speech model, when you ask for it in the Welcome window or in Settings › Audio & Model. By default the model comes from Hugging Face (`huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml`), which sees the request like any download (IP address, time).
- Recognition works offline.
- Rhemion has no analytics, crash reporting, telemetry, account or update check.

## Permissions

Accessibility (notice the dictation key, insert text, read a selection for the dictionary) and Microphone (hear you while you dictate; macOS may list Rhemion's helper `rhemion-runtime` separately). Uninstall removes Rhemion's entries from these lists.

## Contact

Questions: open an issue. Security problems: see [SECURITY.md](SECURITY.md).
