#!/bin/bash
# Builds NetMeter.app into ./build (universal: Apple Silicon + Intel).
#   VERSION=1.2.0 ./build.sh   sets the app version (default: latest git tag, else 0.0.0)
#   BUILD_NUMBER=42 ./build.sh sets CFBundleVersion (default: git commit count)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

if swift build -c release --arch arm64 --arch x86_64; then
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/NetMeter"
else
    echo "warning: universal build failed; building for this Mac's architecture only" >&2
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/NetMeter"
fi

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
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP (version $VERSION, build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/NetMeter"))"
