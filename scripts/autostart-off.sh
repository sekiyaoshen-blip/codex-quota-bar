#!/usr/bin/env bash
set -euo pipefail

LABEL="io.github.sekiyaoshen-blip.codex-quota-bar"
OLD_LABEL="io.github.sekiyaoshen-blip.codexquotabar.autostart"
DOMAIN="gui/$(/usr/bin/id -u)"

for name in "$LABEL" "$OLD_LABEL"; do
  /bin/launchctl bootout "$DOMAIN/$name" >/dev/null 2>&1 || true
  /bin/rm -f "$HOME/Library/LaunchAgents/$name.plist"
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -x "$SCRIPT_DIR/aliases.sh" ]]; then
  "$SCRIPT_DIR/aliases.sh" off
fi

/bin/rm -f "$HOME/.local/bin/codex-quota-bar" "$HOME/.local/bin/codexquotabar-follow-codex.sh"
/bin/rm -f "$HOME/Library/Logs/CodexQuotaBar/autostart.out.log" "$HOME/Library/Logs/CodexQuotaBar/autostart.err.log"
/bin/rmdir "$HOME/Library/Logs/CodexQuotaBar" >/dev/null 2>&1 || true

echo "已关闭自动启动。"
