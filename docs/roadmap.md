# Cyberlab Roadmap

Planning document for taking this repository from its current state to a
self-contained, classroom-deployable cyber range appliance.

**Written:** 2026-08-04
**Analyzed at commit:** `5dd0092`
**Target:** own classroom pilot spring 2027, appliance design by summer 2027
**Not on the critical path:** this supplements the Cyber.org curriculum.
Nothing here blocks teaching this year.

---

## Product definition

**Cyberlab is a lab-in-a-box:** a small cluster of quiet, low-power compute
nodes in a rolling rack that a school district can deploy into a classroom and
run a cyber range on, with no dependence on district network services.

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
| Connectivity | **Assume none** | Everything preloaded; zero downloads at deploy or run time |
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
- **A hard ceiling of three course types.** Course index 3 produces codes
  `3xx`, which exceeds 255 and is not a valid IP octet. The fourth distinct
  course a teacher runs breaks subnet generation.
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
This removes all three defects at once — no leading zeros, no octet ceiling,
no cross-teacher collision — without changing the VMID or network formulas
themselves, since both already treat `section_code` as an opaque number.

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

This is unresolved and it materially changes the BOM and the district
conversation.

**Model A — box joins the classroom LAN.** District assigns it an IP; students
browse to it from school devices. Simple hardware, but requires district
network approval and an IP allocation, and puts the appliance on their LAN.

**Model B — box brings its own network.** Include a switch and/or access point
in the BOM; student devices connect directly to the lab network. Truly plug
into power and go, and it **sidesteps district network approval almost
entirely** — a significant product advantage.

**The catch with Model B:** district-managed Chromebooks are frequently locked
to the district network, forced through a proxy, or unable to join arbitrary
Wi-Fi. That may make Model B unusable with exactly the student devices the
product targets.

This needs a real answer from a district sysadmin before the BOM is finalized.

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
- **The other four templates.** Only `debian13` has been built live.
  `win7` and `metasploitable2` set `agent_enabled: false`, so they take a
  different validation path than the one now proven, and neither is a
  `cloud_image` build.
- **Juice Shop and Metasploitable3** are not in the catalog yet.

### Phase 3 — Hardware and BOM (Oct-Nov 2026)

Acquire and validate the cluster. Measure real per-VM RAM. Verify noise under
load in a room, power draw on a single classroom circuit, and thermals in a
closed rack. Resolve the student-network question above. Publish BOM v1.

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

3-5 nodes plus a teacher console plus a possible WAP (if student-network
Model B is chosen) is 5-7 ports before adding slack — **8-port unmanaged**
over 5-port. Pod affinity keeps VM traffic node-local by design, so the
switch only ever carries corosync heartbeat, template sync, and
management/Guacamole traffic: gigabit unmanaged is plenty. Keep it dumb on
purpose — zero config is consistent with "reproducible from the public
recipe," and a managed switch is one more thing to document and one more
thing that can drift from the recipe.

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

None of the above resolves the student-network question (Model A vs B)
above, and that materially changes port count and whether a WAP belongs on
the same cart/circuit. Pin it down before locking BOM v1.

### Phase 4 — Pod provisioning engine (Nov-Dec 2026)

`pod up`, `pod down`, `pod reset`. Node scheduler with pod affinity. Linked
clones under 60 seconds. Idle reaper. Right-sized slot definitions and
`data/labs.yml` scenarios.

### Phase 5 — Network isolation (Dec 2026)

Create per-section and per-pod VNets. No egress from lab networks — not the
internet, not the district LAN, not the Proxmox management network. Prove
isolation with a test that runs on every deploy. Prove DHCPDISCOVER receives
DHCPOFFER.

**The access LXC is the one deliberate exception and must be designed as one.**
Guacamole has to reach every guest to broker consoles, so it holds an interface
into each pod VNet (or a routed path to it) — tightly scoped, and explicitly
carved out in the isolation test. Settle this in Phase 5 rather than
discovering it in Phase 6, or the test gets written and then quietly weakened
to make consoles work.

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

### Phase 8 — Pilot (Mar-Apr 2027)

Your own classroom, one section, one scenario. Then a friendly district.
Instrument everything; fix; repeat. Map labs onto the Cyber.org units they
supplement.

---

## Immediate next actions

1. Resolve the student-network question with a district sysadmin — it gates
   the BOM
2. Run `install-cyberlab.sh` twice on wiped Proxmox hardware to close Phase 0
4. Price a 3-node and 4-node cluster; verify the refurb supply is repeatable
   enough to publish as a BOM
