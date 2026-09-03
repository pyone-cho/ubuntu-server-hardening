#!/usr/bin/env bash
#
# Ubuntu Server Hardening Script
# Target: Ubuntu 26.04 LTS (also compatible with 24.04+)
#
# Run AFTER you have confirmed SSH key access works.
# Usage:
#   cp .env.example .env && nano .env
#   sudo ./scripts/harden-server.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Defaults (overridden by .env)
SSH_PORT="${SSH_PORT:-22}"
ADMIN_USER="${ADMIN_USER:-ubuntu}"
LOCK_ROOT="${LOCK_ROOT:-1}"
SSH_ALLOWED_USERS="${SSH_ALLOWED_USERS:-ubuntu}"
OUTLINE_API_PORT="${OUTLINE_API_PORT:-}"
EXTRA_TCP_PORTS="${EXTRA_TCP_PORTS:-}"
SKIP_UPGRADE="${SKIP_UPGRADE:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

CONFIG_DIR="${PROJECT_ROOT}/config"

load_env() {
  local env_file="${PROJECT_ROOT}/.env"
  if [[ -f "${env_file}" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "${env_file}"
    set +a
    info "Loaded configuration from ${env_file}"
  else
    warn "No .env file found — using defaults (copy .env.example to .env to customize)"
  fi
}

check_admin_user() {
  info "Checking admin user: ${ADMIN_USER}..."

  if ! id "${ADMIN_USER}" &>/dev/null; then
    die "Admin user '${ADMIN_USER}' does not exist. Create it before running hardening."
  fi

  if ! groups "${ADMIN_USER}" | grep -qE '\b(sudo|wheel|admin)\b'; then
    die "Admin user '${ADMIN_USER}' is not in the sudo group."
  fi

  local admin_home
  admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
  if [[ ! -s "${admin_home}/.ssh/authorized_keys" ]]; then
    die "No SSH key found for '${ADMIN_USER}' at ${admin_home}/.ssh/authorized_keys"
  fi

  info "Admin user '${ADMIN_USER}' has sudo access and SSH key(s)"
}

check_ssh_key_access() {
  check_admin_user
  info "Safe to disable SSH password authentication"
}

lock_root_account() {
  if [[ "${LOCK_ROOT}" != "1" ]]; then
    warn "Skipping root lock (LOCK_ROOT=0)"
    return
  fi

  info "Locking root account..."

  # Prevent direct root login shell (SSH already blocks via PermitRootLogin no)
  passwd -l root
  usermod -s /usr/sbin/nologin root 2>/dev/null || usermod -s /bin/false root

  if passwd -S root 2>/dev/null | grep -qE ' L |\*'; then
    info "Root account locked (password disabled, login shell disabled)"
  else
    warn "Root lock may not have applied fully — check: passwd -S root"
  fi
}

apply_system_updates() {
  if [[ "${SKIP_UPGRADE}" == "1" ]]; then
    warn "Skipping system upgrade (SKIP_UPGRADE=1)"
    apt-get update -qq
    return
  fi

  info "Updating package lists and applying security upgrades..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -y -qq
  apt-get autoremove -y -qq
}

install_base_packages() {
  info "Installing security packages..."
  install_packages \
    ufw \
    fail2ban \
    unattended-upgrades \
    apt-listchanges \
    logwatch \
    auditd \
    audispd-plugins \
    libpam-pwquality \
    chrony \
  systemctl enable --now chrony
}

configure_unattended_upgrades() {
  info "Configuring automatic security updates..."
  install_packages unattended-upgrades

  if [[ -f "${CONFIG_DIR}/unattended-upgrades/20auto-upgrades" ]]; then
    cp "${CONFIG_DIR}/unattended-upgrades/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
  fi

  dpkg-reconfigure -f noninteractive unattended-upgrades 2>/dev/null || true
  systemctl enable unattended-upgrades
}

configure_sysctl() {
  info "Applying kernel network hardening (sysctl)..."
  if [[ -f "${CONFIG_DIR}/sysctl/99-hardening.conf" ]]; then
    cp "${CONFIG_DIR}/sysctl/99-hardening.conf" /etc/sysctl.d/99-hardening.conf
    sysctl --system >/dev/null
  fi
}

configure_ssh() {
  info "Hardening SSH (port ${SSH_PORT})..."

  mkdir -p /etc/ssh/sshd_config.d
  backup_file /etc/ssh/sshd_config

  if [[ -f "${CONFIG_DIR}/ssh/sshd_config.d/99-hardening.conf" ]]; then
    cp "${CONFIG_DIR}/ssh/sshd_config.d/99-hardening.conf" /etc/ssh/sshd_config.d/99-hardening.conf
  fi

  # Port override
  if grep -q '^Port ' /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null; then
    sed -i "s/^Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config.d/99-hardening.conf
  else
    echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config.d/99-hardening.conf
  fi

  # Restrict to specific users if configured
  if [[ -n "${SSH_ALLOWED_USERS}" ]]; then
  IFS=',' read -ra users <<< "${SSH_ALLOWED_USERS}"
    local allow_line="AllowUsers"
    for u in "${users[@]}"; do
      u="$(echo "${u}" | xargs)"
      [[ -n "${u}" ]] && allow_line+=" ${u}"
    done
    if ! grep -q '^AllowUsers ' /etc/ssh/sshd_config.d/99-hardening.conf; then
      echo "${allow_line}" >> /etc/ssh/sshd_config.d/99-hardening.conf
    fi
  fi

  # Validate before reload
  if ! sshd -t 2>/dev/null; then
    die "sshd configuration test failed — not reloading SSH"
  fi

  systemctl reload ssh || systemctl reload sshd
  info "SSH hardened and reloaded"
}

configure_fail2ban() {
  info "Configuring fail2ban..."
  if [[ -f "${CONFIG_DIR}/fail2ban/jail.local" ]]; then
    cp "${CONFIG_DIR}/fail2ban/jail.local" /etc/fail2ban/jail.local
  fi

  # Match SSH port if non-default
  if [[ "${SSH_PORT}" != "22" ]]; then
    sed -i "s/^port     = ssh/port     = ${SSH_PORT}/" /etc/fail2ban/jail.local
  fi

  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

configure_ufw() {
  info "Configuring UFW firewall..."

  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  ufw allow "${SSH_PORT}/tcp" comment 'SSH'

  if [[ -n "${OUTLINE_API_PORT}" ]]; then
    ufw allow "${OUTLINE_API_PORT}/tcp" comment 'Outline management API'
    info "Allowed Outline API port: ${OUTLINE_API_PORT}/tcp"
  fi

  if [[ -n "${EXTRA_TCP_PORTS}" ]]; then
    IFS=',' read -ra ports <<< "${EXTRA_TCP_PORTS}"
    for p in "${ports[@]}"; do
      p="$(echo "${p}" | xargs)"
      [[ -n "${p}" ]] && ufw allow "${p}/tcp" comment 'Extra port'
    done
  fi

  ufw --force enable
  info "UFW enabled"
}

harden_shared_memory() {
  info "Securing /run/shm mount..."
  if ! grep -q '/run/shm' /etc/fstab; then
    echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
  fi
}

disable_unused_services() {
  info "Disabling common unnecessary services (if present)..."
  local services=(
    avahi-daemon
    cups
    isc-dhcp-server
    isc-dhcp-server6
    slapd
    nfs-server
    rpcbind
  )
  for svc in "${services[@]}"; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null; then
      systemctl disable --now "${svc}" 2>/dev/null || true
      info "Disabled ${svc}"
    fi
  done
}

configure_auditd() {
  info "Enabling auditd..."
  systemctl enable --now auditd
}

configure_pam_pwquality() {
  info "Enforcing password quality (for local/sudo accounts)..."
  local pwquality="/etc/security/pwquality.conf"
  backup_file "${pwquality}"

  declare -A settings=(
    ["minlen"]="14"
    ["dcredit"]="-1"
    ["ucredit"]="-1"
    ["lcredit"]="-1"
    ["ocredit"]="-1"
    ["maxrepeat"]="3"
    ["difok"]="4"
  )

  for key in "${!settings[@]}"; do
    if grep -q "^${key}" "${pwquality}" 2>/dev/null; then
      sed -i "s/^${key}.*/${key} = ${settings[${key}]}/" "${pwquality}"
    else
      echo "${key} = ${settings[${key}]}" >> "${pwquality}"
    fi
  done
}

set_motd_permissions() {
  chmod 644 /etc/issue /etc/issue.net 2>/dev/null || true
}

print_summary() {
  echo ""
  echo "=============================================="
  echo "  Server hardening complete"
  echo "=============================================="
  echo "  SSH port:        ${SSH_PORT}"
  echo "  Password auth:   disabled"
  echo "  Root SSH login:  disabled"
  echo "  Root account:    locked"
  echo "  Admin user:      ${ADMIN_USER}"
  echo "  UFW:             enabled (deny incoming)"
  echo "  fail2ban:        enabled"
  echo "  Auto-updates:    enabled"
  echo "  Log file:        ${LOG_FILE}"
  echo "=============================================="
  echo ""
  echo "Next steps:"
  echo "  1. Open a NEW terminal and verify SSH: ssh -p ${SSH_PORT} user@your-server"
  echo "  2. Run: sudo ./scripts/install-outline.sh"
  echo "  3. Add Outline access-key ports to UFW (see README.md)"
  echo ""
}

main() {
  require_root
  require_ubuntu
  ensure_log_dir
  load_env

  info "Starting server hardening..."

  if [[ "${NONINTERACTIVE}" != "1" ]]; then
    echo ""
    echo "This script will:"
    echo "  - Upgrade packages"
    echo "  - Lock the root account (admin: ${ADMIN_USER})"
    echo "  - Disable SSH password authentication"
    echo "  - Enable UFW (allow SSH on port ${SSH_PORT})"
    echo "  - Install fail2ban and unattended-upgrades"
    echo ""
    if ! prompt_confirm "Continue?"; then
      die "Aborted by user"
    fi
  fi

  check_ssh_key_access
  lock_root_account
  apply_system_updates
  install_base_packages
  configure_unattended_upgrades
  configure_sysctl
  configure_ssh
  configure_fail2ban
  configure_ufw
  harden_shared_memory
  disable_unused_services
  configure_auditd
  configure_pam_pwquality
  set_motd_permissions

  print_summary
  info "Hardening finished successfully"
}

main "$@"
