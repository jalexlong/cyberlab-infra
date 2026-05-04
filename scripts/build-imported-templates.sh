#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-all}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_FILE="${REPO_ROOT}/data/templates.yml"
WORKDIR="/var/lib/vz/template/cache/cyberlab"
mkdir -p "${WORKDIR}"

STORAGE_VM="${STORAGE_VM:-local-lvm}"

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
ensure_cmd unzip unzip
ensure_cmd find findutils
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

build_import_candidate() {
  local key="$1"
  load_template "${key}"

  local filename
  filename="$(basename "${SOURCE_URL}")"
  local image_path="${WORKDIR}/${filename}"

  download_if_missing "${SOURCE_URL}" "${image_path}"
  destroy_if_exists "${CANDIDATE_VMID}"

  qm create "${CANDIDATE_VMID}" \
    --name "${CANDIDATE_NAME}" \
    --ostype "${OS_TYPE}" \
    --memory "${MEMORY_MB}" \
    --cores "${CPU}" \
    --cpu x86-64-v2-AES \
    --scsihw "${SCSIHW}" \
    --net0 "${NET_MODEL},bridge=${BRIDGE}"

  qm importdisk "${CANDIDATE_VMID}" "${image_path}" "${STORAGE_VM}"

  qm set "${CANDIDATE_VMID}" \
    --scsi0 "${STORAGE_VM}:vm-${CANDIDATE_VMID}-disk-0" \
    --boot order=scsi0

  if [[ "${CLOUD_INIT}" == "true" ]]; then
    qm set "${CANDIDATE_VMID}" \
      --ide2 "${STORAGE_VM}:cloudinit" \
      --serial0 socket \
      --vga serial0
  else
    qm set "${CANDIDATE_VMID}" \
      --serial0 socket \
      --vga std
  fi

  if [[ "${AGENT_EXPECTED}" == "true" ]]; then
    qm set "${CANDIDATE_VMID}" --agent enabled=1
  else
    qm set "${CANDIDATE_VMID}" --agent enabled=0 || true
  fi

  echo "Built candidate ${CANDIDATE_NAME} (${CANDIDATE_VMID})"
}

build_metasploitable_candidate() {
  load_template "metasploitable2"

  local zip_path="${WORKDIR}/$(basename "${SOURCE_URL}")"
  local extract_dir="${WORKDIR}/metasploitable2"

  download_if_missing "${SOURCE_URL}" "${zip_path}"
  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  unzip -o "${zip_path}" -d "${extract_dir}"

  local vmdk
  vmdk="$(find "${extract_dir}" -iname '*.vmdk' | head -n 1)"
  [[ -n "${vmdk}" ]]

  destroy_if_exists "${CANDIDATE_VMID}"

  qm create "${CANDIDATE_VMID}" \
    --name "${CANDIDATE_NAME}" \
    --ostype "${OS_TYPE}" \
    --memory "${MEMORY_MB}" \
    --cores "${CPU}" \
    --cpu x86-64-v2-AES \
    --scsihw "${SCSIHW}" \
    --net0 "${NET_MODEL},bridge=${BRIDGE}"

  qm importdisk "${CANDIDATE_VMID}" "${vmdk}" "${STORAGE_VM}"

  qm set "${CANDIDATE_VMID}" \
    --scsi0 "${STORAGE_VM}:vm-${CANDIDATE_VMID}-disk-0" \
    --boot order=scsi0 \
    --serial0 socket \
    --vga std \
    --agent enabled=0

  echo "Built candidate ${CANDIDATE_NAME} (${CANDIDATE_VMID})"
}

case "${ACTION}" in
  debian13) build_import_candidate "debian13" ;;
  parrot) build_import_candidate "parrot" ;;
  metasploitable|metasploitable2) build_metasploitable_candidate ;;
  all)
    build_import_candidate "debian13"
    build_import_candidate "parrot"
    build_metasploitable_candidate
    ;;
  *)
    echo "Usage: $0 {debian13|parrot|metasploitable2|all}" >&2
    exit 1
    ;;
esac
