#!/usr/bin/env bash
# Install LaunchAgent for scheduled backup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/config.sh"
pc_load_config

: "${PC_BACKUP_LAUNCH_HOUR:=7}"
: "${PC_BACKUP_LAUNCH_MINUTE:=30}"
: "${PC_BACKUP_ENCRYPT_SECRETS:=1}"

if [[ -z "${PC_BACKUP_ROOT:-}" ]]; then
  echo "ERROR: PC_BACKUP_ROOT is unset. Set it in backup.yaml before installing." >&2
  exit 1
fi

BACKUP_SCRIPT="${SCRIPT_DIR}/backup.sh"
PLIST_LABEL="com.pc-backup"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"

PATH_ENTRIES=()
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  if [[ -n "${BREW_PREFIX}" ]]; then
    PATH_ENTRIES+=("${BREW_PREFIX}/bin" "${BREW_PREFIX}/sbin")
  fi
fi
PATH_ENTRIES+=(/usr/local/bin /usr/bin /bin /usr/sbin /sbin)
LAUNCH_PATH="$(IFS=:; echo "${PATH_ENTRIES[*]}")"

chmod +x "${SCRIPT_DIR}"/*.sh
mkdir -p "${HOME}/Library/LaunchAgents"

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BACKUP_SCRIPT}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${PC_BACKUP_LAUNCH_HOUR}</integer>
    <key>Minute</key>
    <integer>${PC_BACKUP_LAUNCH_MINUTE}</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/pc-backup.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/pc-backup.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${LAUNCH_PATH}</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
launchctl enable "gui/$(id -u)/${PLIST_LABEL}"

echo "Installed ${PLIST_PATH}"
echo "Schedule: ${PC_BACKUP_LAUNCH_HOUR}:$(printf '%02d' "${PC_BACKUP_LAUNCH_MINUTE}") daily"
echo "Logs: ~/Library/Logs/pc-backup.log"
echo "Root: ${PC_BACKUP_ROOT}"
echo "PATH: ${LAUNCH_PATH}"

pc_load_gpg_pass_from_keychain
if [[ -z "${PC_BACKUP_GPG_PASS:-}" && "${PC_BACKUP_ENCRYPT_SECRETS}" == "1" ]]; then
  echo ""
  echo "WARN: PC_BACKUP_GPG_PASS is unset — scheduled runs will fail at secrets step."
fi
