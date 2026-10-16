#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --configuration release --build-system native --disable-sandbox
BIN_DIR="$(swift build --configuration release --build-system native --disable-sandbox --show-bin-path)"
APP="$PWD/dist/Luma.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Luma" "$APP/Contents/MacOS/Luma"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
