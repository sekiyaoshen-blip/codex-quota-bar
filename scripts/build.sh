#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="codex-quota-bar.app"
APP_DIR="$DIST_DIR/$APP_NAME"
TARGET_TRIPLE="arm64-apple-macosx13.0"

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc \
  -target "$TARGET_TRIPLE" \
  -O \
  -framework AppKit \
  -o "$BUILD_DIR/CodexQuotaBar" \
  "$ROOT_DIR/Sources/main.swift"

BUILT_ARCHS="$(/usr/bin/lipo -archs "$BUILD_DIR/CodexQuotaBar")"
if [[ "$BUILT_ARCHS" != "arm64" ]]; then
  echo "构建产物架构错误：期望 arm64，实际为 $BUILT_ARCHS" >&2
  exit 1
fi

cp "$BUILD_DIR/CodexQuotaBar" "$APP_DIR/Contents/MacOS/CodexQuotaBar"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/bin/install -m 0755 "$ROOT_DIR/scripts/follow.sh" "$APP_DIR/Contents/Resources/codex-quota-bar"
/usr/bin/install -m 0755 "$ROOT_DIR/scripts/update.sh" "$APP_DIR/Contents/Resources/update.sh"

codesign --force --deep --sign - "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --verify --deep --strict "$APP_DIR"

PACKAGED_ARCHS="$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/CodexQuotaBar")"
if [[ "$PACKAGED_ARCHS" != "arm64" ]]; then
  echo "应用包架构错误：期望 arm64，实际为 $PACKAGED_ARCHS" >&2
  exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/codex-quota-bar.zip"

echo "Built: $APP_DIR"
echo "Archive: $DIST_DIR/codex-quota-bar.zip"
