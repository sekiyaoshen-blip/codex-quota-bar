#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="codex-quota-bar.app"
APP_DIR="$DIST_DIR/$APP_NAME"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc \
  -O \
  -framework AppKit \
  -o "$BUILD_DIR/CodexQuotaBar" \
  "$ROOT_DIR/Sources/main.swift"

cp "$BUILD_DIR/CodexQuotaBar" "$APP_DIR/Contents/MacOS/CodexQuotaBar"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --deep --sign - "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --verify --deep --strict "$APP_DIR"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/codex-quota-bar.zip"

echo "Built: $APP_DIR"
echo "Archive: $DIST_DIR/codex-quota-bar.zip"
