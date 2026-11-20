#!/bin/bash
# Build Porthole.app: the menu bar app plus the `porthole` CLI/MCP server, ad-hoc signed.
#   scripts/build-app.sh [output-dir]     (default: .build/Porthole.app)
# Set PORTHOLE_UNIVERSAL=1 for an arm64 + x86_64 build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.build}"
APP="$OUT/Porthole.app"
cd "$ROOT"

VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/PortholeCore/Version.swift)"
if [ "${PORTHOLE_UNIVERSAL:-0}" = 1 ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN="$ROOT/.build/apple/Products/Release"
else
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/PortholeApp" "$APP/Contents/MacOS/Porthole"
# The CLI lives in Helpers: MacOS/porthole would collide with MacOS/Porthole on a case-insensitive disk.
cp "$BIN/porthole" "$APP/Contents/Helpers/porthole"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp assets/porthole-icon.png "$APP/Contents/Resources/porthole-icon.png"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to run on this Mac. Sign the CLI first, then the app around it.
codesign --force --sign - --identifier io.github.gregglickert.porthole.cli "$APP/Contents/Helpers/porthole" 2>/dev/null
codesign --force --sign - "$APP" 2>/dev/null
echo "$APP"
