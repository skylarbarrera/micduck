#!/usr/bin/env bash
# Create a self-signed code-signing identity, once, so the Accessibility grant survives rebuilds.
#
# An ad-hoc signature has no stable identity, so macOS pins the Accessibility grant to the
# binary's exact hash. Rebuilding produces a new hash and silently revokes the grant, while the
# old entry still shows as enabled in System Settings. Signing with a real identity makes macOS
# match on the certificate instead, so the grant survives every later rebuild.
set -euo pipefail

ID_NAME="${SIGN_ID:-micduck-selfsigned}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$ID_NAME" >/dev/null 2>&1; then
  echo "identity '$ID_NAME' already exists, nothing to do"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$ID_NAME" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# OpenSSL 3 defaults to a SHA-256 MAC that Apple's importer rejects, so pin the older
# algorithms. These are also what LibreSSL produces, so this works whichever openssl is first
# on PATH.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:micduck \
  -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES

# -T /usr/bin/codesign lets codesign use the key without a prompt on every build.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P micduck -T /usr/bin/codesign -A

echo "created identity '$ID_NAME'"
echo "now run ./install.sh --launchagent and grant Accessibility one final time"
