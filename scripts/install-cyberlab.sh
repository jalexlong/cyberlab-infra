#!/usr/bin/env bash
set -euo pipefail

REPO_DIR_DEFAULT="/root/cyberlab-infra"
ANSIBLE_DIR_REL="ansible"
INVENTORY_FILE="inventory.yml"
PLAYBOOK_FILE="playbooks/host-bootstrap.yml"

log() {
  printf '[cyberlab-install] %s\n' "$*"
}

fail() {
  printf '[cyberlab-install] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "Run this installer as root on the Proxmox host."
  fi
}

require_proxmox() {
  if ! command -v pveversion >/dev/null 2>&1; then
    fail "This does not appear to be a Proxmox VE host."
  fi
}

install_host_prereqs() {
  export DEBIAN_FRONTEND=noninteractive
  log "Installing installer prerequisites"
  apt-get update
  apt-get install -y git curl sudo python3 python3-apt ansible
}

resolve_repo_dir() {
  if [ -n "${CYBERLAB_REPO_DIR:-}" ]; then
    REPO_DIR="${CYBERLAB_REPO_DIR}"
  elif [ -f "./${ANSIBLE_DIR_REL}/${PLAYBOOK_FILE}" ]; then
    REPO_DIR="$(pwd)"
  else
    REPO_DIR="${REPO_DIR_DEFAULT}"
  fi
}

clone_or_update_repo() {
  local repo_url="${CYBERLAB_REPO_URL:-https://github.com/jalexlong/cyberlab-infra.git}"
  local repo_branch="${CYBERLAB_REPO_BRANCH:-main}"

  if [ -d "${REPO_DIR}/.git" ]; then
    log "Updating existing repo at ${REPO_DIR}"
    git -C "${REPO_DIR}" fetch --all --prune
    git -C "${REPO_DIR}" checkout "${repo_branch}"
    git -C "${REPO_DIR}" pull --ff-only origin "${repo_branch}"
  else
    log "Cloning repo into ${REPO_DIR}"
    git clone --branch "${repo_branch}" "${repo_url}" "${REPO_DIR}"
  fi
}

assert_repo_layout() {
  [ -f "${REPO_DIR}/${ANSIBLE_DIR_REL}/${PLAYBOOK_FILE}" ] || fail "Could not find ${ANSIBLE_DIR_REL}/${PLAYBOOK_FILE}"
  [ -f "${REPO_DIR}/${ANSIBLE_DIR_REL}/${INVENTORY_FILE}" ] || fail "Could not find ${ANSIBLE_DIR_REL}/${INVENTORY_FILE}"
}

run_host_bootstrap() {
  log "Running host bootstrap playbook"
  cd "${REPO_DIR}/${ANSIBLE_DIR_REL}"
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  ansible-playbook -i "${INVENTORY_FILE}" "${PLAYBOOK_FILE}"
}

show_next_steps() {
  cat <<'EOF'

[cyberlab-install] Install phase complete.

Expected results:
- Proxmox automation user/token created
- Controller CT 800 created and bootstrapped
- Controller trust handoff established
- Controller ready for validation and SDN bootstrap

Recommended verification on the Proxmox host:
  pct status 800
  pct exec 800 -- bash -lc 'cd /root/cyberlab-infra/ansible && export LANG=C.UTF-8 LC_ALL=C.UTF-8 && ansible-playbook -i inventory.yml playbooks/controller-validate-proxmox-api.yml'

When controller API validation passes, bootstrap SDN with:
  pct exec 800 -- bash -lc 'cd /root/cyberlab-infra/ansible && export LANG=C.UTF-8 LC_ALL=C.UTF-8 && ansible-playbook -i inventory.yml playbooks/controller-bootstrap-sdn.yml'
EOF
}

main() {
  require_root
  require_proxmox
  need_cmd apt-get
  install_host_prereqs
  resolve_repo_dir
  clone_or_update_repo
  assert_repo_layout
  run_host_bootstrap
  show_next_steps
}

main "$@"
