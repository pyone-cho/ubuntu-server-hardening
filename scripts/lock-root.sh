#!/usr/bin/env bash
#
# Lock the root account after verifying the admin user is ready.
# Usage:
#   sudo ./scripts/lock-root.sh
#   ADMIN_USER=ubuntu sudo ./scripts/lock-root.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ADMIN_USER="${ADMIN_USER:-ubuntu}"
LOCK_ROOT="${LOCK_ROOT:-1}"

load_env() {
  local env_file="${PROJECT_ROOT}/.env"
  if [[ -f "${env_file}" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "${env_file}"
    set +a
    ADMIN_USER="${ADMIN_USER:-ubuntu}"
    LOCK_ROOT="${LOCK_ROOT:-1}"
  fi
}

check_admin_user() {
  info "Checking admin user: ${ADMIN_USER}..."

  if ! id "${ADMIN_USER}" &>/dev/null; then
    die "Admin user '${ADMIN_USER}' does not exist."
  fi

  if ! groups "${ADMIN_USER}" | grep -qE '\b(sudo|wheel|admin)\b'; then
    die "Admin user '${ADMIN_USER}' is not in the sudo group."
  fi

  local admin_home
  admin_home="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
  if [[ ! -s "${admin_home}/.ssh/authorized_keys" ]]; then
    die "No SSH key found for '${ADMIN_USER}' at ${admin_home}/.ssh/authorized_keys"
  fi

  info "Admin user '${ADMIN_USER}' is ready"
}

lock_root_account() {
  if [[ "${LOCK_ROOT}" != "1" ]]; then
    die "Root lock disabled (LOCK_ROOT=0)"
  fi

  info "Locking root account..."
  passwd -l root
  usermod -s /usr/sbin/nologin root 2>/dev/null || usermod -s /bin/false root

  echo ""
  echo "Root account locked."
  echo "  Verify: passwd -S root   (should show 'L' for locked)"
  echo "  Login as: ssh ${ADMIN_USER}@your-server"
  echo "  Admin tasks: sudo <command>"
  echo ""
}

main() {
  require_root
  require_ubuntu
  ensure_log_dir
  load_env

  if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
    echo "This will lock the root account. Admin user: ${ADMIN_USER}"
    if ! prompt_confirm "Continue?"; then
      die "Aborted by user"
    fi
  fi

  check_admin_user
  lock_root_account
}

main "$@"
