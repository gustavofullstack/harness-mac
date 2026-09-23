#!/usr/bin/env bash
# Builds Harness.app from the Swift package (release, arm64 + x86_64 when available).
# Usage: scripts/bundle.sh [output-dir]   (default: ./dist)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist}"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
APP="$OUT/Harness.app"

swift build -c release --product Harness --arch arm64 --arch x86_64 2>/dev/null \
  || swift build -c release --product Harness
BIN="$(swift build -c release --product Harness --show-bin-path)/Harness"
[ -x "$BIN" ] || BIN="$(ls -d .build/apple/Products/Release/Harness 2>/dev/null)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Harness"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Harness</string>
  <key>CFBundleDisplayName</key><string>Harness</string>
  <key>CFBundleIdentifier</key><string>io.github.harness-mac</string>
  <key>CFBundleExecutable</key><string>Harness</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "$APP"
