#!/usr/bin/env bash
# Shared helpers for ubuntu-server-hardening scripts.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly LOG_DIR="/var/log/ubuntu-server-hardening"
readonly LOG_FILE="${LOG_DIR}/hardening.log"

log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}" 2>/dev/null || echo "[${timestamp}] [${level}] ${message}"
}

info()  { log "INFO"  "$@"; }
warn()  { log "WARN"  "$@"; }
error() { log "ERROR" "$@"; }

die() {
  error "$@"
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root (use: sudo $0)"
  fi
}

require_ubuntu() {
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS: /etc/os-release missing"
  fi

  # shellcheck source=/dev/null
  source /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    die "This script supports Ubuntu only (detected: ${ID:-unknown})"
  fi

  local major="${VERSION_ID%%.*}"
  if [[ "${major}" -lt 24 ]]; then
    warn "Tested on Ubuntu 24.04+ and 26.04 LTS. Detected: ${PRETTY_NAME:-Ubuntu}"
  else
    info "Detected: ${PRETTY_NAME:-Ubuntu}"
  fi
}

ensure_log_dir() {
  mkdir -p "${LOG_DIR}"
  chmod 750 "${LOG_DIR}"
}

backup_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    cp -a "${file}" "${file}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backed up ${file}"
  fi
}

install_packages() {
  local packages=("$@")
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${packages[@]}"
}

service_reload_safe() {
  local unit="$1"
  if systemctl is-active --quiet "${unit}"; then
    systemctl reload "${unit}" || systemctl restart "${unit}"
  fi
}

prompt_confirm() {
  local message="$1"
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    return 0
  fi
  read -r -p "${message} [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}
