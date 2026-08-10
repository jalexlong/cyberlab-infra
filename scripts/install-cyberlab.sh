#!/usr/bin/env bash
# Bootstrap the Cyberlab platform on a Proxmox VE host.
#
# This is the human-facing entrypoint for a fresh Proxmox host. It installs host
# prerequisites, ensures the repo is present, detects controller management
# networking, runs host bootstrap, then executes controller-side validation and
# SDN bootstrap.

set -Eeuo pipefail
IFS=$'\n\t'

# Declared and assigned separately so that `set -e` still sees a failing
# substitution; `readonly X="$(cmd)"` returns readonly's status, not cmd's.
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_NAME SCRIPT_DIR

readonly REPO_DIR_DEFAULT="/root/cyberlab-infra"
readonly ANSIBLE_DIR_REL="ansible"
readonly INVENTORY_FILE="inventory.yml"
readonly HOST_BOOTSTRAP_PLAYBOOK="playbooks/host-bootstrap.yml"
readonly CONTROLLER_VALIDATE_PLAYBOOK="playbooks/controller-validate-proxmox-api.yml"
readonly CONTROLLER_SDN_PLAYBOOK="playbooks/controller-bootstrap-sdn.yml"
readonly CONTROLLER_PACKAGE_CACHE_PLAYBOOK="playbooks/controller-bootstrap-package-cache.yml"
readonly CONTROLLER_FIREWALL_PLAYBOOK="playbooks/controller-bootstrap-firewall.yml"
readonly CONTROLLER_ISOLATION_PLAYBOOK="playbooks/controller-assert-isolation.yml"
readonly DETECT_CONTROLLER_NETWORK_SCRIPT_REL="scripts/detect-controller-network.sh"
readonly CONTROLLER_NETWORK_VARS_REL="private/generated/controller-network.yml"
readonly CONTROLLER_CTID_DEFAULT="800"
readonly REPO_URL_DEFAULT="https://github.com/jalexlong/cyberlab-infra.git"
readonly REPO_BRANCH_DEFAULT="main"

REPO_DIR=""
REPO_URL="${CYBERLAB_REPO_URL:-${REPO_URL_DEFAULT}}"
REPO_BRANCH="${CYBERLAB_REPO_BRANCH:-${REPO_BRANCH_DEFAULT}}"
CONTROLLER_CTID="${CYBERLAB_CONTROLLER_CTID:-${CONTROLLER_CTID_DEFAULT}}"
SKIP_REPO_UPDATE="${CYBERLAB_SKIP_REPO_UPDATE:-0}"
SKIP_HOST_PREREQS="${CYBERLAB_SKIP_HOST_PREREQS:-0}"
SKIP_NETWORK_DETECT="${CYBERLAB_SKIP_NETWORK_DETECT:-0}"
ROTATE_API_TOKEN="${CYBERLAB_ROTATE_API_TOKEN:-0}"
SKIP_CONTROLLER_VALIDATE="${CYBERLAB_SKIP_CONTROLLER_VALIDATE:-0}"
SKIP_SDN_BOOTSTRAP="${CYBERLAB_SKIP_SDN_BOOTSTRAP:-0}"
# Opt-in, not opt-out. The package cache is Phase 2.5 work and is off until it
# is proven on the target hardware, the same way section VNets are.
WITH_PACKAGE_CACHE="${CYBERLAB_WITH_PACKAGE_CACHE:-0}"
# Opt-in for the same reason the package cache is, plus one of its own: this
# writes a default-deny firewall to a live host. It is off until an operator
# asks for it, and asking for it also runs the isolation assertions, because
# writing the rules and proving they are in force are not the same claim --
# that gap is exactly what 2026-08-07 measured.
WITH_FIREWALL="${CYBERLAB_WITH_FIREWALL:-0}"
QUIET="${CYBERLAB_QUIET:-0}"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Bootstrap the Cyberlab platform on a Proxmox VE host.

Options:
  --repo-dir DIR              Use or clone repo at DIR
  --repo-url URL              Git repo URL to clone when repo is absent
  --repo-branch BRANCH        Git branch to checkout/pull
  --controller-ctid CTID      Controller CTID, default ${CONTROLLER_CTID_DEFAULT}
  --skip-host-prereqs         Do not apt install installer prerequisites
  --skip-repo-update          Do not fetch/pull existing repo
  --skip-network-detect       Do not run scripts/detect-controller-network.sh
  --skip-controller-validate  Do not run controller API validation playbook
  --skip-sdn-bootstrap        Do not run controller SDN bootstrap playbook
  --with-package-cache        Build the apt-cacher-ng package cache LXC (off by default)
  --with-firewall             Write the isolation firewall and assert it (off by default)
  --rotate-api-token          Force recreation of the Proxmox API token and rewrite controller secret
  -q, --quiet                 Reduce status output
  -h, --help                  Show this help

Environment overrides:
  CYBERLAB_REPO_DIR=/root/cyberlab-infra
  CYBERLAB_REPO_URL=${REPO_URL_DEFAULT}
  CYBERLAB_REPO_BRANCH=${REPO_BRANCH_DEFAULT}
  CYBERLAB_CONTROLLER_CTID=${CONTROLLER_CTID_DEFAULT}
  CYBERLAB_SKIP_HOST_PREREQS=0|1
  CYBERLAB_SKIP_REPO_UPDATE=0|1
  CYBERLAB_SKIP_NETWORK_DETECT=0|1
  CYBERLAB_SKIP_CONTROLLER_VALIDATE=0|1
  CYBERLAB_SKIP_SDN_BOOTSTRAP=0|1
  CYBERLAB_WITH_PACKAGE_CACHE=0|1
  CYBERLAB_WITH_FIREWALL=0|1

Network detector pass-through examples:
  CYBERLAB_CONTROLLER_VLAN=99 ${SCRIPT_NAME}
  CYBERLAB_CONTROLLER_DNS="192.168.99.1" ${SCRIPT_NAME}
  CYBERLAB_CONTROLLER_BRIDGE=vmbr0 CYBERLAB_CONTROLLER_VLAN=99 ${SCRIPT_NAME}
EOF
}

# ---------------------------------------------------------------------------
# Run logging.
#
# Every run leaves a transcript under /var/log/cyberlab so a failure can be
# read after the fact instead of reconstructed from memory. Both streams are
# captured, because the useful part of an installer run is the Ansible output
# on stdout, not just the status lines this script prints to stderr.
#
# Logging must never be the reason a run fails. If the directory cannot be
# created or written — a read-only root, a non-root caller — the script says so
# once and carries on without a transcript.
# ---------------------------------------------------------------------------
readonly LOG_DIR_DEFAULT="/var/log/cyberlab"
LOG_DIR="${CYBERLAB_LOG_DIR:-${LOG_DIR_DEFAULT}}"
LOG_FILE=""

setup_logging() {
  local base="${SCRIPT_NAME%.sh}"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"

  if ! mkdir -p -- "${LOG_DIR}" 2>/dev/null; then
    printf '[cyberlab-install] WARNING: cannot create %s; continuing without a log file\n' \
      "${LOG_DIR}" >&2
    return 0
  fi

  local candidate="${LOG_DIR}/${base}-${stamp}.log"
  if ! : >"${candidate}" 2>/dev/null; then
    printf '[cyberlab-install] WARNING: cannot write %s; continuing without a log file\n' \
      "${candidate}" >&2
    return 0
  fi

  LOG_FILE="${candidate}"
  chmod 0640 -- "${LOG_FILE}" 2>/dev/null || true
  ln -sfn -- "${LOG_FILE}" "${LOG_DIR}/${base}-latest.log" 2>/dev/null || true

  # Joined by hand rather than with "${ORIGINAL_ARGS[*]}": these scripts set
  # IFS to newline/tab, so the array subscript form would wrap the header
  # across lines.
  local args_str="" arg
  for arg in ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}; do
    args_str+="${arg} "
  done
  args_str="${args_str% }"
  [[ -n "${args_str}" ]] || args_str="(none)"

  {
    printf '=== %s ===\n' "${SCRIPT_NAME}"
    printf 'started: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'host:    %s\n' "$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    printf 'user:    %s\n' "$(id -un 2>/dev/null || echo unknown)"
    printf 'args:    %s\n' "${args_str}"
    printf '===\n\n'
  } >>"${LOG_FILE}"

  # Tee both streams from here on. Command substitution elsewhere in the
  # script is unaffected: it pipes the subshell's stdout independently of this
  # redirection.
  exec > >(tee -a -- "${LOG_FILE}") 2>&1

  log "Logging to ${LOG_FILE}"
}

log() {
  if [[ "${QUIET}" != "1" ]]; then
    printf '[cyberlab-install] %s\n' "$*" >&2
  fi
}

warn() {
  printf '[cyberlab-install] WARNING: %s\n' "$*" >&2
}

fail() {
  printf '[cyberlab-install] ERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local rc="$1"
  local line="$2"
  printf '[cyberlab-install] ERROR: command failed at line %s with exit code %s\n' "${line}" "${rc}" >&2
  exit "${rc}"
}

trap 'on_error "$?" "$LINENO"' ERR

need_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || fail "Missing required command: ${cmd}"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || fail "Run this installer as root on the Proxmox host."
}

require_proxmox() {
  command -v pveversion >/dev/null 2>&1 || fail "This does not appear to be a Proxmox VE host."
}

parse_args() {
  while (( "$#" > 0 )); do
    case "$1" in
      --repo-dir)
        [[ "$#" -ge 2 ]] || fail "Missing argument for --repo-dir"
        REPO_DIR="$2"
        shift 2
        ;;
      --repo-url)
        [[ "$#" -ge 2 ]] || fail "Missing argument for --repo-url"
        REPO_URL="$2"
        shift 2
        ;;
      --repo-branch)
        [[ "$#" -ge 2 ]] || fail "Missing argument for --repo-branch"
        REPO_BRANCH="$2"
        shift 2
        ;;
      --controller-ctid)
        [[ "$#" -ge 2 ]] || fail "Missing argument for --controller-ctid"
        CONTROLLER_CTID="$2"
        shift 2
        ;;
      --skip-host-prereqs)
        SKIP_HOST_PREREQS=1
        shift
        ;;
      --skip-repo-update)
        SKIP_REPO_UPDATE=1
        shift
        ;;
      --skip-network-detect)
        SKIP_NETWORK_DETECT=1
        shift
        ;;
      --skip-controller-validate)
        SKIP_CONTROLLER_VALIDATE=1
        shift
        ;;
      --skip-sdn-bootstrap)
        SKIP_SDN_BOOTSTRAP=1
        shift
        ;;
      --with-package-cache)
        WITH_PACKAGE_CACHE=1
        shift
        ;;
      --with-firewall)
        WITH_FIREWALL=1
        shift
        ;;
      --rotate-api-token)
	ROTATE_API_TOKEN=1
	shift
	;;
      -q|--quiet)
        QUIET=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

install_host_prereqs() {
  if [[ "${SKIP_HOST_PREREQS}" == "1" ]]; then
    log "Skipping host prerequisite installation"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive

  log "Installing installer prerequisites"
  apt-get update
  apt-get install -y \
    ansible \
    curl \
    git \
    python3 \
    python3-apt \
    sudo
}

resolve_repo_dir() {
  if [[ -n "${REPO_DIR}" ]]; then
    return 0
  fi

  if [[ -n "${CYBERLAB_REPO_DIR:-}" ]]; then
    REPO_DIR="${CYBERLAB_REPO_DIR}"
  elif [[ -f "${SCRIPT_DIR}/../${ANSIBLE_DIR_REL}/${HOST_BOOTSTRAP_PLAYBOOK}" ]]; then
    REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
  elif [[ -f "./${ANSIBLE_DIR_REL}/${HOST_BOOTSTRAP_PLAYBOOK}" ]]; then
    REPO_DIR="$(pwd -P)"
  else
    REPO_DIR="${REPO_DIR_DEFAULT}"
  fi
}

clone_or_update_repo() {
  if [[ -d "${REPO_DIR}/.git" ]]; then
    if [[ "${SKIP_REPO_UPDATE}" == "1" ]]; then
      log "Using existing repo without update: ${REPO_DIR}"
      return 0
    fi

    log "Updating existing repo at ${REPO_DIR}"
    git -C "${REPO_DIR}" fetch --all --prune
    git -C "${REPO_DIR}" checkout "${REPO_BRANCH}"
    git -C "${REPO_DIR}" pull --ff-only origin "${REPO_BRANCH}"
    return 0
  fi

  log "Cloning repo into ${REPO_DIR}"
  mkdir -p -- "$(dirname -- "${REPO_DIR}")"
  git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
}

assert_file() {
  local path="$1"
  [[ -f "${path}" ]] || fail "Missing required file: ${path}"
}

assert_repo_layout() {
  assert_file "${REPO_DIR}/${ANSIBLE_DIR_REL}/${INVENTORY_FILE}"
  assert_file "${REPO_DIR}/${ANSIBLE_DIR_REL}/${HOST_BOOTSTRAP_PLAYBOOK}"
  assert_file "${REPO_DIR}/${ANSIBLE_DIR_REL}/${CONTROLLER_VALIDATE_PLAYBOOK}"
  assert_file "${REPO_DIR}/${ANSIBLE_DIR_REL}/${CONTROLLER_SDN_PLAYBOOK}"
  assert_file "${REPO_DIR}/${ANSIBLE_DIR_REL}/${CONTROLLER_FIREWALL_PLAYBOOK}"
  assert_file "${REPO_DIR}/${ANSIBLE_DIR_REL}/${CONTROLLER_ISOLATION_PLAYBOOK}"
  assert_file "${REPO_DIR}/${DETECT_CONTROLLER_NETWORK_SCRIPT_REL}"
}

ensure_detector_executable() {
  local detector="${REPO_DIR}/${DETECT_CONTROLLER_NETWORK_SCRIPT_REL}"

  if [[ ! -x "${detector}" ]]; then
    log "Making network detector executable"
    chmod +x -- "${detector}"
  fi
}

run_controller_network_detection() {
  if [[ "${SKIP_NETWORK_DETECT}" == "1" ]]; then
    log "Skipping controller network detection"
    return 0
  fi

  local detector="${REPO_DIR}/${DETECT_CONTROLLER_NETWORK_SCRIPT_REL}"
  local output_file="${REPO_DIR}/${CONTROLLER_NETWORK_VARS_REL}"

  ensure_detector_executable

  log "Detecting controller management network"
  "${detector}" --output "${output_file}"

  [[ -s "${output_file}" ]] || fail "Controller network vars were not generated: ${output_file}"
  log "Controller network vars written to ${output_file}"
}

ansible_env_exports() {
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
}

run_host_bootstrap() {
  log "Running host bootstrap playbook"
  ansible_env_exports

  local -a extra_args=()

  if [[ "${ROTATE_API_TOKEN}" == "1" ]]; then
	  log "API token rotation requested"
	  extra_args+=("-e" "cyberlab_rotate_api_token=true")
  fi

  (
    cd -- "${REPO_DIR}/${ANSIBLE_DIR_REL}"
    ansible-playbook -i "${INVENTORY_FILE}" "${HOST_BOOTSTRAP_PLAYBOOK}" "${extra_args[@]}"
  )
}

assert_controller_running() {
  log "Checking controller CT ${CONTROLLER_CTID}"
  pct status "${CONTROLLER_CTID}" | grep -q "status: running" \
    || fail "Controller CT ${CONTROLLER_CTID} is not running."
}

run_controller_playbook() {
  local playbook="$1"

  log "Running ${playbook} inside controller CT ${CONTROLLER_CTID}"
  pct exec "${CONTROLLER_CTID}" -- bash -lc \
    "cd /root/cyberlab-infra/${ANSIBLE_DIR_REL} && export LANG=C.UTF-8 LC_ALL=C.UTF-8 && ansible-playbook -i ${INVENTORY_FILE} ${playbook}"
}

run_controller_validation() {
  if [[ "${SKIP_CONTROLLER_VALIDATE}" == "1" ]]; then
    log "Skipping controller API validation playbook"
    return 0
  fi

  run_controller_playbook "${CONTROLLER_VALIDATE_PLAYBOOK}"
}

run_controller_sdn_bootstrap() {
  if [[ "${SKIP_SDN_BOOTSTRAP}" == "1" ]]; then
    log "Skipping controller SDN bootstrap playbook"
    return 0
  fi

  run_controller_playbook "${CONTROLLER_SDN_PLAYBOOK}"
}

# Opt-in. Depends on svc0, which controller-bootstrap-sdn.yml always builds as
# an infrastructure network, so this must run after it rather than beside it.
run_controller_package_cache() {
  if [[ "${WITH_PACKAGE_CACHE}" != "1" ]]; then
    log "Skipping package cache build (pass --with-package-cache to enable)"
    return 0
  fi

  run_controller_playbook "${CONTROLLER_PACKAGE_CACHE_PLAYBOOK}"
}

# Two playbooks, always together and always in this order. Writing the rules is
# not the same claim as the rules being in force: on 2026-08-07 a host carried
# a correct rule set that was not applied to a single guest, because the flag
# requesting filtering and the file supplying the policy are separate state.
run_controller_firewall() {
  if [[ "${WITH_FIREWALL}" != "1" ]]; then
    log "Skipping firewall bootstrap (pass --with-firewall to enable)"
    log "  NOTE: without it this host has an SDN and no isolation. Lab guests"
    log "  can reach the management address, each other's sections, and a"
    log "  recursive resolver. See docs/network-isolation.md."
    return 0
  fi

  run_controller_playbook "${CONTROLLER_FIREWALL_PLAYBOOK}"
  run_controller_playbook "${CONTROLLER_ISOLATION_PLAYBOOK}"
}

show_runtime_summary() {
  log "Runtime configuration:"
  log "  repo_dir=${REPO_DIR}"
  log "  repo_url=${REPO_URL}"
  log "  repo_branch=${REPO_BRANCH}"
  log "  controller_ctid=${CONTROLLER_CTID}"
  log "  network_vars=${REPO_DIR}/${CONTROLLER_NETWORK_VARS_REL}"
  log "  rotate_api_token=${ROTATE_API_TOKEN}"
}

# Report a phase as done or skipped. The summary previously hardcoded every
# phase as completed, so `--skip-sdn-bootstrap` still printed "SDN zone and
# VNET bootstrap" under "Completed phases" — the run reported work it had just
# announced it was skipping.
phase_line() {
  local skipped="$1" label="$2"
  if [[ "${skipped}" -eq 1 ]]; then
    printf -- '- %s (SKIPPED)\n' "${label}"
  else
    printf -- '- %s\n' "${label}"
  fi
}

show_success_summary() {
  cat <<EOF

[cyberlab-install] Platform bootstrap complete.

Phases:
$(phase_line 0 "Proxmox host bootstrap")
$(phase_line 0 "Controller CT ${CONTROLLER_CTID} bootstrap")
$(phase_line 0 "Controller SSH trust bootstrap")
$(phase_line "${SKIP_CONTROLLER_VALIDATE}" "Proxmox API validation from controller")
$(phase_line "${SKIP_SDN_BOOTSTRAP}" "SDN zone and VNET bootstrap")
$(phase_line "$((1 - WITH_PACKAGE_CACHE))" "Package cache LXC (Phase 2.5)")
$(phase_line "$((1 - WITH_FIREWALL))" "Isolation firewall + assertions (Phase 5)")

Useful checks:
  pct status ${CONTROLLER_CTID}
  pct exec ${CONTROLLER_CTID} -- bash -lc 'source /root/cyberlab-infra/private/secrets/proxmox-api.env && curl -sk -H "Authorization: PVEAPIToken=\${PROXMOX_API_TOKEN_ID}=\${PROXMOX_API_TOKEN_SECRET}" "\${PROXMOX_API_URL}/version"'

Generated network vars:
  ${REPO_DIR}/${CONTROLLER_NETWORK_VARS_REL}

Next recommended milestone:
- complete Debian 13 template finalize/promote pipeline
- add clone-test validation from template 900 to test VM 950
EOF
}

main() {
  # Recorded before parse_args consumes them, so the transcript header shows
  # how the run was actually invoked.
  ORIGINAL_ARGS=("$@")

  parse_args "$@"

  # After parse_args so --help and a bad flag exit without leaving a stray
  # empty transcript, and before require_root so a non-root run is recorded.
  setup_logging

  require_root
  require_proxmox
  need_cmd apt-get
  need_cmd git
  need_cmd pct
  need_cmd grep
  need_cmd bash

  install_host_prereqs
  resolve_repo_dir
  clone_or_update_repo
  assert_repo_layout
  run_controller_network_detection
  show_runtime_summary
  run_host_bootstrap
  assert_controller_running
  run_controller_validation
  run_controller_sdn_bootstrap
  run_controller_package_cache
  run_controller_firewall
  show_success_summary
}

main "$@"

