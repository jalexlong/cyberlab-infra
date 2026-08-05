# Cyberlab Roadmap

Planning document for taking this repository from its current state to a
self-contained, classroom-deployable cyber range appliance.

**Written:** 2026-08-04
**Last revised:** 2026-08-05 — student-network question resolved, package cache
promoted to Phase 2.5, network isolation designed (`docs/network-isolation.md`)
**Originally analyzed at commit:** `5dd0092`
**Target:** own classroom pilot spring 2027, appliance design by summer 2027
**Not on the critical path:** this supplements the Cyber.org curriculum.
Nothing here blocks teaching this year.

**Curriculum target:** Arkansas's Cybersecurity CTE pathway — a fixed
three-course sequence. This is why `course_index`'s 3-value ceiling (see
Identifiers) is not live pressure today, and why the template catalog and
`data/sections.yml`'s `course_code` values should track that pathway's actual
courses rather than a generic set. The ceiling is now *enforced* rather than
merely documented — `section_code` above 255 is rejected by `validate_inputs()`,
since it cannot be an IP octet.

---

## Product definition

**Cyberlab is a lab-in-a-box:** a small cluster of quiet, low-power compute
nodes in a rolling rack that a school district can deploy into a classroom and
run a cyber range on, with no dependence on district network services.

**"No dependence" is meant literally, and the factory-seeded package cache is
what makes it true** (Phase 2.5). An air-gapped unit can still install software
into lab guests, so the district provides one inbound-reachable IP address and
nothing else — no egress, DNS, NTP, or wireless. Most of the design decisions
below are downstream of taking that sentence seriously.

Two delivery paths:

| SKU | What ships | Licensing position |
|---|---|---|
| **Recipe** | Public BOM, install automation, documentation | You distribute no software — no GPL/AGPL obligation attaches |
| **Prebuilt** | Assembled, imaged, tested hardware | You distribute Proxmox — source-offer and trademark obligations apply |

**Design principle that makes this work:** the prebuilt units must be
reproducible from the public recipe. If the box a district buys is exactly the
free recipe applied to hardware, then GPL/AGPL compliance is close to
automatic — the source offer is satisfied by the recipe itself — and your value
is assembly, testing, warranty, and support rather than software lock-in. That
is an honest model to sell to schools, and it is much easier to defend than a
proprietary fork.

### Licensing obligations for the prebuilt SKU

- Provide or offer complete corresponding source for AGPL/GPL components. A
  written offer valid three years is the conventional mechanism; Proxmox
  publishes its source.
- **Do not modify Proxmox.** Notably, the common "remove the subscription nag"
  patch is a modification and would trigger publication obligations.
- Do not call the product Proxmox or imply endorsement. "Built on Proxmox VE"
  is fine.
- Your own control plane and playbooks are **not** infected. Code calling `qm`
  across an API boundary is a separate work; GPL explicitly permits mere
  aggregation.

---

## Constraints

| Constraint | Value | Consequence |
|---|---|---|
| Deployment | Classroom appliance, rolling rack | Noise, power, and thermal are product requirements |
| Topology | 3-5 refurb mini/SFF PCs | ~32-64 GB RAM per node; density matters; no shared storage |
| Connectivity | **Assume none; use it if present** | Must deploy and run fully offline. Where egress exists it is used for host updates and an apt cache — see the student-network section. Templates are never built on the appliance either way |
| Peak concurrency | 16-30 students | Drives the RAM budget and therefore the BOM |
| VM allocation | On-demand pods | Created at lab start, destroyed at lab end |
| Student hardware | Any browser | No client install, no VPN, no local hypervisor |
| Remote access | Opt-in module, **off by default** | Shipped units self-contained; your own box enables the tunnel |
| Licensing | FOSS, reproducible from public recipe | See product definition above |

---

## Current state

Summer work (`c44bdfd`…`5dd0092`) closed the largest gaps from the first
analysis:

- **The validation gate now exists.** `controller-validate-template-clone.yml`
  clones a promoted template, boots it, waits on the QEMU guest agent,
  discovers a non-loopback IPv4, pings it, and cleans up.
- **One template catalog.** `data/templates.yml` removed;
  `ansible/vars/templates.yml` is authoritative.
- **Dead code removed** — `template_env.py` (which held a guaranteed
  `NameError`), `build-imported-templates.sh`, `create-installer-template-vms.sh`.
- **Testing and recovery docs** added.

### The four Phase 0 defects are closed

All four defects listed in the original analysis were fixed by `c7fb52d` and
`8f7a6af`, which landed before this document was first committed — the list was
stale on arrival. Verified at `73bec83`:

| Defect | Resolution |
|---|---|
| `automation_token_secret` never assigned | `set_fact` restored in `host-bootstrap.yml`, parsing the documented JSON form with a UUID-scan fallback, guarded by an assert that fails loudly when extraction yields nothing |
| Automation user gets no privileges | `CyberlabAutomation` role created and reconciled, granted at `/` with `--propagate 1`, then read back and asserted |
| False green in API validation | `controller-validate-proxmox-api.yml` now queries `/access/permissions` and asserts 7 required privileges at `/`, rather than inferring health from `/version` |
| `#{ROTATE_API_TOKEN}` and `raiseValueError` | Both corrected |

The role definition and the validator's required-privilege list are separate
declarations that must agree. They currently do — all 7 asserted privileges
(`SDN.Allocate`, `VM.Allocate`, `VM.Clone`, `VM.Config.Network`,
`Datastore.AllocateSpace`, `Pool.Allocate`, `Sys.Modify`) exist in
`automation_role_privs`. **Nothing enforces that agreement**, so a privilege
added to the validator but not the role produces a bootstrap that succeeds and
a validation that fails. Worth a CI check in Phase 1.

### Structural gaps

- **`pve1` runs infrastructure SDN only: the zone `virtnet` and `prov0`.**
  Everything was removed on 2026-08-05 and `prov0` was restored the same day
  because the template factory cannot work without it — see the two notes
  below. `pve2` still has no SDN at all.
- **There are no classroom networks and no egress control.** Per-section VNets
  are declared in `data/environments/school-lab.yml` but are not built;
  `cyberlab_sdn_build_sections` defaults to false. Phase 5 builds them from
  zero rather than tightening existing behaviour.
- **Phase 0 exit remains unproven.** The fixes are correct by inspection and
  parts of the bootstrap path have now been exercised live (see
  `docs/testing.md`), but the exit criterion itself — two consecutive clean
  `install-cyberlab.sh` runs on a wiped host — has not been run.
- **ansible-lint runs at `basic` with four rules deferred** (`fqcn`,
  `no-changed-when`, `risky-shell-pipe`, `name` — 68 findings). Each is a real
  improvement, but fixing them edits the only currently-tested path to a
  working host, so each should be retired with a hardware run behind it. See
  `.ansible-lint`.

### Resolved: `proxmox-sdn.yml` deleted

It hardcoded `sdn_zone: "cyberlab"` while the platform's zone is `virtnet`
(`ansible/inventory.yml`, and the promoted-template milestone), so running it
against a live host would have created a **second, divergent SDN zone**
alongside the real one. `controller-bootstrap-sdn.yml` is the current, tested
path and reads the zone from `proxmox_sdn.zone.name`.

Worth recording how close this came to being a live incident. The playbook was
inert only by accident — it targeted `hosts: poseidon`, absent from inventory,
so it ran zero tasks and exited zero. Retargeting it to `proxmox_targets` to
satisfy the new inventory check made it genuinely runnable against `pve1`. A
lint fix converted a dead playbook into a loaded one, and only a manual read
of the file caught it. Two lessons: a playbook that "passes" by matching no
hosts is not passing, and mechanically satisfying a linter can raise real risk
while lowering apparent risk.

### Removed: all SDN, both hosts (2026-08-05)

Zones, VNets and subnets were deleted from `pve1` and `pve2`. Nothing remains:
no VNet interfaces, no `dnsmasq@<zone>` units. Management networking was left
untouched on both — `vmbr0` and the default route via `10.64.62.1`.

Before removal `pve1` carried the zone `virtnet` with seven VNets: `prov0`,
the hand-built `vnet0`/`vnet1`, and four section networks (`t101c011`,
`t101c112`, `t101c123`, `t101c213`) built from `data/environments/school-lab.yml`.
`pve2` carried its own separate `virtnet` with `prov0`, `vnet0` and `vnet1` —
the two hosts are not clustered, so each had an independent SDN.

**Why:** the design was exploratory and the decision was that it is not worth
carrying into the rebuild. Removal was zero-impact — nothing was attached to
any VNet. CT `800` is on `vmbr0` and every VM is NIC-less by convention
(`8ae9823`), so the SDN was serving no guest at the time it was deleted.

**The repo still describes all of it**, but no longer builds it by default —
see the restore note below. The section definitions in `data/environments/`
are unchanged and remain a description of an intended design rather than of
either host's state.

Two things worth knowing before rebuilding SDN:

- **Subnet deletion is blocked by IPAM allocations.** On `pve2` the delete
  failed with `cannot delete subnet '10.30.0.0/24', not empty` until the
  entries were released with `pvesh delete /cluster/sdn/vnets/<vnet>/ips`. The
  allocations were stale — they named VMIDs `900`, `9002`, `9003`, `9004`,
  which live on `pve1`, not `pve2`. IPAM state outlives the guests it
  describes and is not reconciled against them.
- **The zone cannot be deleted before its VNets**, and a VNet cannot be
  deleted before its subnets. Order is subnets, then VNets, then zone, then
  `pvesh set /cluster/sdn` to apply.

### Restored: `prov0` only, `pve1` (2026-08-05)

Removing all SDN also removed the provisioning network, and that blocked the
template factory. `prov0` was restored on `pve1` the same day. `pve2` has none
and needs none — every template sets `target_node: pve1`.

**Why `prov0` is not optional.** The dependency is on its addressing, not just
its name, so pointing templates at `vmbr0` would not have been a bridge swap:

- `ansible/vars/templates.yml` sets `bridge: prov0` on all five templates.
- Builds are addressed from its subnet — `bootstrap_ipconfig0` is
  `ip=10.30.0.10/24,gw=10.30.0.1`, and `nameserver` is `10.30.0.1`, the VNet
  gateway running dnsmasq.
- Its subnet is the **only** one with `snat: true`. Section VNets are
  deliberately `snat: false`, so `prov0` is the sole egress path for the
  `apt-get` work in `controller-finalize-template-vm.yml`. Commit `5dd0092`
  exists to make that egress work end to end.

`prov0` is attached transiently and never ships: `controller-promote-template.yml`
strips every `netN` before `qm template`, and
`controller-validate-template-clone.yml` re-attaches one on a disposable clone.

**How it is kept minimal.** `controller-bootstrap-sdn.yml` previously
concatenated infrastructure and section VNets unconditionally, so there was no
way to have one without the other. `cyberlab_sdn_build_sections` now gates the
section half and defaults to false (`031629f`). A plain run — including
`install-cyberlab.sh` with no flags — builds the zone and `prov0` and stops.
Pass `-e cyberlab_sdn_build_sections=true` for the classroom networks.

The playbook is additive, so turning the flag back off does not remove
classroom VNets an earlier run created. Tear those down deliberately, in the
order above.

---

## Hardware-gated backlog

Everything below is deliberately deferred because it cannot be verified from a
laptop. Collected here so a lab session has one list to work from rather than
five phases to re-read.

**The existing school host is disposable.** It carries an exploratory build
that predates this architecture — a proto-prototype used to work out how the
pieces wire together — and nothing on it is load-bearing. The intended path is
to capture it (`scripts/capture-host-state.sh`, see
`docs/bootstrap-checklist.md` Phase 0-minus), wipe it, and rebuild on the
current design.

That changes the calculus for everything in this table. The deferrals below
were originally written as *risk* — "don't touch the only tested path to a
working host." With a disposable host the risk is mostly gone and what remains
is *iteration cost*: a bad run costs a rebuild, not data. So these items are
better batched into one lab session than spread across several cautious ones,
and a failed run is an acceptable outcome rather than something to avoid.

Three cautions survive the pivot:

- **Capture before wiping, and verify the capture from a second machine.** The
  facts are cheap to save and expensive to rediscover.
- **The capture includes `/etc/pve/priv/` by default**, so that a restore
  yields a working environment rather than a locked-out one — the right
  trade for a development host. It makes the destination credential-bearing,
  and it means rotating credentials *after* any actual restore. A district
  deployment should use `--no-secrets` instead.
- **`pve2` briefly held the only rollback path for the decommissioned
  `www.farmcardscode.org`** — the Cloudflare tunnel credentials and
  `farmcardscode.env` exist in no repository. **Resolved 2026-08-05:** a full
  `vzdump` of VM `500` and the capture were archived to USB and to the laptop,
  and verified from a second machine. Both hosts are disposable again. See
  `docs/bootstrap-checklist.md` before assuming that stays true — anything
  created on these hosts and nowhere else re-earns this caution.

Suggested order for the first session after the wipe: capture and verify, then
wipe, then the Phase 0 run twice — because a clean install on a genuinely
fresh host is the thing every other item depends on. The lint retirements are
good work to do *between* the two install runs, since re-running the installer
is the verification they need anyway.

**The package cache (Phase 2.5) is the exception to that ordering.** Build and
seed it *before* the wipe, then let the rebuild re-create it — that turns the
wipe into the proof that the cache is reproducible from `install-cyberlab.sh`
rather than a hand-built artifact that merely exists. Nothing is lost by
wiping a seeded cache while the classroom still has egress; the one-way door
is air-gapping, not wiping.

| Item | Why it needs hardware | Where |
|---|---|---|
| Capture the existing host, verify the capture elsewhere, then wipe | The facts are cheap to save and expensive to rediscover | Phase 0-minus |
| Two consecutive clean `install-cyberlab.sh` runs on a wiped host; token performs a privileged action | The Phase 0 exit criterion. The defect fixes are correct by inspection only, and `set_fact` parsing of `pveum` output is exactly the kind of thing that reviews clean and surprises live | Phase 0 |
| Retire `fqcn` from `.ansible-lint` `skip_list` | Mechanical, but touches nearly every playbook at once | Phase 1 |
| Retire `no-changed-when` | Several hits are genuine idempotency bugs, several are correct as written (reconcile tasks that really do change state each run). Needs per-task judgement plus a run to confirm | Phase 1 |
| Retire `risky-shell-pipe` | `set -o pipefail` changes failure semantics of shell tasks that currently tolerate a failing pipe stage | Phase 1 |
| Retire `name` | Cosmetic; safe to do any time, but bundle it with a run | Phase 1 |
| Measure real per-VM and per-LXC RAM | Every sizing number in this document is an estimate | Phase 3 |
| Right-size `slots.yml` from those measurements | See the RAM budget section — currently ~22.5 GB/student | Phase 3/4 |
| Validate the template pipeline end to end offline | prepare → finalize → promote → validate, plus a deliberately broken image failing the gate | Phase 2 |
| Build and seed the `apt-cacher-ng` LXCs, then install a package with the uplink unplugged | Needs a real host, a real template build to warm it, and a cable to physically pull — none of which exist on a laptop | Phase 2.5 |
| Capture on the uplink for a full class period and confirm only ARP and the Guacamole port appear | The whole egress-suppression design is unverified until something watches the wire. See `docs/network-isolation.md` | Phase 5 |
| Noise under load, power draw on one circuit, thermals | Product requirements, not nice-to-haves | Phase 3 |

Laptop-doable items that came out of the same work, for contrast: the
catalog/licensing cleanup, `data/labs.yml`, the factory/site split audit, and
the pod-engine design.

---

## Architecture

### Factory versus site — the defining split

**A shipped appliance cannot build its own templates.** The pipeline currently
downloads Debian cloud images, `apt-get install`s from Debian repos, and pulls
LXC templates via `pveam`. Commit `5dd0092` added `prov0` egress specifically
so template builds could reach the internet.

With no connectivity assumed, the system splits in two:

| | Factory (your bench, online) | Site (classroom, offline) |
|---|---|---|
| Template download and build | Yes | Never |
| Validation gate | Yes | Never |
| Package installation | Yes, baked into images | Never |
| Pod clone / start / stop / destroy | For testing | Yes |
| Guacamole connection provisioning | For testing | Yes |

This is good news: the entire template factory — the most fragile part of the
system — becomes your problem rather than a district sysadmin's. The appliance
only needs to clone from images already present.

**Work this implies:**

- `bootstrap-controller.sh` currently runs `apt-get update`/`install`. That
  becomes a factory step baked into the controller LXC image. Dropping
  OpenTofu already removed its third-party apt repository and GPG key from
  this path, leaving only Debian repositories to account for.
- The controller also needs the `community.proxmox` collection from Galaxy
  (`ansible/requirements.yml`). Same problem, same answer: vendor it into the
  image at build time.
- `host-bootstrap.yml` runs `pveam download`. Factory step.
- Templates must be replicated to every node's local storage, because linked
  clones require the template on the same storage as the clone.
- **Time.** Offline means no NTP. Clock drift breaks TLS validation, Guacamole
  tokens, and Proxmox corosync membership. Designate one node as the cluster
  time source.
- **DNS.** No upstream resolver. Ship a local one for lab names.
- **Certificates.** Guacamole over HTTPS on an offline box has no public CA
  path. Either ship an internal CA and accept the distribution problem, or
  serve plain HTTP on an isolated network and document the tradeoff.
- **Updates.** Districts need new labs and patches somehow. Design a signed
  offline bundle applied from USB.

### Cluster topology

Three to five mini/SFF nodes, local NVMe on each, no shared storage.

- **Proxmox cluster needs three nodes for quorum.** Three is the floor.
- **No Ceph.** It wants more RAM and more nodes than this hardware has. Local
  ZFS or LVM-thin per node, with templates replicated to each.
- **Pod affinity: all VMs of a pod land on one node.** This lets pod networks
  use node-local SDN zones instead of VXLAN spanning nodes — dramatically less
  to break offline, and no inter-node traffic for pod-internal packets. The
  scheduler picks the least-loaded node with room for the whole pod.
- **No HA.** A node failure kills the pods on it; students restart. Acceptable
  for a classroom lab, and HA on refurb hardware is a support burden with no
  educational payoff.

### RAM budget — this drives the BOM

Full VMs, lean sizing, roughly 6 GB per 3-VM pod:

| Nodes × RAM | Usable after host overhead | Concurrent students at 6 GB/pod |
|---|---|---|
| 3 × 64 GB = 192 GB | ~180 GB | ~20 (tight at 30) |
| 4 × 64 GB = 256 GB | ~240 GB | ~30 with headroom |
| 5 × 64 GB = 320 GB | ~300 GB | ~40 |

**Four nodes at 64 GB is the recommended starting point** for a 30-student
target. Three nodes is a fine 16-20 student pilot and the minimum for quorum.

The current `slots.yml` values are far more generous than this hardware can
carry, and by a wider margin than "`atk` is 8 GB" suggests. Measured against
the file as it stands:

| Slot | vCPU | RAM |
|---|---|---|
| `atk` | 4 | 8192 MB |
| `win` | 2 | 8192 MB |
| `srv` | 2 | 2048 MB |
| `vic` | 2 | 2048 MB |
| `www` | 2 | 2048 MB |
| **Total per student** | **12** | **22.5 GB** |

That is **~660 GB at 30 concurrent students** — roughly 2.6× a 4-node × 64 GB
cluster, and unreachable on the DDR3 tier at any node count.

Two separate corrections are needed, and they are easy to conflate:

1. **Sizing.** Individual slot values are too large.
2. **Shape.** The RAM budget above costs a *3-VM pod*; `slots.yml` defines
   *five* slots. Even correctly-sized slots overshoot if every student gets all
   five. Decide whether a pod is a subset of slots chosen per lab — which is
   what `data/labs.yml` should express — or whether the slot list itself
   shrinks.

Right-sizing is mandatory, not optional, and per-slot numbers should come from
the Phase 3 measurement rather than from estimates.

`slots.yml` also names `win7-template` and `metasploitable2-template`, the two
images the content-licensing table below says cannot ship. Removing them from
the catalog forces a `slots.yml` change; `tests/test_inventory_consistency.py`
enforces that the two files agree, so CI will flag it rather than letting the
slots dangle.

### Density: use Proxmox LXC, not a second hypervisor

Earlier analysis raised container density as an argument for a hypervisor
abstraction with an Incus backend. **That was the wrong conclusion — Proxmox
runs LXC containers natively, alongside VMs.** The density win is available
without changing hypervisors at all.

A container-based pod runs roughly 1-1.5 GB instead of 6 GB. On a 3-node
cluster that is the difference between ~20 concurrent students and 100+.

Containers cannot run Windows, and cannot host labs needing custom kernels or
kernel exploitation. So the model is mixed:

- **VMs** for Windows targets, privilege escalation, kernel-level work
- **LXC** for networking, recon, web application, and log analysis labs

Start with VMs — they work for everything. Add LXC as a density optimization
once specific labs prove they don't need full virtualization.

### Hypervisor abstraction: build discipline, not an interface

With density available inside Proxmox and AGPL manageable through the
reproducible-from-recipe principle, the case for a formal `HypervisorDriver`
interface is much weaker than it looked. An appliance means you control the
whole stack and standardize on one backend; shipping two doubles your support
burden for zero district benefit.

**Recommendation: the middle path.**

- Proxmox-specific calls confined to one Ansible role or one Python module
- VMIDs never appear in `data/` or in the control-plane schema — they live in
  an allocation table the Proxmox layer owns
- The pod engine's vocabulary is templates, pods, networks, and addresses, not
  `qm` flags

This keeps a future backend swap as a bounded refactor rather than
archaeology, at a fraction of the cost of building the abstraction now.

### Identifiers

The encoded scheme `vmid = teacher_id * 1000000 + section_code * 1000 + offset`
was designed for a single-teacher deployment. Its ceiling — 999 teachers, 999
sections, 999 VMs — is **not** a problem for a per-school appliance, so the
scalability argument for replacing it has largely evaporated.

What remains is flexibility: organizational facts change (teachers move,
sections get co-taught), VMIDs are Proxmox-specific, and a fixed assignment
leaves most of the space empty while fighting on-demand allocation. Also,
`policy.yml` reserves offsets 100-199 for students — 20 students at 5 slots —
while `icsa1` has 24 and `itsb3` has 30, already overflowing.

**Downgraded to "worth doing when convenient."** Keep human readability in VM
names and Proxmox tags; move VMIDs to a pool allocator when the pod engine is
built anyway.

**2026-08-05 — three more concrete defects found in the encoding, and the
"convenient later" allocator is now the decided direction, not just an
option.** `section_code` is `<course_index><day><block>` — undocumented as a
composition, but recoverable from `data/sections.yml`: `its=1, cyb=2`,
`A=1, B=2`. That composition breaks in three ways:

- **A leading zero is already lost.** `icsa1` (course index 0) stores
  `section_code: 11`, but `docs/data-model.md` documents the VMID formula as
  "next three digits: section code." `t101c011` (the VNet name) pads it back;
  `10.101.11.0/24` (the subnet, from the network formula) does not. The
  identifier is stored in a form that cannot represent its own scheme.
- **A ceiling of three course types.** Course index 3 produces codes `3xx`,
  which exceeds 255 and is not a valid IP octet. Not a defect in practice:
  this platform targets Arkansas's Cybersecurity CTE pathway, which is itself
  a three-course sequence, so `course_index` never needs a fourth value. Worth
  knowing before the platform generalizes past that one pathway — a district
  running a different, larger course sequence would hit this ceiling for
  real.
- **The encoding is teacher-independent, but a validator demanded global
  uniqueness.** Two teachers teaching the same course in the same block —
  an ordinary timetable — produce the same `section_code` and were rejected,
  even though both the VMID and network formulas already multiply in
  `teacher_id` ahead of it, so nothing would actually have collided. Fixed as
  a stopgap in `generate_runtime_artifacts.py`: the uniqueness check is now
  scoped to `(teacher_id, section_code)`, matching what the formulas actually
  require. This does not fix the leading-zero or ceiling defects, and is not
  the redesign below — it only stops the current encoding from rejecting
  valid input while it is still in use.

**Decided: stop encoding `section_code`, allocate it sequentially instead.**
Course/day/block stay as the separate, already-readable fields they are in
`sections.yml` (`course_code`, `day`, `block`); `section_code` becomes an
opaque integer assigned as each section is created, from a per-teacher range.
This removes the leading-zero defect and the cross-teacher collision (already
patched as a stopgap above) without changing the VMID or network formulas
themselves, since both already treat `section_code` as an opaque number. The
octet ceiling is not live pressure for the three-course target pathway, but
an opaque allocator removes it too, for free, rather than leaving a landmine
for the day this platform generalizes past that one pathway.

**Not implemented yet, and deliberately so.** `data/environments/school-lab.yml`'s
VNet names and subnets are hand-authored to match the current encoded values;
nothing today derives them from `section_code` programmatically. Renumbering
now means hand-recomputing four subnets with no generator to keep them
honest — exactly the kind of one-off allocation this decision exists to stop
doing by hand. It belongs with the pod-engine's actual allocator (Phase 4),
built once rather than twice.

### Access control

Proxmox's per-student user/pool/ACL model is retired. It cannot express
"three concurrent pods," "expires in ninety minutes," or "only during third
block."

| Layer | Component | License | Responsibility |
|---|---|---|---|
| Identity | Guacamole DB auth day one; Keycloak/Authentik later | Apache 2.0 / MIT | Who is this person |
| Authorization | **Control plane (ours)** | Ours | Policy and quotas |
| Connection broker | Apache Guacamole | Apache 2.0 | Which consoles are reachable now |
| Hypervisor | Proxmox VE | AGPLv3 | Runs workloads; one service account |

`pod up` provisions Guacamole connections through its REST API; `pod down`
removes them. A student sees only what the control plane created for them.

Retire for students: `proxmox-users.yml`, `proxmox-pools.yml`,
`proxmox-acls.yml`, `proxmox-pool-membership.yml`. Keep Proxmox RBAC for the
teacher/admin account only.

#### Guacamole connection-group hierarchy — decided: teacher > section > student

Three levels, mirroring the data model exactly:

- **Teacher** — top-level connection group per teacher.
- **Section** — one connection group per section beneath its teacher. A user
  group holds that section's students; the teacher gets read access to it,
  which is how a teacher sees only their own sections without per-connection
  grants.
- **Student** — connections named by slot alone (`atk`, `win`, `srv`, …), not
  by the full VM name. Guacamole's JDBC schema requires connection name
  uniqueness only within a parent group, not globally, so nesting buys back
  the short names that a flat namespace would force into something like
  `jlong-cyba3-heron-47-atk`.

`guacamole_entity` **is** globally unique on `(name, type)` — usernames, unlike
connection names, are a single flat namespace across the whole deployment.
That constraint is what the username decision below satisfies.

#### Student usernames — decided: section prefix kept, codename randomised, mapping never stored here

Format stays `<display_section>-<codename>-<nn>`, e.g. `cyba3-heron-47`.

- **Section prefix kept, deliberately.** It costs a small amount of
  anonymity — a dropped credential slip narrows to one class rather than the
  whole school — in exchange for simplifying what a teacher has to know to
  fix a problem: which section a broken pod belongs to, without a lookup.
  That trade favors the person who has to act on the information day to day.
- **Codename is drawn uniformly at random**, not assigned positionally, and
  is never seeded from data that is itself committed to git (`teacher_id`,
  `section_code`). Fixed 2026-08-05 — see "Student identity boundary" in
  `docs/data-model.md` and `tests/test_student_credential_generation.py` for
  what was wrong and how it is now guarded.
- **The mapping from username to real student is never held by this system,
  at any stage.** A teacher who needs to know who holds `cyba3-heron-47`
  keeps that association in their own gradebook or the school's SIS — a
  system that already carries student records under the school's own
  compliance obligations. This appliance does not become that system.
  Enforced by `tests/test_no_student_pii.py`, which runs in CI on every push
  and PR.

#### Identity provider is deferred, not designed out

Guacamole's OIDC extension provides *authentication only* — it must be layered
on top of the database auth extension, which is what actually holds users,
connections, and permissions. The DB extension is required either way, so
building the control plane against Guacamole's REST API and DB auth now makes a
later Keycloak addition a drop-in (a JAR in `extensions/` plus config) rather
than a refactor.

Reasons to hold off at pilot scale: Keycloak is a JVM app wanting ~2 GB, which
is real money on a 16-32 GB node; and OIDC pushes hard toward HTTPS, colliding
with the unresolved offline-certificate problem above. For one classroom, 30
students, and no district SSO requirement, Guacamole's own DB auth is
sufficient. **Add the IdP when a district requires federation — a selling
milestone, not a pilot one.**

#### Console delivery

**Not Proxmox's built-in noVNC.** It requires the viewer to *be* a Proxmox user
with console permission on the specific guest — exactly the per-student ACL
model retired above — and it drags students into the admin plane. It also
cannot express "expires in ninety minutes." Guacamole brokers consoles instead,
so Proxmox sees one service account.

**LXC containers have no framebuffer.** The Proxmox container console is a tty,
not a desktop. Access path therefore varies by guest type:

| Guest | Path | Cost |
|---|---|---|
| LXC, CLI-only lab | SSH — Guacamole speaks it natively | Nearly free |
| LXC, GUI needed | XFCE + xrdp/VNC server *inside* the container | Erodes the density win |
| VM | VNC to the QEMU socket, or a server in the guest | Full VM cost |

Most container-suitable labs — recon, networking, log analysis, much of
Metasploitable3 — are CLI-only, so SSH covers them and renders fine in a
browser. Reserve desktop-in-container for labs genuinely needing a GUI browser,
and prefer one shared toolbox container per pod over a desktop in every
container. Access method tiers alongside the hardware tiers above.

#### Student frontend: stock Guacamole first

Guacamole's own UI already shows a logged-in user exactly the connections they
have been granted, with thumbnails, and connects on click. That is the
requirement stated above, natively, with no application to write. It themes
without code.

Build a custom portal only for what Guacamole has no opinion about — lab
instructions beside the console, a pod reset button, a countdown, scoring.
Those are pedagogical features whose shape is unknown until the pilot. At that
point it is a small app calling the control-plane API and linking out to
Guacamole per machine, not a rewrite.

**Decision: Phase 6 ships stock Guacamole. Revisit a portal after Phase 8.**

Kasm Workspaces is the obvious-looking alternative and is ruled out: its
Community Edition caps at 5 concurrent sessions and forbids revenue-generating
use, failing both the concurrency target and the prebuilt SKU. Guacamole
(Apache 2.0) carries no such terms.

### Provisioning tool — decided: Ansible, no OpenTofu

**OpenTofu is dropped.** The four `.tf` files were empty and have been removed,
along with the OpenTofu install from `bootstrap-controller.sh`.

A declarative IaC tool is a poor fit for resources created and destroyed many
times a day per user: pods have no meaningful desired state between lab
periods, and reconciling them against a state file is friction with no payoff.
Ansible plus the control plane covers everything the platform actually does.

Removing it also deletes an internet-dependent bootstrap step — the OpenTofu
apt repository and GPG key — which is a direct win for the factory/site split
above. One fewer external dependency to vendor into an offline appliance.

If IaC is ever revisited for durable infrastructure: **OpenTofu (MPL 2.0),
never Terraform (BUSL 1.1, not open source).**

### Content licensing

| Image | Status | Action |
|---|---|---|
| Debian 13 | Permissive | Keep — base and primary target |
| Parrot OS | GPL-based, redistributable with compliance | For the prebuilt SKU, prefer a slim self-built Debian toolbox |
| **Windows 7** | **Non-redistributable, out of support** | **Remove.** `ansible/vars/templates.yml:142` points at an archive.org ISO — untenable in anything sold |
| Metasploitable2 | Redistribution terms ambiguous | Replace with **Metasploitable3 (BSD-3-Clause)** |
| — | — | Add **OWASP Juice Shop (MIT)** |

Both problem images are `enabled: false` today, so there is no urgency — but
neither can ship in a prebuilt unit.

---

## Open design question: how do student devices reach the box?

Carried unresolved from the first draft (2026-08-04) through 2026-08-05.
**Reframed 2026-08-05: this was two questions wearing one coat, and the half
that gates the pilot is already answered.**

**Model A — box joins the LAN.** It is assigned an IP; students browse to it
from school devices on the same subnet.

**Model B — box brings its own network.** A switch and/or access point in the
BOM; student devices connect directly to the lab network, sidestepping
district network approval.

**The catch with Model B:** district-managed Chromebooks are frequently locked
to the district network, forced through a proxy, or unable to join arbitrary
Wi-Fi — possibly unusable with exactly the devices the product targets.

### Resolved for the pilot: Model A, already in production

The current classroom runs Model A today. Servers are plugged into the
classroom's wall ethernet ports, lab computers are on the same subnet, and
they reach the box without any special provision. No district approval was
sought or needed, because a teacher plugging a machine into a classroom
ethernet port does not trigger district review.

**This unblocks BOM v1.** The question was listed as gating the BOM; it gates
the *product* BOM, not the *pilot* BOM. Nothing about the pilot cluster's
hardware waits on a sysadmin conversation. Switch mandatory, WAP not
purchased — buy and build against Model A.

**What stays genuinely open is the district-sale case**, which is a different
question with different unknowns (below). Do not let it hold up hardware.

### Deployment location is upstream of the network question

The appliance does not have to sit in the classroom. The labs are virtual —
students reach consoles through a browser — so a district may prefer to rack
it wherever their other network equipment lives, next to the switches it
depends on, with easier physical and network access for whoever maintains it.

That mostly dissolves Model B. **An access point in a wiring closet serves
nobody.** Model B only makes sense for a cart that lives in the room with the
students; the moment the box is centrally located, students reach it over the
district's existing network by definition, which is Model A. So the real
branch is not "how do devices reach the box" but "where does the box live,"
and the network model falls out of it:

| Deployment | Where it lives | Network model | AP in BOM? |
|---|---|---|---|
| **Classroom cart** | The room, on a rolling cart | A (wall port) or B | Only if B |
| **Central rack** | District MDF/IDF with their switches | A, necessarily | No |
| **Mobile / pop-up** | Moves between rooms or sites | B | Yes |

**Model B is demoted to the mobile/pop-up case** — competition teams, summer
camps, a cart shared between schools — where there is no permanent port to
plug into and the AP genuinely earns its place. It is no longer a co-equal
contender for the primary deployment, and it should not shape BOM v1. Note
the irony that makes this easy to accept: Model B is least likely to work
exactly where the product is most needed, since a district locked down enough
to refuse an IP is a district whose Chromebooks cannot join a strange SSID.

### Egress and the apt cache

**Intent: the box gets internet egress; lab VMs still get none.** The host
stays patched, and an apt caching proxy serves packages *into* the isolated
section VNets so lab guests can `apt install` without SNAT and without any
path off the box.

This is the right shape, and it preserves the property that matters. Section
VNets keep `snat: false` (`controller-bootstrap-sdn.yml`), so the Phase 5
isolation test still asserts what it should: no route to the internet, the
district LAN, or the management network. Students gain package installs, not
reach. Compare the alternatives — no packages at all is pedagogically
crippling, and giving lab VNets SNAT gives up the isolation guarantee
entirely.

**A VMID was already reserved for it** — `801`, as "future apt-cache or
package mirror service", allocated before the service was designed. Designing
it showed one ID was not enough, since VMIDs are cluster-unique and the cache
is per-node; `data/bootstrap-policy.yml` and `docs/platform-pipeline.md` now
reserve `801-805`. **Phase 2.5 builds it.**

Two things to settle when it is built:

- **It is the second deliberate exception to Phase 5 isolation.** The access
  LXC is the first, and Phase 5 already insists that exception be designed
  rather than discovered. The apt cache needs the same network position — a
  foot in each pod VNet, a foot with egress — and must be named in the
  isolation test alongside Guacamole. Two carve-outs is defensible; the
  failure mode is a fourth and a fifth arriving unexamined until isolation is
  fiction. Colocating both on one LXC would halve the carve-outs, at the cost
  of putting egress on the box students can already reach — a smaller attack
  surface argues for keeping `apt-cacher-ng` separate from Tomcat. Decide in
  Phase 5, deliberately, either way.
- **It softens the "assume none" connectivity constraint**, which currently
  reads "everything preloaded; zero downloads at deploy or run time."
  Connectivity should be a *floor, not a prohibition*: the appliance must
  work with none, and use it when present. The factory/site split is
  unaffected — the appliance still never builds templates — but "zero
  downloads at run time" is no longer the intent, and the Constraints table
  should say so.

### Questions for the district sysadmin — district-sale scope only

Not needed for the pilot. These belong to the eventual conversation about
dropping a prebuilt unit onto someone else's network.

**Model A, the expected path:**

1. What's the process and lead time for a single static IP or DHCP
   reservation for one device — a same-day network-team ticket, or a formal
   security review measured in weeks?
2. **Is there 802.1X, NAC, or sticky-MAC port security on the ports this
   would use?** This is the question that most plausibly breaks Model A, and
   it is invisible until you try. It evidently is not in force on the current
   classroom's ports, since servers plugged into the wall simply worked — but
   that is a fact about one district, not a general one.
3. Would you rather this live in a classroom or in your rack with the other
   network equipment? (Their answer determines the chassis/mounting question
   in Phase 3, and most sysadmins will have a strong preference.)
4. Does your process distinguish a device requesting *internet egress* from
   one that only needs to be *reachable on-segment*? The box wants modest
   egress for updates (above) but its student-facing surface is inbound-only.
5. Is there a segmented classroom/lab VLAN it could join, rather than
   anything touching core infrastructure?

**Model B, only if Model A is refused outright:**

6. Are Chromebooks restricted to district Wi-Fi at the device/MDM level (a
   Google Admin network allowlist) or the network level? Different exception
   paths.
7. If MDM-level: can one classroom-local SSID with no WAN uplink be added to
   the allowlist for one set of devices, or does every SSID trigger the same
   review regardless of what it connects to?
8. Do the specific Chromebook models require validated internet access before
   joining a network? Some ChromeOS configurations reject a network failing an
   internet-reachability check on connect — which would break a no-egress AP
   technically, even where policy permits it.

### Consequences for Phase 3

The central-rack possibility contradicts assumptions currently stated with
confidence in Phase 3 and in Constraints:

- **"Noise, power, and thermal are product requirements"** is a
  classroom-cart claim. In an MDF nobody hears the box, and the noise
  criterion is close to free.
- **The rolling A/V cart recommendation** was argued partly from candidate
  chassis not being rack-eared. For a district that wants this in their rack,
  shelf trays in a 19" rack stop being a compromise and become correct.
- These are two deployment profiles, not one. The BOM likely branches: same
  compute, different mounting and no AP. Resolve alongside the Phase 3
  measurements rather than guessing now.

---

## Phases

### Phase 0 — Stabilize (Aug 2026)

Code work complete: the four defects are fixed (see current state above), root
`.gitignore` covers `__pycache__/`, and `ansible/ansible.cfg` and
`ansible/requirements.yml` now exist.

**Exit:** two consecutive clean `install-cyberlab.sh` runs on a wiped host;
API token demonstrably performs a privileged action.

**Status 2026-08-05 — met in substance, gate still open.** Six runs against
`pve1`, ending in two consecutive runs that are identical, converged and
exit zero, with the API token validating its 7 required privileges from
inside CT `800` each time. What the runs did *not* cover is the wiped host:
CT `800`, the automation user, the pools and the legacy template VMs were all
still present, so controller creation and template-volume discovery were
skipped as already-satisfied rather than exercised. The gate stays open until
a run on a genuinely fresh host. See `docs/testing.md` for the run log.

The runs earned their keep — nothing here was visible from a laptop:

- **`CyberlabAutomation` did not exist on the host.** The role and its ACL
  were created by the first run, and the token then validated. Phase 0 defect
  2 is now proven against live Proxmox rather than by inspection.
- **The installer bounced the controller on every run.** `pct set` writes
  rather than compares, so the network reconcile fired unconditionally,
  stopping and starting CT `800` each time and dropping its DHCP lease — its
  address moved mid-session. Fixed in `9e463b0`.
- **`bootstrap-controller.sh` re-ran every time**, doing `apt-get install` and
  a `git pull` inside the controller on each pass, which made a re-run depend
  on network reachability it did not need. Fixed in `ab9762c`.
- **The completion summary reported skipped phases as completed.** A run with
  `--skip-sdn-bootstrap` printed that it was skipping SDN and then listed
  "SDN zone and VNET bootstrap" under completed phases.

`changed` on a converged second run fell from 12 to 2 across those fixes. The
two that remain are the `pveum` role and ACL reconciles, left deliberately as
a reconcile pattern.

### Phase 1 — CI (Sep 2026) — done

`.github/workflows/ci.yml` runs `yamllint`, `ansible-lint`, `ruff`,
`shellcheck`, and `pytest` on every push and pull request. Configuration lives
in `.yamllint`, `.ansible-lint`, and `pyproject.toml`; tooling in
`requirements-dev.txt`. `docs/testing.md` Level 1 documents running the same
set locally.

**Exit met.** Each of the four Phase 0 defects was reintroduced on a scratch
copy and confirmed to turn the suite red, as were three structural regressions
(privilege drift, a playbook targeting an absent host, a wrapper importing a
missing playbook). Passing tests alone would not have demonstrated this.

Two classes of defect predicted by the original analysis were found and fixed
while building this:

- **`proxmox-sdn.yml` targeted `hosts: poseidon`**, absent from inventory.
  Both `--syntax-check` and `bash -n` passed on it. This is the worst failure
  mode available: a play aimed at a nonexistent group runs zero tasks and exits
  zero. The playbook has since been deleted as stale — see the resolution note
  in the current state section.
- **`policy.yml`'s `username_policy` was loaded and discarded** —
  `format_student_username` hardcoded the same pattern, so editing the
  source-of-truth file changed nothing. Now consumed, matching how
  `password_policy` and `pool_policy` already worked.

Also fixed: five `SC2155` warnings where `readonly X="$(cmd)"` masked the
substitution's exit status under `set -Eeuo pipefail`, defeating the scripts'
own error handling.

Note that `ruff` — not `pytest` — is what guards defect 4. `raiseValueError(…)`
is syntactically valid, so `py_compile` accepts it; `F821` (undefined name)
rejects it. The `select` list in `pyproject.toml` is pinned explicitly so a
ruff upgrade cannot silently change what CI enforces.

### Phase 2 — Factory template pipeline (Oct 2026)

Debian 13 green through prepare → finalize → promote → validate. Add Juice
Shop and Metasploitable3. **Formalize the factory/site split** — mark every
task that requires internet and move it behind a factory-only flag.

**Exit:** a deliberately broken image fails validation; a documented image set
is producible offline from a bench build.

**Status 2026-08-05 — first half met.** Debian 13 is green through the full
pipeline, and the broken-image half of the exit is done: the real stale
template of 2026-05-07 was kept as a `vzdump` and restored deliberately, and
validation refused it (`failed=1`) while the good image passed the same test
(`validation_passed=true`). Details and how to reproduce are in
`docs/testing.md`.

Promotion is now gated on a working guest agent (`a835073`), so that particular
image can no longer be produced in the first place.

**Still open for Phase 2:**

- **Offline producibility from a bench build** — the second half of the exit,
  and entirely untested. Every build so far has pulled a cloud image and run
  `apt-get` over `prov0`'s SNAT, which is exactly what a shipped appliance
  cannot do. This is the factory/site split, and it is the larger piece.
  **Extend the exit criterion:** a lab guest must complete `apt-get update`
  and an install from the factory-seeded package cache with the appliance's
  uplink *physically disconnected*. Unplugging the cable is the only version
  of this test that cannot pass for the wrong reason — a firewall rule or a
  route can be wrong in a way that still resolves and still fetches.
- **The other four templates.** Only `debian13` has been built live.
  `win7` and `metasploitable2` set `agent_enabled: false`, so they take a
  different validation path than the one now proven, and neither is a
  `cloud_image` build.
- **Juice Shop and Metasploitable3** are not in the catalog yet.

### Phase 2.5 — Package cache, before the air gap (Oct-Nov 2026)

**Promoted to a phase of its own, and sequenced here deliberately.** The cache
is not a convenience bolted onto an offline appliance — it is what lets an
air-gapped lab still install software. The observed positioning claim is that
comparable classroom ranges tend to fall on one side or the other: either they
need internet, or they ship sealed images with no package installation at all.
Treated here as a differentiator worth building deliberately rather than an
audited survey of the market — worth confirming against specific competitors
before it goes in any sales material.

**It is also a one-way door, which is the real reason it comes now.** A cache
can only be seeded while the lab still has egress. Once a unit is air-gapped —
or once this classroom's own build goes offline — there is no path to fill it.
Every other phase can be reordered; this one cannot be done late. Numbered 2.5
rather than inserted as a new Phase 3 so the existing phase numbers, which the
rest of this document references throughout, keep meaning what they mean.

**Depends on** Phase 2's Debian 13 pipeline being green, which it is, because
the template finalize pass is what does the seeding.

#### Placement: one LXC per node, on a service VNet

Not one shared service for the cluster. Pod affinity puts pod networks in
node-local `simple` zones — the existing hosts already prove this, each having
carried its own independent `virtnet` — so a cache container on node 1 has no
path to a pod VNet on node 2. A cache per node keeps every packet node-local,
costs only disk, and matches the decision already accepted for templates
("replicated to every node's local storage").

Three alternatives, and why not:

- **One interface per pod VNet on a single container.** Strongest isolation
  story — link-local, no routing permitted at all — but Proxmox caps an LXC at
  ten NICs and Phase 5 wants a VNet *per pod*. Dead at roughly nine students.
- **Put the cache on `prov0`.** Tempting, since `prov0` is the one subnet with
  `snat: true` and already has egress. Rejected on architecture: `prov0` is
  factory-time infrastructure, stripped from every shipped unit, and the
  factory/site split is the defining split of this design. A site-time service
  must not live on a factory-time network.
- **Run `apt-cacher-ng` on the Proxmox host directly.** No container, no VMID,
  no cross-node problem, bound to each VNet gateway. Rejected on blast radius:
  this is a lab where students practice exploitation by design, and a service
  reachable from lab networks must not run on the hypervisor.

**The container is dual-homed, and that is how the air gap gets crossed
exactly once.** `net0` on the service VNet is permanent and carries no egress;
`net1` on `prov0` exists only during factory seeding and is stripped before
the unit ships. This mirrors the pattern the template pipeline already uses and
documents — `prov0` attached transiently, removed by
`controller-promote-template.yml` before `qm template` — so it is an
established idiom here rather than a new one.

#### Work items

- **Define a `svc0` VNet** alongside `prov0` in `ansible/inventory.yml`:
  `snat: false`, four characters so it clears the Proxmox 8-character limit.
  `10.31.0.0/24` is safe alongside `prov0`'s `10.30.0.0/24`: section subnets
  are `10.<teacher_id>.<section_code>.0/24` and **`teacher_id` starts at 101
  by design**, leaving 101-255 — about 150 teachers — clear of the low octets
  reserved for infrastructure.

  **What is worth adding is a range assert on `teacher_id`**, which does not
  exist today. `generate_runtime_artifacts.py` checks that it is an integer
  and that it is unique, but not that it falls in 101-255. The floor is load-
  bearing for the infrastructure subnets and the ceiling is load-bearing for
  the network formula itself — `teacher_id: 256` produces an invalid octet,
  the same failure mode already documented for `course_index` in Identifiers.
  Both ends currently rest on convention.
- **A `controller-bootstrap-package-cache.yml` playbook**, and its call in
  `install-cyberlab.sh` behind a flag defaulting the same way
  `cyberlab_sdn_build_sections` does — off until it is proven.
- **Size it.** 512 MB RAM is ample for `apt-cacher-ng`; the disk is the real
  cost, plausibly 10-20 GB per node, times node count, since each node carries
  its own. Cheap on local NVMe, but not free, and BOM v1 should know before
  Phase 3 prices drives.
- **Explicit proxy, not transparent.** Bake
  `Acquire::http::Proxy "http://<node-cache>:3142";` into template images
  rather than intercepting port 80 with DNAT. Declarative, visible in the
  image, and it **fails closed** — an unreachable cache makes `apt` error
  rather than quietly trying to reach the internet. It also removes the DNS
  dependency from lab guests entirely, since the proxy resolves upstream names
  on their behalf.
- **Seed via the finalize pass.** `controller-finalize-template-vm.yml`
  already runs `apt-get` over `prov0`'s SNAT; pointing it at the cache means
  the cache warms with exactly the package set the shipped labs install, with
  no separate manifest to maintain and drift.
- **Supplement with a small explicit manifest** in `data/` for packages labs
  install at *run* time but templates do not bake. Those never pass through
  the factory, so they never warm the cache on their own.
- **Pin retention.** `apt-cacher-ng` expires unreferenced files by default. On
  an offline appliance that slowly empties a cache nothing can refill, and it
  fails months after deployment, in someone else's classroom, looking like
  corruption rather than configuration.

#### Exit

- The cache LXC is reproducible from `install-cyberlab.sh` on a clean host.
- A template build's `apt` traffic demonstrably passes *through* the cache —
  verified from the cache's own hit/miss counters, not from the build merely
  succeeding, which it would do either way.
- **A lab guest completes `apt-get update` and an install with the host's
  uplink physically unplugged.** Pulling the cable is the only version of this
  test that cannot pass for the wrong reason; a wrong rule or a stale route
  can still resolve and still fetch.
- Cache contents survive a reboot of the container and its host.

**What this reduces the district ask to.** With the cache seeded and the
firewall enforcing isolation, the appliance needs exactly one thing from a
district: **an inbound-reachable IP address.** No egress, no DNS, no NTP, no
access point, no outbound firewall exceptions. That is the smallest ask this
product can make, it is the same ask in a classroom or a central rack, and it
shortens the Phase 7 site survey to port security, IP assignment, and physical
location.

**VMID note:** `data/bootstrap-policy.yml` and `docs/platform-pipeline.md`
reserve `801-805`, one per node, since VMIDs are cluster-unique and a per-node
service cannot share one ID.

### Phase 3 — Hardware and BOM (Oct-Nov 2026)

Acquire and validate the cluster. Measure real per-VM RAM. Verify noise under
load in a room, power draw on a single classroom circuit, and thermals in a
closed rack. Settle the cart-versus-rack deployment profile (see Still open
below). Publish BOM v1.

**Exit:** a running 3-node cluster you have measured, not estimated.

#### Benchmark framing

The workload is mostly idle VMs with bursty activity (a student exploiting
something, a compile, a boot storm at the start of class), not sustained
compute. Raw CPU benchmarks (Passmark/Geekbench) are a weak proxy for node
selection. Two better filters:

- **Procurement-time coarse filter** — cheap to check before buying: 4c/8t
  floor, 6c/12t preferred (concurrency headroom, not per-VM speed); RAM
  ceiling *actually reachable*, not official QVL, since corporate SFF boards
  routinely run 64GB unofficially past what the spec sheet claims (2×32GB
  DDR4 SODIMM — verify per-model on r/MiniPCs or ServeTheHome before buying in
  bulk); a real NVMe M.2 slot, not SATA-only or eMMC, since concurrent
  linked-clone boot storms at class start are a random-4K-IOPS problem, not a
  sequential-throughput one; VT-x/VT-d or AMD-V/AMD-Vi present (universal by
  the targeted era, but confirm on any oddball unit).
- **Post-acquisition validation benchmark** — buy one candidate node before
  committing to the fleet, boot N concurrent linked clones (2-3 pods worth),
  time to guest-agent-ready, and watch actual RAM/CPU consumed. This doubles
  as the check on whether `slots.yml` sizing (already flagged above as too
  generous) is realistic. One unit validated beats five units estimated.

#### Hardware generation, given the DRAM pricing crisis

| Generation | Verdict | Why |
|---|---|---|
| DDR5 (12th gen Intel+/Ryzen 7000+) | Skip | Squeezed hardest by the current DRAM price spike, and these units are still early in corporate first-owner life so they aren't flooding refurb/liquidation channels yet. Bad on both cost axes. |
| DDR3 (2nd-4th gen Intel, pre-~2015) | Skip for primary nodes | Cheapest and most abundant on the refurb market, but typically caps at 16-32GB/node — blows the 64GB/node target and forces chasing the RAM budget with more nodes instead of more RAM. Only worth it as a free throwaway ancillary box (time source, local DNS, teacher jump host). |
| DDR4, 8th-10th gen Intel (Coffee Lake / Coffee Lake Refresh / Comet Lake) | **Target** | Sweet spot today: heavy corporate refresh liquidation keeps supply plentiful, DDR4 SODIMM pricing hasn't spiked like DDR5 since fab capacity didn't need to shift, and 6c/12t (i5-8500T/i7-8700T/i5-10500T) is available versus quad-core-only on the prior generation. |
| DDR4, 6th-7th gen Intel (Skylake/Kaby Lake) | Budget/pilot floor | Cheapest DDR4 entry, quad-core, officially 32GB (sometimes 64GB unofficially — check per-model). Reasonable for a 3-node pilot or a 5th node added later; not what the whole BOM should anchor to. |
| AMD Ryzen PRO 4000/5000 (Renoir/Cezanne) | Opportunistic | Strong core count/IPC for the era on DDR4, but AMD's corporate fleet share was small so these don't show up in bulk refurb lots the way Intel does. Grab them cheap when found; don't plan procurement around finding enough. |

Node candidates in the target generation: Lenovo ThinkCentre M720q/M920q/M75q,
HP EliteDesk/ProDesk 600/800 G4/G5 Mini, Dell OptiPlex 5070/7070 Micro.
Budget-floor candidates: ThinkCentre M700/M900, EliteDesk 800 G2/G3, OptiPlex
3040/5050/7040 Micro. AMD candidates: EliteDesk 705 G4/G5 Mini, ThinkCentre
M75q Gen2.

#### Switch

3-5 nodes plus a teacher console is 4-6 ports before adding slack — **8-port
unmanaged** over 5-port. (The WAP that would have taken a port is not in BOM
v1; see the student-network section.) Pod affinity keeps VM traffic node-local
by design, so the switch only ever carries corosync heartbeat, template sync,
and node management: gigabit unmanaged is plenty. Keep it dumb on purpose —
zero config is consistent with "reproducible from the public recipe," and a
managed switch is one more thing to document and one more thing that can drift
from the recipe.

**Revised 2026-08-05: the switch is not uplinked to the district.** An
unmanaged switch floods broadcast and multicast to every port, so uplinking it
puts ARP, mDNS, DHCP and any BPDUs onto the school network where no host
firewall can filter them — layer 3 rules never see layer 2 leave. Instead
**one node carries the district uplink on a second NIC**, and the switch stays
a closed cluster network with no physical path off the cart. See
`docs/network-isolation.md`.

BOM consequence: one USB3 gigabit adapter for the uplink node, or a candidate
model that takes an internal second NIC (verify per model; prefer internal).
One adapter for the cluster, not one per node. The port count above already
assumes no uplink port is consumed.

#### Rack

None of the candidate chassis are rack-eared, and footprints vary by vendor
and generation — buying a mixed/variable fleet across generations to chase
value means a 19" rack would just become a mounting frame for flat shelf
trays, at more cost and weight for no real benefit at this scale. A
**rolling open-shelf A/V cart** fits better: cheap, doesn't lock the BOM to
one chassis shape, gives good airflow for the thermal-under-load exit
criterion above, and — important given refurb reliability variance — allows
easy physical access to swap a dead unit without unracking anything. Put the
unmanaged switch and a power strip/PDU on the same shelf.

Power math supports the form factor choice: SFF/Tiny units run roughly
35-65W under load, so even 5 nodes + switch stays well under 500W total —
nowhere near stressing a standard classroom 15A circuit.

#### Still open

**Resolved 2026-08-05 for BOM v1 purposes: Model A, no WAP.** The pilot
classroom already runs Model A off wall ethernet ports, and the central-rack
deployment option demotes Model B to the mobile/pop-up case. The switch was
always mandatory; the WAP is not purchased. See the student-network section.

What that section leaves open for Phase 3 to settle: whether the product ships
a **classroom-cart** or **central-rack** profile, which changes mounting (A/V
cart versus rack shelf trays) and softens the noise criterion, since a box in
an MDF has no one to disturb. Same compute either way, so this does not block
node selection or the measurement work.

### Phase 4 — Pod provisioning engine (Nov-Dec 2026)

`pod up`, `pod down`, `pod reset`. Node scheduler with pod affinity. Linked
clones under 60 seconds. Idle reaper. Right-sized slot definitions and
`data/labs.yml` scenarios.

### Phase 5 — Network isolation (Dec 2026)

Create per-section and per-pod VNets. No egress from lab networks — not the
internet, not the district LAN, not the Proxmox management network. Prove
isolation with a test that runs on every deploy. Prove DHCPDISCOVER receives
DHCPOFFER.

**`docs/network-isolation.md` holds the concrete rule set** — the Proxmox
firewall blocks, sysctl hardening, service suppression, and the verification
procedure. It covers a second requirement beyond keeping students contained:
keeping the *cluster itself* quiet on the school network, so that corosync
heartbeat, mDNS, BPDUs, DHCP broadcast, subscription checks and NTP pool
lookups never reach a district sysadmin's monitoring. The headline decision
there is topological rather than a rule — **the switch is not uplinked; one
node is** — because layer 2 noise cannot be filtered by a layer 3 firewall.

**The access LXC is the one deliberate exception and must be designed as one.**
Guacamole has to reach every guest to broker consoles, so it holds an interface
into each pod VNet (or a routed path to it) — tightly scoped, and explicitly
carved out in the isolation test. Settle this in Phase 5 rather than
discovering it in Phase 6, or the test gets written and then quietly weakened
to make consoles work.

#### `snat: false` is not isolation — suspected, and the first thing to test

The roadmap has been reading `snat: false` on section VNets as "no egress at
all" (`controller-bootstrap-sdn.yml:61` says so in a comment). **That is
probably wrong, and the error is in the direction that matters.** SNAT
controls address translation, not reachability. What the current build
produces is:

- a `simple` zone, which puts a **gateway address for every VNet subnet on the
  host itself**;
- `net.ipv4.ip_forward=1`, set persistently in
  `/etc/sysctl.d/99-cyberlab-forwarding.conf` and *asserted* by the SDN
  bootstrap — enabled for `prov0`'s SNAT, but forwarding is global, not
  per-interface;
- **no firewall rules anywhere in the repository.** No datacenter firewall
  config, no VNet rules, nothing.

A host that routes, with an address on every lab subnet and no filter, is a
router between all of them. So a lab guest can likely reach other sections'
subnets, `prov0`'s `10.30.0.0/24`, and — most seriously — **the Proxmox
management address on `vmbr0`**, which the host answers directly and has a
return route for. Phase 5's stated requirement is no path to "the internet,
the district LAN, or the Proxmox management network." The third is the one
that plausibly already fails.

Actual internet access is still unlikely, since a lab-sourced packet matches
no SNAT rule and gets no return path — so "no egress" is accidentally true for
the internet and accidentally false for everything local.

**Epistemic status: reasoned from the configuration, not observed.** Section
VNets exist on no host right now, so this could not be tested from this
session. Confirm before designing around it — build one section VNet, attach a
guest, and from it try (a) `ping` the management IP, (b) reach a guest in
another section, (c) reach `10.30.0.1`. If those succeed, isolation is a
firewall project, not an SDN-flag project, and every design below depends on
it.

#### Isolation enforcement — decided: Proxmox firewall, not a firewall VM

Isolation is enforced by the **built-in Proxmox firewall**. A dedicated
firewall appliance (OPNsense or similar) is rejected as the platform boundary.

**Why the built-in one wins here:**

- **It is enforced at the guest's own tap/veth interface, not at a routing
  chokepoint.** That is the direct fix for the defect above: a per-guest
  default-deny holds no matter how permissively the host routes between VNets,
  so isolation stops depending on the SDN topology being right.
- **Rules live in `/etc/pve/`**, which is the replicated cluster filesystem, so
  they propagate to every node with no extra machinery — and node-local pod
  networks make that matter.
- **No new Proxmox privileges.** Cluster and host rules need `Sys.Modify`;
  per-guest rules need `VM.Config.Network`. Both are already in
  `automation_role_privs` and both are already asserted by
  `controller-validate-proxmox-api.yml`. Adoption costs nothing on the
  access-control side.
- **Zero RAM**, against 2-4 GB per node for a firewall VM — real money on nodes
  already over budget at 22.5 GB/student.
- **Text config is reproducible from the public recipe**, consistent with the
  licensing position, where a VM appliance is another image to distribute.

**The argument that actually settles it, though, is pedagogical.** This is a
lab where students study, misconfigure, and attack firewalls by design. The
mechanism enforcing their containment must not be the mechanism they are
learning to break. If OPNsense were the platform boundary, a student who
successfully misconfigures the teaching firewall would thereby breach platform
isolation — the blast radius of a *correct* lab exercise would include the
platform. Keeping enforcement in the hypervisor, below anything a pod can
reach, keeps those two concerns from ever touching.

**So OPNsense is reclassified: curriculum, not infrastructure.** It is a good
lab template — BSD-2-Clause, no licensing friction, and firewall
administration is genuinely in the pathway — living *inside* a pod as
something students configure. It is simply never the platform's own boundary.
Worth adding to the template catalog on those grounds; worth nothing as
infrastructure.

**The gotcha that must be designed in, not discovered:** the Proxmox firewall
applies to a NIC only when that NIC has `firewall=1` in the guest config. A
guest missing it is **silently unfiltered** — rules present, correct, and not
applied. That is precisely the failure class this repository has already been
bitten by twice (the playbook targeting an absent host, `username_policy`
loaded and discarded). The pod engine sets the flag, and the isolation test
asserts it **per guest** rather than trusting that it was set.

Rule shape, stateful so return traffic needs no rule of its own:

- Datacenter: `enable: 1`.
- Every lab guest: `policy_in: DROP`, `policy_out: DROP`.
- One security group applied to every lab guest:
  - OUT → package cache, tcp/3142 only
  - OUT → VNet gateway, udp/67-68 and 53
  - OUT → its own pod subnet, so students can reach their own targets
  - IN ← its own pod subnet
  - IN ← Guacamole, console ports only
- `host.fw`: drop lab subnets to the management address, as defence in depth.
  Guest-level `policy_out: DROP` should already prevent it; both, because this
  is the assertion most likely to be quietly wrong.

#### Package cache — the second deliberate carve-out

**The service itself is built in Phase 2.5**, which is where its placement,
seeding, and disk budget are decided. What belongs here is only its status as
an exception to isolation.

**The two carve-outs point in opposite directions, and that is what makes them
testable.** Guacamole *initiates into* pod VNets and pods must never initiate
to it; the cache is *initiated to* by pods and must never initiate to them.
Both are unidirectional. State both as stateful rules in that form and the
isolation test writes itself.

**What the isolation test must assert**, from inside a pod VNet:

1. No route to the internet, tested **by IP**, not by name — a DNS failure
   passes a naive test for the wrong reason.
2. No reach to the district LAN, and specifically **not the Proxmox management
   address**. This is the assertion the finding above says may fail today.
3. No reach to another pod's or section's subnet.
4. Reaches the cache on `3142` and **nothing else on that host** — the
   carve-out is a host *and port*, not a host. Testing only that the cache
   works would pass a container with SSH exposed to every student in the
   building.
5. Guacamole reaches pod guests; pod guests do not reach Guacamole.
6. `apt-get update` and an install succeed through the proxy — the carve-out
   is verified working, not merely permitted.

### Phase 6 — Access layer (Jan 2027)

**A single LXC** holding `guacd`, the Tomcat web app, and PostgreSQL together —
fewer moving parts beats service separation on an offline appliance. Budget
~2 GB. Connection provisioning tied to pod lifecycle, idle timeout, stock
Guacamole UI and DB auth per the access-control section above. Session
recording writes heavily; plan storage before enabling it broadly.

**Remote access tunnel as an opt-in module, disabled by default** —
`cloudflared` outbound-only, zero inbound ports, Cloudflare Access in front.
Enabled on your own box; shipped off.

### Phase 7 — Appliance packaging (Feb-Mar 2027)

Reproducible image build. Offline update bundle, signed, applied from USB.
First-boot configuration for a district sysadmin. Recovery procedure. The
documentation a stranger needs to run this without you.

#### Pre-deployment site survey

Ship a short checklist answered **before** a unit is boxed, because each item
below fails at the customer's site rather than on the bench, and two of them
fail silently.

- **Port security on the target ethernet ports — 802.1X, NAC, or sticky-MAC.**
  The single most likely cause of a unit that arrives, plugs in, and does not
  work. A port doing 802.1X supplicant authentication drops an unregistered
  device with no error the device can report; from the classroom it presents
  as "the box is broken." The pilot classroom has none of this — servers
  plugged into wall ports simply worked — which is exactly why it is invisible
  from here and has to be asked rather than assumed. If present, the fixes are
  a MAC exemption on the port, a dedicated non-authenticating port, or MAB,
  all of which need lead time from their network team.
- **Where the unit lives** — classroom or central rack. Determines mounting
  hardware, whether noise matters, and which cable run it needs. See the
  student-network section.
- **IP assignment** — static or DHCP reservation, on which VLAN, and whether
  students' devices can route to it. A correct IP on a segment students cannot
  reach is the second silent failure.
- **Whether egress is permitted** — worth recording, but **not a requirement**.
  The package cache ships seeded from the factory (see Phase 5), so a unit with
  no outbound path runs labs normally; egress only buys automatic host patching
  and a self-refreshing cache. Ask so the answer is recorded rather than
  assumed, and so a district that grants it gets the benefit.
- **Switch port count available**, if the unit uplinks to district
  infrastructure rather than carrying its own switch.

### Phase 8 — Pilot (Mar-Apr 2027)

Your own classroom, one section, one scenario. Then a friendly district.
Instrument everything; fix; repeat. Map labs onto the Cyber.org units they
supplement.

---

## Immediate next actions

1. **Build and seed the `apt-cacher-ng` LXCs (Phase 2.5)** — the next major
   item. Everything else here can be reordered; this cannot, because a cache
   can only be filled while the lab still has egress, and the current build
   still does
2. **Test whether `snat: false` actually isolates** (Phase 5) — build one
   section VNet, attach a guest, and try to reach the Proxmox management
   address from it. If that succeeds, isolation is a firewall project and the
   Proxmox-firewall work moves ahead of the pod engine. Cheap to run in the
   same lab session as item 1
3. Run `install-cyberlab.sh` twice on wiped Proxmox hardware to close Phase 0.
   Worth doing *after* item 1, not before: the wipe-and-rebuild then doubles as
   the proof that the cache is reproducible from the installer rather than a
   hand-built artifact that happens to exist
4. Price a 3-node and 4-node cluster; verify the refurb supply is repeatable
   enough to publish as a BOM — **no longer blocked** on the student-network
   question, which resolved to Model A for the pilot. Fold in the cache's
   per-node disk once item 1 has measured it

The district-sysadmin conversation is no longer an immediate action. It
belongs to the prebuilt SKU (Phase 7) and its question list is parked in the
student-network section until there is a district to ask.
