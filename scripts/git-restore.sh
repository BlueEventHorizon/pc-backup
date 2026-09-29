#!/usr/bin/env bash

# Git restore functions. This file is sourced by restore.sh.

# Record a failed restore step and keep going, so that one unreachable remote or
# broken mirror does not stop the remaining repositories. restore.sh lists the
# failures at the end and exits non-zero.
pc_restore_fail() {
  PC_RESTORE_FAILURES=$((${PC_RESTORE_FAILURES:-0} + 1))
  PC_RESTORE_FAILED_ITEMS+=("$1")
  pc_log "ERROR: $1"
}

pc_restore_git_refs() {
  local mirror="$1" destination="$2" object ref
  while IFS=' ' read -r object ref; do
    [[ -n "${object}" && -n "${ref}" ]] || continue
    case "${ref}" in refs/backup-snapshots/*) continue ;; esac
    git -C "${destination}" update-ref "${ref}" "${object}" || return 1
  done < <(git -C "${mirror}" for-each-ref --format='%(objectname) %(refname)' refs)
}

pc_restore_git_state() {
  local destination="$1" state_dir="$2"
  [[ -d "${state_dir}" ]] || return 0
  if [[ -f "${state_dir}/staged.patch" ]]; then
    pc_log "Restoring staged changes: ${destination}"
    git -C "${destination}" apply --index "${state_dir}/staged.patch" || return 1
  fi
  if [[ -f "${state_dir}/unstaged.patch" ]]; then
    pc_log "Restoring unstaged changes: ${destination}"
    git -C "${destination}" apply "${state_dir}/unstaged.patch" || return 1
  fi
  if [[ -f "${state_dir}/untracked.tar.gz" ]]; then
    pc_log "Restoring untracked files: ${destination}"
    tar -xzf "${state_dir}/untracked.tar.gz" -C "${destination}" || return 1
  fi
}

pc_restore_git_path_seen() {
  local needle="$1" item
  for item in "${PC_RESTORE_GIT_PATHS[@]}"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

pc_prepare_restore_git_paths() {
  local mirror info source
  [[ "${PC_RESTORE_GIT_PATHS_READY:-0}" == "1" ]] && return 0
  pc_require_cmd git
  PC_RESTORE_GIT_PATHS_READY=1
  PC_RESTORE_GIT_PATHS=()

  while IFS= read -r -d '' mirror; do
    [[ "$(git -C "${mirror}" config --get backup.mode 2>/dev/null || true)" == "git-mirror" ]] || continue
    source=$(dirname -- "${mirror}")
    pc_restore_git_path_seen "${source}" || PC_RESTORE_GIT_PATHS+=("${source}")
  done < <(find "${PC_BACKUP_ROOT}" -path "${PC_BACKUP_ROOT}/.pc-backup" -prune -o -type d -name .git -prune -print0)

  if [[ -d "${PC_BACKUP_ROOT}/.pc-backup/git-full" ]]; then
    while IFS= read -r -d '' info; do
      source=$(sed -n '5p' "${info}")
      [[ -n "${source}" ]] || continue
      pc_restore_git_path_seen "${source}" || PC_RESTORE_GIT_PATHS+=("${source}")
    done < <(find "${PC_BACKUP_ROOT}/.pc-backup/git-full" -type f -name '*.repo-info' -print0)
  fi
}

pc_restore_one_git_mirror() {
  local mirror="$1" destination origin state_rel state_dir tmp_dir tmp_checkout
  destination=$(git -C "${mirror}" config --get backup.originalPath 2>/dev/null || true)
  origin=$(git -C "${mirror}" config --get backup.originalOrigin 2>/dev/null || true)
  state_rel=$(git -C "${mirror}" config --get backup.statePath 2>/dev/null || true)
  [[ -n "${destination}" ]] || { pc_warn "Git mirror lacks backup.originalPath: ${mirror}"; return 0; }
  [[ "${destination}" == /* ]] || { pc_warn "unsafe Git restore path: ${destination}"; return 0; }

  pc_log "Git restore: ${mirror#${PC_BACKUP_ROOT}/} -> ${destination}"
  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    return 0
  fi
  if ! git -C "${mirror}" fsck --full >/dev/null; then
    pc_restore_fail "Git mirror verification failed: ${mirror#${PC_BACKUP_ROOT}/}"
    return 0
  fi
  if ! mkdir -p "$(dirname -- "${destination}")"; then
    pc_restore_fail "cannot create parent directory: ${destination}"
    return 0
  fi
  if [[ -e "${destination}" ]]; then
    if [[ ! -d "${destination}" || -e "${destination}/.git" ]]; then
      pc_warn "Git destination already exists; skipped: ${destination}"
      return 0
    fi
    # Explicit files.mirror entries may have created the repository directory.
    # Clone separately, then merge the checkout while preserving extra files.
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/pc-backup-git-restore.XXXXXX")
    tmp_checkout="${tmp_dir}/repository"
    if ! git clone "${mirror}" "${tmp_checkout}"; then
      rm -rf -- "${tmp_dir}"
      pc_restore_fail "Git clone failed: ${mirror#${PC_BACKUP_ROOT}/} -> ${destination}"
      return 0
    fi
    if ! rsync -a "${tmp_checkout}/" "${destination}/"; then
      rm -rf -- "${tmp_dir}"
      pc_restore_fail "Git checkout copy failed: ${destination}"
      return 0
    fi
    rm -rf -- "${tmp_dir}"
  elif ! git clone "${mirror}" "${destination}"; then
    pc_restore_fail "Git clone failed: ${mirror#${PC_BACKUP_ROOT}/} -> ${destination}"
    return 0
  fi
  if ! pc_restore_git_refs "${mirror}" "${destination}"; then
    pc_restore_fail "Git refs restore failed: ${destination}"
    return 0
  fi
  if [[ -n "${origin}" ]] && ! git -C "${destination}" remote set-url origin "${origin}"; then
    pc_restore_fail "Git remote restore failed: ${destination}"
    return 0
  fi
  if [[ -n "${state_rel}" ]]; then
    state_dir="${PC_BACKUP_ROOT}/${state_rel}"
    if ! pc_restore_git_state "${destination}" "${state_dir}"; then
      pc_restore_fail "Git local changes could not be restored (repository itself was restored): ${destination}"
      return 0
    fi
  fi
}

pc_restore_repo_info() {
  local info="$1" mode="$2" destination origin head branch source
  {
    IFS= read -r destination || true
    IFS= read -r origin || true
    IFS= read -r head || true
    IFS= read -r branch || true
    IFS= read -r source || true
  } < "${info}"
  [[ -n "${destination}" && "${destination}" == /* ]] \
    || { pc_warn "invalid repository info: ${info}"; return 0; }

  if [[ "${mode}" == "git-url" ]]; then
    pc_log "Git URL restore: ${origin} -> ${destination}"
    [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
    [[ ! -e "${destination}" ]] || { pc_warn "Git destination already exists; skipped: ${destination}"; return 0; }
    [[ -n "${origin}" ]] || { pc_restore_fail "repository URL missing: ${info#${PC_BACKUP_ROOT}/}"; return 0; }
    if ! mkdir -p "$(dirname -- "${destination}")"; then
      pc_restore_fail "cannot create parent directory: ${destination}"
      return 0
    fi
    if ! git clone "${origin}" "${destination}"; then
      pc_restore_fail "Git clone failed: ${origin} -> ${destination}"
      return 0
    fi
    if [[ -n "${head}" && "$(git -C "${destination}" rev-parse HEAD 2>/dev/null || true)" != "${head}" ]]; then
      pc_warn "restored HEAD differs from recorded HEAD: ${destination}"
    fi
  else
    [[ -n "${source}" ]] || { pc_warn "Git full source missing in repository info: ${info}"; return 0; }
    pc_log "Git full restore: ${source#${PC_BACKUP_ROOT}/} -> ${destination}"
    [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
    [[ ! -e "${destination}" ]] || { pc_warn "Git destination already exists; skipped: ${destination}"; return 0; }
    if ! mkdir -p "${destination}" || ! rsync -a "${source}/" "${destination}/"; then
      pc_restore_fail "Git full restore failed: ${source#${PC_BACKUP_ROOT}/} -> ${destination}"
      return 0
    fi
  fi
}

pc_restore_git() {
  local mirror info
  pc_require_cmd git
  pc_require_cmd rsync
  pc_prepare_restore_git_paths
  while IFS= read -r -d '' mirror; do
    [[ "$(git -C "${mirror}" config --get backup.mode 2>/dev/null || true)" == "git-mirror" ]] || continue
    pc_restore_one_git_mirror "${mirror}"
  done < <(find "${PC_BACKUP_ROOT}" -path "${PC_BACKUP_ROOT}/.pc-backup" -prune -o -type d -name .git -prune -print0)
  if [[ -d "${PC_BACKUP_ROOT}/.pc-backup/git-url" ]]; then
    while IFS= read -r -d '' info; do
      pc_restore_repo_info "${info}" git-url
    done < <(find "${PC_BACKUP_ROOT}/.pc-backup/git-url" -type f -name '*.repo-info' -print0)
  fi
  if [[ -d "${PC_BACKUP_ROOT}/.pc-backup/git-full" ]]; then
    while IFS= read -r -d '' info; do
      pc_restore_repo_info "${info}" git-full
    done < <(find "${PC_BACKUP_ROOT}/.pc-backup/git-full" -type f -name '*.repo-info' -print0)
  fi
}
