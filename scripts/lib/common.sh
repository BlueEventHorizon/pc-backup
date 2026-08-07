#!/usr/bin/env bash

# Shared helpers. Keep compatible with macOS Bash 3.2.

pc_timestamp() {
  date '+%Y%m%d-%H%M%S'
}

pc_iso_time() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

pc_log() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "${line}"
  if [[ -n "${PC_LOG_FILE:-}" ]]; then
    printf '%s\n' "${line}" >> "${PC_LOG_FILE}"
  fi
}

pc_warn() {
  pc_log "WARN: $*"
  PC_WARNING_COUNT=$((${PC_WARNING_COUNT:-0} + 1))
}

pc_die() {
  pc_log "ERROR: $*" >&2
  exit 1
}

pc_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || pc_die "required command not found: $1"
}

pc_json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "${value}"
}

pc_json_string() {
  printf '"%s"' "$(pc_json_escape "$1")"
}

pc_contains_path() {
  local needle="$1" needle_real item_real
  shift
  local item
  needle_real=$(pc_absolute_path "${needle}" 2>/dev/null || printf '%s' "${needle%/}")
  for item in "$@"; do
    item_real=$(pc_absolute_path "${item}" 2>/dev/null || printf '%s' "${item%/}")
    [[ "${item_real%/}" == "${needle_real%/}" ]] && return 0
  done
  return 1
}

pc_path_is_equal_or_below_any() {
  local needle="$1" needle_real item item_real
  shift
  needle_real=$(pc_absolute_path "${needle}" 2>/dev/null || printf '%s' "${needle%/}")
  for item in "$@"; do
    item_real=$(pc_absolute_path "${item}" 2>/dev/null || printf '%s' "${item%/}")
    if [[ "${needle_real}" == "${item_real}" || "${needle_real}" == "${item_real}/"* ]]; then
      return 0
    fi
  done
  return 1
}

pc_absolute_path() {
  local input="$1" parent name
  if [[ -d "${input}" ]]; then
    (cd -- "${input}" 2>/dev/null && pwd -P)
    return
  fi
  parent=$(dirname -- "${input}")
  name=$(basename -- "${input}")
  parent=$(cd -- "${parent}" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "${parent}" "${name}"
}

pc_storage_rel() {
  local path="${1%/}" home_real home_logical
  home_real=$(cd -- "${HOME}" 2>/dev/null && pwd -P || printf '%s' "${HOME}")
  home_logical=$(cd -- "${HOME}" 2>/dev/null && pwd -L || printf '%s' "${HOME}")
  if [[ "${path}" == "${HOME}" || "${path}" == "${home_logical}" || "${path}" == "${home_real}" ]]; then
    printf 'home\n'
  elif [[ "${path}" == "${HOME}/"* ]]; then
    printf 'home/%s\n' "${path#${HOME}/}"
  elif [[ "${path}" == "${home_logical}/"* ]]; then
    printf 'home/%s\n' "${path#${home_logical}/}"
  elif [[ "${path}" == "${home_real}/"* ]]; then
    printf 'home/%s\n' "${path#${home_real}/}"
  else
    printf 'absolute/%s\n' "${path#/}"
  fi
}

# User-facing storage path. Paths below HOME keep the same relative path that
# appears in YAML. External absolute paths are grouped below _absolute/.
pc_visible_storage_rel() {
  local storage
  storage=$(pc_storage_rel "${1%/}")
  case "${storage}" in
    home/*) printf '%s\n' "${storage#home/}" ;;
    home) printf '_home\n' ;;
    absolute/*) printf '_absolute/%s\n' "${storage#absolute/}" ;;
    *) printf '%s\n' "${storage}" ;;
  esac
}

pc_secret_storage_dir() {
  local anchor=""
  if [[ ${#PC_BACKUP_SECRET_PATHS[@]} -gt 0 ]]; then
    anchor="${PC_BACKUP_SECRET_PATHS[0]}"
  fi
  if [[ -n "${anchor}" ]]; then
    printf '%s/%s\n' "${PC_BACKUP_ROOT}" "$(pc_visible_storage_rel "${anchor}")"
  else
    printf '%s/.pc-backup/secrets\n' "${PC_BACKUP_ROOT}"
  fi
}

pc_validate_destination() {
  [[ -n "${PC_BACKUP_ROOT:-}" ]] || pc_die "PC_BACKUP_ROOT is unset"
  [[ "${PC_BACKUP_ROOT}" == /* ]] || pc_die "PC_BACKUP_ROOT must be an absolute path"
  [[ "${PC_BACKUP_ROOT}" != "/" && "${PC_BACKUP_ROOT}" != "${HOME}" ]] \
    || pc_die "unsafe PC_BACKUP_ROOT: ${PC_BACKUP_ROOT}"

  if [[ -n "${PC_BACKUP_DESTINATION_ID:-}" ]]; then
    local marker="${PC_BACKUP_ROOT}/.pc-backup-destination" actual=""
    [[ -f "${marker}" ]] || pc_die "destination is not initialized: run scripts/init-backup-destination.sh"
    IFS= read -r actual < "${marker}" || true
    [[ "${actual}" == "${PC_BACKUP_DESTINATION_ID}" ]] \
      || pc_die "destination ID mismatch: ${PC_BACKUP_ROOT}"
  fi
}

pc_validate_absolute_paths() {
  local label="$1" path
  shift
  for path in "$@"; do
    [[ "${path}" == /* ]] || pc_die "${label} requires absolute paths: ${path}"
  done
}

pc_validate_source_destination_separation() {
  local label="$1" destination_real source source_real
  shift
  destination_real=$(pc_absolute_path "${PC_BACKUP_ROOT}" 2>/dev/null \
    || printf '%s' "${PC_BACKUP_ROOT%/}")

  for source in "$@"; do
    source_real=$(pc_absolute_path "${source}" 2>/dev/null \
      || printf '%s' "${source%/}")
    if [[ "${source_real}" == "${destination_real}" \
      || "${source_real}" == "${destination_real}/"* \
      || "${destination_real}" == "${source_real}/"* ]]; then
      pc_die "${label} overlaps backup destination: ${source} <-> ${PC_BACKUP_ROOT}"
    fi
  done
}

pc_acquire_lock() {
  [[ "${PC_BACKUP_DRY_RUN:-0}" == "1" ]] && return 0
  local lock_root="${PC_BACKUP_ROOT}/.pc-backup/locks"
  PC_LOCK_DIR="${lock_root}/backup.lock"
  mkdir -p "${lock_root}"
  if ! mkdir "${PC_LOCK_DIR}" 2>/dev/null; then
    local detail=""
    [[ -f "${PC_LOCK_DIR}/owner" ]] && detail=$(tr '\n' ' ' < "${PC_LOCK_DIR}/owner")
    pc_die "another backup appears to be running (${detail:-unknown owner})"
  fi
  {
    printf 'pid=%s\n' "$$"
    printf 'host=%s\n' "$(hostname)"
    printf 'started=%s\n' "$(pc_iso_time)"
  } > "${PC_LOCK_DIR}/owner"
}

pc_release_lock() {
  if [[ -n "${PC_LOCK_DIR:-}" && -d "${PC_LOCK_DIR}" ]]; then
    rm -f "${PC_LOCK_DIR}/owner"
    rmdir "${PC_LOCK_DIR}" 2>/dev/null || true
  fi
}

pc_manifest_join_array() {
  local file="$1" first=1 line
  printf '['
  if [[ -f "${file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -n "${line}" ]] || continue
      [[ ${first} -eq 1 ]] || printf ','
      printf '\n    %s' "${line}"
      first=0
    done < "${file}"
  fi
  [[ ${first} -eq 1 ]] || printf '\n  '
  printf ']'
}

pc_tar_is_safe() {
  local archive="$1" entry
  while IFS= read -r entry || [[ -n "${entry}" ]]; do
    case "${entry}" in
      /*|../*|*/../*|*/..) return 1 ;;
    esac
  done < <(tar -tf "${archive}")
  return 0
}
