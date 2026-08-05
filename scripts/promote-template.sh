#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <template-id-or-name>" >&2
  echo "Example: $0 debian13" >&2
  echo "Example: $0 tpl-debian13-base" >&2
  exit 1
fi

TEMPLATE_NAME="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY_FILE="${ANSIBLE_DIR}/inventory.yml"
PROMOTE_PLAYBOOK="${ANSIBLE_DIR}/playbooks/controller-promote-template.yml"

if [[ ! -f "${INVENTORY_FILE}" ]]; then
  echo "Missing Ansible inventory: ${INVENTORY_FILE}" >&2
  exit 1
fi

if [[ ! -f "${PROMOTE_PLAYBOOK}" ]]; then
  echo "Missing promote playbook: ${PROMOTE_PLAYBOOK}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Run logging. See install-cyberlab.sh for the rationale; the convention is
# shared. Promotion converts a VM into a template, which is not reversible
# without a rebuild, so it is worth a transcript. Logging is never allowed to
# fail a run.
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
LOG_DIR="${CYBERLAB_LOG_DIR:-/var/log/cyberlab}"
LOG_FILE=""

setup_logging() {
  local base="${SCRIPT_NAME%.sh}"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"

  mkdir -p -- "${LOG_DIR}" 2>/dev/null || {
    printf '[%s] WARNING: cannot create %s; continuing without a log file\n' \
      "${SCRIPT_NAME}" "${LOG_DIR}" >&2
    return 0
  }

  local candidate="${LOG_DIR}/${base}-${stamp}.log"
  : >"${candidate}" 2>/dev/null || {
    printf '[%s] WARNING: cannot write %s; continuing without a log file\n' \
      "${SCRIPT_NAME}" "${candidate}" >&2
    return 0
  }

  LOG_FILE="${candidate}"
  chmod 0640 -- "${LOG_FILE}" 2>/dev/null || true
  ln -sfn -- "${LOG_FILE}" "${LOG_DIR}/${base}-latest.log" 2>/dev/null || true

  {
    printf '=== %s ===\n' "${SCRIPT_NAME}"
    printf 'started: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'host:    %s\n' "$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    printf 'user:    %s\n' "$(id -un 2>/dev/null || echo unknown)"
    printf 'args:    %s\n' "${TEMPLATE_NAME}"
    printf '===\n\n'
  } >>"${LOG_FILE}"

  exec > >(tee -a -- "${LOG_FILE}") 2>&1
  printf '[%s] Logging to %s\n' "${SCRIPT_NAME}" "${LOG_FILE}" >&2
}

setup_logging

cd "${ANSIBLE_DIR}"

# Deliberately not exec: ansible-playbook must remain a child so the tee
# subprocess set up above outlives it and flushes the transcript. Propagate its
# exit status by hand.
ansible-playbook \
  -i "${INVENTORY_FILE}" \
  "${PROMOTE_PLAYBOOK}" \
  -e "template_name=${TEMPLATE_NAME}"
exit $?
