#!/usr/bin/env bash
set -euo pipefail

LABEL="io.github.sekiyaoshen-blip.codex-quota-bar"
OLD_LABEL="io.github.sekiyaoshen-blip.codexquotabar.autostart"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE_SCRIPT="$ROOT_DIR/scripts/follow.sh"
FOLLOWER_DIR="$HOME/.local/bin"
FOLLOWER_PATH="$FOLLOWER_DIR/codex-quota-bar"
OLD_FOLLOWER_PATH="$FOLLOWER_DIR/codexquotabar-follow-codex.sh"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
OLD_PLIST_PATH="$PLIST_DIR/$OLD_LABEL.plist"
LOG_DIR="$HOME/Library/Logs/codex-quota-bar"
OLD_LOG_DIR="$HOME/Library/Logs/CodexQuotaBar"
DOMAIN="gui/$(/usr/bin/id -u)"

if [[ $# -gt 1 ]]; then
  echo "用法：$0 [应用路径]" >&2
  exit 2
fi

APP_INPUT="${1:-/Applications/codex-quota-bar.app}"
if [[ "$APP_INPUT" != /* ]]; then
  APP_INPUT="$PWD/$APP_INPUT"
fi
APP_PARENT="$(cd "$(dirname "$APP_INPUT")" 2>/dev/null && pwd -P)" || {
  echo "找不到安装目录：$(dirname "$APP_INPUT")" >&2
  exit 1
}
APP_PATH="$APP_PARENT/$(basename "$APP_INPUT")"

if [[ ! -x "$APP_PATH/Contents/MacOS/CodexQuotaBar" ]]; then
  echo "找不到应用：$APP_PATH" >&2
  exit 1
fi

mkdir -p "$FOLLOWER_DIR" "$PLIST_DIR" "$LOG_DIR"
/usr/bin/install -m 0755 "$SOURCE_SCRIPT" "$FOLLOWER_PATH"

PLIST_TMP="$(/usr/bin/mktemp "$PLIST_DIR/.codex-quota-bar.XXXXXX")"
trap '/bin/rm -f "$PLIST_TMP"' EXIT

/bin/cat >"$PLIST_TMP" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.sekiyaoshen-blip.codex-quota-bar</string>
    <key>ProgramArguments</key>
    <array>
        <string>FOLLOWER_PATH</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>CODEX_QUOTA_BAR_APP_PATH</key>
        <string>APP_PATH</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>STDOUT_PATH</string>
    <key>StandardErrorPath</key>
    <string>STDERR_PATH</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -remove ProgramArguments.0 "$PLIST_TMP"
/usr/bin/plutil -insert ProgramArguments.0 -string "$FOLLOWER_PATH" "$PLIST_TMP"
/usr/bin/plutil -replace EnvironmentVariables.CODEX_QUOTA_BAR_APP_PATH -string "$APP_PATH" "$PLIST_TMP"
/usr/bin/plutil -replace StandardOutPath -string "$LOG_DIR/out.log" "$PLIST_TMP"
/usr/bin/plutil -replace StandardErrorPath -string "$LOG_DIR/err.log" "$PLIST_TMP"
/usr/bin/plutil -lint "$PLIST_TMP" >/dev/null
/bin/chmod 0644 "$PLIST_TMP"

/bin/launchctl bootout "$DOMAIN/$OLD_LABEL" >/dev/null 2>&1 || true
/bin/rm -f "$OLD_PLIST_PATH" "$OLD_FOLLOWER_PATH"
/bin/rm -f "$OLD_LOG_DIR/autostart.out.log" "$OLD_LOG_DIR/autostart.err.log"
/bin/rmdir "$OLD_LOG_DIR" >/dev/null 2>&1 || true
if [[ -f "$PLIST_PATH" ]] && \
   /usr/bin/cmp -s "$PLIST_TMP" "$PLIST_PATH" && \
   /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  # 配置和服务都没有变化，保留现有注册，避免重复触发系统提示。
  /bin/rm -f "$PLIST_TMP"
else
  /bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  /bin/mv -f "$PLIST_TMP" "$PLIST_PATH"
  /bin/launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
  /bin/launchctl enable "$DOMAIN/$LABEL"
fi

echo "已开启自动启动：$APP_PATH"
