#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
APP_NAME="codex-quota-bar.app"
BUILD_APP="$ROOT_DIR/dist/$APP_NAME"
DEFAULT_INSTALL_DIR="$HOME/Library/Application Support/codex-quota-bar"
INSTALL_APP="${1:-$DEFAULT_INSTALL_DIR/$APP_NAME}"
INSTALL_DIR="$(dirname "$INSTALL_APP")"
TEMP_APP="$INSTALL_DIR/.$APP_NAME.installing.$$"
BACKUP_APP="$INSTALL_DIR/.$APP_NAME.backup.$$"
LEGACY_APP="/Applications/Codex 额度栏.app"
LEGACY_APP_SHORT="/Applications/codex-quota-bar.app"
APP_WAS_RUNNING=0
NEW_APP_INSTALLED=0

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

is_installed_app_running() {
  /bin/ps -axo command= | /usr/bin/grep -F -x -q "$INSTALL_APP/Contents/MacOS/CodexQuotaBar"
}

finish() {
  local status=$?
  trap - EXIT
  set +e

  if [[ "$status" -ne 0 && ( "$NEW_APP_INSTALLED" -eq 1 || -d "$BACKUP_APP" ) ]]; then
    /usr/bin/pkill -x CodexQuotaBar >/dev/null 2>&1 || true
    if [[ "$NEW_APP_INSTALLED" -eq 1 ]]; then
      /bin/rm -rf "$INSTALL_APP"
    fi
    if [[ -d "$BACKUP_APP" ]]; then
      /bin/mv "$BACKUP_APP" "$INSTALL_APP"
      "$ROOT_DIR/scripts/autostart-on.sh" "$INSTALL_APP" >/dev/null 2>&1 || true
      if [[ "$APP_WAS_RUNNING" -eq 1 ]]; then
        /usr/bin/open -gj "$INSTALL_APP" >/dev/null 2>&1 || true
      fi
    else
      for legacy_app in "$LEGACY_APP_SHORT" "$LEGACY_APP"; do
        if [[ -d "$legacy_app" ]]; then
          if [[ "$APP_WAS_RUNNING" -eq 1 ]]; then
            /usr/bin/open -gj "$legacy_app" >/dev/null 2>&1 || true
          fi
          break
        fi
      done
    fi
  fi

  /bin/rm -rf "$TEMP_APP" "$BACKUP_APP"
  exit "$status"
}
trap finish EXIT

"$ROOT_DIR/scripts/build.sh"
/usr/bin/ditto "$BUILD_APP" "$TEMP_APP"

if /usr/bin/pgrep -x CodexQuotaBar >/dev/null 2>&1; then
  APP_WAS_RUNNING=1
  /usr/bin/pkill -x CodexQuotaBar >/dev/null 2>&1 || true
fi
for _ in {1..50}; do
  /usr/bin/pgrep -x CodexQuotaBar >/dev/null 2>&1 || break
  /bin/sleep 0.1
done
if /usr/bin/pgrep -x CodexQuotaBar >/dev/null 2>&1; then
  echo "旧版本未能退出，请手动退出后重试。" >&2
  exit 1
fi

if [[ -d "$INSTALL_APP" ]]; then
  /bin/mv "$INSTALL_APP" "$BACKUP_APP"
fi
/bin/mv "$TEMP_APP" "$INSTALL_APP"
NEW_APP_INSTALLED=1

"$ROOT_DIR/scripts/autostart-on.sh" "$INSTALL_APP"
/usr/bin/open -gj "$INSTALL_APP"

for _ in {1..50}; do
  if is_installed_app_running; then
    /bin/sleep 1
    is_installed_app_running || break
    /bin/rm -rf "$BACKUP_APP"
    for legacy_app in "$LEGACY_APP" "$LEGACY_APP_SHORT"; do
      if [[ "$legacy_app" != "$INSTALL_APP" ]]; then
        /bin/rm -rf "$legacy_app"
      fi
    done
    NEW_APP_INSTALLED=0
    /bin/rm -rf "$ROOT_DIR/.build" "$ROOT_DIR/dist"
    echo "安装完成并已启动：$INSTALL_APP"
    exit 0
  fi
  /bin/sleep 0.1
done

echo "安装已完成，但应用未能启动：$INSTALL_APP" >&2
exit 1
