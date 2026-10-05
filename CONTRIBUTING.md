# Contributing to Rhemion

Thank you for your interest. Rhemion is maintained by one person, so a little coordination saves everyone time.

## Before you start

- **Open an issue first for anything that changes behavior**: a new feature, a new default, a change to permissions or storage. Small fixes (typos, obvious bugs, docs) can go straight to a pull request.
- Rhemion is **private by design**. Changes that send audio, text or usage data off the Mac will not be accepted. Any future network feature must be opt-in and clearly under the user's control.

## Development

Build instructions: [BUILDING.md](BUILDING.md). Code, comments and user-facing text are in English.

## Pull requests

- One purpose per pull request; focused changes are far easier to review.
- Anything touching the microphone, hotkeys, text insertion or permissions must be tested live on a Mac. Say what you tested and on which macOS version.
- Interface changes follow the existing look: reuse the components and colors already in the app rather than adding new ones.
- Keep recordings, transcripts, personal paths and secrets out of the diff.

## Review

One maintainer reviews everything, so it may take a while. The roadmap is maintainer-driven; not every good idea will fit.

By contributing, you agree that your work is licensed under the [MIT License](LICENSE) and to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
