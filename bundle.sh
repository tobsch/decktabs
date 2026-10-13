#!/bin/sh
# Builds DeckTabs.app (release) into build/DeckTabs.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/DeckTabs.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DeckTabs "$APP/Contents/MacOS/DeckTabs"
# Icon: icon/icon-1024.png (from icon/make-icon.swift) → AppIcon.icns
[ -f icon/icon-1024.png ] || swift icon/make-icon.swift icon/icon-1024.png
SET=build/AppIcon.iconset; rm -rf "$SET"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon/icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon/icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
  <key>CFBundleName</key><string>DeckTabs</string>
  <key>CFBundleDisplayName</key><string>Agent Deck Tabs</string>
  <key>CFBundleIdentifier</key><string>io.github.tobsch.DeckTabs</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>DeckTabs</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Localizations: English is the development language, German translations in Resources/de.lproj
cp -R Resources/en.lproj Resources/de.lproj "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "$APP"
