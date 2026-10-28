#!/bin/bash
# Build the Mac App Store package: dist/appstore/artbip-<version>-<build>.pkg,
# ready to upload with `xcrun altool` (needs Xcode selected) or Transporter.
#
# make_app.sh builds the sandboxed appstore channel with an ad-hoc signature.
# This script re-signs it with the Apple Distribution certificate, embeds the
# provisioning profile, and wraps it in an installer package signed with the
# 3rd Party Mac Developer Installer certificate. Nothing is notarized: the App
# Store does its own review and signing.
#
# One-time setup (see marketing/docs/launch-checklist.md, B4):
#   1. "Apple Distribution" and "3rd Party Mac Developer Installer" identities in
#      the login keychain (ARTBIP_CERT=appleDistribution / macInstaller with
#      scripts/make_signing_request.sh and scripts/install_signing_cert.sh).
#   2. The Mac App Store provisioning profile for com.mcginn.artbip at
#      ~/.artbip-signing/artbip_Mac_App_Store.provisionprofile
#      (override with ARTBIP_PROFILE).
#
# Version: the nearest v* tag without the describe suffix, so a build a few
# commits past v0.1.0 is 0.1.0 with a higher build number. The App Store only
# needs each upload's CFBundleVersion to be new.
#
# usage: scripts/make_appstore.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${ARTBIP_PROFILE:-$HOME/.artbip-signing/artbip_Mac_App_Store.provisionprofile}
BUNDLE_ID=com.mcginn.artbip

# --- preflight ---------------------------------------------------------------
identity() {   # identity <policy> <name prefix>
  security find-identity -v -p "$1" 2>/dev/null \
    | grep "\"$2" | head -1 | sed -E 's/.*"(.*)"/\1/' || true
}
APP_ID=$(identity codesigning "Apple Distribution")
PKG_ID=$(identity basic "3rd Party Mac Developer Installer")
[[ -n "$APP_ID" ]] || { echo "error: no \"Apple Distribution\" identity in the keychain" >&2; exit 1; }
[[ -n "$PKG_ID" ]] || { echo "error: no \"3rd Party Mac Developer Installer\" identity in the keychain" >&2; exit 1; }
[[ -f "$PROFILE" ]] || { echo "error: provisioning profile not found: $PROFILE" >&2; exit 1; }
echo "app signing:       $APP_ID"
echo "installer signing: $PKG_ID"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
security cms -D -i "$PROFILE" > "$WORK/profile.plist"
pval() { /usr/libexec/PlistBuddy -c "Print :$1" "$WORK/profile.plist"; }
TEAM=$(pval 'TeamIdentifier:0')
PROFILE_APP_ID=$(pval 'Entitlements:com.apple.application-identifier')
if [[ "$PROFILE_APP_ID" != "$TEAM.$BUNDLE_ID" ]]; then
  echo "error: profile is for $PROFILE_APP_ID, not $TEAM.$BUNDLE_ID" >&2
  exit 1
fi
EXPIRES=$(pval ExpirationDate)
echo "profile:           $(pval Name) (team $TEAM, expires $EXPIRES)"

TAG=$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)
VERSION=${TAG#v}
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "error: no v* tag to take the version from (found \"$TAG\")" >&2
  exit 1
fi

# --- build -------------------------------------------------------------------
python3 scripts/check_repo_leaks.py
ARTBIP_CHANNEL=appstore ARTBIP_RELEASE=1 ARTBIP_VERSION="$VERSION" scripts/make_app.sh >/dev/null
APP=dist/appstore/artbip.app
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
echo "built $APP ($VERSION, build $BUILD)"

# --- sign --------------------------------------------------------------------
# Xcode would add the application and team identifiers to the entitlements
# from the profile; without Xcode they are added here. The App Store rejects a
# sandboxed app whose signature lacks them or whose profile is missing.
cp packaging/appstore.entitlements "$WORK/entitlements.plist"
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" \
  -c "Add :com.apple.developer.team-identifier string $TEAM" \
  "$WORK/entitlements.plist"
# The downloaded profile carries com.apple.quarantine, which the App Store
# rejects anywhere in the app (ITMS-91109): copy without extended attributes
# and clear the rest before signing.
cp -X "$PROFILE" "$APP/Contents/embedded.provisionprofile"
xattr -cr "$APP"
codesign --force --sign "$APP_ID" --entitlements "$WORK/entitlements.plist" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$WORK/signed.plist"
for KEY in com.apple.security.app-sandbox com.apple.application-identifier; do
  /usr/libexec/PlistBuddy -c "Print :$KEY" "$WORK/signed.plist" >/dev/null \
    || { echo "error: signed app lacks entitlement $KEY" >&2; exit 1; }
done
echo "signature verified (sandboxed, $TEAM.$BUNDLE_ID)"

# --- package -----------------------------------------------------------------
PKG="dist/appstore/artbip-${VERSION}-${BUILD}.pkg"
rm -f "$PKG"
# productbuild prints "write: Permission denied" a few times here; harmless.
# The payload's ._ entries carry extended attributes. com.apple.provenance
# can't be removed from files written here and is accepted; quarantine is not.
productbuild --component "$APP" /Applications --sign "$PKG_ID" "$PKG" >/dev/null 2>&1
# The installer makes root the owner, so anything not world-readable can't
# be read by the app at all, and the App Store rejects it (ITMS-90255).
pkgutil --expand "$PKG" "$WORK/expanded"
BAD=$(lsbom -p fM "$WORK"/expanded/*.pkg/Bom | awk '$1 != "." && $2 !~ /^[-dl]r..r..r/')
[[ -z "$BAD" ]] || { echo "error: package has files other users can't read:" >&2; echo "$BAD" >&2; exit 1; }
mkdir "$WORK/payload"
(cd "$WORK/payload" && gunzip -dc ../expanded/*.pkg/Payload | cpio -i --quiet)
QUAR=$(xattr -r "$WORK/payload" | grep com.apple.quarantine || true)
[[ -z "$QUAR" ]] || { echo "error: package has quarantined files (ITMS-91109):" >&2; echo "$QUAR" >&2; exit 1; }
pkgutil --check-signature "$PKG" | sed -n '1,2p'
echo
echo "ready: $PKG"
echo "validate: xcrun altool --validate-app -f $PKG -t macos -u <apple id> -p @keychain:ALTOOL"
echo "upload:   xcrun altool --upload-app   -f $PKG -t macos -u <apple id> -p @keychain:ALTOOL"
