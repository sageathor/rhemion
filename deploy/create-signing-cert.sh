#!/usr/bin/env bash
# Create a stable self-signed "Code Signing" identity ("Rhemion Dev") in the login keychain.
#
# Why this exists: `swift build` ad-hoc (linker) signs the runtime binary, so its CDHash changes
# on every rebuild. macOS TCC keys the microphone grant to the CDHash, so a rebuilt binary is a
# "new" client that silently receives a ZERO (silent) audio stream -> empty transcripts, dictation
# appears dead. Signing every build with ONE stable certificate keeps the code signature — and thus
# the TCC grant — constant across rebuilds. (TCC keys on the signature identity, not on chain trust,
# so a self-signed, untrusted cert is exactly right here.)
#
# Run once. Safe to re-run: it is a no-op if the identity already exists.
set -euo pipefail

IDENTITY_NAME="Rhemion Dev"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "Code signing identity '$IDENTITY_NAME' already present. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cs.conf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Rhemion Dev
[v3]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/cs.key" -out "$TMP/cs.crt" -config "$TMP/cs.conf" >/dev/null 2>&1

# Legacy PBE + SHA1 MAC so Apple's `security import` can read the PKCS#12. OpenSSL 3's default
# PKCS#12 MAC algorithm is rejected by the Security framework ("MAC verification failed").
openssl pkcs12 -export -inkey "$TMP/cs.key" -in "$TMP/cs.crt" \
  -out "$TMP/cs.p12" -name "$IDENTITY_NAME" -passout pass:rhemion \
  -macalg SHA1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES

# Import the key allowlisting ONLY codesign (`-T`), NOT `-A`. `-A` would let ANY application use this
# private key without a prompt -- an unnecessary exposure of the very identity that gates the mic TCC
# grant. With just `-T`, codesign may raise a one-time keychain prompt on first use; click "Always
# Allow". To make it fully non-interactive without `-A`, run once with your login-keychain password:
#   security set-key-partition-list -S apple-tool:,apple: -s -k "<login-password>" "$KC"
security import "$TMP/cs.p12" -k "$KC" -P rhemion -T /usr/bin/codesign

echo "Imported code signing identity '$IDENTITY_NAME' into the login keychain."
echo "It is self-signed and untrusted for certificate chains — that is expected and fine:"
echo "TCC keys on the code signature identity, not on chain trust."
