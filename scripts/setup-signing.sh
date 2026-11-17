#!/bin/bash
# One-time setup: makes a free code-signing certificate on this Mac, so every Launchpad build is signed the
# same way. macOS then recognises updates as the same app: no more Keychain password prompts after each
# update, and Accessibility / Screen Recording stay granted.
# Usage: ~/launchpad/scripts/setup-signing.sh   (asks for your Mac password once, to trust the certificate)
set -euo pipefail
NAME="Launchpad Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Already set up: \"$NAME\" is in your keychain."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

# macOS's own openssl (LibreSSL) writes a .p12 the Keychain can import.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.conf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 12)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$PASS"

# Import the certificate and key; let codesign use the key without asking each build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
# Trust it for code signing (macOS asks for your password here).
echo "macOS will ask for your password to trust the new certificate for signing apps."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Done. Builds are now signed as \"$NAME\"."
  echo "Next: ~/launchpad/scripts/update.sh  (allow the Keychain prompt one last time with \"Always Allow\")."
else
  echo "The certificate was added but isn't usable for signing yet. Open Keychain Access, find \"$NAME\","
  echo "open Trust and set Code Signing to Always Trust, then run this again."
  exit 1
fi
