#!/usr/bin/env bash
# Install LaunchAgent for scheduled backup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
[[ -f "${PROJECT_ROOT}/backup.conf.example" ]] && source "${PROJECT_ROOT}/backup.conf.example"
# shellcheck source=/dev/null
[[ -f "${PROJECT_ROOT}/backup.conf.local" ]] && source "${PROJECT_ROOT}/backup.conf.local"

: "${PC_BACKUP_LAUNCH_HOUR:=7}"
: "${PC_BACKUP_LAUNCH_MINUTE:=30}"
: "${PC_BACKUP_ENCRYPT_SECRETS:=1}"

if [[ -z "${PC_BACKUP_ROOT:-}" ]]; then
  echo "ERROR: PC_BACKUP_ROOT is unset. Set it in backup.conf.local before installing." >&2
  exit 1
fi

BACKUP_SCRIPT="${SCRIPT_DIR}/backup.sh"
PLIST_LABEL="com.pc-backup"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"

chmod +x "${BACKUP_SCRIPT}" "${SCRIPT_DIR}/brewfile-update.sh"
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
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
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

if [[ -z "${PC_BACKUP_GPG_PASS:-}" && "${PC_BACKUP_ENCRYPT_SECRETS}" == "1" ]]; then
  echo ""
  echo "WARN: PC_BACKUP_GPG_PASS is unset — scheduled runs will fail at secrets step."
fi
