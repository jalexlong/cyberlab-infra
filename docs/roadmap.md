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

- **Per-section VNets are never created.** Only `prov0` exists.
- **No egress control** on classroom networks.
- **OpenTofu files still empty** — see decision below.
- **Phase 0 exit remains unproven.** The fixes are correct by inspection but
  have not been run against live Proxmox hardware.
- **ansible-lint runs at `basic` with four rules deferred** (`fqcn`,
  `no-changed-when`, `risky-shell-pipe`, `name` — 68 findings). Each is a real
  improvement, but fixing them edits the only currently-tested path to a
  working host, so each should be retired with a hardware run behind it. See
  `.ansible-lint`.

---

## Architecture

### Factory versus site — the defining split

**A shipped appliance cannot build its own templates.** The pipeline currently
downloads Debian cloud images, `apt-get install`s from Debian repos, adds the
OpenTofu apt repo, and pulls LXC templates via `pveam`. Commit `5dd0092` added
`prov0` egress specifically so template builds could reach the internet.

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

- `bootstrap-controller.sh` currently runs `apt-get update`/`install` and adds
  the OpenTofu apt repo. That becomes a factory step baked into the controller
  LXC image.
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

Note that the current `slots.yml` values are far too generous for this
hardware — `atk` alone is 4 vCPU / 8 GB, which would be 240 GB at 30
concurrent. Right-sizing is mandatory, not optional.

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

### Provisioning tool

The four `.tf` files are empty, which is fortunate. OpenTofu is poor for
resources created and destroyed many times a day per user. Provision pods from
the control plane directly. Reserve OpenTofu for durable infrastructure or drop
it. If any IaC ships: **OpenTofu (MPL 2.0), never Terraform (BUSL 1.1, not open
source).**

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

**Remaining, and it needs hardware:** two consecutive clean
`install-cyberlab.sh` runs on a wiped host, with the API token demonstrably
performing a privileged action. Everything above is verified by inspection
only. Until this runs on live Proxmox, Phase 0 is not closed.

**Exit:** two consecutive clean `install-cyberlab.sh` runs on a wiped host;
API token demonstrably performs a privileged action.

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
  zero. Retargeted to `proxmox_targets`.
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
