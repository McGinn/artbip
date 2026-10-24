#!/bin/bash
# Build an ad-hoc-signed menu-bar app bundle for local testing.
#
#   bash scripts/make_app.sh                          # direct build -> dist/artbip.app
#   ARTBIP_CHANNEL=appstore bash scripts/make_app.sh  # -> dist/appstore/artbip.app
#   ARTBIP_RELEASE=1 ...                              # also require the private editorial checks
#
# Direct build: the CLI binary rides along at Contents/MacOS/artbip (symlink
# it onto PATH if you want `artbip rotate …` in the terminal).
# App Store build: sandboxed, no CLI, no update check, no sponsor link. The
# ad-hoc signature here is for local runs only; submission needs an Apple
# Distribution signature applied by the release process, not this script.
#
# Notes: data/education/starter.json (built by scripts/build_notes.py) is
# bundled as Resources/notes.json. The full editorial source never ships.
set -euo pipefail
cd "$(dirname "$0")/.."
CHANNEL=${ARTBIP_CHANNEL:-direct}
case "$CHANNEL" in direct|appstore) ;; *) echo "ARTBIP_CHANNEL must be direct or appstore" >&2; exit 2;; esac
export ARTBIP_CHANNEL=$CHANNEL
export ARTBIP_SCRATCH_PATH=${ARTBIP_SCRATCH_PATH:-${TMPDIR:-/tmp}/artbip-swift-build-$CHANNEL}

# Version comes from the nearest v* tag (v0.1.0 -> 0.1.0); untagged commits
# get the describe suffix (e.g. 0.1.0-3-gabc1234), non-checkouts 0.0.0-dev.
VERSION=$(git describe --tags --match 'v*' 2>/dev/null | sed 's/^v//' || true)
VERSION=${VERSION:-0.0.0-dev}
# The public history starts from a fresh root commit (2026-10-24), which reset
# the commit count. Builds from the earlier history reached 99, so new builds
# start at 100 and CFBundleVersion never goes backwards.
BUILD=$(( $(git rev-list --count HEAD 2>/dev/null || echo 1) + 99 ))

# The editorial checks read the private content checkout (scripts/content_paths.py).
# Without it, a clone builds from the committed notes file;
# a release build must have it.
if [ -f "${ARTBIP_CONTENT_DIR:-../marketing/content}/info.json" ]; then
  python3 scripts/check_tags.py
  python3 scripts/check_metadata.py
  python3 scripts/audit_visual_claims.py --check
  python3 scripts/check_shared_text.py
  python3 scripts/build_notes.py --check
elif [ -n "${ARTBIP_RELEASE:-}" ]; then
  echo "release build: private editorial source not found (see scripts/content_paths.py)" >&2
  exit 1
else
  echo "note: private editorial source not found; skipping editorial checks"
fi

bash scripts/swift_build.sh -c release
BIN_DIR=$(bash scripts/swift_build.sh -c release --show-bin-path)

if [ "$CHANNEL" = appstore ]; then APP=dist/appstore/artbip.app; else APP=dist/artbip.app; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/ArtbipApp" "$APP/Contents/MacOS/ArtbipApp"
if [ "$CHANNEL" = direct ]; then cp "$BIN_DIR/artbip" "$APP/Contents/MacOS/artbip"; fi
cp data/manifest.json "$APP/Contents/Resources/manifest.json"
cp data/education/starter.json "$APP/Contents/Resources/notes.json"
cp assets/artbip.icns "$APP/Contents/Resources/artbip.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>ArtbipApp</string>
	<key>CFBundleIconFile</key>
	<string>artbip</string>
	<key>CFBundleIdentifier</key>
	<string>com.mcginn.artbip</string>
	<key>CFBundleName</key>
	<string>artbip</string>
	<key>CFBundleDisplayName</key>
	<string>artbip</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Artworks are public domain / CC0; see each work's source link. Code and notes: see the licence notes in the app.</string>
</dict>
</plist>
PLIST

# OneDrive can attach Finder metadata to source resources. It must not enter
# the signed bundle; normalize only this generated artifact, not source files.
xattr -cr "$APP"
python3 scripts/check_bundle_leaks.py "$APP" --channel "$CHANNEL" ${ARTBIP_RELEASE:+--release}
if [ "$CHANNEL" = appstore ]; then
    codesign --force -s - --entitlements packaging/appstore.entitlements "$APP"
else
    codesign --force -s - "$APP/Contents/MacOS/artbip"
    codesign --force -s - "$APP"
fi

echo "built $APP ($CHANNEL)"
echo "test without touching your installed app: ARTBIP_RUNTIME_DIR=\$(mktemp -d) $APP/Contents/MacOS/ArtbipApp"
