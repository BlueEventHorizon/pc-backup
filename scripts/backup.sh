#!/usr/bin/env bash
# Rule-based Mac backup: regular files, Git mirrors, encrypted secrets and Brewfile.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/config.sh"
pc_load_config
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/git-backup.sh"

: "${PC_BACKUP_ENCRYPT_SECRETS:=1}"
: "${PC_BACKUP_ALLOW_PLAINTEXT_SECRETS:=0}"
: "${PC_BACKUP_DRY_RUN:=0}"
: "${PC_BACKUP_CHECK_ONLY:=0}"
# make check validates without comparing against the destination; it never writes.
[[ "${PC_BACKUP_CHECK_ONLY}" != "1" ]] || PC_BACKUP_DRY_RUN=1
: "${PC_BACKUP_RSYNC_DELETE:=1}"
: "${PC_BACKUP_RETENTION_DAYS:=30}"

PC_BACKUP_TIMESTAMP="$(pc_timestamp)"
PC_BACKUP_STARTED_AT="$(pc_iso_time)"
PC_BACKUP_FAILURES=0
PC_WARNING_COUNT=0
PC_DRY_RUN_CHANGED=0
PC_LOCK_DIR=""
PC_WORK_DIR=""
PC_LOCAL_WORK_DIR=""
PC_LOG_FILE=""

cleanup() {
  local rc=$?
  pc_release_lock
  if [[ -n "${PC_WORK_DIR:-}" && -d "${PC_WORK_DIR}" ]]; then
    rm -rf -- "${PC_WORK_DIR}"
  fi
  if [[ -n "${PC_LOCAL_WORK_DIR:-}" && -d "${PC_LOCAL_WORK_DIR}" ]]; then
    rm -rf -- "${PC_LOCAL_WORK_DIR}"
  fi
  exit "${rc}"
}
trap cleanup EXIT INT TERM

pc_record_file_manifest() {
  local source="$1" storage="$2" method="$3" status="$4"
  {
    printf '{"source":'; pc_json_string "${source}"
    printf ',"storage_path":'; pc_json_string "${storage}"
    printf ',"method":'; pc_json_string "${method}"
    printf ',"status":'; pc_json_string "${status}"
    printf '}\n'
  } >> "${PC_MANIFEST_FILES_FILE}"
}

pc_rsync_item() {
  local source="$1" destination="$2" storage_rel="$3" is_dir="$4"
  local change_file rc=0 source_real="" repo exclude_rel
  local git_excludes=()
  if [[ ! -e "${source}" ]]; then
    pc_warn "missing source: ${source}"
    pc_record_file_manifest "${source}" "${storage_rel}" "mirror" "missing"
    return 0
  fi

  if [[ "${is_dir}" == "1" ]]; then
    source_real=$(pc_absolute_path "${source}" 2>/dev/null || printf '%s' "${source%/}")
    for repo in "${PC_GIT_REPOSITORIES[@]}"; do
      if [[ "${repo}" == "${source_real}" ]]; then
        pc_dry_run_diff || pc_log "Regular mirror delegated to Git mode: ${source}"
        pc_record_file_manifest "${source}" "${storage_rel}" "mirror" "delegated-to-git"
        return 0
      fi
      if [[ "${repo}" == "${source_real}/"* ]]; then
        exclude_rel="${repo#${source_real}/}"
        git_excludes+=("${exclude_rel}")
      fi
    done
  fi

  local opts=(-a --human-readable --itemize-changes)
  [[ "${PC_BACKUP_RSYNC_DELETE}" == "1" && "${is_dir}" == "1" ]] && opts+=(--delete)
  for exclude_rel in "${git_excludes[@]}"; do
    opts+=("--exclude=/${exclude_rel}/")
  done

  if pc_dry_run_diff; then
    if [[ "${is_dir}" == "1" ]]; then
      pc_dry_run_rsync "rsync: ${source} -> ${storage_rel}" "${source}/" "${destination}/" "${opts[@]}"
    else
      pc_dry_run_rsync "rsync: ${source} -> ${storage_rel}" "${source}" "${destination}" "${opts[@]}"
    fi
    pc_record_file_manifest "${source}" "${storage_rel}" "mirror" "dry-run"
    return 0
  fi

  pc_log "rsync: ${source} -> ${storage_rel}"
  if [[ ${#git_excludes[@]} -gt 0 ]]; then
    pc_log "rsync excludes ${#git_excludes[@]} Git repository path(s) handled by Git modes"
  fi
  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    pc_record_file_manifest "${source}" "${storage_rel}" "mirror" "dry-run"
    return 0
  else
    if [[ "${is_dir}" == "1" ]]; then
      mkdir -p "${destination}"
    else
      mkdir -p "$(dirname -- "${destination}")"
    fi
    change_file="${PC_BACKUP_ROOT}/.pc-backup/changes/${PC_BACKUP_TIMESTAMP}-${storage_rel//\//_}.txt"
    if [[ "${is_dir}" == "1" ]]; then
      rsync "${opts[@]}" "${source}/" "${destination}/" > "${change_file}" 2>&1 || rc=$?
    else
      rsync "${opts[@]}" "${source}" "${destination}" > "${change_file}" 2>&1 || rc=$?
    fi
    [[ -s "${change_file}" ]] || rm -f "${change_file}"
  fi

  if [[ ${rc} -ne 0 ]]; then
    pc_warn "rsync exit ${rc}: ${source}"
    PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
    pc_record_file_manifest "${source}" "${storage_rel}" "mirror" "failed"
  else
    pc_record_file_manifest "${source}" "${storage_rel}" "mirror" "ok"
  fi
}

pc_backup_regular_files() {
  local storage destination path

  for path in "${PC_BACKUP_MIRROR_PATHS[@]}"; do
    storage=$(pc_visible_storage_rel "${path}")
    destination="${PC_BACKUP_ROOT}/${storage}"
    if [[ -d "${path}" ]]; then
      pc_rsync_item "${path}" "${destination}" "${storage}" 1
    else
      pc_rsync_item "${path}" "${destination}" "${storage}" 0
    fi
  done
}

pc_secret_add_unique() {
  local item="$1" existing
  for existing in "${PC_SECRET_ITEMS[@]}"; do
    [[ "${existing}" == "${item}" ]] && return 0
  done
  PC_SECRET_ITEMS+=("${item}")
}

pc_collect_secret_items() {
  local path absolute home_real
  home_real=$(cd -- "${HOME}" 2>/dev/null && pwd -P || printf '%s' "${HOME}")
  PC_SECRET_ITEMS=()
  for path in "${PC_BACKUP_SECRET_PATHS[@]}"; do
    absolute=$(pc_absolute_path "${path}" 2>/dev/null || true)
    [[ -n "${absolute}" && -e "${absolute}" ]] || { pc_warn "secret path missing: ${path}"; continue; }
    if [[ "${absolute}" == "${HOME}/"* ]]; then
      pc_secret_add_unique "${absolute#${HOME}/}"
    elif [[ "${absolute}" == "${home_real}/"* ]]; then
      pc_secret_add_unique "${absolute#${home_real}/}"
    else
      pc_warn "secret path must be below HOME: ${absolute}"
      PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
    fi
  done
}

pc_collect_secret_socket_excludes() {
  local item socket
  PC_SECRET_SOCKET_EXCLUDES=()
  for item in "${PC_SECRET_ITEMS[@]}"; do
    while IFS= read -r -d '' socket; do
      PC_SECRET_SOCKET_EXCLUDES+=("${socket}")
    done < <(
      cd "${HOME}"
      find "${item}" -type s -print0
    )
  done
}

pc_backup_secrets() {
  local bundle tmp_gpg latest dated plaintext_latest secret_dir history_dir socket
  local tar_opts=()
  pc_collect_secret_items
  [[ ${#PC_SECRET_ITEMS[@]} -gt 0 ]] || { pc_log "Secrets: no existing paths configured"; return 0; }

  pc_log "Secrets: ${#PC_SECRET_ITEMS[@]} path(s)"
  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    pc_log "DRY-RUN: would create encrypted secrets archive"
    return 0
  fi

  pc_require_cmd tar
  bundle="${PC_WORK_DIR}/secrets.tar"
  pc_collect_secret_socket_excludes
  tar_opts=(-cf "${bundle}")
  for socket in "${PC_SECRET_SOCKET_EXCLUDES[@]}"; do
    tar_opts+=("--exclude=${socket}")
  done
  if [[ ${#PC_SECRET_SOCKET_EXCLUDES[@]} -gt 0 ]]; then
    pc_log "Secrets: excluded ${#PC_SECRET_SOCKET_EXCLUDES[@]} Unix socket(s)"
  fi
  (
    cd "${HOME}"
    tar "${tar_opts[@]}" \
      --exclude='.ssh/agent' \
      --exclude='.gnupg/S.*' \
      --exclude='.gnupg/*.socket' \
      "${PC_SECRET_ITEMS[@]}"
  )

  secret_dir=$(pc_secret_storage_dir)
  history_dir="${PC_BACKUP_ROOT}/.pc-backup/secrets-history"
  mkdir -p "${secret_dir}" "${history_dir}"
  latest="${secret_dir}/encrypted-backup.tar.gpg"
  dated="${history_dir}/secrets-${PC_BACKUP_TIMESTAMP}.tar.gpg"
  plaintext_latest="${secret_dir}/plaintext-backup.tar"

  if [[ "${PC_BACKUP_ENCRYPT_SECRETS}" == "1" ]]; then
    pc_require_cmd gpg
    pc_require_gpg_pass 1 \
      || pc_die "GPG passphrase unavailable; add it to Keychain or run interactively"
    tmp_gpg="${PC_WORK_DIR}/secrets.tar.gpg"
    printf '%s' "${PC_BACKUP_GPG_PASS}" | gpg --batch --yes --pinentry-mode loopback \
      --passphrase-fd 0 --symmetric --cipher-algo AES256 \
      --output "${tmp_gpg}" "${bundle}"
    cp "${tmp_gpg}" "${dated}"
    cp "${tmp_gpg}" "${latest}.tmp"
    mv "${latest}.tmp" "${latest}"
    chmod 600 "${dated}" "${latest}"
    rm -f "${plaintext_latest}"
    pc_log "Encrypted secrets: ${latest#${PC_BACKUP_ROOT}/}"
  else
    [[ "${PC_BACKUP_ALLOW_PLAINTEXT_SECRETS}" == "1" ]] \
      || pc_die "plaintext secrets refused; enable encryption"
    cp "${bundle}" "${plaintext_latest}.tmp"
    mv "${plaintext_latest}.tmp" "${plaintext_latest}"
    chmod 600 "${plaintext_latest}"
    pc_warn "secrets stored as plaintext by explicit configuration"
  fi
}

pc_backup_brew() {
  [[ "${PC_BACKUP_BREW:-1}" == "1" ]] || { pc_log "Brewfile: disabled"; return 0; }
  [[ -x "${SCRIPT_DIR}/brewfile-update.sh" ]] || return 0
  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    pc_log "DRY-RUN: would refresh Brewfile"
  elif command -v brew >/dev/null 2>&1; then
    "${SCRIPT_DIR}/brewfile-update.sh" "${PC_BACKUP_ROOT}/.pc-backup/homebrew" >> "${PC_LOG_FILE}" 2>&1 \
      || pc_warn "Brewfile update failed"
  else
    pc_warn "brew not found; Brewfile skipped"
  fi
}

pc_write_manifest() {
  local status="success" target tmp
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
  [[ ${PC_BACKUP_FAILURES} -eq 0 ]] || status="partial_failure"
  if [[ ${PC_BACKUP_FAILURES} -eq 0 && ${PC_WARNING_COUNT} -gt 0 ]]; then
    status="success_with_warnings"
  fi
  mkdir -p "${PC_BACKUP_ROOT}/.pc-backup/manifests"
  tmp="${PC_WORK_DIR}/manifest.json"
  {
    printf '{\n  "schema_version": 1,\n  "backup_id": '; pc_json_string "${PC_BACKUP_TIMESTAMP}"
    printf ',\n  "started_at": '; pc_json_string "${PC_BACKUP_STARTED_AT}"
    printf ',\n  "completed_at": '; pc_json_string "$(pc_iso_time)"
    printf ',\n  "hostname": '; pc_json_string "$(hostname)"
    printf ',\n  "status": '; pc_json_string "${status}"
    printf ',\n  "warnings": %s,\n  "failures": %s,\n  "repositories": ' "${PC_WARNING_COUNT}" "${PC_BACKUP_FAILURES}"
    pc_manifest_join_array "${PC_MANIFEST_REPOS_FILE}"
    printf ',\n  "files": '
    pc_manifest_join_array "${PC_MANIFEST_FILES_FILE}"
    printf '\n}\n'
  } > "${tmp}"
  target="${PC_BACKUP_ROOT}/.pc-backup/manifests/manifest-${PC_BACKUP_TIMESTAMP}.json"
  cp "${tmp}" "${target}"
  cp "${tmp}" "${PC_BACKUP_ROOT}/.pc-backup/manifests/manifest-latest.json.tmp"
  mv "${PC_BACKUP_ROOT}/.pc-backup/manifests/manifest-latest.json.tmp" \
    "${PC_BACKUP_ROOT}/.pc-backup/manifests/manifest-latest.json"
}

# Keep this tool and the active configuration inside the backup so that a new
# Mac can restore without a separate checkout of this project or backup.yaml.
pc_backup_tool_bundle() {
  local bundle="${PC_BACKUP_ROOT}/.pc-backup/tool" project_real root_real tmp previous item local_tool
  local items=(Makefile README.md requirements.txt scripts)
  project_real=$(pc_absolute_path "${PROJECT_ROOT}" 2>/dev/null || printf '%s' "${PROJECT_ROOT}")
  root_real=$(pc_absolute_path "${PC_BACKUP_ROOT}" 2>/dev/null || printf '%s' "${PC_BACKUP_ROOT%/}")
  if [[ "${project_real}" == "${root_real}" || "${project_real}" == "${root_real}/"* ]]; then
    pc_log "Tool bundle: running from inside the backup destination; not updated"
    return 0
  fi
  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    pc_log "DRY-RUN: would update tool bundle: .pc-backup/tool"
    return 0
  fi

  # Build the bundle on local disk; replace the one in the destination only
  # when its content differs, so cloud storage does not re-sync it every run.
  local_tool=$(mktemp -d "${PC_LOCAL_WORK_DIR}/tool.XXXXXX")
  for item in "${items[@]}"; do
    [[ -e "${PROJECT_ROOT}/${item}" ]] || continue
    if ! rsync -a --exclude=__pycache__ --exclude=.DS_Store "${PROJECT_ROOT}/${item}" "${local_tool}/"; then
      rm -rf -- "${local_tool}"
      pc_warn "failed to copy tool bundle item: ${item}"
      PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
      return 0
    fi
  done
  if ! cp -- "${PC_BACKUP_ACTIVE_CONFIG}" "${local_tool}/backup.yaml" || ! chmod 600 "${local_tool}/backup.yaml"; then
    rm -rf -- "${local_tool}"
    pc_warn "failed to copy configuration into tool bundle: ${PC_BACKUP_ACTIVE_CONFIG}"
    PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
    return 0
  fi
  if [[ -d "${bundle}" ]] && diff -rq "${local_tool}" "${bundle}" >/dev/null 2>&1; then
    rm -rf -- "${local_tool}"
    pc_log "Tool bundle unchanged: .pc-backup/tool"
    return 0
  fi
  tmp=$(mktemp -d "${PC_BACKUP_ROOT}/.pc-backup/.tool.XXXXXX")
  previous="${tmp}.previous"
  if ! rsync -a "${local_tool}/" "${tmp}/"; then
    rm -rf -- "${tmp}" "${local_tool}"
    pc_warn "failed to copy tool bundle: ${bundle}"
    PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
    return 0
  fi
  rm -rf -- "${local_tool}"
  if [[ -e "${bundle}" ]] && ! mv -- "${bundle}" "${previous}"; then
    rm -rf -- "${tmp}"
    pc_warn "failed to replace tool bundle: ${bundle}"
    PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
    return 0
  fi
  if ! mv -- "${tmp}" "${bundle}"; then
    [[ ! -e "${previous}" ]] || mv -- "${previous}" "${bundle}" || true
    rm -rf -- "${tmp}"
    pc_warn "failed to replace tool bundle: ${bundle}"
    PC_BACKUP_FAILURES=$((PC_BACKUP_FAILURES + 1))
    return 0
  fi
  rm -rf -- "${previous}"
  pc_log "Tool bundle updated: .pc-backup/tool (config: ${PC_BACKUP_ACTIVE_CONFIG})"
}

pc_prune_old_metadata() {
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] && return 0
  find "${PC_BACKUP_ROOT}/.pc-backup/changes" -type f -name '*.txt' -mtime "+${PC_BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
  find "${PC_BACKUP_ROOT}/.pc-backup/logs" -type f -name '*.log' -mtime "+${PC_BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
  find "${PC_BACKUP_ROOT}/.pc-backup/manifests" -type f -name 'manifest-2*.json' -mtime "+${PC_BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
  find "${PC_BACKUP_ROOT}/.pc-backup/secrets-history" -type f -name 'secrets-2*.tar.gpg' -mtime "+${PC_BACKUP_RETENTION_DAYS}" -delete 2>/dev/null || true
}

main() {
  pc_require_cmd rsync
  pc_validate_destination
  pc_validate_absolute_paths PC_BACKUP_MIRROR_PATHS "${PC_BACKUP_MIRROR_PATHS[@]}"
  pc_validate_absolute_paths PC_BACKUP_GIT_ROOTS "${PC_BACKUP_GIT_ROOTS[@]}"
  pc_validate_absolute_paths PC_BACKUP_GIT_URL_ONLY_PATHS "${PC_BACKUP_GIT_URL_ONLY_PATHS[@]}"
  pc_validate_absolute_paths PC_BACKUP_GIT_FULL_PATHS "${PC_BACKUP_GIT_FULL_PATHS[@]}"
  pc_validate_absolute_paths PC_BACKUP_GIT_SKIP_PATHS "${PC_BACKUP_GIT_SKIP_PATHS[@]}"
  pc_validate_absolute_paths PC_BACKUP_SECRET_PATHS "${PC_BACKUP_SECRET_PATHS[@]}"
  pc_validate_source_destination_separation PC_BACKUP_MIRROR_PATHS "${PC_BACKUP_MIRROR_PATHS[@]}"
  pc_validate_source_destination_separation PC_BACKUP_GIT_ROOTS "${PC_BACKUP_GIT_ROOTS[@]}"
  pc_validate_source_destination_separation PC_BACKUP_SECRET_PATHS "${PC_BACKUP_SECRET_PATHS[@]}"
  case "${PC_BACKUP_GIT_DEFAULT_MODE}" in git-mirror|git-url|git-full|skip) ;; *) pc_die "invalid PC_BACKUP_GIT_DEFAULT_MODE" ;; esac
  case "${PC_BACKUP_GIT_DIRTY_MODE}" in backup|warn|fail) ;; *) pc_die "invalid PC_BACKUP_GIT_DIRTY_MODE" ;; esac
  case "${PC_BACKUP_GIT_LFS_MODE}" in local|warn|skip) ;; *) pc_die "invalid PC_BACKUP_GIT_LFS_MODE" ;; esac

  if [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    PC_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pc-backup-dry-run.XXXXXX")
  else
    mkdir -p "${PC_BACKUP_ROOT}/.pc-backup/logs" "${PC_BACKUP_ROOT}/.pc-backup/changes"
    PC_LOG_FILE="${PC_BACKUP_ROOT}/.pc-backup/logs/${PC_BACKUP_TIMESTAMP}.log"
    PC_WORK_DIR=$(mktemp -d "${PC_BACKUP_ROOT}/.pc-backup/.work.XXXXXX")
  fi
  # New Git mirrors are built and checked here (local disk), not in the destination.
  PC_LOCAL_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pc-backup-local.XXXXXX")
  PC_MANIFEST_REPOS_FILE="${PC_WORK_DIR}/repositories.jsonl"
  PC_MANIFEST_FILES_FILE="${PC_WORK_DIR}/files.jsonl"
  : > "${PC_MANIFEST_REPOS_FILE}"
  : > "${PC_MANIFEST_FILES_FILE}"

  pc_acquire_lock
  pc_log "=== PC backup start ==="
  pc_log "Destination: ${PC_BACKUP_ROOT}"
  if [[ "${PC_BACKUP_CHECK_ONLY}" == "1" ]]; then
    pc_log "Mode: check (no comparison with destination)"
  elif [[ "${PC_BACKUP_DRY_RUN}" == "1" ]]; then
    pc_log "Mode: dry-run (only changes against the destination are shown)"
  fi

  pc_backup_brew
  pc_prepare_git_repositories
  pc_backup_regular_files
  pc_backup_git_repositories
  pc_backup_secrets
  pc_backup_tool_bundle
  pc_write_manifest
  pc_prune_old_metadata

  if [[ ${PC_BACKUP_FAILURES} -gt 0 ]]; then
    pc_log "=== PC backup completed with ${PC_BACKUP_FAILURES} failure(s) ==="
    return 1
  fi
  pc_dry_run_diff && pc_log "DRY-RUN: ${PC_DRY_RUN_CHANGED} file/Git item(s) with changes (secrets, Brewfile and tool bundle are rewritten every run)"
  pc_log "=== PC backup complete (${PC_WARNING_COUNT} warning(s)) ==="
  [[ "${PC_BACKUP_DRY_RUN}" == "1" ]] || du -sh "${PC_BACKUP_ROOT}" 2>/dev/null | tee -a "${PC_LOG_FILE}" || true
}

main "$@"
