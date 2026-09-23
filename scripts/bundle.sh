#!/usr/bin/env bash
# Builds DSH.app from the Swift package (release, arm64 + x86_64 when available).
# Usage: scripts/bundle.sh [--install]
#   --install  replaces /Applications/DSH.app with the new build (never leaves two copies)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=dist
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
APP="$OUT/DSH.app"

swift build -c release --product DSH --arch arm64 --arch x86_64 2>/dev/null \
  || swift build -c release --product DSH
BIN="$(swift build -c release --product DSH --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null || swift build -c release --product DSH --show-bin-path)/DSH"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
touch "$OUT/.metadata_never_index"   # keep build copies out of Spotlight/Launchpad
cp "$BIN" "$APP/Contents/MacOS/DSH"

# Icon: the harness's own logo, read from the local dsh install at build time (never committed);
# without dsh installed, the neutral icon in Resources/ is used.
LOGO=""
if DSH_BIN="$(command -v dsh 2>/dev/null)"; then
  ROOT="$(cd "$(dirname "$(realpath "$DSH_BIN")")/../../.." && pwd)"
  LOGO="$(find "$ROOT" -maxdepth 4 -path '*dsh-web-frontend/dist/favicon.svg' 2>/dev/null | head -1)"
fi
if [ -n "$LOGO" ]; then
  swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns" "$LOGO" >/dev/null
elif [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DSH</string>
  <key>CFBundleDisplayName</key><string>DSH</string>
  <key>CFBundleIdentifier</key><string>io.github.harness-mac</string>
  <key>CFBundleExecutable</key><string>DSH</string>
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

if [ "${1:-}" = "--install" ]; then
  # Earlier builds were named Harness.app; keep exactly one app installed.
  for old in /Applications/Harness.app /Applications/DSH.app; do
    [ -d "$old" ] && mv "$old" "$HOME/.Trash/$(basename "$old" .app)-$(date +%s).app"
  done
  ditto "$APP" /Applications/DSH.app
  rm -rf "$APP"
  echo /Applications/DSH.app
else
  echo "$APP"
fi
