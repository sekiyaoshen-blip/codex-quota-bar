#!/usr/bin/env bash
set -uo pipefail

if [[ $# -ne 3 ]]; then
  exit 2
fi

EXPECTED_VERSION="$1"
INSTALL_APP="$2"
DEFAULTS_DOMAIN="$3"

if [[ ! "$EXPECTED_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ || "$INSTALL_APP" != /* || -z "$DEFAULTS_DOMAIN" ]]; then
  exit 2
fi

UPDATE_WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-quota-bar-update.XXXXXX")" || exit 1
UPDATE_REPO="$UPDATE_WORK_DIR/repo"

cleanup() {
  if [[ -n "$UPDATE_WORK_DIR" && "$UPDATE_WORK_DIR" == */codex-quota-bar-update.* ]]; then
    /bin/rm -rf "$UPDATE_WORK_DIR"
  fi
}
trap cleanup EXIT

skip_version() {
  /usr/bin/defaults write "$DEFAULTS_DOMAIN" skipped_update_version -string "$EXPECTED_VERSION" >/dev/null
}

if ! /usr/bin/git clone --depth 1 https://github.com/sekiyaoshen-blip/codex-quota-bar.git "$UPDATE_REPO" >/dev/null 2>&1; then
  skip_version
  exit 1
fi

CLONED_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$UPDATE_REPO/Info.plist" 2>/dev/null)"
if [[ "$CLONED_VERSION" != "$EXPECTED_VERSION" ]]; then
  skip_version
  exit 1
fi

if "$UPDATE_REPO/scripts/install.sh" "$INSTALL_APP" >/dev/null 2>&1; then
  /usr/bin/defaults delete "$DEFAULTS_DOMAIN" skipped_update_version >/dev/null 2>&1 || true
  exit 0
fi

skip_version
if ! /bin/ps -axo command= | /usr/bin/grep -F -x -q "$INSTALL_APP/Contents/MacOS/CodexQuotaBar"; then
  /usr/bin/open -n -g -j -a "$INSTALL_APP" >/dev/null 2>&1 || true
fi
exit 1
