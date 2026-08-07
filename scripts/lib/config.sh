#!/usr/bin/env bash

# Load and validate backup.yaml through PyYAML.

pc_load_config() {
  local config_path="${PC_BACKUP_CONFIG:-}" generated python_command=""
  local venv_dir="${PC_BACKUP_VENV_DIR:-${PROJECT_ROOT}/.venv}"

  if [[ -z "${config_path}" ]]; then
    if [[ -f "${PROJECT_ROOT}/backup.yaml" ]]; then
      config_path="${PROJECT_ROOT}/backup.yaml"
    elif [[ -f "${PROJECT_ROOT}/backup.yml" ]]; then
      config_path="${PROJECT_ROOT}/backup.yml"
    else
      printf 'ERROR: backup.yaml was not found in %s\n' "${PROJECT_ROOT}" >&2
      return 2
    fi
  fi

  case "${config_path}" in
    *.yaml|*.yml)
      if [[ -n "${PC_BACKUP_PYTHON:-}" ]] && "${PC_BACKUP_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
        python_command="${PC_BACKUP_PYTHON}"
      elif [[ -x "${venv_dir}/bin/python" ]] && \
        "${venv_dir}/bin/python" -c 'import yaml' >/dev/null 2>&1; then
        python_command="${venv_dir}/bin/python"
      elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        python_command=$(command -v python3)
      else
        printf 'Python/PyYAML is not ready; starting dependency setup.\n' >&2
        "${SCRIPT_DIR}/setup-dependencies.sh" || {
          printf 'ERROR: dependencies unavailable. Run: %s/setup-dependencies.sh\n' "${SCRIPT_DIR}" >&2
          return 2
        }
        python_command="${venv_dir}/bin/python"
      fi
      generated=$("${python_command}" "${SCRIPT_DIR}/load-config.py" "${config_path}") || return $?
      # The Python loader validates every field and shell-quotes every value.
      eval "${generated}"
      ;;
    *) printf 'ERROR: configuration must be a YAML file: %s\n' "${config_path}" >&2; return 2 ;;
  esac
  PC_BACKUP_ACTIVE_CONFIG="${config_path}"
}

pc_load_gpg_pass_from_keychain() {
  [[ -n "${PC_BACKUP_GPG_PASS:-}" ]] && return 0
  [[ -n "${PC_BACKUP_GPG_KEYCHAIN_ACCOUNT:-}" && -n "${PC_BACKUP_GPG_KEYCHAIN_SERVICE:-}" ]] || return 0
  command -v security >/dev/null 2>&1 || return 0
  PC_BACKUP_GPG_PASS=$(security find-generic-password \
    -a "${PC_BACKUP_GPG_KEYCHAIN_ACCOUNT}" \
    -s "${PC_BACKUP_GPG_KEYCHAIN_SERVICE}" -w 2>/dev/null || true)
}

pc_require_gpg_pass() {
  local confirm="${1:-0}" confirmation=""
  pc_load_gpg_pass_from_keychain
  [[ -n "${PC_BACKUP_GPG_PASS:-}" ]] && return 0

  # LaunchAgent and redirected/non-interactive runs have no terminal to prompt.
  [[ -t 0 || -t 1 || -t 2 ]] || return 1

  printf 'GPG passphrase (not found in Keychain): ' > /dev/tty
  IFS= read -r -s PC_BACKUP_GPG_PASS < /dev/tty || return 1
  printf '\n' > /dev/tty
  [[ -n "${PC_BACKUP_GPG_PASS}" ]] || return 1

  if [[ "${confirm}" == "1" ]]; then
    printf 'Confirm GPG passphrase: ' > /dev/tty
    IFS= read -r -s confirmation < /dev/tty || return 1
    printf '\n' > /dev/tty
    if [[ "${PC_BACKUP_GPG_PASS}" != "${confirmation}" ]]; then
      PC_BACKUP_GPG_PASS=""
      confirmation=""
      printf 'ERROR: passphrases do not match.\n' >&2
      return 1
    fi
  fi
  confirmation=""
  return 0
}
