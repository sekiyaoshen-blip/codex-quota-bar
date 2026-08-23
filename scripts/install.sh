#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_NAME="codex-quota-bar.app"
BUILD_APP="$ROOT_DIR/dist/$APP_NAME"
DEFAULT_INSTALL_DIR="$HOME/Library/Application Support/codex-quota-bar"
INSTALL_APP="${1:-$DEFAULT_INSTALL_DIR/$APP_NAME}"
INSTALL_DIR="$(dirname "$INSTALL_APP")"
TEMP_APP="$INSTALL_DIR/.$APP_NAME.installing.$$"
LEGACY_APP="/Applications/Codex 额度栏.app"
LEGACY_APP_SHORT="/Applications/codex-quota-bar.app"

if [[ "$INSTALL_APP" != /* ]]; then
  echo "安装路径必须是绝对路径：$INSTALL_APP" >&2
  exit 2
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
  /bin/mkdir -p "$INSTALL_DIR"
fi
if [[ ! -w "$INSTALL_DIR" ]]; then
  echo "安装目录不存在或不可写：$INSTALL_DIR" >&2
  exit 1
fi

cleanup() {
  /bin/rm -rf "$TEMP_APP"
}
trap cleanup EXIT

"$ROOT_DIR/scripts/build.sh"

/usr/bin/pkill -x CodexQuotaBar >/dev/null 2>&1 || true
for _ in {1..50}; do
  /usr/bin/pgrep -x CodexQuotaBar >/dev/null 2>&1 || break
  /bin/sleep 0.1
done
if /usr/bin/pgrep -x CodexQuotaBar >/dev/null 2>&1; then
  echo "旧版本未能退出，请手动退出后重试。" >&2
  exit 1
fi

/usr/bin/ditto "$BUILD_APP" "$TEMP_APP"
/bin/rm -rf "$INSTALL_APP"
/bin/mv "$TEMP_APP" "$INSTALL_APP"
for legacy_app in "$LEGACY_APP" "$LEGACY_APP_SHORT"; do
  if [[ "$legacy_app" != "$INSTALL_APP" ]]; then
    /bin/rm -rf "$legacy_app"
  fi
done

"$ROOT_DIR/scripts/autostart-on.sh" "$INSTALL_APP"
/usr/bin/open -gj "$INSTALL_APP"

for _ in {1..50}; do
  if /usr/bin/pgrep -x CodexQuotaBar >/dev/null 2>&1; then
    /bin/rm -rf "$ROOT_DIR/.build" "$ROOT_DIR/dist"
    echo "安装完成并已启动：$INSTALL_APP"
    exit 0
  fi
  /bin/sleep 0.1
done

echo "安装已完成，但应用未能启动：$INSTALL_APP" >&2
exit 1
