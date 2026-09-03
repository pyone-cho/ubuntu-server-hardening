#!/usr/bin/env bash
#
# Outline VPN Server Installer
# Target: Ubuntu 26.04 LTS (also compatible with 24.04+)
#
# Installs Docker and the official Outline Server.
# Run harden-server.sh first, then this script.
#
# Usage:
#   sudo ./scripts/install-outline.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OUTLINE_INSTALL_URL="https://raw.githubusercontent.com/Jigsaw-Code/outline-server/master/src/server_manager/install_scripts/install_server.sh"
OUTLINE_OUTPUT_FILE="/root/outline-api-credentials.json"

load_env() {
  local env_file="${PROJECT_ROOT}/.env"
  if [[ -f "${env_file}" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "${env_file}"
    set +a
  fi
}

install_docker() {
  if command -v docker &>/dev/null; then
    info "Docker already installed: $(docker --version)"
    return
  fi

  info "Installing Docker..."
  install_packages ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  # shellcheck source=/dev/null
  source /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${VERSION_CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  info "Docker installed: $(docker --version)"
}

run_outline_installer() {
  info "Running official Outline Server installer..."
  info "Source: ${OUTLINE_INSTALL_URL}"

  local tmp_log
  tmp_log="$(mktemp)"
  trap 'rm -f "${tmp_log}"' EXIT

  # Official installer is interactive for hostname confirmation; pipe yes for automation
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
  bash -c "$(curl -fsSL "${OUTLINE_INSTALL_URL}")" 2>&1 | tee "${tmp_log}"
  else
    bash -c "$(curl -fsSL "${OUTLINE_INSTALL_URL}")" 2>&1 | tee "${tmp_log}"
  fi

  # Parse API URL and cert from installer output
  local api_url api_cert api_port
  api_url="$(grep -oP 'apiUrl":"\K[^"]+' "${tmp_log}" 2>/dev/null | head -1 || true)"
  api_cert="$(grep -oP 'certSha256":"\K[^"]+' "${tmp_log}" 2>/dev/null | head -1 || true)"

  if [[ -z "${api_url}" ]]; then
    # Fallback: look for JSON block in output
    api_url="$(sed -n 's/.*"apiUrl"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${tmp_log}" | head -1)"
    api_cert="$(sed -n 's/.*"certSha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${tmp_log}" | head -1)"
  fi

  if [[ -n "${api_url}" ]]; then
    api_port="$(echo "${api_url}" | grep -oP ':\K[0-9]+(?=/)' || echo "")"
    cat > "${OUTLINE_OUTPUT_FILE}" <<EOF
{
  "apiUrl": "${api_url}",
  "certSha256": "${api_cert}",
  "apiPort": "${api_port}",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 600 "${OUTLINE_OUTPUT_FILE}"
    info "Credentials saved to ${OUTLINE_OUTPUT_FILE}"
  else
    warn "Could not parse API credentials from installer output — check ${tmp_log} manually"
  fi
}

open_outline_firewall_ports() {
  if ! command -v ufw &>/dev/null || ! ufw status | grep -q "Status: active"; then
    warn "UFW not active — configure firewall manually for Outline ports"
    return
  fi

  if [[ -f "${OUTLINE_OUTPUT_FILE}" ]]; then
    local api_port
    api_port="$(grep -oP '"apiPort": "\K[0-9]+' "${OUTLINE_OUTPUT_FILE}" 2>/dev/null || true)"
    if [[ -n "${api_port}" ]]; then
      ufw allow "${api_port}/tcp" comment 'Outline management API'
      info "UFW: allowed Outline API port ${api_port}/tcp"
    fi
  fi

  info "Outline access-key ports are assigned when you create keys in Outline Manager."
  info "After creating keys, allow each port: sudo ufw allow <port>/tcp comment 'Outline access key'"
}

print_summary() {
  echo ""
  echo "=============================================="
  echo "  Outline VPN Server installed"
  echo "=============================================="

  if [[ -f "${OUTLINE_OUTPUT_FILE}" ]]; then
    echo ""
    echo "  API credentials: ${OUTLINE_OUTPUT_FILE}"
    echo ""
    cat "${OUTLINE_OUTPUT_FILE}"
    echo ""
    echo "  Add this server in Outline Manager (desktop app):"
    echo "  https://getoutline.org/get-started/"
  else
    echo ""
    echo "  Check installer output above for apiUrl and certSha256."
  fi

  echo ""
  echo "  Docker containers:"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
  echo "=============================================="
  echo ""
  echo "Important:"
  echo "  - Save apiUrl and certSha256 in a password manager"
  echo "  - Open access-key ports in UFW when keys are created"
  echo "  - Reboot is not required"
  echo ""
}

main() {
  require_root
  require_ubuntu
  ensure_log_dir
  load_env

  info "Starting Outline VPN server installation..."

  if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
    if ! prompt_confirm "Install Docker and Outline Server?"; then
      die "Aborted by user"
    fi
  fi

  install_docker
  run_outline_installer
  open_outline_firewall_ports
  print_summary

  info "Outline installation finished"
}

main "$@"
