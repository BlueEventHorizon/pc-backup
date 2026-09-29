#!/usr/bin/env bash
# Restore regular files, Git repositories, secrets and Homebrew state.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/config.sh"
pc_load_config
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/git-restore.sh"

: "${PC_BACKUP_DRY_RUN:=0}"
: "${PC_BACKUP_RESTORE_YES:=0}"
: "${PC_BACKUP_ALLOW_PLAINTEXT_SECRETS:=0}"

RESTORE_FILES=0
RESTORE_GIT=0
RESTORE_SECRETS=0
RESTORE_BREW=0
SELECTION_GIVEN=0
NO_SECRETS=0
PC_WARNING_COUNT=0
PC_LOG_FILE=""

usage() {
  cat <<'EOF'
Usage: restore.sh [--dry-run] [--yes] [--all] [--files] [--git]
                  [--secrets|--no-secrets] [--brew]

  --dry-run      show actions without writing
  --yes          skip interactive confirmation
  --all          restore files, Git repositories and secrets
  --files        restore regular files
  --git          restore Git mirrors, URL-only and full repositories
  --secrets      restore the encrypted secrets archive
  --no-secrets   exclude secrets (useful with --all)
  --brew         run brew bundle after file restoration
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) PC_BACKUP_DRY_RUN=1 ;;
    --yes) PC_BACKUP_RESTORE_YES=1 ;;
    --all) RESTORE_FILES=1; RESTORE_GIT=1; RESTORE_SECRETS=1; SELECTION_GIVEN=1 ;;
    --files) RESTORE_FILES=1; SELECTION_GIVEN=1 ;;
    --git) RESTORE_GIT=1; SELECTION_GIVEN=1 ;;
    --secrets) RESTORE_SECRETS=1; SELECTION_GIVEN=1 ;;
    --no-secrets) RESTORE_SECRETS=0; NO_SECRETS=1 ;;
    --brew) RESTORE_BREW=1; SELECTION_GIVEN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ${SELECTION_GIVEN} -eq 0 ]]; then
  RESTORE_FILES=1
  RESTORE_GIT=1
  [[ ${NO_SECRETS} -eq 1 ]] || RESTORE_SECRETS=1
fi

pc_restore_rsync_item() {
  local source="$1" destination="$2" is_dir="$3"
  local git_path exclude_rel
  local git_excludes=()
  [[ -e "${source}" ]] || { pc_warn "missing in backup: ${source}"; return 0; }

  if [[ "${is_dir}" == "1" ]]; then
    for git_path in "${PC_RESTORE_GIT_PATHS[@]}"; do
      if [[ "${git_path}" == "${source}" ]]; then
        pc_log "Regular restore delegated to Git mode: ${source#${PC_BACKUP_ROOT}/}"
        return 0
      fi
      if [[ "${git_path}" == "${source}/"* ]]; then
        exclude_rel="${git_path#${source}/}"
        git_excludes+=("${exclude_rel}")
      fi
    done
  fi

  pc_log "rsync restore: ${source#${PC_BACKUP_ROOT}/} -> ${destination}"
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
  if [[ "${is_dir}" == "1" ]]; then
    mkdir -p "${destination}"
    local opts=(-a)
    for exclude_rel in "${git_excludes[@]}"; do
      opts+=("--exclude=/${exclude_rel}/")
    done
    rsync "${opts[@]}" "${source}/" "${destination}/"
  else
    mkdir -p "$(dirname -- "${destination}")"
    rsync -a "${source}" "${destination}"
  fi
}

pc_restore_files() {
  local path source destination storage
  pc_require_cmd rsync
  for path in "${PC_BACKUP_MIRROR_PATHS[@]}"; do
    destination="${path}"
    storage=$(pc_visible_storage_rel "${destination}")
    source="${PC_BACKUP_ROOT}/${storage}"
    if [[ -d "${source}" ]]; then
      pc_restore_rsync_item "${source}" "${destination}" 1
    else
      pc_restore_rsync_item "${source}" "${destination}" 0
    fi
  done
}

pc_restore_secrets() {
  local secret_dir encrypted plaintext tmp tmp_dir
  secret_dir=$(pc_secret_storage_dir)
  encrypted="${secret_dir}/encrypted-backup.tar.gpg"
  plaintext="${secret_dir}/plaintext-backup.tar"
  if [[ -f "${encrypted}" ]]; then
    pc_require_cmd gpg
    pc_require_gpg_pass \
      || pc_die "GPG passphrase unavailable; add it to Keychain or run interactively"
    pc_log "Decrypting secrets archive into HOME"
    [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/pc-backup-secrets.XXXXXX")
    tmp="${tmp_dir}/secrets.tar"
    trap 'rm -rf -- "${tmp_dir}"' EXIT INT TERM
    if printf '%s' "${PC_BACKUP_GPG_PASS}" | gpg --batch --yes --pinentry-mode loopback \
      --passphrase-fd 0 --output "${tmp}" --decrypt "${encrypted}"; then
      pc_tar_is_safe "${tmp}" || pc_die "unsafe path found in secrets archive"
      tar -xf "${tmp}" -C "${HOME}"
      rm -rf -- "${tmp_dir}"
      trap - EXIT INT TERM
    else
      rm -rf -- "${tmp_dir}"
      trap - EXIT INT TERM
      pc_die "failed to decrypt secrets"
    fi
  elif [[ -f "${plaintext}" ]]; then
    [[ "${PC_BACKUP_ALLOW_PLAINTEXT_SECRETS}" == "1" ]] \
      || pc_die "plaintext secrets archive refused"
    pc_warn "restoring plaintext secrets archive"
    [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] || tar -xf "${plaintext}" -C "${HOME}"
  else
    pc_warn "no secrets archive found"
    return 0
  fi

  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
  if [[ -d "${HOME}/.ssh" ]]; then
    chmod 700 "${HOME}/.ssh" || true
    chmod 600 "${HOME}/.ssh"/id_* 2>/dev/null || true
    chmod 644 "${HOME}/.ssh"/*.pub 2>/dev/null || true
  fi
  [[ ! -d "${HOME}/.gnupg" ]] || chmod 700 "${HOME}/.gnupg" || true
}

pc_restore_brew() {
  local brewfile="${PC_BACKUP_ROOT}/.pc-backup/homebrew/Brewfile"
  [[ -f "${brewfile}" ]] || { pc_warn "Brewfile not found"; return 0; }
  pc_require_cmd brew
  pc_log "brew bundle --file=${brewfile}"
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] || brew bundle --file="${brewfile}"
}

main() {
  pc_validate_destination
  pc_validate_absolute_paths PC_BACKUP_MIRROR_PATHS "${PC_BACKUP_MIRROR_PATHS[@]}"
  [[ -d "${PC_BACKUP_ROOT}/.pc-backup" ]] || pc_die "backup metadata not found: ${PC_BACKUP_ROOT}/.pc-backup"
  pc_log "=== PC restore ==="
  pc_log "Source: ${PC_BACKUP_ROOT}"
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && pc_log "Mode: dry-run"

  if [[ "${PC_BACKUP_DRY_RUN}" != "1" && "${PC_BACKUP_RESTORE_YES}" != "1" ]]; then
    printf 'Restore selected data from %s? [y/N] ' "${PC_BACKUP_ROOT}"
    read -r answer
    case "${answer}" in y|Y|yes|YES) ;; *) pc_log "Aborted"; exit 1 ;; esac
  fi

  pc_prepare_restore_git_paths
  # Secrets come first: git-url repositories are cloned from their remote and
  # need the restored SSH keys and credentials. Git comes after files so that
  # non-Git files are in place before repositories are restored.
  [[ ${RESTORE_SECRETS} -eq 0 ]] || pc_restore_secrets
  [[ ${RESTORE_FILES} -eq 0 ]] || pc_restore_files
  [[ ${RESTORE_GIT} -eq 0 ]] || pc_restore_git
  [[ ${RESTORE_BREW} -eq 0 ]] || pc_restore_brew
  pc_log "=== PC restore complete (${PC_WARNING_COUNT} warning(s)) ==="
  pc_log "Re-authentication may still be required for gh, SSO and MCP sessions."
}

main "$@"
