#!/bin/bash
# Creates a self-signed code-signing identity in a project-local keychain (.signing/).
# The keychain is not added to the user's search list; codesign gets it via --keychain.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
DIR="$ROOT/.signing"
KEYCHAIN="$DIR/zephyr-dev.keychain-db"
if [ -f "$KEYCHAIN" ]; then echo "exists: $KEYCHAIN"; exit 0; fi
mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"
PASS=$(/usr/bin/openssl rand -hex 16)
P12PASS=$(/usr/bin/openssl rand -hex 16)
umask 077
printf '%s' "$PASS" > keychain-password
cat > cert.conf <<'CONF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Zephyr Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.conf
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 -passout "pass:$P12PASS" -name "Zephyr Local Signing"
security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import identity.p12 -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
rm -f key.pem identity.p12 cert.conf
echo "created: $KEYCHAIN"
