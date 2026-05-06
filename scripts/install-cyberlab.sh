#!/usr/bin/env bash
set -euo pipefail

REPO_DIR_DEFAULT="/root/cyberlab-infra"
ANSIBLE_DIR_REL="ansible"
INVENTORY_FILE="inventory.yml"
HOST_BOOTSTRAP_PLAYBOOK="playbooks/host-bootstrap.yml"
CONTROLLER_VALIDATE_PLAYBOOK="playbooks/controller-validate-proxmox-api.yml"
CONTROLLER_SDN_PLAYBOOK="playbooks/controller-bootstrap-sdn.yml"
CONTROLLER_CTID="800"

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
  [ "$(id -u)" -eq 0 ] || fail "Run this installer as root on the Proxmox host."
}

require_proxmox() {
  command -v pveversion >/dev/null 2>&1 || fail "This does not appear to be a Proxmox VE host."
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
  elif [ -f "./${ANSIBLE_DIR_REL}/${HOST_BOOTSTRAP_PLAYBOOK}" ]; then
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
  [ -f "${REPO_DIR}/${ANSIBLE_DIR_REL}/${HOST_BOOTSTRAP_PLAYBOOK}" ] || fail "Could not find ${ANSIBLE_DIR_REL}/${HOST_BOOTSTRAP_PLAYBOOK}"
  [ -f "${REPO_DIR}/${ANSIBLE_DIR_REL}/${CONTROLLER_VALIDATE_PLAYBOOK}" ] || fail "Could not find ${ANSIBLE_DIR_REL}/${CONTROLLER_VALIDATE_PLAYBOOK}"
  [ -f "${REPO_DIR}/${ANSIBLE_DIR_REL}/${CONTROLLER_SDN_PLAYBOOK}" ] || fail "Could not find ${ANSIBLE_DIR_REL}/${CONTROLLER_SDN_PLAYBOOK}"
  [ -f "${REPO_DIR}/${ANSIBLE_DIR_REL}/${INVENTORY_FILE}" ] || fail "Could not find ${ANSIBLE_DIR_REL}/${INVENTORY_FILE}"
}

run_host_bootstrap() {
  log "Running host bootstrap playbook"
  cd "${REPO_DIR}/${ANSIBLE_DIR_REL}"
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
  ansible-playbook -i "${INVENTORY_FILE}" "${HOST_BOOTSTRAP_PLAYBOOK}"
}

assert_controller_running() {
  log "Checking controller CT ${CONTROLLER_CTID}"
  pct status "${CONTROLLER_CTID}" | grep -q "status: running" || fail "Controller CT ${CONTROLLER_CTID} is not running."
}

run_controller_playbook() {
  local playbook="$1"
  log "Running ${playbook} inside controller CT ${CONTROLLER_CTID}"
  pct exec "${CONTROLLER_CTID}" -- bash -lc \
    "cd /root/cyberlab-infra/${ANSIBLE_DIR_REL} && export LANG=C.UTF-8 LC_ALL=C.UTF-8 && ansible-playbook -i ${INVENTORY_FILE} ${playbook}"
}

run_controller_validation() {
  run_controller_playbook "${CONTROLLER_VALIDATE_PLAYBOOK}"
}

run_controller_sdn_bootstrap() {
  run_controller_playbook "${CONTROLLER_SDN_PLAYBOOK}"
}

show_success_summary() {
  cat <<'EOF'

[cyberlab-install] Platform bootstrap complete.

Completed phases:
- Proxmox host bootstrap
- Controller CT 800 bootstrap
- Controller SSH trust bootstrap
- Proxmox API validation from controller
- SDN zone and VNET bootstrap

Useful checks:
  pct status 800
  pct exec 800 -- bash -lc 'source /root/cyberlab-infra/private/secrets/proxmox-api.env && curl -sk -H "Authorization: PVEAPIToken=${PROXMOX_API_TOKEN_ID}=${PROXMOX_API_TOKEN_SECRET}" "${PROXMOX_API_URL}/version"'

Next recommended milestone:
- automate template creation and promotion
EOF
}

main() {
  require_root
  require_proxmox
  need_cmd apt-get
  need_cmd pct
  install_host_prereqs
  resolve_repo_dir
  clone_or_update_repo
  assert_repo_layout
  run_host_bootstrap
  assert_controller_running
  run_controller_validation
  run_controller_sdn_bootstrap
  show_success_summary
}

main "$@"
