#!/bin/bash
# Generate the private key and CSR for a signing certificate.
#
# ARTBIP_CERT picks which one (each gets its own key):
#   developerID         Developer ID Application (direct download, default)
#   appleDistribution   Apple Distribution (signs the Mac App Store app)
#   macInstaller        Mac Installer Distribution (signs the App Store .pkg)
#
# Normally Keychain Access does this ("Request a Certificate From a Certificate
# Authority"), but it buries the key somewhere you cannot easily back up. Doing
# it with openssl keeps the key as a file you can copy to another Mac.
#
# The key never leaves this machine — only the .csr gets uploaded to Apple.
#
# usage: scripts/make_signing_request.sh "Your Name" you@example.com
#        ARTBIP_CERT=appleDistribution scripts/make_signing_request.sh …
set -euo pipefail

CERT=${ARTBIP_CERT:-developerID}
case "$CERT" in
  developerID)       KIND="Developer ID Application (only the Account Holder can; limit 5)";;
  appleDistribution) KIND="Apple Distribution";;
  macInstaller)      KIND="Mac Installer Distribution";;
  *) echo "ARTBIP_CERT must be developerID, appleDistribution or macInstaller" >&2; exit 2;;
esac

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
if [[ -f "$DIR/$CERT.key" ]]; then
  echo "error: $DIR/$CERT.key already exists — not overwriting." >&2
  echo "       Move it aside deliberately if you really want a new key." >&2
  exit 1
fi

openssl genrsa -out "$DIR/$CERT.key" 2048
chmod 600 "$DIR/$CERT.key"
openssl req -new -key "$DIR/$CERT.key" -out "$DIR/$CERT.csr" \
  -subj "/emailAddress=${EMAIL}/CN=${NAME}/C=US"

cat <<EOF

wrote $DIR/$CERT.csr

Next:
  1. https://developer.apple.com/account/resources/certificates/add
  2. Choose "$KIND".
  3. Upload $DIR/$CERT.csr
  4. Download the .cer, then run:
       ARTBIP_CERT=$CERT scripts/install_signing_cert.sh ~/Downloads/<downloaded>.cer
EOF
