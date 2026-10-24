#!/bin/bash
# Generate the private key and CSR for a Developer ID Application certificate.
#
# Normally Keychain Access does this ("Request a Certificate From a Certificate
# Authority"), but it buries the key somewhere you cannot easily back up. Doing
# it with openssl keeps the key as a file you can copy to another Mac.
#
# The key never leaves this machine — only the .csr gets uploaded to Apple.
#
# usage: scripts/make_signing_request.sh "Your Name" you@example.com
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 \"Your Name\" you@example.com" >&2
  exit 2
fi
NAME="$1"
EMAIL="$2"
DIR="$HOME/.artbip-signing"

mkdir -p "$DIR"
chmod 700 "$DIR"

# Refuse to clobber: overwriting the key orphans any certificate already issued
# against it, and the only fix is revoking that certificate at Apple.
if [[ -f "$DIR/developerID.key" ]]; then
  echo "error: $DIR/developerID.key already exists — not overwriting." >&2
  echo "       Move it aside deliberately if you really want a new key." >&2
  exit 1
fi

openssl genrsa -out "$DIR/developerID.key" 2048
chmod 600 "$DIR/developerID.key"
openssl req -new -key "$DIR/developerID.key" -out "$DIR/developerID.csr" \
  -subj "/emailAddress=${EMAIL}/CN=${NAME}/C=US"

cat <<EOF

wrote $DIR/developerID.csr

Next:
  1. https://developer.apple.com/account/resources/certificates/add
  2. Choose "Developer ID Application" (only the Account Holder can; limit 5).
  3. Upload $DIR/developerID.csr
  4. Download the .cer, then run:
       scripts/install_signing_cert.sh ~/Downloads/developerID.cer
EOF
