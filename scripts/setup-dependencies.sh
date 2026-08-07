#!/usr/bin/env bash
# Environment-aware bootstrap for Python and PyYAML on macOS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${PC_BACKUP_VENV_DIR:-${PROJECT_ROOT}/.venv}"
ASSUME_YES=0
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Usage: setup-dependencies.sh [--yes] [--check]

  --yes    perform required installs without confirmation
  --check  check only; do not install anything
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

has_pyyaml() {
  "$1" -c 'import sys, yaml; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' \
    >/dev/null 2>&1
}

find_ready_python() {
  local candidate
  if [[ -n "${PC_BACKUP_PYTHON:-}" ]] && has_pyyaml "${PC_BACKUP_PYTHON}"; then
    printf '%s\n' "${PC_BACKUP_PYTHON}"
    return 0
  fi
  if [[ -x "${VENV_DIR}/bin/python" ]] && has_pyyaml "${VENV_DIR}/bin/python"; then
    printf '%s\n' "${VENV_DIR}/bin/python"
    return 0
  fi
  candidate=$(command -v python3 2>/dev/null || true)
  if [[ -n "${candidate}" ]] && has_pyyaml "${candidate}"; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  return 1
}

find_base_python() {
  local candidate
  candidate=$(command -v python3 2>/dev/null || true)
  if [[ -n "${candidate}" ]] && "${candidate}" -c \
    'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
    printf '%s\n' "${candidate}"
    return 0
  fi
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [[ -x "${candidate}" ]] && "${candidate}" -c \
      'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

confirm() {
  local prompt="$1" answer
  [[ ${ASSUME_YES} -eq 0 ]] || return 0
  [[ -t 0 || -t 1 || -t 2 ]] || return 1
  printf '%s [y/N] ' "${prompt}" > /dev/tty
  IFS= read -r answer < /dev/tty || return 1
  case "${answer}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

ready=$(find_ready_python || true)
if [[ -n "${ready}" ]]; then
  printf 'Dependencies ready: %s (PyYAML available)\n' "${ready}"
  exit 0
fi

if [[ ${CHECK_ONLY} -eq 1 ]]; then
  printf 'Dependencies missing: Python 3.8+ with PyYAML is required.\n' >&2
  printf 'Run: %s/setup-dependencies.sh\n' "${SCRIPT_DIR}" >&2
  exit 1
fi

base_python=$(find_base_python || true)
if [[ -z "${base_python}" ]]; then
  if command -v brew >/dev/null 2>&1; then
    if ! confirm 'Python 3.8+ was not found. Install Homebrew Python now?'; then
      printf 'Installation cancelled. Run later: brew install python\n' >&2
      exit 1
    fi
    brew install python
    base_python=$(find_base_python || true)
  else
    cat >&2 <<'EOF'
ERROR: Python 3.8+ was not found and Homebrew is unavailable.
Install Python from https://www.python.org/downloads/macos/ or install Homebrew,
then run scripts/setup-dependencies.sh again.
EOF
    exit 1
  fi
fi

[[ -n "${base_python}" ]] || {
  printf 'ERROR: Python installation completed but python3 is still unavailable.\n' >&2
  exit 1
}

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  if ! confirm "Create project virtual environment at ${VENV_DIR}?"; then
    printf 'Installation cancelled.\n' >&2
    exit 1
  fi
  "${base_python}" -m venv "${VENV_DIR}"
fi

if ! has_pyyaml "${VENV_DIR}/bin/python"; then
  if ! confirm 'Install PyYAML into the project virtual environment?'; then
    printf 'Installation cancelled.\n' >&2
    exit 1
  fi
  "${VENV_DIR}/bin/python" -m pip install -r "${PROJECT_ROOT}/requirements.txt"
fi

if ! has_pyyaml "${VENV_DIR}/bin/python"; then
  printf 'ERROR: PyYAML installation could not be verified.\n' >&2
  exit 1
fi

printf 'Dependencies installed: %s\n' "${VENV_DIR}/bin/python"
