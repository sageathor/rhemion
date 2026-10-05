# Troubleshooting

## "Rhemion" cannot be opened / Apple could not verify it

Expected on first launch: Rhemion is not notarized by Apple. Click **Done**, then **System Settings › Privacy & Security › Security › Open Anyway** and confirm. On macOS 15 and later, Control-click › Open no longer offers this.

If **Open Anyway** is not there, open Rhemion from the Applications folder once more, then look again.

If you have checked the download's SHA-256 checksum, you can also remove the download flag in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Rhemion.app
```

This skips macOS's check for this app; only do it for a download you have verified.

## "Rhemion is damaged and can't be opened"

The download was probably corrupted, or unpacked by a tool that broke the signature. Download the ZIP again, open it with Finder, and compare the checksum with the release page.

## Nothing happens when I hold the key

- **Accessibility** must be on for Rhemion: System Settings › Privacy & Security › Accessibility. After turning it on, quit Rhemion (⌥⌘Q) and open it again.
- Check the key in Settings › General › Push-to-talk key. Fn may not work on some external keyboards, so add a second key.
- The speech model must be downloaded. While it is missing, the menu bar menu shows "Setup incomplete: download model".

## The text does not appear in the app

- **Accessibility** must be on for Rhemion (see above).
- Some apps refuse inserted text; set Settings › General › **Text insertion** to **Clipboard**.
- Password fields are not filled, by design.

## Empty transcripts, or nothing is recognized

- **Microphone** must be on: System Settings › Privacy & Security › Microphone. Rhemion may appear there twice, as Rhemion and as `rhemion-runtime`, its built-in helper that records the audio. Both should be on.
- Check the microphone in Settings › Audio & Model › **Microphone**.

## Permissions are on, but Rhemion acts as if they are not

This can happen after replacing Rhemion with a build signed differently, for example your own build. Reset the entries in Terminal, then open Rhemion and allow again:

```sh
tccutil reset Accessibility com.sageathor.rhemion.app
tccutil reset Microphone com.sageathor.rhemion.app
tccutil reset Microphone com.sageathor.rhemion.runtime
```

## The model download is stuck

Check the internet connection and press **Retry** in the Welcome window or in Settings › Audio & Model › **Speech model (Parakeet)**. The download is about 460 MB.

## Reporting a problem

Open an [issue](https://github.com/sageathor/rhemion/issues/new/choose) with your macOS version, the Rhemion version (menu bar icon › **About Rhemion**, where **Copy** copies it) and the steps. Please do not attach recordings or transcripts.
