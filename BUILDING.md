# Building Rhemion

## Requirements

- macOS 15 or later on Apple Silicon
- Xcode 26 or later (Swift 6.2)

## One-time: a signing certificate

macOS ties the Microphone and Accessibility permissions to the app's code signature. An ad-hoc signature changes on every build, so permissions would be lost after each rebuild. Create a stable self-signed certificate once:

```sh
bash deploy/create-signing-cert.sh
```

It adds a code-signing identity named "Rhemion Dev" to your login keychain. It exists only on your Mac; it is not the certificate the official releases are signed with.

## Build

```sh
bash deploy/build-app.sh
```

The result is `Rhemion.app` in the repository root: the app and its built-in helper (`Contents/Helpers/rhemion-runtime`), both signed with "Rhemion Dev". Move it to `/Applications` and open it.

To make a ZIP with its SHA-256 checksum, as attached to releases:

```sh
bash deploy/package-release.sh --test
```

The ZIP and the `.sha256` file appear in `release/`. Without `--test`, the script expects `VERSION` to be a final version (for example `3.0.0`).

## Bundle identifiers

| Component | Identifier |
|---|---|
| App | `com.sageathor.rhemion.app` |
| Helper | `com.sageathor.rhemion.runtime` |

A self-built Rhemion and a downloaded release share these identifiers but not the signature. When you switch between them, macOS may ask for the permissions again.

## Project layout

- `native/`: Swift package with the app, the helper and the libraries (audio, recognition, text insertion, storage).
- `deploy/`: build, signing, packaging and uninstall scripts, fonts, icons.
