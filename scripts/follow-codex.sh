#!/bin/zsh
set -u

APP="${CODEX_QUOTA_BAR_APP_PATH:-/Applications/Codex 额度栏.app}"

# Match only the official app's main executable. Helper, renderer, Crashpad,
# CLI, and proxy processes must not make the quota bar start by themselves.
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
  print -u2 "Codex 额度栏不存在或不可执行：$APP"
  exit 1
fi

/usr/bin/open -gj "$APP"
