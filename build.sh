#!/bin/bash
# Builds NetMeter.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release
BIN="$(swift build -c release --show-bin-path)/NetMeter"
[ -f "$BIN" ] || BIN=".build/apple/Products/Release/NetMeter"

APP="build/NetMeter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NetMeter"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NetMeter</string>
    <key>CFBundleDisplayName</key><string>NetMeter</string>
    <key>CFBundleIdentifier</key><string>com.jamilxt.netmeter</string>
    <key>CFBundleExecutable</key><string>NetMeter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"
echo "Install: cp -R $APP /Applications/ && open /Applications/NetMeter.app"
