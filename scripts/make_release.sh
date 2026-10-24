#!/bin/bash
# Build a signed, notarized, stapled artbip.dmg ready to attach to a release.
#
# make_app.sh produces an ad-hoc-signed bundle, which is fine for local use but
# hits Gatekeeper on anyone else's Mac. Since artbip requires macOS 15, and
# Sequoia removed the Control-click -> Open bypass for unsigned apps, an
# unsigned download sends every user into System Settings -> Privacy & Security
# to click "Open Anyway". This script is what avoids that.
#
# One-time setup:
#   1. Developer ID Application certificate installed in the login keychain
#      (security find-identity -v -p codesigning  should list it).
#   2. Notary credentials stored once, so nothing secret lives in this repo:
#        xcrun notarytool store-credentials artbip-notary \
#          --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
#      The app-specific password comes from appleid.apple.com, not your Apple
#      ID password.
#
# usage: scripts/make_release.sh [--skip-notarize]
set -euo pipefail
cd "$(dirname "$0")/.."

KEYCHAIN_PROFILE="${ARTBIP_NOTARY_PROFILE:-artbip-notary}"
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

# --- preflight: fail loudly and early, not halfway through a notary upload ---
# `|| true` matters: under `set -e` + pipefail, grep finding nothing would kill
# the script here, swallowing the explanation below.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
if [[ -z "$IDENTITY" ]]; then
  cat >&2 <<'EOF'
error: no "Developer ID Application" certificate in the keychain.

  security find-identity -v -p codesigning

should list one. If it does not, create it at
https://developer.apple.com/account/resources/certificates/add
(type: Developer ID Application) using ~/.artbip-signing/developerID.csr,
then import the downloaded .cer with scripts/install_signing_cert.sh.
EOF
  exit 1
fi
echo "signing identity: $IDENTITY"

if [[ $SKIP_NOTARIZE -eq 0 ]] && ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  echo "error: notary profile '$KEYCHAIN_PROFILE' not found or invalid." >&2
  echo "       run xcrun notarytool store-credentials (see the header of this script)." >&2
  exit 1
fi

VERSION=$(git describe --tags --match 'v*' 2>/dev/null | sed 's/^v//' || true)
VERSION=${VERSION:-0.0.0-dev}

# Refuse to notarize anything but a tagged commit. `git describe` on an untagged
# commit yields "0.1.16-6-g34ab350", which is not a valid
# CFBundleShortVersionString (Apple wants up to three period-separated integers)
# and produces a DMG named after a git hash. Notarizing that spends an Apple
# submission on an artifact nobody should download. --skip-notarize still works
# for testing the signing chain.
if [[ $SKIP_NOTARIZE -eq 0 && ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "error: HEAD is not on a v* tag — version reads \"$VERSION\"." >&2
  echo "       Tag the release first:  git tag v0.1.0 && scripts/make_release.sh" >&2
  echo "       Or pass --skip-notarize to test signing only." >&2
  exit 1
fi

APP=dist/artbip.app
DMG="dist/artbip-${VERSION}.dmg"

# ARTBIP_RELEASE turns on the release-only gates: the private editorial checks
# must run, and the bundle may not carry sandbox service config or keys.
python3 scripts/check_repo_leaks.py
ARTBIP_RELEASE=1 scripts/make_app.sh >/dev/null
echo "built $APP ($VERSION)"

# --- sign, inside out ------------------------------------------------------
# Nested code must be signed before the thing that contains it, or the outer
# signature seals a binary that then changes. The CLI at Contents/MacOS/artbip
# is a second executable, not a resource, so it needs its own signature.
#
# --options runtime enables the hardened runtime, which notarization requires.
# --timestamp gets a trusted timestamp so signatures stay valid after the
# certificate expires.
for BIN in "$APP/Contents/MacOS/artbip" "$APP/Contents/MacOS/ArtbipApp"; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$BIN"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "signature verified"

# Built after the app is stapled, so the copy inside carries its own ticket.
build_dmg() {
  rm -f "$DMG"
  local stage
  stage=$(mktemp -d)
  cp -R "$APP" "$stage/"
  ln -s /Applications "$stage/Applications"   # drag-to-install target
  hdiutil create -volname "artbip" -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$stage"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  echo "built $DMG"
}

if [[ $SKIP_NOTARIZE -eq 1 ]]; then
  build_dmg
  echo "skipping notarization (--skip-notarize); this DMG will trip Gatekeeper"
  exit 0
fi

# --- notarize, in two stages ------------------------------------------------
# The app is notarized and stapled *before* the DMG is built, then the DMG is
# notarized and stapled in turn. Both artifacts end up carrying their own
# ticket.
#
# Stapling only the DMG is not enough. A ticket is attached to a specific file,
# so it travels with the disk image and not with what comes out of it: the
# moment a user drags artbip.app to /Applications and ejects, the app has no
# ticket and first launch depends on Gatekeeper reaching Apple. That works
# online and fails on a machine that happens to be offline — exactly the case
# stapling exists to cover. The extra submission costs a few minutes.
#
# The app is submitted inside a zip because notarytool only accepts zip, dmg,
# and pkg. `ditto -c -k --keepParent` is the required form; `zip` mangles the
# symlinks and extended attributes in a bundle. The ticket is stapled to the
# .app itself, never to the zip, which is then thrown away.
notarize() {   # notarize <file-to-submit> <thing-to-staple>
  echo "submitting $(basename "$1") to Apple…"
  if ! xcrun notarytool submit "$1" --keychain-profile "$KEYCHAIN_PROFILE" --wait; then
    echo >&2
    echo "notarization failed. For the reason:" >&2
    echo "  xcrun notarytool log <submission-id> --keychain-profile $KEYCHAIN_PROFILE" >&2
    exit 1
  fi
  xcrun stapler staple "$2"
  xcrun stapler validate "$2"
}

ZIP="dist/artbip-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP" "$APP"
rm -f "$ZIP"

build_dmg
notarize "$DMG" "$DMG"

# The definitive check: what Gatekeeper itself will say on someone else's Mac.
echo
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | sed 's/^/  /'
echo
echo "ready: $DMG"
echo "attach with: gh release upload v${VERSION} $DMG"
