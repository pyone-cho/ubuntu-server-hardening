#!/usr/bin/env bash
#
# Allow an Outline access-key port through UFW.
# Usage: sudo ./scripts/outline-ufw-allow.sh <port>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

require_root

PORT="${1:-}"
if [[ -z "${PORT}" ]] || ! [[ "${PORT}" =~ ^[0-9]+$ ]] || [[ "${PORT}" -lt 1 ]] || [[ "${PORT}" -gt 65535 ]]; then
  die "Usage: $0 <port>"
fi

if ! command -v ufw &>/dev/null; then
  die "UFW is not installed"
fi

ufw allow "${PORT}/tcp" comment "Outline access key ${PORT}"
ufw status numbered | grep -E "${PORT}/tcp|Outline" || ufw status

info "Allowed TCP port ${PORT} for Outline access key"
