# Network isolation and egress suppression

How the appliance stays silent on a school network.

**Written:** 2026-08-05
**Status:** design. Nothing here is implemented or verified on hardware yet.
**Related:** `docs/roadmap.md` Phase 5 (isolation), Phase 2.5 (package cache),
Phase 7 (site survey).

---

## The requirement

A district sysadmin's monitoring should see this appliance as one quiet host
that speaks only when spoken to. Anything else — stray ICMP, port scans
leaking from lab guests, broadcast to `255.255.255.255`, multicast discovery,
cluster heartbeat — is at best unexplained traffic on someone else's network
and at worst an IDS alert with our name on it.

The goal is stated negatively on purpose: **no packet leaves the uplink unless
a rule exists that says it should.** Default-deny outbound, not default-allow
with exceptions bolted on.

### Ranked by expected damage

Probability times severity, not severity alone. An earlier draft of this
document ranked by severity and put rogue DHCP and BPDUs at the top; both are
severe but neither is likely, and ranking that way misdirects attention toward
exotic failures and away from the ones that will actually happen by default.

| # | Leak | Likelihood | Consequence |
|---|---|---|---|
| 1 | **Lab guest traffic escaping** | **High** — depends on firewall rules being right, and `snat: false` is already suspected insufficient (roadmap, Phase 5) | Looks exactly like an internal attacker. `nmap` from a student VM is indistinguishable from a real compromise |
| 2 | **Phone-home** — subscription checks, `apt` timers, NTP pools | **High** — on by default; happens unless explicitly suppressed | Unexplained outbound to the internet from a box sold as air-gapped. Erodes the central product claim |
| 3 | **Corosync heartbeat on the uplink** | **Moderate** — only if the cluster network is not physically separated | Constant unexplained UDP between unknown hosts, every few hundred ms, forever |
| 4 | **mDNS / LLMNR / NetBIOS broadcast** | **Moderate** — if `avahi-daemon` is installed | Noise; clutters discovery tooling |
| 5 | **Stray ICMP** | Moderate | Mostly harmless, trivially avoidable |
| 6 | **Rogue DHCP** — SDN `dnsmasq` answering on the uplink | **Low** — requires a VNet deliberately bridged to a physical NIC | School devices take `10.30.0.x` leases and lose network. Ejection from the district network |
| 7 | **BPDUs from a Linux bridge** | **Low** — Proxmox generates `bridge_stp off` | BPDU guard err-disables the switch port. Visible outage, and the logs name us |

Items 6 and 7 stay on the list despite low likelihood because both are cheap to
assert against and expensive to discover. That is a different argument from
"design around them," and they should not consume design attention ahead of
items 1 and 2.

---

## The architectural decision that does most of the work

**Do not uplink the switch. Uplink one node.**

The roadmap's Phase 3 currently puts 3-5 nodes plus a teacher console on an
8-port unmanaged switch, with the switch uplinked to the wall port. That
topology cannot be made quiet by firewall rules, because the noisiest classes
of traffic are layer 2:

- An unmanaged switch floods **broadcast and multicast to every port**,
  including the uplink. ARP, mDNS, DHCP, BPDUs — all of it reaches the school
  network regardless of what any host firewall says, because a layer 3 filter
  never sees them leave.
- Corosync unicast between nodes mostly stays local through MAC learning, but
  that is a property of switch behaviour, not a guarantee, and it degrades
  under flooding conditions (unknown-unicast flooding, MAC table overflow).

So separate the two networks **physically**:

```
                      ┌──────────────────────────────┐
   district wall port │                              │
   ───────────────────┤ uplink node (vmbr0)          │
                      │   only host with a district  │
                      │   facing interface           │
                      │                              │
                      │        vmbr1 ────────────────┼──┐
                      └──────────────────────────────┘  │
                                                        │
                      ┌──────────────────────────────┐  │
                      │ node 2 (vmbr1 only)          ├──┤  8-port unmanaged
                      └──────────────────────────────┘  │  switch — NO uplink
                      ┌──────────────────────────────┐  │
                      │ node 3 (vmbr1 only)          ├──┘
                      └──────────────────────────────┘
```

Everything cluster-related — corosync, pmxcfs, template replication, NTP
peering, node management — lives on `vmbr1` and has **no physical path** to the
district. Broadcast cannot escape a switch that is not connected to anything.

**BOM consequence.** The uplink node needs a second NIC. Most Tiny/SFF
candidates ship with one, so budget a USB3 gigabit adapter for that one node,
or select a dual-NIC model (some ThinkCentre M920q and OptiPlex Micro units
take an optional second NIC in the Flex/expansion slot — verify per model,
and prefer the internal option over USB where it exists). This is one adapter
for the whole cluster, not one per node.

**Accepted consequence.** The uplink node is a single point of failure for
student access. Consistent with the existing no-HA decision: a node failure
kills the pods on it and students restart. Here it would mean nobody reaches
Guacamole until that node is back. Acceptable for a classroom; worth stating
in the product documentation rather than discovering.

**If a second NIC is genuinely impossible**, the fallback is a managed switch
with VLANs — which contradicts the roadmap's deliberate "keep it dumb"
reasoning and adds config that can drift from the recipe. Prefer the adapter.

---

## Aside: what BPDU guard is, and why it is not a MAC whitelist

Worth writing down because it is easy to mistake for port security, and the
two behave nothing alike.

**Spanning Tree Protocol** exists to stop layer 2 loops. Switches flood
broadcast, so a loop between two switches melts a network in seconds. STP
prevents that by having switches exchange **BPDUs** (Bridge Protocol Data
Units) to elect a root bridge and block redundant paths.

**BPDUs are supposed to come only from switches.** A wall jack in a classroom
is an *access port* — an end host plugs in there, and end hosts have no
business speaking STP. So access ports are typically configured with PortFast
(or "edge port") to skip STP's listening/learning delay, and **BPDU guard** is
applied alongside it.

BPDU guard's entire logic is: *if a BPDU is ever received on this port, shut
the port down.* The port goes to `err-disable`, and it stays down until an
admin clears it or an errdisable-recovery timer expires. **One frame is
enough.**

**So it is protocol-presence detection, not identity.** There is no MAC
whitelist, no list to be on, no RBAC, and nothing is compared against anything.
The switch is not asking *who* sent this — it is reacting to the fact that
this protocol appeared somewhere it must never appear. The distinction from
what it is commonly confused with:

| Mechanism | Question it asks | Basis |
|---|---|---|
| **BPDU guard** | "Did an STP frame arrive on an edge port?" | Protocol presence. No identity involved |
| **Port security / sticky MAC** | "Is this MAC allowed here, and how many are there?" | MAC whitelist — genuinely identity-based |
| **802.1X / NAC** | "Has this device authenticated?" | Credentials, closest to RBAC |
| **Root guard** | "Did a *superior* BPDU arrive?" | Accepts BPDUs, rejects ones that would change root election |

**Why it matters here, and why it is item 7 rather than item 2.** A Linux
bridge *can* speak STP, and if it does, and there is a path to a school access
port, the port shuts. But Proxmox generates `bridge_stp off` in
`/etc/network/interfaces` by default, and with the one-uplink topology no VNet
bridge has a physical path to the district at all. So the realistic exposure is
narrow: someone enabling STP on a bridge to be "safe," or a future topology
that plugs both the switch and a node into wall jacks — which would also create
the physical loop STP exists to catch. The mitigation is a one-line assert that
`bridge_stp` is off on every bridge, plus never building that topology.

---

## What must be allowed to broadcast

Default-deny outbound is the rule, but a few things are genuinely mandatory,
and denying them breaks the link rather than quieting it.

**On the uplink, the only required broadcast is ARP.** ARP requests go to
`ff:ff:ff:ff:ff:ff` and are unavoidable — every device on every network does
this constantly, and no monitoring system flags it. It must be permitted.

**DHCP is not required on the uplink, and should not be used.** A static
address on the district-facing interface means the host never emits
`DHCPDISCOVER` to `255.255.255.255`, never appears in the district's DHCP
logs, and never depends on a lease surviving. This is the one place where
choosing static over DHCP is a genuine isolation control rather than a
preference — it removes an entire class of broadcast rather than filtering it.

**DHCP *is* required inside lab VNets, and stays there.** The DORA exchange is
broadcast by definition, and Phase 5's exit criterion explicitly proves
`DHCPDISCOVER` receives `DHCPOFFER`. That traffic never reaches the uplink,
because a `simple` zone bridge has no physical port — which is also why rogue
DHCP is item 6 rather than item 1.

Everything else — mDNS (`5353`), LLMNR, NetBIOS (`137/138`), directed
broadcast to `255.255.255.255`, and all multicast (`224.0.0.0/4`) — is denied
and logged on the uplink.

---

## Sequencing: deny before the link comes up

The window between "uplink is live" and "firewall is enforcing" is the window
in which everything above leaks. It should be zero, and it can be, because
nothing requires the link to exist before rules are written.

**Order the bootstrap so the firewall is enforcing *before* the interface is
brought up**, rather than immediately after. Concretely:

1. Write the firewall configuration with default-deny and enable it.
2. **Assert it is active** — read the state back rather than trusting that
   applying it worked. This repository has been bitten twice by steps that
   passed by doing nothing.
3. Only then bring up the uplink interface.
4. Only then start the build and seeding work.

Deny-then-connect is strictly better than connect-then-deny and costs nothing
extra. It also means a failure to apply the firewall leaves the box offline
rather than loud — the correct direction to fail.

### Two firewall profiles, mirroring the factory/site split

The build needs egress that a deployed unit must never have, so the rules are
not the same in both states. Rather than editing one profile back and forth,
carry two — the same shape as the existing factory/site split:

| | Factory profile | Site profile |
|---|---|---|
| Outbound `80/443` from the package cache | Allowed | **Denied** |
| Outbound `80/443` from template builds via `prov0` | Allowed | `prov0` does not exist |
| Inbound Guacamole | Allowed | Allowed |
| Everything else outbound | Denied and logged | Denied and logged |

**Shipping means switching to the site profile and asserting the factory
allows are gone** — not assuming they were removed. Pair it with the existing
Phase 2.5 assertion that no subnet carries `snat: true`, since those two
together are what actually make the unit air-gapped rather than merely
configured to look that way.

---

## What Proxmox emits by default

Enumerated so that suppression can be checked off against it rather than
assumed. **Not yet verified by capture on this hardware** — this is the list
to *test against*, and the verification section below is how.

| Source | Traffic | Default | Suppression |
|---|---|---|---|
| Corosync (knet) | UDP 5405-5412, node to node | On once clustered | Bind to `vmbr1` via `ring0_addr` on the cluster subnet |
| pmxcfs | Rides corosync | On | Same |
| SDN `dnsmasq@<zone>` | DHCP/DNS on VNet bridges | On per zone | Structurally contained — a `simple` zone bridge has no physical port, so this cannot reach the uplink without a VNet being deliberately bridged to a NIC. Assert that invariant rather than configuring around it |
| Host DHCP client | `DHCPDISCOVER` to `255.255.255.255` | If uplink is DHCP | **Static IP on the uplink.** Never DHCP |
| `pve-daily-update.timer` | Repo + `shop.proxmox.com` | On | Disable at site, or point at the package cache |
| `apt-daily(-upgrade).timer` | Debian repos | On | Disable at site |
| `pvesubscription` | `shop.proxmox.com` | Periodic | Set off; also deny by rule |
| `systemd-timesyncd` / chrony | UDP 123 to NTP pools | On | Local stratum only, peers on `vmbr1` |
| `avahi-daemon` | mDNS multicast | Sometimes installed | Purge, do not merely disable |
| IPv6 | RS/NS, `ff02::` multicast | On | `accept_ra=0`, disable on uplink |
| Linux bridge STP | BPDUs | Off in PVE-generated config, **but confirm for SDN bridges** | `bridge_stp off`, and verify no BPDU egresses |
| LLDP | Neighbour advertisements | Only if `lldpd` installed | Do not install |

---

## Firewall rules

Proxmox firewall, per the Phase 5 decision. Enforced at each guest's
tap/veth and at the host, so it does not depend on routing topology.

> **Syntax caveat.** The blocks below are the intended *shape*. PVE 8.2 moved
> the firewall to an nftables backend and added host `FORWARD` rules, so exact
> directives must be checked against the installed version's documentation
> when this is implemented. Do not paste these in unverified.

### `cluster.fw`

```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP

[ALIASES]
uplink_gw      10.64.62.1
mgmt_net       10.64.62.0/24
cluster_net    10.32.0.0/24
svc_net        10.31.0.0/24
prov_net       10.30.0.0/24
broadcast      255.255.255.255

[IPSET cluster_nodes]
10.32.0.11
10.32.0.12
10.32.0.13

[IPSET admin_hosts]
# teacher workstation only; not the whole district subnet

[IPSET pkg_cache]
10.31.0.10

[IPSET guacamole]
10.31.0.20

[group lab_guest]
# Applied to every lab VM and CT. Stateful: return traffic needs no rule.
IN  ACCEPT -source +pod_subnet
IN  ACCEPT -source +guacamole -p tcp -dport 22,3389,5900:5999
OUT ACCEPT -dest +pod_subnet
OUT ACCEPT -dest +pkg_cache -p tcp -dport 3142
OUT ACCEPT -dest +vnet_gateway -p udp -dport 53,67,68
OUT DROP   -dest +broadcast -log warning
OUT DROP   -dest 224.0.0.0/4 -log warning
OUT DROP   -log warning

[group uplink_quiet]
# Applied to the uplink interface on the one district-facing node.
OUT DROP -dest +broadcast -log warning
OUT DROP -dest 224.0.0.0/4 -log warning
OUT DROP -p icmp -log warning
OUT DROP -p udp -dport 123 -log warning
OUT DROP -p udp -dport 5353 -log warning
OUT DROP -p udp -dport 137:138 -log warning
```

The `-log warning` on the final drops is deliberate: a silent default-deny
tells you nothing, and the whole point of this exercise is being able to
answer "what did the box try to send?" before a sysadmin has to ask.

### `host.fw`, uplink node

```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP

[RULES]
# Inbound: students reach Guacamole. This is the entire district-facing surface.
IN  ACCEPT -i vmbr0 -p tcp -dport 443

# Admin, restricted to known hosts. Not open to the district subnet.
IN  ACCEPT -i vmbr0 -source +admin_hosts -p tcp -dport 8006
IN  ACCEPT -i vmbr0 -source +admin_hosts -p tcp -dport 22

# Cluster traffic: private interface only, never the uplink.
IN  ACCEPT -i vmbr1 -source +cluster_nodes -p udp -dport 5405:5412
OUT ACCEPT -o vmbr1 -dest   +cluster_nodes -p udp -dport 5405:5412
IN  ACCEPT -i vmbr1 -source +cluster_nodes -p udp -dport 123
OUT ACCEPT -o vmbr1 -dest   +cluster_nodes -p udp -dport 123
IN  ACCEPT -i vmbr1 -source +cluster_nodes -p tcp -dport 22,8006

# Everything else outbound on the uplink is denied and logged.
GROUP uplink_quiet -i vmbr0
```

### `host.fw`, non-uplink nodes

Identical minus the `vmbr0` rules — those nodes have no district-facing
interface at all, which is the point.

### Optional egress, when a district permits it

Egress is an optimization, never a requirement (Phase 2.5). Where allowed,
open it narrowly and only on the uplink node:

```
OUT ACCEPT -o vmbr0 -source +pkg_cache -p tcp -dport 80,443
```

Only the cache reaches out, only on HTTP/HTTPS. Hosts still do not.

---

## OS-level hardening

Firewall rules do not cover everything; several of these are the only control
for their class of traffic.

```
# Anti-spoof and anti-noise
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1

# IPv6 off on the uplink; the district is almost certainly v4-only
net.ipv6.conf.vmbr0.disable_ipv6 = 1
net.ipv6.conf.all.accept_ra = 0
```

`net.ipv4.ip_forward=1` stays — the SDN requires it, and
`controller-bootstrap-sdn.yml` asserts it. That is precisely why the
guest-level default-deny has to carry the isolation rather than the routing
topology. See the Phase 5 note on `snat: false`.

Service suppression:

```
systemctl disable --now pve-daily-update.timer
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
systemctl disable --now systemd-timesyncd     # if chrony is the time source
apt-get purge avahi-daemon                    # purge, not disable
```

Time, per the roadmap's offline-NTP note: one node is the cluster time source,
running `local stratum 10` with **no upstream pool or server directives** at
site, peering only across `vmbr1`. Without this every node quietly tries to
reach `*.pool.ntp.org` forever.

---

## Guest-level invariants

These are assertions for the pod engine and the isolation test, not
configuration:

- **No lab guest may have a NIC on `vmbr0` or `vmbr1`.** Lab guests attach to
  pod VNets only. The repo already keeps VMs NIC-less by convention
  (`8ae9823`); this makes it a checked invariant rather than a habit.
- **Every lab NIC has `firewall=1`.** Without it the rules above are present,
  correct, and not applied — see the Phase 5 note. Assert per guest.
- **No subnet at site carries `snat: true`.** `prov0` is factory-only and must
  not exist on a shipped unit. Assert its absence rather than its
  configuration.
- **Windows guests broadcast constantly** (NetBIOS, LLMNR, mDNS). That is
  fine and stays inside the VNet, because a `simple` zone bridge has no
  physical uplink. It is only a problem if a guest is ever bridged to
  `vmbr0`, which the first invariant prevents.

---

## Verification

Design claims about silence are worth nothing unverified. Every item below
produces evidence, and the last one is the one that actually persuades a
sysadmin.

1. **Capture on the uplink.** Mirror the wall port, or put a laptop inline,
   and capture for a full class period with a lab running. The only things
   present should be ARP for the gateway and TCP on the Guacamole port.
   Anything else is a bug with a packet attached to it.
2. **Scan from the district side.** `nmap` the appliance from a school-side
   host. Only the Guacamole port answers. Management ports must not respond
   from anywhere but `admin_hosts`.
3. **Scan from inside a lab guest.** `nmap` the management subnet, the other
   pod subnets, and the district range. Everything times out. This is the
   student-attacker case and the one most likely to be quietly wrong.
4. **Pull the cable.** With the uplink unplugged, a full lab session still
   works end to end — pods start, consoles broker, packages install from the
   cache. Anything that breaks was an undeclared dependency.
5. **Check the drop log.** After a week of real classroom use, read the
   logged drops. Each one is either a suppression that is working or a
   phone-home nobody had accounted for.
6. **Hand the sysadmin the capture.** A pcap and a one-page summary saying
   "here is everything this box emitted in a week" is a materially different
   conversation from "trust me, it's isolated." Do this during the pilot, and
   it becomes a reusable sales artifact for the prebuilt SKU.
