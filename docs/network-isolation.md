# Network isolation and egress suppression

How the appliance stays silent on a school network.

**Written:** 2026-08-05
**Last revised:** 2026-08-07 — isolation failure measured end to end
**Status:** design, with a measured failure to design against. Nothing here is
implemented. The *baseline* was measured on `pve1` 2026-08-05; the
*consequence* — that lab guests reach the management address, each other
across sections, and a recursive resolver — was measured 2026-08-07. The rule
set itself remains unimplemented and untested.
**Related:** `docs/roadmap.md` Phase 5 (isolation), Phase 2.5 (package cache),
Phase 7 (site survey).

---

## Measured baseline — `pve1`, 2026-08-05

Read off the live host rather than assumed. Several of this document's first-
draft assumptions were wrong, and are corrected throughout.

| Fact | Value |
|---|---|
| Proxmox VE | **9.2.9** (`proxmox-ve 9.2.0`), Debian 13 trixie, kernel 6.17.13-4-pve |
| Firewall packages | `pve-firewall 6.0.5` (legacy) and `proxmox-firewall 1.2.3` (nftables), **both services enabled and active** |
| Active backend | **Neither is producing rules.** `nft list tables` is empty and no `nftables: 1` opt-in exists in `/etc/pve` |
| Datacenter firewall | **`enable: 0` in `cluster.fw` — disabled.** Per-guest configs exist and are inert because of it |
| School network | **`10.64.62.0/23`**, not a `/24`. `vmbr0` is `10.64.62.200/23` |
| `net.ipv4.ip_forward` | `1` |
| Bridge STP | `0` (off) on `vmbr0` and `prov0` |
| `avahi-daemon` | **Not installed** — only `libavahi-*` client libraries |
| Time sync | `chrony` **active and syncing to the public pool** |

### What this changes

- **The firewall being disabled is the headline.** `pve-firewall status`
  reports `disabled/running`. This is the empirical half of the `snat: false`
  suspicion in Phase 5: forwarding is on, the host holds a gateway on every
  VNet subnet, and **nothing is filtering**. The remaining unknown is only
  whether lab guests can therefore reach the management address, which still
  needs a section VNet and a guest to test.
- **Guest-level `enable: 1` does nothing while the datacenter firewall is
  off.** `500.fw` carries it and has no effect. The enable flags are a
  hierarchy, not independent switches, and the outermost one wins. Worth
  stating because the failure is silent in the safe direction now — rules
  simply do not apply — but becomes silent in the *unsafe* direction later:
  once the datacenter firewall is enabled, every guest that was relying on
  nothing suddenly inherits whatever its `.fw` file says.
- **`chrony` is a live, continuous egress path right now.** It is reaching
  `2.debian.pool.ntp.org` with four sources at full reachability. Item 2 in the
  ranking below is not hypothetical on this host; it is happening.
- **mDNS drops down the list, not off it.** `avahi-daemon` is not installed,
  only its client libraries, so nothing on the *host* emits mDNS. Windows lab
  guests still will, which is why it stays in the ranking at 5 rather than
  disappearing.
- **BPDU risk is confirmed low.** STP is off on both bridges, as predicted.
- **Every subnet mask in this document was wrong.** The school network is a
  `/23`. Rules below use `10.64.62.0/23`.

### Stale state to clear before the rebuild

Found incidentally and worth removing rather than carrying forward, consistent
with the roadmap's position that the current host is a disposable
proto-prototype:

- `/etc/pve/firewall/500.fw` — VM `500` is the decommissioned
  `farmcardscode.org` host. Its `enable: 1` was a deliberate step toward
  experimenting with the Proxmox firewall; the experimentation went to
  OPNsense instead, so this is an abandoned starting point rather than a
  mistake.
- `/etc/pve/firewall/9004.fw` — a template VMID.
- `cluster.fw` aliases `lab-net1 10.0.2.0/24` and `prod-net 10.0.1.0/24`,
  neither of which exists in the current design.
- **Duplicate SNAT rules.** `iptables-save -t nat` shows the
  `10.30.0.0/24 -> vmbr0` masquerade repeated five times, alongside a stale
  `10.0.12.0/24` rule for a subnet the SDN no longer defines. **The SDN apply
  path appends rather than reconciles**, so rules accumulate across runs. Worth
  a check in the rebuild — an idempotent playbook that leaves a growing
  ruleset behind is not idempotent where it counts.

---

## Measured: isolation is broken, and DNS is the surprise — `pve1`, 2026-08-07

The 2026-08-05 baseline recorded the *preconditions* and left the consequence
untested, because section VNets existed on no host and there was nothing to
test from. That gap is now closed. All four section VNets were built with
`controller-bootstrap-sdn.yml -e cyberlab_sdn_build_sections=true`, two
disposable Debian 13 guests were cloned onto two different sections, and the
probes were run from inside one of them.

Test rig: guest `950` on `t101c011` (`10.101.11.100`), guest `955` on
`t101c112` (`10.101.112.100`), both by DHCP, both NICs with `firewall=0`,
datacenter firewall still `enable: 0`.

| From a lab guest, target | Result | Should be |
|---|---|---|
| Own section gateway `10.101.11.1` | **reachable** | reachable (control) |
| **Proxmox management `10.64.62.200` ICMP** | **REACHABLE** | blocked |
| **Proxmox Web UI `10.64.62.200:8006`** | **REACHABLE** | blocked |
| **Proxmox SSH `10.64.62.200:22`** | **REACHABLE** | blocked |
| Other section gateway `10.101.112.1` | **REACHABLE** | blocked |
| **Other section's guest `10.101.112.100`** | **REACHABLE** | blocked |
| Third section gateway `10.101.123.1` | **REACHABLE** | blocked |
| `prov0` gateway `10.30.0.1` | **REACHABLE** | blocked |
| District gateway `10.64.62.1` | blocked | blocked |
| Controller CT `800` at `10.64.62.74`, ICMP and tcp/22 | blocked | blocked |
| Internet `1.1.1.1` / `8.8.8.8`, ICMP and tcp/443 | blocked | blocked |
| **Recursive DNS for any name** | **REACHABLE** | blocked |

**The Phase 5 prediction was right, and the ranking of severity was right.**
Roadmap Phase 5 said to expect all three of management, cross-section and
`prov0` to succeed. All three do. Isolation is a firewall project, exactly as
predicted, not an SDN-flag project.

### Why the district LAN is blocked but the management address is not

These look inconsistent and are not. `10.64.62.200` is an address *on the host
itself*, so a guest packet is delivered locally and the host answers from an
interface that already has a route back to `10.101.11.0/24`. Traffic to
`10.64.62.1` or `10.64.62.74` must instead be *forwarded* out `vmbr0`, and
with `snat: false` it arrives carrying a `10.101.11.100` source address that
those devices have no route back to.

**So the district LAN and internet are protected by the absence of a return
route, not by a policy.** That is an accident of addressing, and it is one
static route on a district device — or one SNAT rule added later for a good
reason — away from evaporating. It should not be counted as isolation. The
management address, meanwhile, needs no forwarding at all, which is exactly why
it is the one that fails.

### The finding that was not predicted: DNS is a live egress channel

`getent hosts deb.debian.org` succeeds from a lab guest. This is not a cached
or hosts-file answer: a randomly generated name under `example.com` returns
`NXDOMAIN`, which means the query genuinely reached upstream recursion and came
back with an authoritative answer. **tcp/53 to the VNet gateway is also open**,
which is the high-bandwidth variant. A direct UDP query to `8.8.8.8` times out,
so guests cannot bypass the gateway — but they do not need to, because the
zone's `dnsmasq` resolves on their behalf and the host has egress.

This matters more than it first sounds:

- **It is a data exfiltration path.** DNS tunnelling over a fully recursive
  resolver, with TCP available, is a standard technique — and this is a lab
  whose entire purpose is teaching students to find exactly this kind of thing.
  "No egress from lab networks" is currently false, and false through the one
  protocol nobody thinks of as egress.
- **It inverts the naive-test warning already in the roadmap.** Phase 5 warns
  that testing the internet *by name* can fail for the wrong reason and pass a
  naive test. The live host shows the mirror image: name resolution **succeeds**
  while IP reachability **fails**. A by-name test would report the internet
  reachable; a by-IP test reports it blocked. Both are misleading alone, so the
  isolation test has to assert both, separately and by name.
- **Phase 2.5 already wants this closed.** The package-cache design specifies an
  *explicit* proxy precisely so lab guests need no DNS at all. That decision is
  now load-bearing for isolation, not merely tidy: with an explicit proxy the
  gateway resolver can be refused outright rather than left as the one hole in a
  default-deny.

### Consequences for the rule set

The rule shape below stays as designed, with two corrections:

1. **`OUT → VNet gateway, udp/67-68 and 53` is too generous.** Port 53 there is
   the tunnelling channel. Once the package cache is explicit, drop `53` and
   keep only DHCP. If any lab genuinely needs name resolution, it should get a
   local zone served with no upstream recursion, not a forwarder.
2. **Assert the negative for DNS, by name.** Add "cannot resolve an external
   name" to the isolation test's required assertions. Nothing in the current
   list would have caught this.

---

## Enforced and verified — `pve1`, 2026-08-07

The datacenter firewall is **on**, and the isolation the design asked for is now
real rather than intended. Same rig as above, `firewall=1` on both lab guests.

| From a lab guest, target | Before | After |
|---|---|---|
| Same-section peer *(control)* | reachable | **reachable** |
| Proxmox management ICMP / 8006 / 22 | REACHABLE | **blocked** |
| Other section's gateway and guest | REACHABLE | **blocked** |
| `prov0` gateway | REACHABLE | **blocked** |
| Internet by IP, ICMP and tcp/443 | blocked | **blocked** |
| External name resolution | REACHABLE | **blocked** |
| Package cache tcp/3142 | reachable | **reachable** |
| Package cache tcp/22 and ICMP | reachable | **blocked** |
| `apt-get update` + install via cache | — | **works** (16.4 MB, then 7.7 MB at 57 MB/s) |

**The carve-out is a host *and* a port, and that is now demonstrated rather
than asserted**: `3142` answers, `22` and ICMP on the same container do not.
Testing only that the cache works would have passed a container with SSH
exposed to every student in the building.

### Backend: legacy `pve-firewall`, not `proxmox-firewall`

**Decided against nftables for now, on the vendor's own words.** The Proxmox
documentation marks `proxmox-firewall` as *tech preview* and states plainly
that it "is currently not suited for production use." For a unit shipped to a
district that settles it, regardless of nftables being the better long-term
technology.

It also failed here in practice. With `nftables: 1` set while guests already
carried `firewall=1`, `proxmox-firewall` logged
`error updating firewall rules: cannot execute nftables commands` every five
seconds and never populated its guest maps — while its `bridge` table still
default-dropped guest traffic. **A firewall broken closed**, which reads
exactly like working isolation until you notice the control has failed too.
The documented sequence is: clear the NIC flag, switch the backend, restart
every running guest, then re-enable the flag.

Switching back is one line, so this is a revisit-later decision, not a fork.
Both backends consume identical `/etc/pve/*.fw` configuration, so the rule set
below is what migrates when the preview graduates.

### Five things that will bite anyone reproducing this

Each of these produced a wrong measurement before it was understood, and every
one of them is silent.

1. **`qm set --net0 …` without an explicit MAC regenerates the MAC.** That
   invalidates the DHCP lease, the SDN IPAM binding, *and* the MAC-source
   filter the firewall itself installs — so the guest loses its address and
   every probe returns "blocked" for reasons unrelated to policy. **The pod
   engine must set `firewall=1` at guest creation**, or preserve the MAC
   explicitly on every update.
2. **`qm destroy --purge` deletes `/etc/pve/firewall/<vmid>.fw`.** Rebuilding a
   guest therefore drops its firewall policy while leaving `firewall=1` in the
   NIC config — it comes back **unfiltered and looking configured**. This is
   the same failure class as the playbook targeting an absent host: the state
   that proves enforcement is separate from the state that requests it.
3. **`host.fw` rejects `policy_in` and `policy_out`** as unparseable. They are
   datacenter- and guest-level options only. Host policy comes from the
   defaults plus explicit rules.
4. **DHCP needs a host *outbound* rule.** The zone's `dnsmasq` runs on the
   host, so every OFFER is host-outbound. Without an explicit
   `OUT ACCEPT -p udp -dport 67:68`, `dnsmasq` logs
   `Error sending DHCP packet: Operation not permitted` and guests sit with no
   address forever. The inbound half must also sit **above** the lab-subnet
   DROP, because a renewing client sources from its leased `10.101.x.x`
   address — otherwise leases work at boot and fail at renewal, minutes into a
   class.
5. **The section gateway is the host**, so "ping your own gateway" is not a
   valid intra-section control — it is deliberately blocked by the lab→host
   DROP. Intra-section connectivity must be tested **guest to guest**. Using
   the gateway as the control reports a broken firewall when the firewall is
   correct.

### The rule set as applied

`cluster.fw` carries `enable: 1`, `policy_in: DROP`, `policy_out: DROP`, and
one security group:

```
[group lab-guest]
OUT ACCEPT -dest dc/cache -p tcp -dport 3142   # carve-out: host AND port
OUT ACCEPT -p udp -dport 67:68                 # DHCP only
# port 53 deliberately absent -- see the DNS finding above
```

Each guest adds only its own section:

```
GROUP lab-guest
OUT ACCEPT -dest 10.101.11.0/24
IN  ACCEPT -source 10.101.11.0/24
```

`host.fw` allows DHCP in and out ahead of a `10.101.0.0/16 → host` DROP, then
SSH, `8006` and ICMP for management. **The lab-subnet DROP covers `teacher_id`
101 only** — lab space is `10.<101-255>.x.0/24`, so this needs generalising
before a second teacher exists.

### Still not covered

- **Guacamole's carve-out**, which does not exist yet. It points the opposite
  way to the cache — Guacamole initiates *into* pod VNets — and that asymmetry
  is what makes both testable.
- **`policy_out: DROP` was never verified for the host itself**, only for
  guests.
- **The cable has still not been pulled.** Stripping the cache's egress
  interface is strictly weaker than the physical test.

### Rig teardown

Guests `950` and `955` are disposable and destroyed with
`qm stop <id> && qm destroy <id> --purge`. The section VNets they used were
created by the standard playbook and can be removed subnets → VNets → zone.

---

## Reproducing this from the repository, 2026-08-10

Everything above was placed **by hand**. A wiped host running
`install-cyberlab.sh` came back with the SDN and the package cache and **no
isolation at all** — a lab that looks complete from the commit log and lets
any student reach the Proxmox Web UI. That gap is now closed by two playbooks
and a script.

| File | What it does |
|---|---|
| `ansible/playbooks/controller-bootstrap-firewall.yml` | Writes `cluster.fw`, `host.fw` and every per-guest `.fw`, derived from `data/environments/<env>.yml` |
| `ansible/playbooks/controller-assert-isolation.yml` | Checks that the policy is present *and in force* |
| `scripts/isolation-probe.sh` | The measured reachability matrix, re-runnable, judged rather than eyeballed |

`install-cyberlab.sh --with-firewall` runs the first two, in that order,
always together. Both are opt-in for the same reason the package cache is,
plus one of their own: this writes a default-deny firewall to a live host.

### What is derived rather than transcribed

- **One host DROP per teacher `/16`**, taken from the section subnets the
  environment declares. The hand-placed rule covered `teacher_id` 101 only and
  carried a comment saying so; adding a second teacher to the data model now
  produces their DROP automatically.
- **Each guest's own section subnet**, read from the VNet the guest is
  *actually attached to* rather than from a file someone copied. This is what
  catches the case that really happened: `955` was moved to section A for a
  control test and kept section A's `.fw` afterwards.
- **Which guests are lab guests at all** — anything bridged to a section VNet.
  The controller on `vmbr0` and the cache on `svc0` are deliberately not.

### The two tiers, and why the distinction is load-bearing

`controller-assert-isolation.yml` runs **tier 1** on every deploy: read-only
configuration assertions that need no guests and finish in seconds. It cannot
prove a packet was dropped. What it *can* prove is that nothing is in the
state where it looks configured and is not — which is the state that actually
occurred, in three of the five traps below.

**Tier 2** is the live matrix, run from inside a guest through the guest
agent, and it is opt-in because it needs a running lab guest and a
same-section peer:

```
ansible-playbook -i inventory.yml playbooks/controller-assert-isolation.yml \
  -e cyberlab_probe_vmid=950 -e cyberlab_probe_peer_ip=10.101.11.101
```

A tier-1 pass with tier 2 never run is a **weaker claim** than the one made on
2026-08-07, and the playbook's summary says so rather than reporting green.

**The control is treated as pass/fail, not as one row among seventeen.** A run
where everything is "blocked" is exactly what a guest with no DHCP lease
reports, and that misreading cost a full round of measurements when a
regenerated MAC silently dropped a lease. If the same-section peer is
unreachable, the probe refuses to trust any other verdict and exits non-zero.

### What the repo checks without hardware

`tests/test_firewall_policy.py` guards the rule *shape* in CI, where there is
no Proxmox host: that port 53 stays out of the `lab-guest` group, that the
cache carve-out names a port and not just a host, that `host.fw` writes the
inbound DHCP accept above the lab-subnet DROP, that `host.fw` is written
before `cluster.fw`, and that a derived teacher `/16` can never swallow the
`10.30.0.0/24` and `10.31.0.0/24` infrastructure networks.

### Verified against `pve1`, 2026-08-10

`controller-assert-isolation.yml` was run against the live host, which still
carries the hand-placed rules. **Both tiers passed with zero changes.** Tier 2
reproduced all seventeen rows from guest `950` — including the negative
assertions that matter most: the cache answers on `3142` and refuses `22` and
ICMP.

This is the assertion half proving itself against a state that was
independently measured.

### The generated rules, diffed against the hand-placed ones

`controller-bootstrap-firewall.yml` supports `--check --diff`, which is the
supported way to preview it against a live host. Read-only discovery tasks
carry `check_mode: false` so the per-guest diffs are real rather than empty:

```bash
ansible-playbook -i inventory.yml playbooks/controller-bootstrap-firewall.yml \
  --check --diff
```

Run against `pve1` on 2026-08-10, comparing rule directives only and ignoring
comments and blank lines:

| File | Result |
|---|---|
| `host.fw` | **Rules identical** — 12 directives, same order |
| `950.fw` / `955.fw` | **Rules identical** — 9 directives each |
| `cluster.fw` | One difference, in `[ALIASES]` only |

The `cluster.fw` difference is that the generated file drops
`schoolnet 10.64.62.0/23` and adds `svcnet 10.31.0.0/24`. **Neither alias is
referenced by any rule** — `grep` across every `.fw` on the host finds only
`dc/cache` and `dc/provnet` in use, and `mgmt` is unreferenced too. So the
generated configuration is behaviourally identical to what is running.

Two things this diff settles that were open:

- **The per-teacher `/16` generalisation is a no-op today.** `school-lab` has
  one teacher, so the derived DROP is exactly the hand-placed
  `10.101.0.0/16`. It was expected to be the one real difference and is not;
  it only starts to matter when a second teacher appears, which is the point.
- **No NIC would be touched.** Both lab guests already carry `firewall=1`, so
  the MAC-preserving `qm set` is skipped entirely — the swap cannot disturb a
  DHCP lease or an IPAM binding.

`schoolnet` is the one piece of information the swap would lose. It is
documentation rather than policy, and re-deriving it needs the host's own
management prefix at runtime, so it is deliberately not carried today.

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
| 2 | **Phone-home** — subscription checks, `apt` timers, NTP pools | **Confirmed happening** — `chrony` on `pve1` is syncing to `2.debian.pool.ntp.org` right now, four sources at full reach | Unexplained outbound to the internet from a box sold as air-gapped. Erodes the central product claim |
| 3 | **Corosync heartbeat on the uplink** | **Moderate** — only if the cluster network is not physically separated. Not yet live; the hosts are not clustered | Constant unexplained UDP between unknown hosts, every few hundred ms, forever |
| 4 | **Stray ICMP** | Moderate | Mostly harmless, trivially avoidable |
| 5 | **mDNS / LLMNR / NetBIOS broadcast** | **Low on the host** — `avahi-daemon` is not installed on `pve1`, only client libraries. Remains a guest-side concern for Windows VMs | Noise; clutters discovery tooling |
| 6 | **Rogue DHCP** — SDN `dnsmasq` answering on the uplink | **Low** — requires a VNet deliberately bridged to a physical NIC | School devices take `10.30.0.x` leases and lose network. Ejection from the district network |
| 7 | **BPDUs from a Linux bridge** | **Low, confirmed** — `stp_state` is `0` on both `vmbr0` and `prov0` | BPDU guard err-disables the switch port. Visible outage, and the logs name us |

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

> **Syntax caveat, narrowed by the baseline above.** `pve1` runs PVE 9.2.9
> with both firewall backends installed but **neither producing rules**, and
> no `nftables: 1` opt-in. So the backend this design lands on is still an open
> choice, not a given:
>
> - **Legacy `pve-firewall`** is what the `.fw` syntax below targets and is the
>   safer default today.
> - **`proxmox-firewall`** (nftables) is the direction Proxmox is moving and
>   handles host `FORWARD` rules more coherently, which matters here because
>   inter-VNet traffic is forwarded, not local.
>
> Decide deliberately during Phase 5 and record it. Either way the `.fw` files
> are the interface — the nftables backend consumes the same configuration —
> so the rule *shape* below survives the choice. Verify exact directives
> against PVE 9.2 documentation before pasting.

### `cluster.fw`

```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP

[ALIASES]
uplink_gw      10.64.62.1
mgmt_net       10.64.62.0/23
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
# systemd-timesyncd is already inactive on pve1; chrony is the time source
# avahi-daemon is not installed on pve1 -- verify before assuming on a new host
```

**Time is the live one.** `chrony` on `pve1` currently carries
`pool 2.debian.pool.ntp.org iburst` and is actively synchronising to four
public servers. At site that must become: one node designated as the cluster
time source, running `local stratum 10` with **no `pool` or `server`
directives at all**, and every other node peering to it across `vmbr1`. Until
that change, each node independently reaches the public internet on UDP 123
for as long as it is powered on.

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
