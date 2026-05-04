#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <template_key>" >&2
  exit 1
fi

KEY="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_FILE="${REPO_ROOT}/data/templates.yml"

# shellcheck disable=SC1090
source <(python3 "${REPO_ROOT}/scripts/template_env.py" "${TEMPLATES_FILE}" "${KEY}")

if qm status "${CANDIDATE_VMID}" >/dev/null 2>&1; then
  qm shutdown "${CANDIDATE_VMID}" >/dev/null 2>&1 || true
fi

if qm status "${APPROVED_VMID}" >/dev/null 2>&1; then
  qm stop "${APPROVED_VMID}" >/dev/null 2>&1 || true
  qm destroy "${APPROVED_VMID}" --destroy-unreferenced-disks 1
fi

qm clone "${CANDIDATE_VMID}" "${APPROVED_VMID}" --name "${APPROVED_NAME}" --full 1
qm template "${APPROVED_VMID}"

echo "Promoted ${KEY}: ${CANDIDATE_VMID} -> ${APPROVED_VMID}"
