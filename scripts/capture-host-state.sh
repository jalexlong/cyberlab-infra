#!/usr/bin/env bash
# Capture the state of a Proxmox host before wiping and rebuilding it.
#
# This script is intentionally read-only. It creates and modifies nothing on
# the host; it copies configuration and records the output of query commands.
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
# Secrets: /etc/pve/priv/ holds API token secrets and cluster keys. It is
# EXCLUDED by default, because a rebuild regenerates all of it and because the
# usual destination for this capture is a USB stick. Pass --with-secrets only
# if you have a specific reason, and treat the destination accordingly.

set -Eeuo pipefail
IFS=$'\n\t'

# Declared and assigned separately so that `set -e` still sees a failing
# substitution; `readonly X="$(cmd)"` returns readonly's status, not cmd's.
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

DEST=""
WITH_GUESTS=0
WITH_SECRETS=0

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --dest <directory> [options]

Capture Proxmox host configuration and state before a rebuild. Read-only.

Required:
  --dest <dir>        Where to write the capture (e.g. /mnt/usb/pve1-capture)

Options:
  --with-guests       Also vzdump every VM and container. Slow and large.
  --with-secrets      Also copy /etc/pve/priv/. Off by default; see header.
  -h, --help          Show this help.

Example:
  ${SCRIPT_NAME} --dest /mnt/usb/pve1-\$(date +%Y%m%d)
EOF
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

mkdir -p "${DEST}"/{config,facts}
log "Capturing to ${DEST}"

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
record sdn-subnets pvesh get /cluster/sdn/subnets --output-format json

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
    warn "Including /etc/pve/priv — the destination now holds secret material."
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
