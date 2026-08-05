#!/usr/bin/env bash
# Capture the state of a Proxmox host before wiping and rebuilding it.
#
# This script makes no changes to host configuration. It only reads: it copies
# configuration and records the output of query commands. The two things it
# writes are its capture directory, and its own run transcript under
# /var/log/cyberlab (override with CYBERLAB_LOG_DIR). Nothing the host depends
# on is touched.
#
# Run it before a deliberate teardown so the rebuild starts from recorded fact
# rather than from memory.
#
# What it is for: the empirical details a rebuild needs and nobody remembers —
# which bridge carries management traffic, what the storage is actually called,
# which VMIDs were in use, what the SDN zone was named. These are the inputs
# docs/bootstrap-checklist.md asks for.
#
# What it is not: a backup product. Guest disks are captured only if you ask
# for them with --with-guests, and even then via vzdump, which is slow and
# large. For a disposable proto-prototype host the configuration and the facts
# are usually all that is worth keeping.
#
# Secrets: /etc/pve/priv/ holds API token secrets and cluster keys. These ARE
# captured by default, so that restoring the capture yields a working
# environment rather than one you are locked out of. That is the right default
# for a development host. If you ever actually restore from this capture,
# rotate the credentials afterwards.
#
# Pass --no-secrets for a host whose keys should not leave it — a district
# deployment, or any capture whose destination you do not control. The rebuild
# regenerates everything in priv/ regardless, so excluding it only costs you
# the ability to revert.

set -Eeuo pipefail
IFS=$'\n\t'

# Declared and assigned separately so that `set -e` still sees a failing
# substitution; `readonly X="$(cmd)"` returns readonly's status, not cmd's.
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

DEST=""
WITH_GUESTS=0
WITH_SECRETS=1

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --dest <directory> [options]

Capture Proxmox host configuration and state before a rebuild. Read-only.

Required:
  --dest <dir>        Where to write the capture (e.g. /mnt/usb/pve1-capture)

Options:
  --with-guests       Also vzdump every VM and container. Slow and large.
  --no-secrets        Skip /etc/pve/priv/. Captured by default so a restore
                      yields a working environment; see header.
  --with-secrets      Explicitly keep the default. Accepted for clarity.
  -h, --help          Show this help.

Example:
  ${SCRIPT_NAME} --dest /mnt/usb/pve1-\$(date +%Y%m%d)
EOF
}

# ---------------------------------------------------------------------------
# Run logging. See install-cyberlab.sh for the rationale; the convention is
# shared. Logging is never allowed to fail a run.
# ---------------------------------------------------------------------------
readonly LOG_DIR_DEFAULT="/var/log/cyberlab"
LOG_DIR="${CYBERLAB_LOG_DIR:-${LOG_DIR_DEFAULT}}"
LOG_FILE=""

setup_logging() {
  local base="${SCRIPT_NAME%.sh}"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"

  if ! mkdir -p -- "${LOG_DIR}" 2>/dev/null; then
    printf '[capture] WARNING: cannot create %s; continuing without a log file\n' \
      "${LOG_DIR}" >&2
    return 0
  fi

  local candidate="${LOG_DIR}/${base}-${stamp}.log"
  if ! : >"${candidate}" 2>/dev/null; then
    printf '[capture] WARNING: cannot write %s; continuing without a log file\n' \
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

  exec > >(tee -a -- "${LOG_FILE}") 2>&1
}

log() {
  printf '[capture] %s\n' "$*" >&2
}

warn() {
  printf '[capture] WARNING: %s\n' "$*" >&2
}

fail() {
  printf '[capture] ERROR: %s\n' "$*" >&2
  exit 1
}

# Recorded before the loop below consumes them, so the transcript header shows
# how the run was actually invoked.
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || fail "--dest requires a value"
      DEST="$2"
      shift 2
      ;;
    --with-guests)
      WITH_GUESTS=1
      shift
      ;;
    --with-secrets)
      WITH_SECRETS=1
      shift
      ;;
    --no-secrets)
      WITH_SECRETS=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${DEST}" ]] || {
  usage >&2
  fail "--dest is required"
}

[[ "$(id -u)" -eq 0 ]] || fail "Must run as root; /etc/pve is not world-readable."

command -v pveversion >/dev/null 2>&1 ||
  fail "pveversion not found. Run this on the Proxmox host itself."

# After the argument and environment checks, so a misuse exits without leaving
# a stray empty transcript.
setup_logging

mkdir -p "${DEST}"/{config,facts}
log "Capturing to ${DEST}"
[[ -n "${LOG_FILE}" ]] && log "Logging to ${LOG_FILE}"

# ---------------------------------------------------------------------------
# Facts: the output of query commands. These are what make a rebuild fast.
# Each is best-effort — a missing command on a given host is not fatal, because
# an incomplete capture is still worth far more than an aborted one.
# ---------------------------------------------------------------------------

record() {
  local name="$1"
  shift
  if "$@" >"${DEST}/facts/${name}.txt" 2>&1; then
    log "  recorded ${name}"
  else
    warn "  ${name} failed or unavailable (kept partial output)"
  fi
}

log "Recording host facts"
record pveversion pveversion -v
record hostname hostname -f
record uptime uptime

log "Recording network layout"
record ip-addr ip -o addr
record ip-link ip -o link
record ip-route ip route show
record bridges bridge link show

log "Recording storage layout"
record lsblk lsblk -f
record pvesm-status pvesm status
record lvm-pvs pvs
record lvm-vgs vgs
record lvm-lvs lvs
record zpool-list zpool list
record zfs-list zfs list

log "Recording guests and identities"
record qm-list qm list
record pct-list pct list
record user-list pveum user list
record role-list pveum role list
record acl-list pveum acl list
record token-list pveum user token list --output-format json

log "Recording SDN"
record sdn-zones pvesh get /cluster/sdn/zones --output-format json
record sdn-vnets pvesh get /cluster/sdn/vnets --output-format json

# Subnets are addressed per VNet. There is no /cluster/sdn/subnets collection
# endpoint: asking for one returns "No 'get' handler defined" and the capture
# silently keeps that error string in place of every gateway, DHCP range and
# SNAT flag — exactly the facts a rebuild needs and nobody remembers.
record_sdn_subnets() {
  local out="${DEST}/facts/sdn-subnets.txt"
  local vnets vnet
  vnets="$(pvesh get /cluster/sdn/vnets --output-format json 2>/dev/null |
    grep -oE '"vnet":"[^"]*"' | cut -d'"' -f4 | sort -u)" || true
  if [[ -z "${vnets}" ]]; then
    printf 'no vnets defined\n' >"${out}"
    log "  recorded sdn-subnets (none)"
    return 0
  fi
  : >"${out}"
  for vnet in ${vnets}; do
    printf '### vnet: %s\n' "${vnet}" >>"${out}"
    pvesh get "/cluster/sdn/vnets/${vnet}/subnets" --output-format json >>"${out}" 2>&1 ||
      warn "  sdn-subnets for ${vnet} failed or unavailable"
    printf '\n' >>"${out}"
  done
  log "  recorded sdn-subnets"
}
record_sdn_subnets

# Hardware inventory. Directly useful to the Phase 3 BOM work: this is a
# ground-truth record of what the box actually contains.
log "Recording hardware inventory"
record dmidecode-system dmidecode -t system
record dmidecode-memory dmidecode -t memory
record dmidecode-processor dmidecode -t processor
record cpuinfo cat /proc/cpuinfo
record meminfo cat /proc/meminfo

# ---------------------------------------------------------------------------
# Configuration: copied verbatim.
# ---------------------------------------------------------------------------

copy_into() {
  local src="$1"
  local subdir="$2"
  if [[ ! -e "${src}" ]]; then
    log "  skipped ${src} (absent)"
    return 0
  fi
  mkdir -p "${DEST}/config/${subdir}"
  if cp -a "${src}" "${DEST}/config/${subdir}/" 2>/dev/null; then
    log "  copied ${src}"
  else
    warn "  could not fully copy ${src}"
  fi
}

log "Copying configuration"
# /etc/pve is a FUSE filesystem; copy its contents rather than the mount point.
if [[ -d /etc/pve ]]; then
  mkdir -p "${DEST}/config/pve"
  if [[ "${WITH_SECRETS}" -eq 1 ]]; then
    warn "Including /etc/pve/priv — ${DEST} now holds keys and token secrets."
    warn "Store it accordingly, and rotate credentials if you ever restore it."
    cp -a /etc/pve/. "${DEST}/config/pve/" 2>/dev/null || warn "  partial /etc/pve copy"
  else
    # Everything except priv/, which the rebuild regenerates anyway.
    find /etc/pve -mindepth 1 -maxdepth 1 ! -name priv -exec \
      cp -a {} "${DEST}/config/pve/" \; 2>/dev/null || warn "  partial /etc/pve copy"
    log "  copied /etc/pve (excluding priv/)"
  fi
fi

copy_into /etc/network/interfaces network
copy_into /etc/network/interfaces.d network
copy_into /etc/hostname system
copy_into /etc/hosts system
copy_into /etc/resolv.conf system
copy_into /etc/apt/sources.list apt
copy_into /etc/apt/sources.list.d apt

# ---------------------------------------------------------------------------
# Optional guest backups.
# ---------------------------------------------------------------------------

if [[ "${WITH_GUESTS}" -eq 1 ]]; then
  log "Dumping guests (this is slow)"
  mkdir -p "${DEST}/guests"
  ids="$(
    { qm list 2>/dev/null | awk 'NR>1 {print $1}'; pct list 2>/dev/null | awk 'NR>1 {print $1}'; } |
      sort -n | uniq
  )"
  if [[ -z "${ids}" ]]; then
    log "  no guests found"
  else
    for id in ${ids}; do
      log "  vzdump ${id}"
      vzdump "${id}" --dumpdir "${DEST}/guests" --mode snapshot --compress zstd ||
        warn "  vzdump ${id} failed; continuing"
    done
  fi
else
  log "Skipping guest disks (--with-guests not given)"
fi

# ---------------------------------------------------------------------------
# Manifest.
# ---------------------------------------------------------------------------

{
  printf 'Cyberlab host capture\n'
  printf 'captured_at: %s\n' "$(date -Is)"
  printf 'captured_from: %s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf 'with_guests: %s\n' "${WITH_GUESTS}"
  printf 'with_secrets: %s\n' "${WITH_SECRETS}"
} >"${DEST}/MANIFEST.txt"

sync
log "Done. Capture written to ${DEST}"
log "Verify it before wiping anything:"
log "  cat ${DEST}/MANIFEST.txt"
log "  ls -R ${DEST} | head -50"
log "  cat ${DEST}/facts/pvesm-status.txt"
