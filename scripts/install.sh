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
LEGACY_APP_BACKUP="$INSTALL_DIR/.codex-quota-bar.legacy.$$"
LEGACY_APP_SHORT_BACKUP="$INSTALL_DIR/.codex-quota-bar.legacy-short.$$"
APP_WAS_RUNNING=0
NEW_APP_INSTALLED=0
AUTOSTART_SUSPENDED=0
AUTOSTART_LABEL="io.github.sekiyaoshen-blip.codex-quota-bar"
AUTOSTART_DOMAIN="gui/$(/usr/bin/id -u)"

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

installed_app_process_count() {
  /bin/ps -axo command= | /usr/bin/awk -v expected="$INSTALL_APP/Contents/MacOS/CodexQuotaBar" '
    {
      command = $0
      sub(/^[[:space:]]+/, "", command)
      if (command == expected || index(command, expected " ") == 1) {
        count++
      }
    }
    END { print count + 0 }
  '
}

is_installed_app_running() {
  [[ "$(installed_app_process_count)" -gt 0 ]]
}

start_app() {
  local app_path="$1"
  /usr/bin/open -n -g -j -a "$app_path"
}

finish() {
  local status=$?
  trap - EXIT
  set +e

  if [[ "$status" -ne 0 && ( "$NEW_APP_INSTALLED" -eq 1 || -d "$BACKUP_APP" || -d "$LEGACY_APP_SHORT_BACKUP" || -d "$LEGACY_APP_BACKUP" ) ]]; then
    /usr/bin/pkill -x CodexQuotaBar >/dev/null 2>&1 || true
    if [[ "$NEW_APP_INSTALLED" -eq 1 ]]; then
      /bin/rm -rf "$INSTALL_APP"
    fi
    if [[ -d "$BACKUP_APP" ]]; then
      /bin/mv "$BACKUP_APP" "$INSTALL_APP"
    fi
    if [[ -d "$LEGACY_APP_SHORT_BACKUP" && ! -e "$LEGACY_APP_SHORT" ]]; then
      /bin/mv "$LEGACY_APP_SHORT_BACKUP" "$LEGACY_APP_SHORT"
    fi
    if [[ -d "$LEGACY_APP_BACKUP" && ! -e "$LEGACY_APP" ]]; then
      /bin/mv "$LEGACY_APP_BACKUP" "$LEGACY_APP"
    fi
    if [[ -d "$INSTALL_APP" ]]; then
      if [[ "$APP_WAS_RUNNING" -eq 1 ]]; then
        start_app "$INSTALL_APP"
        for _ in {1..50}; do
          is_installed_app_running && break
          /bin/sleep 0.1
        done
      fi
    else
      for legacy_app in "$LEGACY_APP_SHORT" "$LEGACY_APP"; do
        if [[ -d "$legacy_app" ]]; then
          if [[ "$APP_WAS_RUNNING" -eq 1 ]]; then
            start_app "$legacy_app"
          fi
          break
        fi
      done
    fi
  fi

  if [[ "$status" -ne 0 && "$AUTOSTART_SUSPENDED" -eq 1 ]]; then
    /bin/launchctl enable "$AUTOSTART_DOMAIN/$AUTOSTART_LABEL" >/dev/null 2>&1 || true
  fi

  /bin/rm -rf "$TEMP_APP" "$BACKUP_APP"
  if [[ "$status" -eq 0 ]]; then
    /bin/rm -rf "$LEGACY_APP_SHORT_BACKUP" "$LEGACY_APP_BACKUP"
  fi
  exit "$status"
}
trap finish EXIT

"$ROOT_DIR/scripts/build.sh"
/usr/bin/ditto "$BUILD_APP" "$TEMP_APP"

/bin/launchctl disable "$AUTOSTART_DOMAIN/$AUTOSTART_LABEL" >/dev/null 2>&1 || true
AUTOSTART_SUSPENDED=1
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

if [[ -d "$LEGACY_APP_SHORT" && "$LEGACY_APP_SHORT" != "$INSTALL_APP" ]]; then
  /bin/mv "$LEGACY_APP_SHORT" "$LEGACY_APP_SHORT_BACKUP"
fi
if [[ -d "$LEGACY_APP" && "$LEGACY_APP" != "$INSTALL_APP" ]]; then
  /bin/mv "$LEGACY_APP" "$LEGACY_APP_BACKUP"
fi

if [[ -d "$INSTALL_APP" ]]; then
  /bin/mv "$INSTALL_APP" "$BACKUP_APP"
fi
/bin/mv "$TEMP_APP" "$INSTALL_APP"
NEW_APP_INSTALLED=1

if ! is_installed_app_running; then
  start_app "$INSTALL_APP"
fi

for _ in {1..50}; do
  if is_installed_app_running; then
    "$ROOT_DIR/scripts/autostart-on.sh" "$INSTALL_APP"
    AUTOSTART_SUSPENDED=0
    /bin/sleep 1
    if ! is_installed_app_running || [[ "$(installed_app_process_count)" -ne 1 ]]; then
      break
    fi
    /bin/rm -rf "$BACKUP_APP"
    /bin/rm -rf "$LEGACY_APP_SHORT_BACKUP" "$LEGACY_APP_BACKUP"
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
