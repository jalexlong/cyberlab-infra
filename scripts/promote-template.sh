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

cd "${ANSIBLE_DIR}"

exec ansible-playbook \
  -i "${INVENTORY_FILE}" \
  "${PROMOTE_PLAYBOOK}" \
  -e "template_name=${TEMPLATE_NAME}"
