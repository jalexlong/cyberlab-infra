# Repair posture

Why this platform is built to be rebuilt by someone who is not its author, and
what that costs.

**Written:** 2026-08-06
**Status:** design, with one part decided. The code licence is settled —
Apache 2.0, applied in `LICENSE` — and the reasoning is kept below because it
should outlive the decision. Everything else here is a commitment about how
later phases get built, not something that exists yet.
**Related:** `docs/roadmap.md` (Phase 3 cluster build sequence, Phase 7
packaging), `docs/network-isolation.md`, `docs/testing.md`

---

## What this replaces

Earlier planning framed this project as a product with a vendor attached: a
prebuilt unit, a recipe published alongside it, and a factory that stayed on
the author's bench. That framing was wrong, and it was wrong in a way that
quietly reintroduced the dependency the whole design exists to remove.

**The actual model: the recipe is the product.** Anyone with hardware, a wall
ethernet port, and the scripts in this repository can stand up their own
factory and their own cluster, build their own templates, and run their own
labs, without ever contacting the author. A district that wants to source its
own e-waste, refurbish it through a student repair programme, and build a unit
from parts is a first-class user of this project, not a fallback for one.

Prebuilt units may still be sold. They are a convenience — assembly, testing,
warranty, support — never the only path, and never a path with capabilities the
DIY path lacks.

**This is not a change of values, it is a change of mechanism.** The
reproducible-from-public-recipe principle was already in `docs/roadmap.md`
under the product definition. What changes is that it stops being a licensing
compliance argument and becomes the delivery model.

---

## The principle

> **Structural containment should constrain the running system. It must never
> constrain the owner's ability to rebuild it.**

This platform gets most of its safety from structure rather than from
configuration: a switch with no uplink cannot leak broadcast, a factory that
never ships cannot be misconfigured at a site, a data model that never receives
a student's name cannot disclose one. Structure fails safe in a way that
configuration does not.

The same property becomes a liability the moment it removes a capability the
owner needs and cannot restore. Containment the owner can deliberately step
outside of, with a documented procedure, is safety. Containment the owner
cannot undo is lock-in, and it is lock-in whether or not the source is
published.

### Auditing the existing decisions against it

| Structural decision | Verdict | Reasoning |
|---|---|---|
| Reproducible from a public recipe | **Supports** | The strongest repair guarantee here, and it is architectural rather than legal |
| Switch not uplinked; one node carries the district link | **Supports** | Verifiable by looking at the back of the cart. Reversible with a cable |
| Proxmox firewall over a firewall VM | **Supports** | Rules are text in `/etc/pve`, readable and editable in place, replicated by the cluster filesystem |
| `firewall=1` and NIC placement asserted per guest | **Supports** | A checked invariant beats a trusted one, for the repairer as much as for CI |
| No HA | Neutral | A stated capability choice, not a lock. Documented consequence: a node failure kills its pods |
| NIC-less templates by convention | Neutral | Convention plus assertion; a rebuilder can see why |
| **Factory/site split** | **Resolved by this document** | Previously the sharpest violation: a site could not build an image. Every unit is now a factory — see below |
| **Seeded cache with no refill path** | **Open** | `docs/roadmap.md` Phase 2.5 already predicts this fails months after deployment "looking like corruption rather than configuration." An owner-built factory is the answer for owner-built units; a genuinely air-gapped site still needs the USB path |

---

## Every unit is a factory

The factory/site split stays as a *description of network state* — a unit
serving a class has no business holding an egress path — but it stops being a
statement about who owns which capability.

| | Previously | Now |
|---|---|---|
| Who can build a template | The author | Any owner |
| What a site needs to build one | A shipment | An ethernet cable and the recipe |
| What "update" means | A signed bundle | Re-run the recipe |
| `prov0` at a site | Must never exist | Must not exist *while serving a class*; stood up deliberately to build, torn down after |

**What falls away.** There is no "factory mode" to design as an escape hatch,
because there is no hatch — the factory is the ordinary state of a unit that is
not currently teaching. The two firewall profiles in
`docs/network-isolation.md` already express exactly this, and they were written
before this document existed: a factory profile that permits egress for builds,
a site profile that denies it, and an assertion at the transition that the
factory allows are gone.

**What this obligates.** The build path must be documented to the same standard
as the run path, because it is now something a stranger performs rather than
something the author performs. It also must be *tested* by a stranger — see
the documentation section below.

The concrete sequence — cluster the bare nodes first, then uplink one, then
build templates once and replicate — lives in `docs/roadmap.md` under Phase 3,
because it is bound up with hardware acquisition and belongs with the phase
that acquires it. It is recorded there rather than here so there is one
authoritative ordering rather than two that can drift.

---

## Update paths

Three, and they are not equivalent. The first is primary and the other two
exist for cases the first cannot reach.

| Path | For | Trust model |
|---|---|---|
| **Re-run the recipe** | Any owner with a factory — the expected case | Whatever the owner already trusts to run the scripts. No new mechanism |
| **USB bundle** | Genuinely air-gapped sites that will never hold a build path | Signature verification against an **owner-enrollable** trust store |
| **Egress, where a district permits it** | Host patching and cache refresh only | Existing apt/Proxmox repository trust |

**The USB path is narrow on purpose.** It exists for a unit that has been
deliberately sealed — no build capability, no egress, a district that wants it
that way. An owner who built their own unit updates by rebuilding, and never
touches this path.

**The trust store is the part that must not be got wrong.** If the appliance
trusts exactly one signing key and offers no way to add another, then an owner
holding the full source, the full recipe, and a correctly built bundle still
cannot install it — the software refuses a legitimate artefact on policy
grounds. That is the failure mode this project exists to oppose, and it would
arrive dressed as a security feature.

So: ship trusting a project key by default, because that is the right default
for a sealed unit that wants updates from upstream. Publish the key-enrollment
procedure alongside everything else. Never make the project key the only one
the store can hold.

---

## Licensing

### What the licence actually governs

Only this project's own layer: the playbooks, the scripts, the control plane,
the admin panel, the tests, and the documentation. The surrounding stack is
already settled by other people's choices and is not affected by this decision.

| Component | Licence | Relationship |
|---|---|---|
| Proxmox VE | AGPLv3 | Called across an API/CLI boundary. Mere aggregation — this project's code is not a derived work |
| Apache Guacamole | Apache 2.0 | Bundled and configured via its REST API |
| Debian, and the lab images | Various, all redistributable | Selected for redistributability in `docs/roadmap.md` |
| **This repository** | **Apache 2.0** | Decided 2026-08-06. See `LICENSE` and `NOTICE` |

The prebuilt SKU still distributes Proxmox and therefore still carries AGPL
source-offer obligations, **and that is true under every option below.** No
licence choice here changes it, so it should not weigh on the decision.

### Candidates

| Licence | Patent grant | Trademark clause | Copyleft | Cost of adoption |
|---|---|---|---|---|
| **MIT** | None (implied at best) | None | None | Lowest. ~170 words, universally recognised |
| **Apache 2.0** | **Explicit** | **Explicit** | None | Low. Standard in institutional and government procurement |
| **BSD-3-Clause** | None | No-endorsement only | None | Low |
| **MPL 2.0** | Explicit | None | **File-level** | Moderate. Changes to project files must be published; proprietary additions alongside are permitted |
| **AGPLv3** | Explicit | None | **Strong, network-triggered** | High. Triggers legal review at most districts |

### The tension, stated plainly

**Permissive maximises how far this spreads. Copyleft maximises the chance that
what spreads stays repairable.** Both are consistent with the values in this
document, and they pull in opposite directions.

The case for permissive is the audience. Under-resourced school districts are
exactly the institutions least equipped to run a licence review, and a
volunteer or teacher forking this to fit their own programme should hit no
friction at all. An e-waste-to-classroom pipeline built by unpaid people dies
on paperwork.

The case for copyleft is that this project's whole thesis is anti-lock-in, and
a permissive licence permits someone to build a locked-in product on top of it.

**That case is weaker here than it first appears, for a structural reason.** A
closed fork does not remove the open original — a district can always take the
public recipe and get a working unit. The value being captured would be
assembly, testing, and support, which is the same honest model this project
already describes for its own prebuilt SKU. And a fork that closes the control
plane still cannot close Proxmox underneath it.

**The real exposure is not code capture. It is name confusion.** The claims
this project makes are safety claims — that lab traffic cannot reach the
district network, that no student PII is stored, that the unit is quiet on
someone else's wire. A fork that keeps the name, drops the isolation tests, and
ships to a school does damage that no code licence prevents, because the harm
is a false claim rather than an appropriation.

### Decided 2026-08-06: Apache 2.0

Permissive, so the adoption argument is satisfied in full, but with the two
provisions MIT lacks that this project specifically needs:

- **An explicit patent grant.** MIT is silent on patents. Apache 2.0 §3 grants
  one from every contributor and terminates it for anyone who initiates patent
  litigation over the work. For software deployed institutionally, by
  volunteers, in schools, that protection is worth having and costs adopters
  nothing.
- **An explicit trademark reservation.** Apache 2.0 §6 declines to grant
  trademark rights, which is the hook that lets a name mean something without
  restricting the code at all. Given that the exposure above is name confusion
  rather than code capture, this is the provision that addresses the actual
  risk.
- **It matches Guacamole**, already in the stack, which keeps the bundle's
  licence story short for anyone who has to read it.

Apache 2.0 is at least as acceptable as MIT in institutional procurement, and
arguably more so, precisely because it is explicit where MIT is silent. The
"MIT is simpler" advantage is real for an individual developer skimming a
README and close to irrelevant for a district.

**If the anti-lock-in guarantee should have legal teeth rather than only
architectural ones, MPL 2.0 is the serious alternative** — file-level copyleft
means improvements to *these* files flow back while a district's own
integrations and a vendor's separate additions stay theirs. `docs/roadmap.md`
already records a preference for MPL 2.0 over BUSL in the OpenTofu note, so it
is not a foreign choice here. The cost is a licence most school IT staff have
not seen before, against a risk that the reproducible-recipe principle already
substantially covers.

**AGPLv3 is rejected.** It would match Proxmox, and it is the strongest
possible anti-lock-in position, but it is the wrong instrument for playbooks
and scripts, and its review burden falls hardest on exactly the
under-resourced districts this project is for.

### Documentation is licensed separately, and it matters more than usual

For this project the documentation is arguably the primary artefact. A repair
guide that cannot be translated, localised for a district's own hardware mix,
or reposted on a school's internal wiki is not doing the job.

**Recommend CC BY-SA 4.0 for `docs/` and the public site**, dual-licensed
alongside the code licence. Share-alike keeps improved repair guides in the
commons, which is the same instinct iFixit follows, and attribution keeps the
provenance of a safety claim traceable. Note that iFixit's own guides add a
non-commercial clause; that is deliberately not recommended here, because it
would block a district's contracted IT vendor from using the guides in paid
work, which is a normal and desirable use.

### The name needs its own policy, whichever licence is chosen

A trademark policy is a separate document from a licence, and no licence
substitutes for one. The shape worth adopting: the name is free to use for the
unmodified recipe and for accurate description ("built on Cyberlab"), and is
not available for a fork that fails the project's own isolation and PII tests.
That ties the name to the verifiable claims rather than to control of the code,
which is consistent with everything else here.

**Applied.** `LICENSE` carries the Apache 2.0 text verbatim, including the
appendix. `NOTICE` asserts copyright, points at the AGPL obligations that
attach to distributing Proxmox regardless of this choice, and disclaims the
Proxmox trademark in the form `docs/roadmap.md` already settled on — "built on
Proxmox VE", no implication of endorsement.

Two consequences worth knowing rather than discovering:

- **Apache 2.0 §4(b) requires modified files to carry prominent notices of the
  change.** A fork is obliged to say what it altered, which is a mild but real
  assist to the name-confusion problem above — a fork that strips the isolation
  tests is supposed to say so.
- **Source file headers are not applied**, and are not required. The appendix
  boilerplate is conventional for Apache projects and would touch every script
  and playbook at once. Worth doing as a single mechanical pass at some point;
  the licence is fully effective without it.

---

## The command ledger

The panel and the logs answer two different questions, and conflating them
produces a dashboard that looks informative and settles no arguments.

| | Question | Surface |
|---|---|---|
| **Assertion** | Is this true *right now*? | Health checks, each with the evidence it read |
| **Ledger** | What happened, and can anyone deny it? | Append-only command history |

### What exists, and the one thing it lacks

`/var/log/cyberlab` already records every command a host-touching script runs
and its output, with a `-latest` symlink and a UTC-stamped file per run. What
it does not have is **integrity**: nothing distinguishes a transcript that was
written by the run from one edited afterwards.

The upgrade is small. **Hash-chain the transcript** — each entry carries the
hash of the entry before it, so an edit anywhere breaks the chain from that
point forward and the break is trivially detectable. No PKI, no key management,
no egress, no dependency a sealed unit cannot satisfy.

### Being honest about what this proves

A hash chain on a box whose operator has root is **tamper-evident, not
tamper-proof**. An operator who can rewrite the log can also recompute the
chain. Calling that non-repudiation would be over-claiming, and this repository
does not over-claim elsewhere.

**A cluster supplies the missing witness for free.** Each node periodically
exchanges its chain head with its peers over `vmbr1` and stores what it
receives. Tampering on one node then contradicts three copies held by machines
the tamperer did not touch, and detection requires no external infrastructure
and no internet — which is the only kind of mechanism this platform can
actually ship. That is a genuine non-repudiation story bounded by an honest
assumption: it holds unless every node is compromised at once.

### Why it earns its place

- **Repair.** "What did this box do, and when" is answerable by the person
  holding it, without the author.
- **The district conversation.** `docs/network-isolation.md` already plans to
  hand a sysadmin a packet capture — *everything this box emitted*. The ledger
  is the other half — *everything this box ran*. Both are readable by someone
  who has no reason to trust the vendor.
- **Disputes resolve on evidence**, including disputes with the author. A
  project about not depending on a vendor should not ask anyone to take the
  vendor's word for what happened.

---

## The admin panel

### It is the test suite pointed at the live box

`tests/` already reads the repository as data and asserts what must be true.
The panel runs the same *class* of assertion against a running unit and shows
the answer with its evidence. Not "CPU at 40%" but "is this true, and how do I
know?"

This is the repository's existing discipline — assert and read back, never
trust that applying a thing worked — made visible to someone who is not the
author. The four Phase 0 defects and the two structural ones recorded in
`docs/roadmap.md` were all of the form *a step that passed by doing nothing*.
The panel's job is to make that class of failure visible on a screen instead of
in a postmortem.

### Three tiers

| Tier | User | Contains |
|---|---|---|
| **1** | Teacher, during class | Sections, pods up/down, reset one student, print credential slips, one guided path for "a student cannot connect" |
| **2** | Operator or district tech | Assertions with state, evidence and remedy; the drop log; node headroom; one-button capture bundle |
| **3** | Anyone, when the panel is down | Every tier-1 and tier-2 action has a documented command-line equivalent |

### Three rules

**The panel is never the only way to do anything.** A management surface that
solely owns a capability is a new single point of failure, and it strands
people in exactly the situation where they need it most. Every action is a view
onto a documented command.

**Show the command.** Display the actual invocation next to the control that
runs it. It teaches the operator the system underneath, it makes a screenshot a
working fallback, and it keeps the panel honest about what it is doing to
someone's hardware.

**Evidence, not status.** A green check meaning "we ran the thing" is precisely
the false green that
`controller-validate-proxmox-api.yml` was rewritten to eliminate — it now
queries `/access/permissions` and asserts seven named privileges rather than
inferring health from `/version`. Every assertion carries what it read and
where it read it.

### Assertion catalogue

Each maps to an invariant this project already states somewhere. The panel is
mostly a rendering problem, not a new analysis problem.

| Assertion | Source of the requirement |
|---|---|
| Datacenter firewall is enabled | `docs/network-isolation.md` — guest rules are inert while it is off |
| Every lab NIC has `firewall=1` | Phase 5. A missing flag is silently unfiltered |
| No subnet carries `snat: true` at a site | Phase 2.5 and Phase 5. `prov0` must be absent while teaching |
| No lab guest has a NIC on `vmbr0` or `vmbr1` | `docs/network-isolation.md` guest invariants |
| `bridge_stp` is off on every bridge | Ranked item 7, cheap to assert |
| Cache answers on 3142 and nothing else on that host | Phase 5 isolation test item 4 |
| Guacamole reaches pods; pods do not reach Guacamole | The two carve-outs, stated as opposite directions |
| Automation role privileges match the validator's list | `docs/roadmap.md` — currently nothing enforces the agreement |
| Nothing under `private/` is tracked by git | `tests/test_no_student_pii.py`, already enforced in CI |
| Template catalogue and `data/slots.yml` agree | `tests/test_inventory_consistency.py`, already enforced in CI |
| Ledger chain is unbroken and peers agree on the head | This document |

Note that the last three already exist as tests. The panel should run the real
thing where one exists rather than reimplementing the check, so that CI and the
panel cannot drift into disagreeing about what is true.

### It is not the student portal

`docs/roadmap.md` decides that Phase 6 ships stock Guacamole and revisits a
custom student portal after Phase 8. That decision is unaffected. The student
surface stays stock; this is the operator surface, a different product for a
different person.

---

## Documentation posture

**Organise troubleshooting by symptom, not by subsystem.** Nobody arrives
thinking "I should inspect the SDN zone." They arrive with *"third block cannot
log in."* System-organised documentation is what an author naturally writes and
is close to useless under time pressure, which is the only condition under
which it gets read.

**Every procedure carries what a repair guide carries:** preconditions,
realistic time, what breaks if it goes wrong, whether it is reversible, what
access is required — and, playing to this repository's existing strength, **how
you know it worked.** A procedure without a verification step is the same
false-green failure the assertions above exist to catch.

### The author cannot test the documentation

This is a structural claim, not a modesty one. Knowing the system is
disqualifying: every gap gets filled silently from memory, and the filling is
invisible to the person doing it.

**So the pilot's exit criterion should include a person who is not the author
bringing a cluster up from bare hardware using only the written procedure,
while the author watches, takes notes, and does not help.** Every question
asked out loud is a documentation defect with a timestamp on it. It costs one
afternoon and it is the only test of this that exists.

`docs/roadmap.md` currently schedules the stranger-facing documentation in
Phase 7 (Feb-Mar 2027), immediately before the Phase 8 pilot. If repairability
is a core value rather than a deliverable, that is late: documentation written
after the fact is written by someone who has already forgotten what was
confusing. The build-path documentation in particular should be drafted as the
build path is automated, not after.

---

## Sourcing and the repair programme

**Stub.** This is public-facing site content rather than design, and it is
tracked here only so the technical half has one home.

The technical selection criteria already exist in `docs/roadmap.md` under Phase
3: the procurement-time coarse filter (core count floor, actually-reachable RAM
ceiling, a real NVMe slot, virtualisation extensions), the
hardware-generation table with its reasoning about DDR4 refurb supply against
DDR5 pricing, and the named node candidates. That material is what a school
sourcing its own hardware needs, and it should be lifted to the site largely
as written.

What belongs on the site and not in this repository:

- How to start a school repair programme that feeds the hardware pipeline
- How to solicit community e-waste, and what to refuse
- What to check on an incoming donated unit before counting it as a node
- Data destruction on donated drives, before anything else happens to them
- The pedagogical case a teacher makes to an administrator

Written once there is a second site to learn from. Writing it from a single
programme would produce advice that is really just a description.

---

## Open questions

- **The documentation licence is still open.** The code licence is settled at
  Apache 2.0, and `LICENSE` at the repository root currently covers `docs/`
  along with everything else. Adopting CC BY-SA 4.0 for documentation, as
  recommended above, would be a dual-licence addition rather than a change —
  nothing about it is foreclosed by the Apache decision. Decide before the
  public site exists, because that is where the distinction starts to matter.
- **Whether the copyright holder stays an individual.** `NOTICE` names a
  person. If an entity is formed to sell prebuilt units, that line and the
  trademark policy below should be revisited together.
- **Whether the trademark policy ships at v1** or waits for a second
  deployment. Arguably it only matters once a fork exists, but it is much
  easier to state before there is a specific fork to appear to be aimed at.
- **Ledger retention.** `docs/roadmap.md` already defers a `logrotate` policy to
  Phase 7 packaging. A hash chain complicates rotation: rotating away the early
  entries removes the chain's root. Decide whether rotation seals and archives a
  segment, or whether the chain is per-boot.
- **Whether the panel ships in Phase 6 with Guacamole, or in Phase 7 with
  packaging.** It is closer to packaging in purpose and closer to the control
  plane in implementation.
- **What a sealed unit does when its owner later wants a factory.** The
  capability is not removed by anything except the absence of egress, so the
  answer is probably "plug it in and re-run the recipe" — but it should be
  written down and tested rather than assumed.
