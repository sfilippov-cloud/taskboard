#!/bin/bash
# One-time: creates a self-signed code-signing certificate "Taskboard Local" in your login keychain and trusts
# it for code signing. build-app.sh then signs Taskboard.app with it, so the app keeps the same identity across
# rebuilds and macOS stops asking again for Downloads, Desktop, Music, microphone… after every reinstall
# (an ad hoc signature changes with every build, and macOS forgets the permissions that were given to it).
#
# macOS will ask you to authorize the trust change (password / Touch ID): that is the step that lets codesign
# use a self-signed certificate. To undo it later:
#   security delete-identity -c "Taskboard Local" ~/Library/Keychains/login.keychain-db
set -euo pipefail

NAME="${1:-Taskboard Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already a valid code-signing identity — nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
# macOS can't read the modern PKCS#12 algorithms OpenSSL 3 uses by default.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:taskboard \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P taskboard -T /usr/bin/codesign
# Authorization dialog: trust this certificate for code signing (current user only).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
security find-identity -v -p codesigning | grep "\"$NAME\"" && echo "Done. Run ./install.sh — the first launch asks once more, then it sticks."
