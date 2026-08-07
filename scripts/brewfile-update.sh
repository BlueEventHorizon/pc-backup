#!/usr/bin/env bash
# Dump Homebrew inventory into the backup mirror (not the tool repo).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/config.sh"
pc_load_config

if [[ -z "${PC_BACKUP_ROOT:-}" ]]; then
  echo "ERROR: PC_BACKUP_ROOT is unset. Set it in backup.yaml." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "brew not found" >&2
  exit 1
fi

BREW_DIR="${1:-${PC_BACKUP_ROOT}/.pc-backup/homebrew}"
BREWFILE="${BREW_DIR}/Brewfile"
mkdir -p "${BREW_DIR}"

echo "Updating ${BREWFILE}"
if brew bundle dump --force --file="${BREWFILE}"; then
  echo "brew bundle dump succeeded"
else
  echo "brew bundle dump failed; generating Brewfile from brew leaves/casks" >&2
  {
    echo "# Generated fallback $(date +%Y-%m-%d) — brew bundle dump unavailable"
    brew leaves | while read -r pkg; do echo "brew \"${pkg}\""; done
    brew list --cask | while read -r pkg; do echo "cask \"${pkg}\""; done
  } > "${BREWFILE}"
fi

brew leaves > "${BREW_DIR}/brew-leaves.txt"
brew list --cask > "${BREW_DIR}/brew-casks.txt"

echo "Done. $(wc -l < "${BREWFILE}") lines in Brewfile -> ${BREW_DIR}"
