#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_NAME="Codex 额度栏.app"
BUILD_APP="$ROOT_DIR/dist/$APP_NAME"
INSTALL_APP="${1:-/Applications/$APP_NAME}"
INSTALL_DIR="$(dirname "$INSTALL_APP")"
TEMP_APP="$INSTALL_DIR/.$APP_NAME.installing.$$"

if [[ "$INSTALL_APP" != /* ]]; then
  echo "安装路径必须是绝对路径：$INSTALL_APP" >&2
  exit 2
fi

if [[ ! -d "$INSTALL_DIR" || ! -w "$INSTALL_DIR" ]]; then
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
  echo "旧版 Codex 额度栏未能退出，请手动退出后重试。" >&2
  exit 1
fi

/usr/bin/ditto "$BUILD_APP" "$TEMP_APP"
/bin/rm -rf "$INSTALL_APP"
/bin/mv "$TEMP_APP" "$INSTALL_APP"

"$ROOT_DIR/scripts/install-autostart.sh" "$INSTALL_APP"
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
