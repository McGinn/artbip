#!/bin/bash
# Build dist/artbip.app — a plain, ad-hoc-signed menu-bar app bundle.
# The CLI binary rides along at Contents/MacOS/artbip (symlink it onto PATH
# if you want `artbip rotate …` in the terminal).
set -euo pipefail
cd "$(dirname "$0")/.."

# Version comes from the nearest v* tag (v0.1.0 -> 0.1.0); untagged commits
# get the describe suffix (e.g. 0.1.0-3-gabc1234), non-checkouts 0.0.0-dev.
VERSION=$(git describe --tags --match 'v*' 2>/dev/null | sed 's/^v//')
VERSION=${VERSION:-0.0.0-dev}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c release

APP=dist/artbip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/ArtbipApp "$APP/Contents/MacOS/ArtbipApp"
cp .build/release/artbip "$APP/Contents/MacOS/artbip"
cp data/manifest.json "$APP/Contents/Resources/manifest.json"
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
	<string>Code MIT-licensed. Artworks are public domain / CC0; see each work's source link.</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP/Contents/MacOS/artbip"
codesign --force -s - "$APP"

echo "built $APP"
echo "install: cp -R $APP /Applications/"
