#!/usr/bin/env bash
# Differential backup via rsync mirror + encrypted secrets bundle.
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
: "${PC_BACKUP_RSYNC_DELETE:=0}"

if [[ -z "${PC_BACKUP_ROOT:-}" ]]; then
  echo "ERROR: PC_BACKUP_ROOT is unset. Set it in backup.conf.local." >&2
  exit 1
fi
if ((${#PC_BACKUP_DIRS[@]} == 0)) || ((${#PC_BACKUP_FILES[@]} == 0)); then
  echo "ERROR: PC_BACKUP_DIRS / FILES must be set (see backup.conf.example)." >&2
  exit 1
fi

# file: .zshrc -> dotfiles/.zshrc | .a/b -> a/b
# dir:  .config -> config | .a/b -> a/b
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

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
DATE_TAG="$(date +%Y%m%d)"
BACKUP_ROOT="${PC_BACKUP_ROOT}"
MIRROR="${BACKUP_ROOT}/mirror"
LOG_DIR="${BACKUP_ROOT}/logs"
CHANGES_DIR="${BACKUP_ROOT}/changes"
META_DIR="${MIRROR}/meta"
SECRETS_STAGING="${BACKUP_ROOT}/.staging-secrets-${TIMESTAMP}"
LOG_FILE="${LOG_DIR}/${TIMESTAMP}.log"
RSYNC_FAILURES=0

RSYNC_OPTS=(-a --human-readable --itemize-changes)
[[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && RSYNC_OPTS+=(--dry-run)
[[ "${PC_BACKUP_RSYNC_DELETE}" == "1" ]] && RSYNC_OPTS+=(--delete)

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

record_rsync() {
  local src="$1" dest_rel="$2" change_file="$3" rc="$4"
  if [[ "${rc}" -ne 0 ]]; then
    log "WARN: rsync exit ${rc} for ${src}"
    RSYNC_FAILURES=$((RSYNC_FAILURES + 1))
  fi
  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    rm -f "${change_file}"
    return 0
  fi
  if [[ -s "${change_file}" ]]; then
    log "  changes recorded: ${change_file}"
  else
    rm -f "${change_file}"
  fi
}

rsync_path() {
  local src="$1" dest_rel="$2" dest="${MIRROR}/${2}"
  if [[ ! -e "${src}" ]]; then
    log "SKIP (missing): ${src}"
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  local change_file="${CHANGES_DIR}/${DATE_TAG}-${dest_rel//\//_}.txt" rc=0
  log "rsync: ${src} -> mirror/${dest_rel}"
  rsync "${RSYNC_OPTS[@]}" "${src}" "${dest}" > "${change_file}" 2>&1 || rc=$?
  record_rsync "${src}" "${dest_rel}" "${change_file}" "${rc}"
}

rsync_dir() {
  local src="$1" dest_rel="$2" dest="${MIRROR}/${2}"
  if [[ ! -d "${src}" ]]; then
    log "SKIP (missing dir): ${src}"
    return 0
  fi
  mkdir -p "${dest}"
  local change_file="${CHANGES_DIR}/${DATE_TAG}-${dest_rel//\//_}.txt" rc=0
  log "rsync: ${src}/ -> mirror/${dest_rel}/"
  rsync "${RSYNC_OPTS[@]}" "${src}/" "${dest}/" > "${change_file}" 2>&1 || rc=$?
  record_rsync "${src}/" "${dest_rel}" "${change_file}" "${rc}"
}

write_inventory() {
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
  mkdir -p "${META_DIR}"
  cat > "${META_DIR}/inventory-${DATE_TAG}.json" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "hostname": "$(hostname)",
  "user": "$(whoami)",
  "dry_run": ${PC_BACKUP_DRY_RUN},
  "encrypt_secrets": ${PC_BACKUP_ENCRYPT_SECRETS}
}
EOF
  cp "${META_DIR}/inventory-${DATE_TAG}.json" "${META_DIR}/inventory-latest.json"
}

backup_secrets_bundle() {
  if ((${#PC_BACKUP_SECRETS[@]} == 0)); then
    log "SKIP secrets (PC_BACKUP_SECRETS empty)"
    return 0
  fi
  require_cmd tar
  mkdir -p "${SECRETS_STAGING}" "${MIRROR}/encrypted"
  local bundle_path="${SECRETS_STAGING}/secrets.tar"
  local latest_path="${MIRROR}/encrypted/secrets-latest.tar.gpg"
  local plaintext_latest="${MIRROR}/encrypted/secrets-latest.tar"

  log "Building secrets bundle"
  local items=() rel
  for rel in "${PC_BACKUP_SECRETS[@]}"; do
    if [[ -e "${HOME}/${rel}" ]]; then
      items+=("${rel}")
    else
      log "SKIP secret (missing): ${HOME}/${rel}"
    fi
  done
  if [[ ${#items[@]} -eq 0 ]]; then
    log "No secrets paths found; skipping bundle"
    rm -rf "${SECRETS_STAGING}"
    return 0
  fi

  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    log "DRY-RUN: would pack ${#items[@]} secret path(s)"
    rm -rf "${SECRETS_STAGING}"
    return 0
  fi

  (
    cd "${HOME}"
    tar -cf "${bundle_path}" \
      --exclude='.ssh/agent' \
      --exclude='.gnupg/S.*' \
      --exclude='.gnupg/*.socket' \
      "${items[@]}" 2>>"${LOG_FILE}"
  )

  if [[ "${PC_BACKUP_ENCRYPT_SECRETS}" == "1" ]]; then
    require_cmd gpg
    if [[ -z "${PC_BACKUP_GPG_PASS:-}" ]]; then
      rm -rf "${SECRETS_STAGING}"
      die "PC_BACKUP_GPG_PASS is unset. Refusing plaintext secrets."
    fi
    local tmp_gpg="${SECRETS_STAGING}/secrets.tar.gpg"
    printf '%s' "${PC_BACKUP_GPG_PASS}" | gpg --batch --yes --pinentry-mode loopback \
      --passphrase-fd 0 \
      --symmetric --cipher-algo AES256 \
      --output "${tmp_gpg}" "${bundle_path}"
    mv -f "${tmp_gpg}" "${latest_path}"
    rm -f "${plaintext_latest}"
    log "Encrypted secrets -> mirror/encrypted/secrets-latest.tar.gpg"
  else
    if [[ "${PC_BACKUP_ALLOW_PLAINTEXT_SECRETS}" != "1" ]]; then
      rm -rf "${SECRETS_STAGING}"
      die "Plaintext secrets refused. Set PC_BACKUP_ALLOW_PLAINTEXT_SECRETS=1 or enable encryption."
    fi
    cp "${bundle_path}" "${plaintext_latest}"
    log "WARN: stored plaintext secrets (explicit allow)"
  fi
  rm -rf "${SECRETS_STAGING}"
}

prune_changes() {
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
  find "${CHANGES_DIR}" -type f -name '*.txt' -mtime +30 -delete 2>/dev/null || true
  find "${LOG_DIR}" -type f -name '*.log' -mtime +30 -delete 2>/dev/null || true
  find "${META_DIR}" -type f -name 'inventory-2*.json' -mtime +30 -delete 2>/dev/null || true
}

main() {
  require_cmd rsync
  mkdir -p "${LOG_DIR}" "${CHANGES_DIR}" "${MIRROR}"

  log "=== PC backup start ==="
  log "Destination: ${BACKUP_ROOT}"
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && log "Mode: dry-run"

  if [[ -x "${SCRIPT_DIR}/brewfile-update.sh" ]]; then
    if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
      log "DRY-RUN: would refresh Brewfile"
    else
      "${SCRIPT_DIR}/brewfile-update.sh" "${MIRROR}/brew" >> "${LOG_FILE}" 2>&1 || log "WARN: brewfile-update failed"
    fi
  fi

  local rel dest
  for rel in "${PC_BACKUP_FILES[@]}"; do
    dest="$(mirror_dest_file "${rel}")"
    rsync_path "${HOME}/${rel}" "${dest}"
  done
  for rel in "${PC_BACKUP_DIRS[@]}"; do
    dest="$(mirror_dest_dir "${rel}")"
    rsync_dir "${HOME}/${rel}" "${dest}"
  done

  backup_secrets_bundle
  write_inventory
  prune_changes

  if [[ "${RSYNC_FAILURES}" -gt 0 ]]; then
    die "completed with ${RSYNC_FAILURES} rsync failure(s)"
  fi

  log "=== PC backup complete ==="
  du -sh "${MIRROR}" 2>/dev/null | tee -a "${LOG_FILE}" || true
}

main "$@"
