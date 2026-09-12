#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
PROJECT_DIR="$PWD"
BUILD_CACHE="$PROJECT_DIR/.build"
APP_DIR="$PROJECT_DIR/dist/听见.app"
mkdir -p "$BUILD_CACHE/module-cache" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -parse-as-library -g -Onone \
  -target arm64-apple-macos26.4 -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_CACHE/module-cache" \
  Sources/*.swift -o "$APP_DIR/Contents/MacOS/Tingjian"
cp Assets/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --identifier local.tingjian.meeting "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
"$APP_DIR/Contents/MacOS/Tingjian" --self-test
printf 'Built: %s\n' "$APP_DIR"
