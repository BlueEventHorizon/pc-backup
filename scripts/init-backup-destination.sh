#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/config.sh"
pc_load_config
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

[[ -n "${PC_BACKUP_ROOT:-}" ]] || pc_die "PC_BACKUP_ROOT is unset"
[[ -n "${PC_BACKUP_DESTINATION_ID:-}" ]] || pc_die "PC_BACKUP_DESTINATION_ID is unset"
[[ "${PC_BACKUP_ROOT}" == /* ]] || pc_die "PC_BACKUP_ROOT must be absolute"
[[ "${PC_BACKUP_ROOT}" != "/" && "${PC_BACKUP_ROOT}" != "${HOME}" ]] \
  || pc_die "unsafe PC_BACKUP_ROOT: ${PC_BACKUP_ROOT}"

mkdir -p "${PC_BACKUP_ROOT}"
marker="${PC_BACKUP_ROOT}/.pc-backup-destination"

if [[ -e "${marker}" ]]; then
  current=""
  IFS= read -r current < "${marker}" || true
  [[ "${current}" == "${PC_BACKUP_DESTINATION_ID}" ]] \
    || pc_die "existing destination ID differs: ${current:-empty}"
  printf 'Already initialized: %s\n' "${PC_BACKUP_ROOT}"
  exit 0
fi

printf '%s\n' "${PC_BACKUP_DESTINATION_ID}" > "${marker}"
chmod 600 "${marker}"
printf 'Initialized: %s\n' "${PC_BACKUP_ROOT}"
printf 'Destination ID: %s\n' "${PC_BACKUP_DESTINATION_ID}"
