#!/usr/bin/env bash
# Restore files from the backup mirror into $HOME (conf-driven).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
[[ -f "${PROJECT_ROOT}/backup.conf.example" ]] && source "${PROJECT_ROOT}/backup.conf.example"
# shellcheck source=/dev/null
[[ -f "${PROJECT_ROOT}/backup.conf.local" ]] && source "${PROJECT_ROOT}/backup.conf.local"

: "${PC_BACKUP_ENCRYPT_SECRETS:=1}"
: "${PC_BACKUP_ALLOW_PLAINTEXT_SECRETS:=0}"
: "${PC_BACKUP_DRY_RUN:=0}"
: "${PC_BACKUP_RESTORE_YES:=0}"
: "${PC_BACKUP_RESTORE_BREW:=0}"
: "${PC_BACKUP_RESTORE_SECRETS:=1}"

usage() {
  cat <<'EOF'
Usage: restore.sh [--dry-run] [--yes] [--brew] [--no-secrets]

  --dry-run      rsync without writing (also PC_BACKUP_DRY_RUN=1)
  --yes          skip interactive confirmation
  --brew         run: brew bundle --file=$MIRROR/brew/Brewfile
  --no-secrets   skip encrypted secrets bundle
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) PC_BACKUP_DRY_RUN=1 ;;
    --yes) PC_BACKUP_RESTORE_YES=1 ;;
    --brew) PC_BACKUP_RESTORE_BREW=1 ;;
    --no-secrets) PC_BACKUP_RESTORE_SECRETS=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [[ -z "${PC_BACKUP_ROOT:-}" ]]; then
  echo "ERROR: PC_BACKUP_ROOT is unset. Set it in backup.conf.local." >&2
  exit 1
fi
if ((${#PC_BACKUP_DIRS[@]} == 0)) || ((${#PC_BACKUP_FILES[@]} == 0)); then
  echo "ERROR: PC_BACKUP_DIRS / FILES must be set (see backup.conf.example)." >&2
  exit 1
fi

# Keep in sync with backup.sh
mirror_dest_file() {
  local rel="${1#/}"
  if [[ "${rel}" != */* ]]; then
    printf 'dotfiles/%s\n' "${rel}"
  else
    printf '%s\n' "${rel#.}"
  fi
}

mirror_dest_dir() {
  local rel="${1#/}"
  printf '%s\n' "${rel#.}"
}

MIRROR="${PC_BACKUP_ROOT}/mirror"
if [[ ! -d "${MIRROR}" ]]; then
  echo "ERROR: mirror not found: ${MIRROR}" >&2
  exit 1
fi

RSYNC_OPTS=(-a --human-readable --itemize-changes)
[[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && RSYNC_OPTS+=(--dry-run)
RSYNC_FAILURES=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

restore_file() {
  local rel="$1"
  local src="${MIRROR}/$(mirror_dest_file "${rel}")"
  local dest="${HOME}/${rel}"
  if [[ ! -e "${src}" ]]; then
    log "SKIP (missing in mirror): ${rel}"
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  log "rsync: mirror/$(mirror_dest_file "${rel}") -> ~/${rel}"
  local rc=0
  rsync "${RSYNC_OPTS[@]}" "${src}" "${dest}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log "WARN: rsync exit ${rc} for ${rel}"
    RSYNC_FAILURES=$((RSYNC_FAILURES + 1))
  fi
}

restore_dir() {
  local rel="$1"
  local src="${MIRROR}/$(mirror_dest_dir "${rel}")"
  local dest="${HOME}/${rel}"
  if [[ ! -d "${src}" ]]; then
    log "SKIP (missing dir in mirror): ${rel}"
    return 0
  fi
  mkdir -p "${dest}"
  log "rsync: mirror/$(mirror_dest_dir "${rel}")/ -> ~/${rel}/"
  local rc=0
  rsync "${RSYNC_OPTS[@]}" "${src}/" "${dest}/" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log "WARN: rsync exit ${rc} for ${rel}/"
    RSYNC_FAILURES=$((RSYNC_FAILURES + 1))
  fi
}

restore_secrets() {
  local gpg_path="${MIRROR}/encrypted/secrets-latest.tar.gpg"
  local tar_path="${MIRROR}/encrypted/secrets-latest.tar"

  if [[ -f "${gpg_path}" ]]; then
    if [[ -z "${PC_BACKUP_GPG_PASS:-}" ]]; then
      die "PC_BACKUP_GPG_PASS is unset; cannot decrypt secrets."
    fi
    require_cmd gpg
    log "Decrypting secrets-latest.tar.gpg"
    if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
      log "DRY-RUN: would decrypt and extract secrets into \$HOME"
      return 0
    fi
    local tmp
    tmp="$(mktemp)"
    printf '%s' "${PC_BACKUP_GPG_PASS}" | gpg --batch --yes --pinentry-mode loopback \
      --passphrase-fd 0 \
      --output "${tmp}" --decrypt "${gpg_path}"
    tar -xf "${tmp}" -C "${HOME}"
    rm -f "${tmp}"
  elif [[ -f "${tar_path}" ]]; then
    if [[ "${PC_BACKUP_ALLOW_PLAINTEXT_SECRETS}" != "1" ]]; then
      die "plaintext secrets-latest.tar present but PC_BACKUP_ALLOW_PLAINTEXT_SECRETS!=1"
    fi
    log "WARN: using plaintext secrets-latest.tar"
    if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
      log "DRY-RUN: would extract plaintext secrets into \$HOME"
      return 0
    fi
    tar -xf "${tar_path}" -C "${HOME}"
  else
    log "SKIP: no secrets bundle in mirror/encrypted/"
    return 0
  fi

  if [[ -d "${HOME}/.ssh" ]]; then
    chmod 700 "${HOME}/.ssh" || true
    chmod 600 "${HOME}/.ssh"/id_* 2>/dev/null || true
    chmod 644 "${HOME}/.ssh"/*.pub 2>/dev/null || true
  fi
  if [[ -d "${HOME}/.gnupg" ]]; then
    chmod 700 "${HOME}/.gnupg" || true
  fi
  log "Secrets restored"
}

main() {
  require_cmd rsync

  log "=== PC restore ==="
  log "Source: ${MIRROR}"
  log "Target: ${HOME}"
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && log "Mode: dry-run"

  if [[ "${PC_BACKUP_DRY_RUN}" != "1" && "${PC_BACKUP_RESTORE_YES}" != "1" ]]; then
    printf 'Restore into %s from %s? [y/N] ' "${HOME}" "${MIRROR}"
    read -r ans
    case "${ans}" in
      y|Y|yes|YES) ;;
      *) log "Aborted."; exit 1 ;;
    esac
  fi

  local rel
  for rel in "${PC_BACKUP_FILES[@]}"; do
    restore_file "${rel}"
  done
  for rel in "${PC_BACKUP_DIRS[@]}"; do
    restore_dir "${rel}"
  done

  if [[ "${PC_BACKUP_RESTORE_SECRETS}" == "1" ]]; then
    restore_secrets
  else
    log "SKIP secrets (--no-secrets)"
  fi

  if [[ "${PC_BACKUP_RESTORE_BREW}" == "1" ]]; then
    if [[ -f "${MIRROR}/brew/Brewfile" ]]; then
      require_cmd brew
      log "brew bundle --file=${MIRROR}/brew/Brewfile"
      if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
        log "DRY-RUN: would run brew bundle"
      else
        brew bundle --file="${MIRROR}/brew/Brewfile"
      fi
    else
      log "SKIP brew (no Brewfile in mirror)"
    fi
  fi

  if [[ "${RSYNC_FAILURES}" -gt 0 ]]; then
    die "completed with ${RSYNC_FAILURES} rsync failure(s)"
  fi

  log "=== PC restore complete ==="
  log "Re-auth still required for tokens not stored in files."
}

main "$@"
