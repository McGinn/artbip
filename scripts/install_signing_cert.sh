#!/bin/bash
# Install a Developer ID Application certificate so codesign can use it.
#
# Apple's portal hands back only the public certificate. On its own that is
# useless for signing — codesign needs the certificate and the matching private
# key sitting together in one keychain. The key was generated locally by
# scripts/make_signing_request.sh and has never left this machine.
#
# The key and certificate are imported directly rather than bundled into a .p12
# first. Exporting a .p12 means choosing an export password, and openssl can
# only ask for one from a terminal — which fails outright in any non-interactive
# shell. Two passwordless imports do the same job. The .p12 is still worth
# having as an off-machine backup, so `--backup` writes one on request.
#
# usage: scripts/install_signing_cert.sh ~/Downloads/developerID_application.cer
#        scripts/install_signing_cert.sh <cer> --backup   # also write a .p12
#          (reads the export password from $ARTBIP_P12_PASSWORD, else prompts)
set -euo pipefail

CER="${1:-$HOME/Downloads/developerID_application.cer}"
BACKUP=0
[[ "${2:-}" == "--backup" ]] && BACKUP=1
DIR="$HOME/.artbip-signing"
KEY="$DIR/developerID.key"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

[[ -f "$CER" ]] || { echo "error: no certificate at $CER" >&2; exit 1; }
[[ -f "$KEY" ]] || {
  echo "error: no private key at $KEY" >&2
  echo "       Without it this certificate cannot sign anything. If the key is" >&2
  echo "       truly gone, revoke the certificate at developer.apple.com and" >&2
  echo "       start over with scripts/make_signing_request.sh." >&2
  exit 1
}

# Refuse a certificate that does not belong to our key: importing a mismatched
# pair produces a certificate the keychain lists but codesign cannot use, and
# the resulting error ("no identity found") says nothing about why.
cert_mod=$(openssl x509 -inform der -in "$CER" -noout -modulus | openssl md5)
key_mod=$(openssl rsa -in "$KEY" -noout -modulus 2>/dev/null | openssl md5)
if [[ "$cert_mod" != "$key_mod" ]]; then
  echo "error: $CER was not issued for $KEY (public keys differ)." >&2
  echo "       Re-download the certificate created from developerID.csr." >&2
  exit 1
fi

# -T /usr/bin/codesign lets codesign use the key without a confirmation dialog
# every single time. Without it, an unattended release build stalls on a prompt.
echo "importing private key…"
security import "$KEY" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/productsign 2>&1 \
  | grep -v "already exists" || true
echo "importing certificate…"
security import "$CER" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/productsign 2>&1 \
  | grep -v "already exists" || true

# Apple's intermediate must be present or the chain will not validate and the
# identity shows as "CSSMERR_TP_NOT_TRUSTED" instead of valid. Xcode installs
# it; a Command Line Tools-only machine may not have it.
if ! security find-certificate -c "Developer ID Certification Authority" >/dev/null 2>&1; then
  echo "fetching Apple's Developer ID intermediate certificate…"
  curl -fsSL -o "$DIR/DeveloperIDG2CA.cer" \
    https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
  security import "$DIR/DeveloperIDG2CA.cer" -k "$KEYCHAIN" || true
fi

if [[ $BACKUP -eq 1 ]]; then
  openssl x509 -inform der -in "$CER" -out "$DIR/developerID.pem"
  P12="$DIR/developerID.p12"
  if [[ -n "${ARTBIP_P12_PASSWORD:-}" ]]; then
    openssl pkcs12 -export -legacy -inkey "$KEY" -in "$DIR/developerID.pem" \
      -name "artbip Developer ID" -out "$P12" -passout env:ARTBIP_P12_PASSWORD
  else
    openssl pkcs12 -export -legacy -inkey "$KEY" -in "$DIR/developerID.pem" \
      -name "artbip Developer ID" -out "$P12"
  fi
  chmod 600 "$P12"
  echo "backup written: $P12 — keep a copy off this machine"
fi

echo
echo "identities now available:"
security find-identity -v -p codesigning

cat <<EOF

If codesign prompts for keychain access on every build, authorise it once:
  security set-key-partition-list -S apple-tool:,apple:,codesign: \\
    -s -k <your-login-password> "$KEYCHAIN"

Back up the key and certificate off this machine:
  scripts/install_signing_cert.sh "$CER" --backup
EOF
