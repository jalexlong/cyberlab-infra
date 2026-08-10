#!/usr/bin/env bash
# Probe network isolation from inside a lab guest, and judge the result.
#
# Runs ON the Proxmox host. Drives a running lab guest through the QEMU guest
# agent and checks what that guest can reach against what it is supposed to be
# able to reach. Exits non-zero on the first verdict that does not match.
#
# This is the generalised form of the one-off /root/fixprobe.sh used to measure
# pve1 on 2026-08-07. That script had every address hardcoded and was run by
# hand exactly once. Phase 5 requires isolation to be proven continuously, so
# the addresses come from the caller (which gets them from the data model) and
# the expected verdicts are asserted rather than eyeballed.
#
# The measured results this reproduces are in docs/network-isolation.md under
# "Enforced and verified".

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

VMID=""
PEER_IP=""
MGMT_IP=""
CACHE_IP=""
CACHE_PORT="3142"
PROV_GATEWAY=""
SECTIONS=""
GUEST_TIMEOUT="200"

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --vmid ID --peer IP --mgmt IP --cache IP [options]

Probe isolation from inside lab guest ID and assert the expected verdicts.

Required:
  --vmid ID            VMID of a running lab guest with the QEMU guest agent
  --peer IP            Address of a second guest in the SAME section. This is
                       the control: it must remain reachable, and a run where
                       everything is blocked proves nothing without it
  --mgmt IP            Proxmox management address, which must NOT be reachable
  --cache IP           Package cache address on svc0

Options:
  --cache-port PORT    Cache port that must answer, default ${CACHE_PORT}
  --prov-gateway IP    prov0 gateway, which must NOT be reachable
  --sections CIDRs     Comma-separated section subnets. The one containing
                       --peer is this guest's own section; every other one is
                       probed and must be blocked
  --timeout SECONDS    Guest agent exec timeout, default ${GUEST_TIMEOUT}
  -h, --help           Show this help

Exit status is 0 only if every verdict matches. The control failing is treated
as an error, not a pass: "nothing is reachable" is the expected output of a
guest with no network at all.
EOF
}

log() {
  printf '[isolation-probe] %s\n' "$*" >&2
}

fail() {
  printf '[isolation-probe] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

parse_args() {
  while (( "$#" > 0 )); do
    case "$1" in
      --vmid) [[ "$#" -ge 2 ]] || fail "Missing argument for --vmid"; VMID="$2"; shift 2 ;;
      --peer) [[ "$#" -ge 2 ]] || fail "Missing argument for --peer"; PEER_IP="$2"; shift 2 ;;
      --mgmt) [[ "$#" -ge 2 ]] || fail "Missing argument for --mgmt"; MGMT_IP="$2"; shift 2 ;;
      --cache) [[ "$#" -ge 2 ]] || fail "Missing argument for --cache"; CACHE_IP="$2"; shift 2 ;;
      --cache-port) [[ "$#" -ge 2 ]] || fail "Missing argument for --cache-port"; CACHE_PORT="$2"; shift 2 ;;
      --prov-gateway) [[ "$#" -ge 2 ]] || fail "Missing argument for --prov-gateway"; PROV_GATEWAY="$2"; shift 2 ;;
      --sections) [[ "$#" -ge 2 ]] || fail "Missing argument for --sections"; SECTIONS="$2"; shift 2 ;;
      --timeout) [[ "$#" -ge 2 ]] || fail "Missing argument for --timeout"; GUEST_TIMEOUT="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown option: $1" ;;
    esac
  done

  [[ -n "${VMID}" ]] || fail "--vmid is required"
  [[ -n "${PEER_IP}" ]] || fail "--peer is required"
  [[ -n "${MGMT_IP}" ]] || fail "--mgmt is required"
  [[ -n "${CACHE_IP}" ]] || fail "--cache is required"
}

# The /24 an address sits in. Section subnets are 10.<teacher>.<section>.0/24
# by construction (data/policy.yml network_policy), so truncating the last
# octet is exact here rather than a guess.
subnet_of() {
  local ip="$1"
  printf '%s.0/24\n' "${ip%.*}"
}

gateway_of() {
  local cidr="$1"
  printf '%s.1\n' "${cidr%.*/*}"
}

# ---------------------------------------------------------------------------
# Build the check table.
#
# Each entry is: expected verdict, label, probe kind, target, port.
# Kinds are `icmp`, `tcp` and `dns`. Expected is `reachable` or `blocked`.
# ---------------------------------------------------------------------------
CHECKS=()

add_check() {
  CHECKS+=("$1|$2|$3|$4|${5:-}")
}

build_checks() {
  local own_subnet
  own_subnet="$(subnet_of "${PEER_IP}")"

  # The control. Guest to guest, never guest to gateway: the section gateway is
  # the host, and the lab-subnet DROP in host.fw blocks it deliberately. Using
  # the gateway as the control reports a broken firewall when the firewall is
  # correct.
  add_check reachable "same-section peer ${PEER_IP} (CONTROL)" icmp "${PEER_IP}"

  # Proxmox management. Reachable before the firewall went on; a student
  # reaching the Web UI is the failure this whole phase exists to prevent.
  add_check blocked "management ICMP ${MGMT_IP}" icmp "${MGMT_IP}"
  add_check blocked "management Web UI ${MGMT_IP}:8006" tcp "${MGMT_IP}" 8006
  add_check blocked "management SSH ${MGMT_IP}:22" tcp "${MGMT_IP}" 22

  # Every other section. Two sections that can reach each other are one section
  # as far as a student is concerned.
  local cidr gw
  if [[ -n "${SECTIONS}" ]]; then
    local saved_ifs="${IFS}"
    IFS=','
    for cidr in ${SECTIONS}; do
      IFS="${saved_ifs}"
      [[ -n "${cidr}" ]] || continue
      [[ "${cidr}" != "${own_subnet}" ]] || continue
      gw="$(gateway_of "${cidr}")"
      add_check blocked "other section gateway ${gw}" icmp "${gw}"
      add_check blocked "other section guest ${gw%.*}.100" icmp "${gw%.*}.100"
      IFS=','
    done
    IFS="${saved_ifs}"
  fi

  # The provisioning network is factory-time infrastructure. A lab guest that
  # reaches it reaches the network templates are built on.
  if [[ -n "${PROV_GATEWAY}" ]]; then
    add_check blocked "prov0 gateway ${PROV_GATEWAY}" icmp "${PROV_GATEWAY}"
  fi

  # Internet. Before the firewall these were blocked only by the absence of a
  # return route, which is not a control -- it is a coincidence of routing that
  # any future SNAT change would silently undo.
  add_check blocked "internet ICMP 1.1.1.1" icmp 1.1.1.1
  add_check blocked "internet TCP 1.1.1.1:443" tcp 1.1.1.1 443

  # DNS. The finding nobody predicted: the zone's dnsmasq is fully recursive,
  # so name resolution was a live exfiltration channel out of an otherwise
  # air-gapped lab.
  add_check blocked "external name resolution" dns deb.debian.org

  # The cache carve-out is a host AND a port. Testing only that the cache works
  # would pass a container with SSH exposed to every student in the building.
  add_check reachable "package cache ${CACHE_IP}:${CACHE_PORT}" tcp "${CACHE_IP}" "${CACHE_PORT}"
  add_check blocked "package cache ${CACHE_IP}:22" tcp "${CACHE_IP}" 22
  add_check blocked "package cache ICMP ${CACHE_IP}" icmp "${CACHE_IP}"
}

# ---------------------------------------------------------------------------
# The guest-side program.
#
# Emitted from the check table, base64'd through `qm guest exec`. It reports
# what it observed and judges nothing; the verdicts are compared on the host so
# a guest cannot report its own success.
# ---------------------------------------------------------------------------
build_guest_script() {
  local entry expected label kind target port

  cat <<'PRELUDE'
icmp() { if ping -c1 -W2 "$1" >/dev/null 2>&1; then echo reachable; else echo blocked; fi; }
tcp()  { if timeout 3 bash -c "echo > /dev/tcp/$1/$2" >/dev/null 2>&1; then echo reachable; else echo blocked; fi; }
dns()  { if timeout 6 getent hosts "$1" >/dev/null 2>&1; then echo reachable; else echo blocked; fi; }
PRELUDE

  local index=0
  for entry in "${CHECKS[@]}"; do
    IFS='|' read -r expected label kind target port <<<"${entry}"
    : "${expected}" "${label}"
    case "${kind}" in
      icmp) printf 'printf "%%s|%%s\\n" %s "$(icmp %s)"\n' "${index}" "${target}" ;;
      tcp)  printf 'printf "%%s|%%s\\n" %s "$(tcp %s %s)"\n' "${index}" "${target}" "${port}" ;;
      dns)  printf 'printf "%%s|%%s\\n" %s "$(dns %s)"\n' "${index}" "${target}" ;;
      *)    fail "Unknown probe kind: ${kind}" ;;
    esac
    index=$((index + 1))
  done
}

run_in_guest() {
  local payload encoded
  payload="$(build_guest_script)"
  encoded="$(printf '%s' "${payload}" | base64 -w0)"

  local raw
  raw="$(qm guest exec "${VMID}" --timeout "${GUEST_TIMEOUT}" -- \
    /bin/bash -c "echo ${encoded} | base64 -d | bash" 2>&1)" \
    || fail "qm guest exec failed against VMID ${VMID}. Is the guest running with qemu-guest-agent installed?"

  printf '%s' "${raw}" | python3 -c '
import json, sys

raw = sys.stdin.read()
try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    sys.stderr.write("guest exec did not return JSON:\n" + raw + "\n")
    raise SystemExit(2)

if payload.get("exited") is not None and not payload.get("exited"):
    sys.stderr.write("guest exec did not complete within the timeout\n")
    raise SystemExit(2)

sys.stdout.write(payload.get("out-data", ""))
err = payload.get("err-data", "")
if err:
    sys.stderr.write(err)
'
}

main() {
  parse_args "$@"

  need_cmd qm
  need_cmd python3
  need_cmd base64

  qm status "${VMID}" 2>/dev/null | grep -q 'status: running' \
    || fail "VMID ${VMID} is not running, so it cannot be probed."

  build_checks
  log "Probing ${#CHECKS[@]} targets from guest ${VMID}"

  local observed
  observed="$(run_in_guest)"

  local failures=0 control_ok=0 index entry expected label verdict
  printf '\n%-10s %-10s %s\n' "EXPECTED" "OBSERVED" "TARGET"
  printf -- '---------- ---------- --------------------------------------------\n'

  for index in "${!CHECKS[@]}"; do
    entry="${CHECKS[${index}]}"
    IFS='|' read -r expected label _ _ _ <<<"${entry}"

    verdict="$(printf '%s\n' "${observed}" | awk -F'|' -v i="${index}" '$1 == i { print $2; exit }')"
    verdict="${verdict//[$'\r\n ']/}"

    if [[ -z "${verdict}" ]]; then
      verdict="NO-RESULT"
    fi

    if [[ "${verdict}" == "${expected}" ]]; then
      printf '%-10s %-10s %s\n' "${expected}" "${verdict}" "${label}"
      [[ "${label}" == *"(CONTROL)"* ]] && control_ok=1
    else
      printf '%-10s %-10s %s   <<< MISMATCH\n' "${expected}" "${verdict}" "${label}"
      failures=$((failures + 1))
    fi
  done

  printf '\n'

  # A failed control invalidates every other line above it. Reported separately
  # because "everything is blocked" is also what a guest with no DHCP lease
  # looks like, and that misreading cost a full round of measurements on
  # 2026-08-07 when a regenerated MAC silently dropped the lease.
  if [[ "${control_ok}" -ne 1 ]]; then
    fail "The same-section control did not pass. Every 'blocked' verdict above is unreliable: a guest with no address reports exactly this. Check the guest holds a DHCP lease before reading anything else."
  fi

  if [[ "${failures}" -gt 0 ]]; then
    fail "${failures} of ${#CHECKS[@]} isolation checks did not match the expected verdict."
  fi

  log "All ${#CHECKS[@]} isolation checks matched, control included."
}

main "$@"
