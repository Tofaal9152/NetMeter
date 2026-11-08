#!/bin/bash
# Builds NetMeter.app (via build.sh) and packages it into build/NetMeter-<version>.dmg
# with an Applications shortcut and first-launch instructions.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
APP="build/NetMeter.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/NetMeter-$VERSION.dmg"
STAGE="build/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read Me First.txt" <<'TXT'
NetMeter: internet speed in your menu bar
==========================================

INSTALL
  Drag NetMeter onto the Applications folder.

FIRST LAUNCH (one time only)
  NetMeter isn't signed with an Apple Developer ID, so macOS will say it
  "cannot be opened" or that Apple "could not verify" it. To allow it:

    1. Open NetMeter from Applications. Click "Done" (or "OK") on the warning.
    2. Open System Settings > Privacy & Security.
    3. Scroll down to the message about NetMeter and click "Open Anyway".
    4. Confirm with your password or Touch ID.

  Or, in Terminal:
    xattr -dr com.apple.quarantine /Applications/NetMeter.app

USING IT
  - Speeds appear in the menu bar. Click them for the details panel.
  - The panel has Live (graph + apps using the network), Usage (daily and
    monthly totals) and Settings.
  - NetMeter adds itself to Login Items on first launch. Turn that off in
    Settings > Launch at login.
  - Quit from the panel's Quit button.

Requires macOS 13 or later. Works on Apple Silicon and Intel Macs.
TXT

hdiutil create -volname "NetMeter" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
