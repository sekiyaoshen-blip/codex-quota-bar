#!/usr/bin/env bash
set -euo pipefail

LABEL="io.github.sekiyaoshen-blip.codexquotabar.autostart"
DOMAIN="gui/$(/usr/bin/id -u)"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
FOLLOWER_PATH="$HOME/.local/bin/codexquotabar-follow-codex.sh"
LOG_DIR="$HOME/Library/Logs/CodexQuotaBar"

/bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
/bin/rm -f "$PLIST_PATH" "$FOLLOWER_PATH"
/bin/rm -f "$LOG_DIR/autostart.out.log" "$LOG_DIR/autostart.err.log"
/bin/rmdir "$LOG_DIR" >/dev/null 2>&1 || true

echo "已关闭 Codex 额度栏的跟随启动；应用本身未被删除。"
