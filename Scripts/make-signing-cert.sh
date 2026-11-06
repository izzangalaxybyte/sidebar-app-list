#!/bin/bash
# Creates a self-signed code-signing certificate in your login keychain so
# every rebuild is signed by the same identity and the Accessibility grant
# survives rebuilds. Run once. macOS will ask for your login password when the
# certificate is marked trusted, and once more in the terminal to let codesign
# use the key without prompting on every build.
#
# Usage: Scripts/make-signing-cert.sh ["Identity Name"]
#
# Uses the system /usr/bin/openssl on purpose: Homebrew's OpenSSL 3 writes
# PKCS12 files the macOS keychain importer rejects ("MAC verification failed").
set -euo pipefail

NAME="${1:-SidebarAppList Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CONF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/openssl.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:temp -name "$NAME"

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P temp \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Trust it for code signing in your user trust domain (password prompt).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
# Let Apple's signing tools use the private key without a per-build keychain
# prompt. Asks for your login password once in the terminal.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$NAME" "$KEYCHAIN" >/dev/null

echo "Identity \"$NAME\" is ready. Scripts/bundle.sh picks it up automatically;"
echo "or set CODESIGN_IDENTITY=\"$NAME\" explicitly."
