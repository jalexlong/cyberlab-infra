#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-all}"

STORAGE_VM="local-lvm"
BRIDGE="vmbr0"

DEBIAN_VMID=9003
DEBIAN_NAME="debian13-template"
DEBIAN_URL="${DEBIAN_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"
DEBIAN_FILE="${DEBIAN_FILE:-debian-13-genericcloud-amd64.qcow2}"

PARROT_VMID=9001
PARROT_NAME="parrot-template"
PARROT_URL="${PARROT_URL:-https://deb.parrot.sh/parrot/iso/7.1/Parrot-security-7.1_amd64.qcow2}"
PARROT_FILE="${PARROT_FILE:-Parrot-security-7.1_amd64.qcow2}"

METASPLOITABLE_VMID=9004
METASPLOITABLE_NAME="metasploitable2-template"
METASPLOITABLE_URL="${METASPLOITABLE_URL:-https://downloads.metasploit.com/data/metasploitable/metasploitable-linux-2.0.0.zip}"
METASPLOITABLE_FILE="${METASPLOITABLE_FILE:-metasploitable-linux-2.0.0.zip}"

WORKDIR="/var/lib/vz/template/cache/cyberlab"
mkdir -p "${WORKDIR}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

for cmd in qm curl unzip find; do
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
  local img="${WORKDIR}/${DEBIAN_FILE}"

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

  qm template "${DEBIAN_VMID}"
  echo "Built ${DEBIAN_NAME} (${DEBIAN_VMID})"
}

build_parrot_template() {
  local img="${WORKDIR}/${PARROT_FILE}"

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
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0

  qm template "${PARROT_VMID}"
  echo "Built ${PARROT_NAME} (${PARROT_VMID})"
}

build_metasploitable_template() {
  local zip="${WORKDIR}/${METASPLOITABLE_FILE}"
  local extract_dir="${WORKDIR}/metasploitable2"

  download_if_missing "${METASPLOITABLE_URL}" "${zip}"
  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  unzip -o "${zip}" -d "${extract_dir}"

  local vmdk
  vmdk="$(find "${extract_dir}" -iname '*.vmdk' | head -n 1)"

  if [[ -z "${vmdk}" ]]; then
    echo "No VMDK found in ${extract_dir}" >&2
    exit 1
  fi

  destroy_if_exists "${METASPLOITABLE_VMID}"

  qm create "${METASPLOITABLE_VMID}" \
    --name "${METASPLOITABLE_NAME}" \
    --ostype l26 \
    --memory 2048 \
    --cores 2 \
    --cpu x86-64-v2-AES \
    --scsihw virtio-scsi-pci \
    --net0 virtio,bridge="${BRIDGE}"

  qm importdisk "${METASPLOITABLE_VMID}" "${vmdk}" "${STORAGE_VM}"

  qm set "${METASPLOITABLE_VMID}" \
    --scsi0 "${STORAGE_VM}:vm-${METASPLOITABLE_VMID}-disk-0" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga serial0

  qm template "${METASPLOITABLE_VMID}"
  echo "Built ${METASPLOITABLE_NAME} (${METASPLOITABLE_VMID})"
}

case "${ACTION}" in
  debian)
    build_debian_template
    ;;
  parrot)
    build_parrot_template
    ;;
  metasploitable)
    build_metasploitable_template
    ;;
  all)
    build_debian_template
    build_parrot_template
    build_metasploitable_template
    ;;
  *)
    echo "Usage: $0 {debian|parrot|metasploitable|all}" >&2
    exit 1
    ;;
esac
