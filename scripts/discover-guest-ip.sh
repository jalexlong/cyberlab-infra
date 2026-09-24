#!/usr/bin/env bash
#
# Print the IPv4 address of a Proxmox guest on a bridged, DHCP-addressed
# network. Exits non-zero and prints nothing usable if the address cannot be
# found within the timeout.
#
#   Usage: discover-guest-ip.sh <vmid> [timeout_seconds]
#
# Why this exists
# ---------------
# The template pipeline's finalize stage needs to SSH to the guest, so it needs
# the guest's address. On pve1 that is trivial: templates build over `prov0`
# with a static `bootstrap_ip` from the catalog. pve2 has no SDN -- its only
# network is the flat district LAN, where addresses come from the district's
# DHCP server and cannot be predicted or reserved.
#
# The obvious answer, asking the QEMU guest agent, does NOT work for a first
# build: Debian's genericcloud image does not ship `qemu-guest-agent`, and the
# finalize stage is what installs it. Discovery has to work before that, or the
# pipeline can never finalize a DHCP template even once.
#
# So this resolves the guest's MAC (which Proxmox assigns and therefore knows
# with certainty) to an IPv4 address using the host's own neighbour table. The
# host shares an L2 broadcast domain with the guest, so the mapping is visible
# locally without asking the guest anything.
#
# Strategy, cheapest first:
#   1. Ask the guest agent. Free when it works, and it does on every run after
#      the first, including for clones of a finalized template.
#   2. Read the existing neighbour table. Free; often already populated because
#      the guest ARPs for its gateway the moment it boots.
#   3. Sweep the host's own subnets to force the table to populate, then reread.
#      Only reached on a cold first build.
# Strict mode, with the three places that legitimately tolerate failure marked
# explicitly rather than by leaving -e off for the whole script. Note that -e is
# already suppressed inside `if` conditions and `&&` lists, which is why the
# strategy functions below can return non-zero as a normal outcome.
set -Eeuo pipefail

VMID="${1:?usage: discover-guest-ip.sh <vmid> [timeout_seconds]}"
TIMEOUT="${2:-180}"

log() { printf '%s\n' "$*" >&2; }

# Proxmox writes the MAC into the NIC line, e.g.
#   net0: virtio=BC:24:11:D8:5B:91,bridge=vmbr0,firewall=1
guest_mac() {
  qm config "$VMID" 2>/dev/null \
    | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
    | head -1 \
    | tr '[:upper:]' '[:lower:]'
}

# Strategy 1. The agent returns JSON; parse it with python3, which Proxmox has.
# Never trust `lo` or a link-local address here.
try_agent() {
  qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for iface in data or []:
    if iface.get("name") == "lo":
        continue
    for addr in iface.get("ip-addresses") or []:
        if addr.get("ip-address-type") != "ipv4":
            continue
        ip = addr.get("ip-address") or ""
        if ip and not ip.startswith(("127.", "169.254.")):
            print(ip)
            sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

# Strategy 2. `ip neigh` holds MAC->IP for anything the host has spoken to.
# FAILED/INCOMPLETE entries carry a MAC but no usable address, so exclude them.
try_neigh() {
  local mac="$1"
  ip -4 neigh show 2>/dev/null \
    | grep -i " ${mac} " \
    | grep -viE 'FAILED|INCOMPLETE' \
    | awk '{print $1}' \
    | head -1
}

# Strategy 3. Force population. Sweeping is the last resort, not the first
# move: it is noisy on a school network, so it runs only when the cheap
# strategies have already failed, and only across subnets the host itself is
# on.
sweep_local_subnets() {
  local cidr cidrs n=0

  # Assigned before the loop rather than substituted into the `for` list, so a
  # failing `ip` is a visible empty string rather than an exit mid-function.
  cidrs="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}')" || true

  for cidr in $cidrs; do
    # Expand the CIDR with python3 rather than slicing octets in shell. Deriving
    # the range by hand gets the boundary wrong whenever the host sits in the
    # upper half of a /23 -- 10.64.63.5/23 is the same network as
    # 10.64.62.201/23, and naive "third octet, then third octet + 1" arithmetic
    # sweeps 10.64.64.0/24, which belongs to someone else.
    #
    # Refuse anything bigger than a /22: sweeping it is neither quick nor polite.
    local hosts
    hosts="$(python3 - "$cidr" <<'PY' 2>/dev/null
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    sys.exit(1)
if net.version != 4 or net.prefixlen < 22:
    sys.exit(1)
for host in net.hosts():
    print(host)
PY
)" || continue

    # if/then rather than `[[ ... ]] && continue`: under `set -e` that AND-list
    # returns non-zero whenever the test is false, which would exit the script
    # on exactly the sweeps that should proceed.
    if [[ -z "$hosts" ]]; then
      continue
    fi

    log "  sweeping ${cidr} to populate the neighbour table"

    local addr
    while IFS= read -r addr; do
      ping -c1 -W1 "$addr" >/dev/null 2>&1 &
      n=$(( n + 1 ))
      # Cap concurrency so a /23 does not fork 500 processes at once.
      if (( n % 64 == 0 )); then wait; fi
    done <<< "$hosts"
    wait
  done
}

# `|| true` because an absent guest or an unmatched grep is a case this script
# reports itself, with a better message than the shell's silent exit.
MAC="$(guest_mac || true)"
if [[ -z "$MAC" ]]; then
  log "ERROR: could not read a MAC address from 'qm config $VMID'."
  exit 2
fi
log "guest $VMID has MAC $MAC; discovering its IPv4 address"

DEADLINE=$(( SECONDS + TIMEOUT ))
SWEPT=0

while (( SECONDS < DEADLINE )); do
  if ip_addr="$(try_agent)" && [[ -n "$ip_addr" ]]; then
    log "found via guest agent: $ip_addr"
    printf '%s\n' "$ip_addr"
    exit 0
  fi

  if ip_addr="$(try_neigh "$MAC")" && [[ -n "$ip_addr" ]]; then
    log "found via neighbour table: $ip_addr"
    printf '%s\n' "$ip_addr"
    exit 0
  fi

  if (( SWEPT == 0 )); then
    log "not in the neighbour table yet; forcing a sweep"
    sweep_local_subnets
    SWEPT=1
    continue
  fi

  sleep 5
done

log "ERROR: no IPv4 address for guest $VMID (MAC $MAC) within ${TIMEOUT}s."
log "       The guest may not have booted, or DHCP may not have answered it."
exit 1
