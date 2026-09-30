#!/usr/bin/env bash
# Read-only verification of manifests, Git mirrors and encrypted secrets.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/config.sh"
pc_load_config
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

PC_LOG_FILE=""
PC_WARNING_COUNT=0
VERIFY_FAILURES=0

verify_manifest() {
  local manifest="${PC_BACKUP_ROOT}/.pc-backup/manifests/manifest-latest.json"
  if [[ ! -s "${manifest}" ]]; then
    pc_warn "manifest missing: ${manifest}"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    if python3 -m json.tool "${manifest}" >/dev/null 2>&1; then
      pc_log "Manifest: ok"
    else
      pc_warn "manifest is not valid JSON"
      VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    fi
  else
    pc_log "Manifest: present (JSON parser unavailable)"
  fi
}

verify_git_mirrors() {
  local mirror count=0 work
  pc_require_cmd git
  pc_require_cmd tar
  # <repo>/.git.tar: extract to a temporary directory and check it completely.
  while IFS= read -r -d '' mirror; do
    count=$((count + 1))
    work=$(mktemp -d "${TMPDIR:-/tmp}/pc-backup-verify.XXXXXX")
    if tar -xf "${mirror}" -C "${work}" 2>/dev/null \
      && git -C "${work}/mirror" fsck --full >/dev/null 2>&1; then
      pc_log "Git mirror ok: ${mirror#${PC_BACKUP_ROOT}/}"
    else
      pc_warn "Git mirror failed: ${mirror#${PC_BACKUP_ROOT}/}"
      VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    fi
    rm -rf -- "${work}"
  done < <(find "${PC_BACKUP_ROOT}" -path "${PC_BACKUP_ROOT}/.pc-backup" -prune -o -type f -name .git.tar -print0)
  # Directory-format mirrors from earlier versions.
  while IFS= read -r -d '' mirror; do
    [[ "$(git -C "${mirror}" config --get backup.mode 2>/dev/null || true)" == "git-mirror" ]] || continue
    count=$((count + 1))
    if git -C "${mirror}" fsck --full >/dev/null 2>&1; then
      pc_log "Git mirror ok: ${mirror#${PC_BACKUP_ROOT}/}"
    else
      pc_warn "Git mirror failed: ${mirror#${PC_BACKUP_ROOT}/}"
      VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    fi
  done < <(find "${PC_BACKUP_ROOT}" -path "${PC_BACKUP_ROOT}/.pc-backup" -prune -o -type d -name .git -prune -print0)
  pc_log "Git mirrors verified: ${count}"
}

verify_secrets() {
  local archive
  archive="$(pc_secret_storage_dir)/encrypted-backup.tar.gpg"
  [[ -f "${archive}" ]] || { pc_log "Encrypted secrets: none"; return; }
  if ! pc_require_gpg_pass; then
    pc_warn "encrypted secrets present but passphrase is unavailable; decrypt test skipped"
    return
  fi
  pc_require_cmd gpg
  pc_require_cmd tar
  if printf '%s' "${PC_BACKUP_GPG_PASS}" | gpg --batch --quiet --pinentry-mode loopback \
    --passphrase-fd 0 --decrypt "${archive}" 2>/dev/null | tar -tf - >/dev/null 2>&1; then
    pc_log "Encrypted secrets: decrypt and archive test ok"
  else
    pc_warn "encrypted secrets verification failed"
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  fi
}

verify_tool_bundle() {
  local bundle="${PC_BACKUP_ROOT}/.pc-backup/tool" item missing=0
  for item in Makefile backup.yaml scripts/restore.sh scripts/load-config.py; do
    [[ -e "${bundle}/${item}" ]] || { pc_warn "tool bundle is missing: .pc-backup/tool/${item}"; missing=1; }
  done
  [[ ${missing} -eq 1 ]] || pc_log "Tool bundle: present"
}

main() {
  pc_validate_destination
  [[ -d "${PC_BACKUP_ROOT}/.pc-backup" ]] || pc_die "backup metadata not found: ${PC_BACKUP_ROOT}/.pc-backup"
  pc_log "=== PC backup verification ==="
  verify_manifest
  verify_git_mirrors
  verify_secrets
  verify_tool_bundle
  if [[ ${VERIFY_FAILURES} -gt 0 ]]; then
    pc_log "Verification failed: ${VERIFY_FAILURES} item(s)"
    return 1
  fi
  pc_log "Verification complete (${PC_WARNING_COUNT} warning(s))"
}

main "$@"
