#!/usr/bin/env bash
# Detect the management-network settings needed for Cyberlab controller CT 800.
#
# This script is intentionally discovery-only. It does not create or modify any
# Proxmox resources. The host bootstrap playbook should consume the generated
# YAML, configure CT 800, and then validate networking from inside the CT before
# installing packages.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

DEFAULT_GENERATED_DIR="${REPO_ROOT}/private/generated"
DEFAULT_OUTPUT_FILE="${DEFAULT_GENERATED_DIR}/controller-network.yml"

OUTPUT_FILE="${CYBERLAB_CONTROLLER_NETWORK_OUTPUT:-${DEFAULT_OUTPUT_FILE}}"
PRINT_STDOUT=0
QUIET="${CYBERLAB_QUIET:-0}"
ALLOW_EMPTY_DNS="${CYBERLAB_ALLOW_EMPTY_DNS:-0}"

# Operator overrides. Keep these environment-based so install-cyberlab.sh can
# pass through values later without needing a separate config format.
MANAGEMENT_BRIDGE_OVERRIDE="${CYBERLAB_CONTROLLER_BRIDGE:-auto}"
CONTROLLER_VLAN_OVERRIDE="${CYBERLAB_CONTROLLER_VLAN:-auto}"
CONTROLLER_DNS_OVERRIDE="${CYBERLAB_CONTROLLER_DNS:-auto}"
CONTROLLER_IP_OVERRIDE="${CYBERLAB_CONTROLLER_IP:-dhcp}"

warnings=()

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Detect Cyberlab controller CT network settings and write generated Ansible vars.

Options:
  -o, --output FILE   Write YAML to FILE
      --stdout        Also print YAML to stdout
  -q, --quiet         Suppress human-readable status messages
  -h, --help          Show this help

Environment overrides:
  CYBERLAB_CONTROLLER_BRIDGE=auto|vmbr0|vmbr1|...
  CYBERLAB_CONTROLLER_VLAN=auto|none|untagged|null|<1-4094>
  CYBERLAB_CONTROLLER_DNS=auto|"10.64.32.29 10.64.32.31"|"192.168.99.1"
  CYBERLAB_CONTROLLER_IP=dhcp|<cidr-ip>[,gw=<gateway>]
  CYBERLAB_CONTROLLER_NETWORK_OUTPUT=/path/to/controller-network.yml
  CYBERLAB_ALLOW_EMPTY_DNS=0|1

Examples:
  ${SCRIPT_NAME}
  CYBERLAB_CONTROLLER_VLAN=99 ${SCRIPT_NAME}
  CYBERLAB_CONTROLLER_DNS="192.168.99.1" ${SCRIPT_NAME} --stdout
EOF
}

log() {
  if [[ "${QUIET}" != "1" ]]; then
    printf '[%s] %s\n' "${SCRIPT_NAME}" "$*" >&2
  fi
}

warn() {
  warnings+=("$*")
  if [[ "${QUIET}" != "1" ]]; then
    printf '[%s] WARNING: %s\n' "${SCRIPT_NAME}" "$*" >&2
  fi
}

die() {
  printf '[%s] ERROR: %s\n' "${SCRIPT_NAME}" "$*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
}

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  local o1 o2 o3 o4
  IFS=. read -r o1 o2 o3 o4 <<< "${ip}"
  for octet in "${o1}" "${o2}" "${o3}" "${o4}"; do
    [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

is_loopback_or_invalid_dns() {
  local ip="$1"
  [[ "${ip}" == 127.* ]] && return 0
  [[ "${ip}" == "0.0.0.0" ]] && return 0
  [[ "${ip}" == "::1" ]] && return 0
  [[ "${ip}" == "localhost" ]] && return 0
  return 1
}

csv_or_space_to_lines() {
  # Accept comma-separated, whitespace-separated, or mixed input.
  tr ',;' '\n\n' <<< "$*" | tr '[:space:]' '\n' | sed '/^$/d'
}

dedupe_lines() {
  awk '!seen[$0]++'
}

yaml_quote() {
  # Double-quote a string for simple YAML scalar use.
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

yaml_list() {
  local indent="$1"
  shift || true

  if (( "$#" == 0 )); then
    printf '%s[]\n' "${indent}"
    return
  fi

  local item
  for item in "$@"; do
    printf '%s- ' "${indent}"
    yaml_quote "${item}"
    printf '\n'
  done
}

select_default_route() {
  ip -o -4 route show default 2>/dev/null \
    | awk '
        {
          metric = 0
          for (i = 1; i <= NF; i++) {
            if ($i == "metric") {
              metric = $(i + 1)
            }
          }
          print metric "\t" $0
        }' \
    | sort -n -k1,1 \
    | cut -f2- \
    | head -n1
}

route_field() {
  local route="$1"
  local field="$2"
  awk -v field="${field}" '{
    for (i = 1; i <= NF; i++) {
      if ($i == field) {
        print $(i + 1)
        exit
      }
    }
  }' <<< "${route}"
}

is_bridge() {
  local dev="$1"
  [[ -d "/sys/class/net/${dev}/bridge" ]]
}

interface_exists() {
  local dev="$1"
  [[ -d "/sys/class/net/${dev}" ]]
}

available_linux_bridges() {
  local dev
  local dev_path

  for dev_path in /sys/class/net/*; do
    [[ -e "${dev_path}" ]] || continue
    dev="$(basename -- "${dev_path}")"
    if is_bridge "${dev}"; then
      printf '%s\n' "${dev}"
    fi
  done | xargs || true
}

bridge_vlan_filtering_state() {
  local bridge="$1"
  local state_file="/sys/class/net/${bridge}/bridge/vlan_filtering"

  if [[ -r "${state_file}" ]]; then
    cat "${state_file}"
    return 0
  fi

  printf 'unknown'
}

bool_from_vlan_filtering() {
  local state="$1"
  case "${state}" in
    1) printf 'true' ;;
    0) printf 'false' ;;
    *) printf 'null' ;;
  esac
}

host_ipv4_for_dev() {
  local dev="$1"
  ip -o -4 addr show dev "${dev}" scope global 2>/dev/null \
    | awk '{print $4; exit}'
}

parse_resolv_conf_nameservers() {
  local file="$1"
  [[ -r "${file}" ]] || return 0

  awk '
    /^[[:space:]]*nameserver[[:space:]]+/ {
      value = $2
      sub(/#.*/, "", value)
      print value
    }
  ' "${file}"
}

parse_resolv_conf_search_domains() {
  local file="$1"
  [[ -r "${file}" ]] || return 0

  awk '
    /^[[:space:]]*search[[:space:]]+/ {
      for (i = 2; i <= NF; i++) {
        if ($i !~ /^#/) print $i
      }
    }
    /^[[:space:]]*domain[[:space:]]+/ {
      if ($2 !~ /^#/) print $2
    }
  ' "${file}"
}

collect_host_dns() {
  local resolv_files=(
    "/etc/resolv.conf"
    "/run/systemd/resolve/resolv.conf"
  )

  local seen_file=()
  local file
  for file in "${resolv_files[@]}"; do
    [[ -r "${file}" ]] || continue

    # Avoid parsing the same file twice if /etc/resolv.conf points at systemd's file.
    local real_file
    real_file="$(readlink -f -- "${file}" 2>/dev/null || printf '%s' "${file}")"
    local already_seen=0
    local prior
    for prior in "${seen_file[@]:-}"; do
      [[ "${prior}" == "${real_file}" ]] && already_seen=1
    done
    (( already_seen == 1 )) && continue
    seen_file+=("${real_file}")

    parse_resolv_conf_nameservers "${file}"
  done \
    | while read -r ns; do
        ns="$(trim "${ns}")"
        [[ -z "${ns}" ]] && continue
        is_ipv4 "${ns}" || continue
        is_loopback_or_invalid_dns "${ns}" && continue
        printf '%s\n' "${ns}"
      done \
    | dedupe_lines
}

collect_search_domains() {
  local resolv_files=(
    "/etc/resolv.conf"
    "/run/systemd/resolve/resolv.conf"
  )

  local file
  for file in "${resolv_files[@]}"; do
    [[ -r "${file}" ]] || continue
    parse_resolv_conf_search_domains "${file}"
  done \
    | sed 's/[[:space:]]*$//' \
    | sed '/^$/d' \
    | dedupe_lines
}

parse_dns_override() {
  csv_or_space_to_lines "${CONTROLLER_DNS_OVERRIDE}" \
    | while read -r ns; do
        ns="$(trim "${ns}")"
        [[ -z "${ns}" ]] && continue
        is_ipv4 "${ns}" || die "Invalid IPv4 DNS server in CYBERLAB_CONTROLLER_DNS: ${ns}"
        is_loopback_or_invalid_dns "${ns}" && die "DNS server is not usable inside CT 800: ${ns}"
        printf '%s\n' "${ns}"
      done \
    | dedupe_lines
}

validate_vlan_override() {
  local value="$1"

  case "${value}" in
    auto)
      printf 'auto'
      return 0
      ;;
    ''|none|None|null|NULL|untagged|Untagged)
      printf ''
      return 0
      ;;
  esac

  [[ "${value}" =~ ^[0-9]+$ ]] || die "Invalid VLAN override: ${value}"
  (( value >= 1 && value <= 4094 )) || die "VLAN override out of range 1-4094: ${value}"
  printf '%s' "${value}"
}

validate_bridge_override() {
  local value="$1"

  if [[ "${value}" == "auto" ]]; then
    printf 'auto'
    return 0
  fi

  interface_exists "${value}" || die "CYBERLAB_CONTROLLER_BRIDGE=${value} does not exist. Use a Linux bridge such as vmbr0."
  is_bridge "${value}" || die "CYBERLAB_CONTROLLER_BRIDGE=${value} exists but is not a Linux bridge. Containers attach to bridges such as vmbr0, not physical/Wi-Fi interfaces."
  printf '%s' "${value}"
}

warn_if_not_proxmox_host() {
  if ! command -v pveversion >/dev/null 2>&1 || ! command -v pct >/dev/null 2>&1; then
    warn "This does not appear to be a Proxmox VE host. Detection may be incomplete outside the target host."
  fi
}

render_yaml() {
  local generated_at="$1"
  local default_route="$2"
  local default_dev="$3"
  local default_gateway="$4"
  local host_management_ipv4="$5"
  local bridge="$6"
  local vlan="$7"
  local controller_ip="$8"
  local bridge_vlan_aware="$9"
  shift 9

  local -a dns_servers=("${DNS_SERVERS[@]}")
  local -a search_domains=("${SEARCH_DOMAINS[@]}")
  local -a local_warnings=("${warnings[@]:-}")

  {
    printf '# Generated by %s. Do not edit by hand.\n' "${SCRIPT_NAME}"
    printf 'cyberlab_detected_network:\n'
    printf '  generated_at: '; yaml_quote "${generated_at}"; printf '\n'
    printf '  source: '; yaml_quote "host-runtime-discovery"; printf '\n'
    printf '  default_route: '; yaml_quote "${default_route}"; printf '\n'
    printf '  default_route_dev: '; yaml_quote "${default_dev}"; printf '\n'
    printf '  default_gateway: '
    if [[ -n "${default_gateway}" ]]; then yaml_quote "${default_gateway}"; else printf 'null'; fi
    printf '\n'
    printf '  host_management_ipv4: '
    if [[ -n "${host_management_ipv4}" ]]; then yaml_quote "${host_management_ipv4}"; else printf 'null'; fi
    printf '\n'
    printf '  management_bridge: '; yaml_quote "${bridge}"; printf '\n'
    printf '  controller_net_vlan: '
    if [[ -n "${vlan}" ]]; then printf '%s' "${vlan}"; else printf 'null'; fi
    printf '\n'
    printf '  controller_ip: '; yaml_quote "${controller_ip}"; printf '\n'
    printf '  controller_nameservers:\n'
    yaml_list '    ' "${dns_servers[@]:-}"
    printf '  search_domains:\n'
    yaml_list '    ' "${search_domains[@]:-}"
    printf '  bridge_vlan_aware: %s\n' "${bridge_vlan_aware}"
    printf '  detection_warnings:\n'
    yaml_list '    ' "${local_warnings[@]:-}"
  }
}

parse_args() {
  while (( "$#" > 0 )); do
    case "$1" in
      -o|--output)
        [[ "$#" -ge 2 ]] || die "Missing argument for $1"
        OUTPUT_FILE="$2"
        shift 2
        ;;
      --stdout)
        PRINT_STDOUT=1
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
        die "Unknown option: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  log "Override bridge: ${MANAGEMENT_BRIDGE_OVERRIDE}"
  log "Override VLAN: ${CONTROLLER_VLAN_OVERRIDE}"
  log "Override DNS: ${CONTROLLER_DNS_OVERRIDE}"

  require_command basename
  require_command ip
  require_command awk
  require_command sed
  require_command sort
  require_command cut
  require_command head
  require_command readlink
  require_command date

  warn_if_not_proxmox_host

  local default_route
  default_route="$(select_default_route)"
  [[ -n "${default_route}" ]] || die "No IPv4 default route found on the Proxmox host. Configure host management networking first."

  local default_dev default_gateway
  default_dev="$(route_field "${default_route}" dev)"
  default_gateway="$(route_field "${default_route}" via)"

  [[ -n "${default_dev}" ]] || die "Could not parse default-route device from: ${default_route}"
  interface_exists "${default_dev}" || die "Default-route interface does not exist: ${default_dev}"

  local detected_bridge=""
  local detected_vlan=""
  local detection_reason=""

  if [[ "${default_dev}" =~ ^(vmbr[0-9]+)\.([0-9]+)$ ]]; then
    detected_bridge="${BASH_REMATCH[1]}"
    detected_vlan="${BASH_REMATCH[2]}"
    detection_reason="default route uses VLAN subinterface ${default_dev}"
  elif is_bridge "${default_dev}"; then
    detected_bridge="${default_dev}"
    detected_vlan=""
    detection_reason="default route uses bridge ${default_dev}"
  elif [[ "${default_dev}" =~ ^(.+)\.([0-9]+)$ ]] && is_bridge "${BASH_REMATCH[1]}"; then
    detected_bridge="${BASH_REMATCH[1]}"
    detected_vlan="${BASH_REMATCH[2]}"
    detection_reason="default route uses bridge VLAN subinterface ${default_dev}"
  elif interface_exists vmbr0 && is_bridge vmbr0; then
    detected_bridge="vmbr0"
    detected_vlan=""
    detection_reason="default route device is not a bridge; falling back to vmbr0"
    warn "Default route uses ${default_dev}, which is not a bridge. Falling back to vmbr0 for CT networking."
  else
    detected_bridge=""
    detected_vlan=""
    detection_reason="could not infer bridge from default route device ${default_dev}"
  fi

  local bridge_override
  bridge_override="$(validate_bridge_override "${MANAGEMENT_BRIDGE_OVERRIDE}")"

  local controller_bridge
  if [[ "${bridge_override}" == "auto" ]]; then
    controller_bridge="${detected_bridge}"
  else
    controller_bridge="${bridge_override}"
    detection_reason="bridge supplied by CYBERLAB_CONTROLLER_BRIDGE"
  fi
  if [[ -z "${controller_bridge}" ]]; then
    local available_bridges
    available_bridges="$(available_linux_bridges)"
    die "Could not infer a Proxmox bridge from default-route device ${default_dev}. Available Linux bridges: ${available_bridges:-none}. Set CYBERLAB_CONTROLLER_BRIDGE to a Linux bridge such as vmbr0."
  fi

  interface_exists "${controller_bridge}" || die "Detected controller bridge does not exist: ${controller_bridge}"
  is_bridge "${controller_bridge}" || die "Detected controller bridge is not a Linux bridge: ${controller_bridge}"

  local vlan_override
  vlan_override="$(validate_vlan_override "${CONTROLLER_VLAN_OVERRIDE}")"

  local controller_vlan
  if [[ "${vlan_override}" == "auto" ]]; then
    controller_vlan="${detected_vlan}"
  else
    controller_vlan="${vlan_override}"
  fi

  local vlan_filtering_state bridge_vlan_aware
  vlan_filtering_state="$(bridge_vlan_filtering_state "${controller_bridge}")"
  bridge_vlan_aware="$(bool_from_vlan_filtering "${vlan_filtering_state}")"

  if [[ -n "${controller_vlan}" && "${bridge_vlan_aware}" == "false" ]]; then
    warn "Controller VLAN tag ${controller_vlan} was detected/requested, but bridge ${controller_bridge} does not report VLAN filtering enabled. CT tagged traffic may fail."
  fi

  local host_management_ipv4
  host_management_ipv4="$(host_ipv4_for_dev "${default_dev}")"
  if [[ -z "${host_management_ipv4}" ]]; then
    warn "No global IPv4 address found directly on default-route device ${default_dev}."
  fi

  local -a DNS_SERVERS=()
  if [[ "${CONTROLLER_DNS_OVERRIDE}" == "auto" ]]; then
    mapfile -t DNS_SERVERS < <(collect_host_dns)
  else
    mapfile -t DNS_SERVERS < <(parse_dns_override)
  fi

  if (( "${#DNS_SERVERS[@]}" == 0 )); then
    if [[ "${ALLOW_EMPTY_DNS}" == "1" ]]; then
      warn "No usable non-loopback IPv4 DNS servers discovered. Continuing because CYBERLAB_ALLOW_EMPTY_DNS=1."
    else
      die "No usable non-loopback IPv4 DNS servers discovered. Set CYBERLAB_CONTROLLER_DNS to the site-approved DNS server(s)."
    fi
  fi

  local -a SEARCH_DOMAINS=()
  mapfile -t SEARCH_DOMAINS < <(collect_search_domains)

  if [[ "${CONTROLLER_IP_OVERRIDE}" != "dhcp" ]]; then
    warn "Static/non-DHCP controller IP override supplied. This script records it but does not validate syntax beyond preserving the value."
  fi

  log "Default route: ${default_route}"
  log "Detected reason: ${detection_reason}"
  log "Controller bridge: ${controller_bridge}"
  if [[ -n "${controller_vlan}" ]]; then
    log "Controller VLAN: ${controller_vlan}"
  else
    log "Controller VLAN: untagged"
  fi
  log "Controller DNS: ${DNS_SERVERS[*]:-none}"

  local generated_at yaml
  generated_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  yaml="$(render_yaml \
    "${generated_at}" \
    "${default_route}" \
    "${default_dev}" \
    "${default_gateway}" \
    "${host_management_ipv4}" \
    "${controller_bridge}" \
    "${controller_vlan}" \
    "${CONTROLLER_IP_OVERRIDE}" \
    "${bridge_vlan_aware}")"

  mkdir -p -- "$(dirname -- "${OUTPUT_FILE}")"
  printf '%s\n' "${yaml}" > "${OUTPUT_FILE}"
  log "Wrote generated network vars: ${OUTPUT_FILE}"

  if (( PRINT_STDOUT == 1 )); then
    printf '%s\n' "${yaml}"
  fi
}

main "$@"

