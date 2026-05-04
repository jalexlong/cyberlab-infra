#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-win7}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_FILE="${REPO_ROOT}/data/templates.yml"
CACHE_DIR="/var/lib/vz/template/iso"
mkdir -p "${CACHE_DIR}"

ISO_STORAGE="${ISO_STORAGE:-local}"
VM_STORAGE="${VM_STORAGE:-local-lvm}"

APT_UPDATED=0
ensure_cmd() {
  local cmd="$1"
  local pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return
  fi
  if [[ "${APT_UPDATED}" -eq 0 ]]; then
    apt-get update
    APT_UPDATED=1
  fi
  apt-get install -y "${pkg}"
}

ensure_cmd qm qemu-server
ensure_cmd curl curl
ensure_cmd python3 python3
ensure_cmd python3-yaml python3-yaml

load_template() {
  local key="$1"
  # shellcheck disable=SC1090
  source <(python3 "${REPO_ROOT}/scripts/template_env.py" "${TEMPLATES_FILE}" "${key}")
}

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
    echo "Destroying existing VMID ${vmid}"
    qm stop "${vmid}" >/dev/null 2>&1 || true
    qm destroy "${vmid}" --destroy-unreferenced-disks 1
  fi
}

build_win7_candidate() {
  load_template "win7"

  local win_iso="${CACHE_DIR}/$(basename "${SOURCE_URL}")"
  local virtio_iso="${CACHE_DIR}/$(basename "${DRIVER_ISO_URL}")"

  download_if_missing "${SOURCE_URL}" "${win_iso}"
  download_if_missing "${DRIVER_ISO_URL}" "${virtio_iso}"

  destroy_if_exists "${CANDIDATE_VMID}"

  qm create "${CANDIDATE_VMID}" \
    --name "${CANDIDATE_NAME}" \
    --ostype "${OS_TYPE}" \
    --bios "${BIOS}" \
    --machine "${MACHINE}" \
    --memory "${MEMORY_MB}" \
    --cores "${CPU}" \
    --cpu x86-64-v2-AES \
    --net0 "${NET_MODEL},bridge=${BRIDGE}"

  case "${DISK_BUS}" in
    sata)
      qm set "${CANDIDATE_VMID}" --sata0 "${VM_STORAGE}:${DISK_GB}"
      ;;
    scsi)
      qm set "${CANDIDATE_VMID}" --scsi0 "${VM_STORAGE}:${DISK_GB}"
      ;;
    *)
      echo "Unsupported disk bus: ${DISK_BUS}" >&2
      exit 1
      ;;
  esac

  qm set "${CANDIDATE_VMID}" \
    --ide2 "${ISO_STORAGE}:iso/$(basename "${win_iso}"),media=cdrom" \
    --ide3 "${ISO_STORAGE}:iso/$(basename "${virtio_iso}"),media=cdrom" \
    --boot order=ide2 \
    --agent enabled=0

  echo "Built installer candidate ${CANDIDATE_NAME} (${CANDIDATE_VMID})"
  echo "Install manually, validate, then promote."
}

case "${ACTION}" in
  win7|all) build_win7_candidate ;;
  *)
    echo "Usage: $0 {win7|all}" >&2
    exit 1
    ;;
esac
