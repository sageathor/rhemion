# Security policy

Rhemion works with sensitive parts of your Mac: the microphone, transcripts of your speech, synthetic keyboard input into the focused app, and the removal of files during Clear Data and Uninstall. Security reports are taken seriously.

## Reporting a vulnerability

**Please report privately, not in a public issue.**

- Email **sageathor@gmail.com** with the details and, if possible, steps to reproduce.
- Or use GitHub **private vulnerability reporting** (Security tab › Report a vulnerability).

Do not attach recordings or transcripts; describe the issue instead. If a proof of concept needs audio, use a throwaway phrase.

Rhemion is a one-person project: fixes are best-effort and prioritized by severity. You will be told honestly where a report stands.

## Supported versions

Only the latest release receives security fixes. Please reproduce on it before reporting.

## Scope

Most relevant:

- anything that sends audio, transcripts or other data off the Mac;
- misuse of the text-insertion or hotkey paths (Accessibility);
- Clear Data, Uninstall or `uninstall.sh` removing files outside Rhemion's own;
- the bundled helper or the model download fetching or running something unexpected.

Out of scope: the macOS warning about an unnotarized app (expected, see README), and issues in upstream projects (FluidAudio, the speech model), which should be reported upstream.
