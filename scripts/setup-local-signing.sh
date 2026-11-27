#!/usr/bin/env bash
# One-time: creates a self-signed code-signing certificate in your login keychain, used to sign
# Debug builds. macOS keys the Accessibility (and Bluetooth, Microphone) permission to the app's
# designated requirement; with ad-hoc signing that's a hash of the binary, so every rebuild
# loses the grant. Signed with this certificate, the requirement is "this bundle ID, signed by
# this certificate", which survives rebuilds and works from any worktree.
#
# The certificate never leaves this Mac and isn't in the repo. Re-running is a no-op.
set -euo pipefail
# macOS's LibreSSL: Homebrew's OpenSSL 3 writes PKCS#12 files the Keychain can't import.
name="JoyMapper Silicon Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "\"$name\" already exists."
else
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$work/key.pem" -out "$work/cert.pem" -config "$work/cert.cnf" 2>/dev/null
  password=$(uuidgen)
  /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$name" -out "$work/identity.p12" -passout "pass:$password" 2>/dev/null
  # -T: let codesign use the key without asking each time.
  security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
  echo "Created \"$name\"."
  echo "Trusting it for code signing (macOS asks for your password once)…"
  security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"
fi

security find-identity -v -p codesigning | grep "$name" >/dev/null \
  && echo "Ready: Debug builds will sign with \"$name\"." \
  || { echo "The certificate exists but isn't trusted for code signing yet. Re-run this script." >&2; exit 1; }
