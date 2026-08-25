#!/usr/bin/env bash
set -euo pipefail

BEGIN_MARKER="# >>> codex-quota-bar aliases >>>"
END_MARKER="# <<< codex-quota-bar aliases <<<"
MODE="${1:-}"
APP_PATH="${2:-$HOME/Library/Application Support/codex-quota-bar/codex-quota-bar.app}"

if [[ "$MODE" != "on" && "$MODE" != "off" ]]; then
  echo "用法：$0 on [应用路径] | off" >&2
  exit 2
fi

LOGIN_SHELL="$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" UserShell 2>/dev/null | /usr/bin/awk '{print $2}' || true)"
LOGIN_SHELL="${LOGIN_SHELL:-${SHELL:-/bin/zsh}}"

case "$(basename "$LOGIN_SHELL")" in
  zsh)
    CONFIG_FILES=("$HOME/.zshrc")
    ;;
  bash)
    CONFIG_FILES=("$HOME/.bash_profile" "$HOME/.bashrc")
    ;;
  *)
    echo "暂不支持当前 shell：$LOGIN_SHELL" >&2
    exit 1
    ;;
esac

if [[ "$MODE" == "on" ]]; then
  printf -v QUOTED_APP '%q' "$APP_PATH"
  RESTART_COMMAND="/usr/bin/pkill -x CodexQuotaBar >/dev/null 2>&1 || true; /usr/bin/open -n -g -j -a $QUOTED_APP"
fi

update_config() {
  local config_file="$1"
  local temp_file

  if [[ "$MODE" == "off" && ! -e "$config_file" && ! -L "$config_file" ]]; then
    return
  fi

  temp_file="$(/usr/bin/mktemp "$HOME/.codex-quota-bar-aliases.XXXXXX")"
  if [[ -e "$config_file" ]]; then
    /usr/bin/env LC_ALL=C /usr/bin/perl -0pe 's/(?:\r?\n)?# >>> codex-quota-bar aliases >>>\r?\n.*?# <<< codex-quota-bar aliases <<<(?:\r?\n)?//sg' \
      "$config_file" >"$temp_file"
  fi

  if [[ "$MODE" == "on" ]]; then
    if [[ -s "$temp_file" ]]; then
      /usr/bin/printf '\n' >>"$temp_file"
    fi
    /usr/bin/printf '%s\n' \
      "$BEGIN_MARKER" \
      "alias codex-quota-bar='$RESTART_COMMAND'" \
      "alias codex-bar='$RESTART_COMMAND'" \
      "$END_MARKER" >>"$temp_file"
  fi

  /bin/cat "$temp_file" >"$config_file"
  /bin/rm -f "$temp_file"
}

for config_file in "${CONFIG_FILES[@]}"; do
  update_config "$config_file"
done

if [[ "$MODE" == "on" ]]; then
  echo "已配置命令：codex-quota-bar、codex-bar（新终端生效）"
else
  echo "已移除命令：codex-quota-bar、codex-bar"
fi
