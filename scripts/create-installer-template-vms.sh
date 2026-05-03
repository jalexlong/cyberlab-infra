#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-win7}"

ISO_STORAGE="local"
VM_STORAGE="local-lvm"
BRIDGE="vmbr0"
CACHE_DIR="/var/lib/vz/template/iso"
mkdir -p "${CACHE_DIR}"

WIN7_VMID=9002
WIN7_NAME="win7-template"
WIN7_ISO_URL="${WIN7_ISO_URL:-https://archive.org/download/win-7-ult-sp1-english/Win7_Ult_SP1_English_x64.iso}"
WIN7_ISO_FILE="${WIN7_ISO_FILE:-Win7_Ult_SP1_English_x64.iso}"

VIRTIO_ISO_URL="${VIRTIO_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.189-1/virtio-win-0.1.189.iso}"
VIRTIO_ISO_FILE="${VIRTIO_ISO_FILE:-virtio-win-0.1.189.iso}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for cmd in qm curl; do
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

build_win7_installer_vm() {
  local win7_iso="${CACHE_DIR}/${WIN7_ISO_FILE}"
  local virtio_iso="${CACHE_DIR}/${VIRTIO_ISO_FILE}"

  download_if_missing "${WIN7_ISO_URL}" "${win7_iso}"
  download_if_missing "${VIRTIO_ISO_URL}" "${virtio_iso}"

  destroy_if_exists "${WIN7_VMID}"

  qm create "${WIN7_VMID}" \
    --name "${WIN7_NAME}" \
    --ostype win7 \
    --bios seabios \
    --machine pc \
    --memory 8192 \
    --cores 2 \
    --cpu x86-64-v2-AES \
    --scsihw virtio-scsi-pci \
    --net0 e1000,bridge="${BRIDGE}"

  qm set "${WIN7_VMID}" \
    --scsi0 "${VM_STORAGE}:60" \
    --ide2 "${ISO_STORAGE}:iso/${WIN7_ISO_FILE},media=cdrom" \
    --ide3 "${ISO_STORAGE}:iso/${VIRTIO_ISO_FILE},media=cdrom" \
    --boot order=ide2

  echo
  echo "Windows 7 installer VM created:"
  echo "  VMID: ${WIN7_VMID}"
  echo "  Name: ${WIN7_NAME}"
  echo
  echo "Next steps:"
  echo "  1. Start VM ${WIN7_VMID}"
  echo "  2. Install Windows 7 manually"
  echo "  3. Install VirtIO drivers from the attached ISO"
  echo "  4. Install qemu-guest-agent if desired"
  echo "  5. Shut down the VM"
  echo "  6. Convert it to a template: qm template ${WIN7_VMID}"
  echo
}

case "${ACTION}" in
  win7|all)
    build_win7_installer_vm
    ;;
  *)
    echo "Usage: $0 {win7|all}" >&2
    exit 1
    ;;
esac
