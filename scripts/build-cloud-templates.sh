#!/usr/bin/env bash
set -euo pipefail

# Usage examples:
#   sudo bash scripts/build-cloud-templates.sh debian
#   sudo bash scripts/build-cloud-templates.sh parrot
#   sudo bash scripts/build-cloud-templates.sh all
#
# Assumptions:
# - run on the Proxmox host
# - qm is available
# - target storage names already exist
# - snippets/cloud-init storage is available if you want cicustom later

ACTION="${1:-all}"

# ---- Environment-specific defaults ----
STORAGE_VM="local-lvm"
STORAGE_ISO="local"
BRIDGE="vmbr0"

# Template VMIDs expected by your OpenTofu plan
DEBIAN_VMID=9003
PARROT_VMID=9001

DEBIAN_NAME="debian13-template"
PARROT_NAME="parrot-template"

# Current upstream locations should be reviewed periodically.
# Debian: use official genericcloud qcow2.
# Parrot: official download page offers QCOW2 for QEMU/KVM.
DEBIAN_URL="${DEBIAN_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"
PARROT_URL="${PARROT_URL:-https://deb.parrot.sh/parrot/iso/7.1/Parrot-security-7.1_amd64.qcow2}"

WORKDIR="/var/lib/vz/template/cache/cyberlab"
mkdir -p "${WORKDIR}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for cmd in qm pvesm curl sha256sum; do
  need_cmd "$cmd"
done

download_if_missing() {
  local url="$1"
  local outfile="$2"

  if [[ -f "${outfile}" ]]; then
    echo "Using cached file: ${outfile}"
    return
  fi

  echo "Downloading ${url}"
  curl -L --fail --output "${outfile}" "${url}"
}

destroy_if_exists() {
  local vmid="$1"
  if qm status "${vmid}" >/dev/null 2>&1; then
    echo "VMID ${vmid} already exists. Destroying it first."
    qm stop "${vmid}" >/dev/null 2>&1 || true
    qm destroy "${vmid}" --destroy-unreferenced-disks 1
  fi
}

build_debian_template() {
  local img="${WORKDIR}/debian-13-genericcloud-amd64.qcow2"

  download_if_missing "${DEBIAN_URL}" "${img}"
  destroy_if_exists "${DEBIAN_VMID}"

  qm create "${DEBIAN_VMID}" \
    --name "${DEBIAN_NAME}" \
    --ostype l26 \
    --scsihw virtio-scsi-pci \
    --agent enabled=1 \
    --memory 2048 \
    --cores 2 \
    --cpu x86-64-v2-AES \
    --net0 virtio,bridge="${BRIDGE}"

  qm importdisk "${DEBIAN_VMID}" "${img}" "${STORAGE_VM}"

  qm set "${DEBIAN_VMID}" \
    --scsi0 "${STORAGE_VM}:vm-${DEBIAN_VMID}-disk-0" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0 \
    --ide2 "${STORAGE_VM}:cloudinit"

  # Optional: resize if you want a larger default root disk
  # qm resize "${DEBIAN_VMID}" scsi0 8G

  qm template "${DEBIAN_VMID}"

  echo "Built template ${DEBIAN_NAME} (${DEBIAN_VMID})"
}

build_parrot_template() {
  local img="${WORKDIR}/parrot-security-amd64.qcow2"

  download_if_missing "${PARROT_URL}" "${img}"
  destroy_if_exists "${PARROT_VMID}"

  qm create "${PARROT_VMID}" \
    --name "${PARROT_NAME}" \
    --ostype l26 \
    --scsihw virtio-scsi-pci \
    --agent enabled=1 \
    --memory 4096 \
    --cores 2 \
    --cpu x86-64-v2-AES \
    --net0 virtio,bridge="${BRIDGE}"

  qm importdisk "${PARROT_VMID}" "${img}" "${STORAGE_VM}"

  qm set "${PARROT_VMID}" \
    --scsi0 "${STORAGE_VM}:vm-${PARROT_VMID}-disk-0" \
    --boot order=scsi0

  # Optional: resize if desired
  # qm resize "${PARROT_VMID}" scsi0 16G

  qm template "${PARROT_VMID}"

  echo "Built template ${PARROT_NAME} (${PARROT_VMID})"
}

case "${ACTION}" in
  debian)
    build_debian_template
    ;;
  parrot)
    build_parrot_template
    ;;
  all)
    build_debian_template
    build_parrot_template
    ;;
  *)
    echo "Usage: $0 {debian|parrot|all}" >&2
    exit 1
    ;;
esac
