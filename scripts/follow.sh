#!/bin/zsh
set -u

APP="${CODEX_QUOTA_BAR_APP_PATH:-$HOME/Library/Application Support/codex-quota-bar/codex-quota-bar.app}"

if ! /bin/ps -axo args= | /usr/bin/awk -v home="$HOME" '
  $1 == "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT" ||
  $1 == "/Applications/Codex.app/Contents/MacOS/Codex" ||
  $1 == home "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT" ||
  $1 == home "/Applications/Codex.app/Contents/MacOS/Codex" { found = 1; exit }
  END { exit found ? 0 : 1 }
'; then
  exit 0
fi

if /usr/bin/pgrep -x CodexQuotaBar >/dev/null 2>&1; then
  exit 0
fi

if [[ ! -x "$APP/Contents/MacOS/CodexQuotaBar" ]]; then
  print -u2 "找不到应用：$APP"
  exit 1
fi

/usr/bin/open -n -g -j -a "$APP"
