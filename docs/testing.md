# Cyberlab Testing Plan

This document defines how Cyberlab changes are validated.

The project currently supports three levels of validation:

1. static checks
2. Ansible syntax checks
3. live Proxmox runtime checks

A change is not considered fully validated until the relevant live runtime checks pass on a Proxmox host.

---

## Validation levels

### Level 1: Static checks

Static checks verify that shell scripts and YAML files are syntactically valid,
that the linters are satisfied, and that the repository's internal invariants
still hold.

These checks run from a normal development laptop, and are exactly what CI runs
on every push and pull request (`.github/workflows/ci.yml`).

Set up once:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/ansible-galaxy collection install -r ansible/requirements.yml
```

Then run the full set:

```bash
.venv/bin/yamllint ansible/ data/ .github/
.venv/bin/ansible-lint --offline ansible/
.venv/bin/ruff check scripts/ tests/
shellcheck --severity=warning scripts/*.sh
.venv/bin/python -m pytest tests/
```

Installing the `community.proxmox` collection is not optional for
`ansible-lint`: without it, `--syntax-check` cannot resolve the
`module_defaults` group and every playbook using the collection reports
`internal-error` instead of being checked.

`tests/` reads the repository as data — it never contacts Proxmox. It covers
what parse-level checks structurally cannot:

- each of the four Phase 0 defects, so reintroducing one turns CI red
- playbooks targeting a group or host absent from `inventory.yml` (a playbook
  aimed at a nonexistent group runs zero tasks and **exits successfully**)
- `vars_files` and `import_playbook` paths that do not resolve
- agreement between `automation_role_privs` in `host-bootstrap.yml` and
  `required_proxmox_privs` in `controller-validate-proxmox-api.yml`, which are
  independent declarations that must match
- slots in `data/slots.yml` naming templates absent from the catalog

Static checks do not prove that Proxmox operations work.

---

### Level 2: Ansible syntax checks

Ansible syntax checks verify that playbooks parse correctly.

Examples:

```bash
cd ansible
ansible-playbook --syntax-check -i inventory.yml playbooks/host-bootstrap.yml
ansible-playbook --syntax-check -i inventory.yml playbooks/controller-build-template-pipeline.yml -e template_name=debian13
ansible-playbook --syntax-check -i inventory.yml playbooks/controller-validate-template-clone.yml -e template_name=debian13
cd ..
```

Syntax checks do not prove that Proxmox API calls, `qm`, `pct`, SDN, DHCP, or guest-agent behavior work at runtime.

---

### Level 3: Live Proxmox runtime checks

Live runtime checks must be run on a real Proxmox host.

These checks prove that automation works against the actual platform.

Runtime validation includes:

- host bootstrap
- controller bootstrap
- controller networking
- DNS resolution inside CT `800`
- Proxmox API access
- SSH trust from controller to host
- SDN bootstrap
- template preparation
- template finalization
- template promotion
- validation clone creation
- validation clone boot
- validation clone network behavior

---

## Current tested checkpoint

The current known-good runtime checkpoint is:

```text
milestone/debian13-template-promoted
```

**Caveat on the artifact, not the checkpoint.** The template VM that milestone
produced was found on 2026-08-05 to have no `qemu-guest-agent` installed, and
was rebuilt. The checkpoint still describes what the code proved when it ran;
it does not mean the VM sitting on the host was ever fully valid. See the
template pipeline run below.

That checkpoint proves:

- host bootstrap works
- controller CT `800` bootstrap works
- controller network preflight works
- controller DNS injection works
- Proxmox API token handoff works
- token rotation behavior works
- controller SSH trust works
- SDN bootstrap works
- provisioning VNet `prov0` exists
- Debian 13 template promotion works

### Live run: 2026-08-05, `pve1`

Run from CT `800` at `25c3a0c`, against `pve1` (Proxmox 9.1.9). This is a
record of what was actually exercised, not a new checkpoint — the Phase 0 exit
criterion was not attempted.

Confirmed working:

- controller → host connectivity, both `localhost` and `pve1` (`ansible -m ping`)
- `--syntax-check` on `host-bootstrap.yml`, `controller-bootstrap-sdn.yml`,
  `controller-validate-template-clone.yml` and
  `controller-build-template-pipeline.yml`
- `controller-bootstrap-sdn.yml` end to end against live SDN, `failed=0`
- the dnsmasq zone-service assertion added in `25c3a0c`

**The dnsmasq defect was real, and the host's journal proves it.** `pve1`
recorded `dnsmasq@virtnet` failing at 14:03:46 with `failed to create listening
socket for 10.0.12.1: Address already in use` — the exact symptom the fix
describes — and entering `active` at 14:05:44 once the stock `dnsmasq.service`
was disabled by hand. At that point one `dnsmasq@virtnet` process held `:53` on
all seven VNet gateway addresses and `:67` for DHCP.

**What this run did and did not prove.** The host was already in the remediated
state before the playbook ran, so the new assertion was observed passing on a
healthy host. Its failure path — the message a future operator actually reads
when the stock service is holding `:53` — was never exercised. Likewise
`host-bootstrap.yml`'s disable task ran against a service that was already
disabled, so only its idempotent case is proven. Both want a run on a host
where the defect is present.

**Re-running `controller-bootstrap-sdn.yml` reports `changed=3` on an
unchanged host.** The three are `Reconcile settings on existing subnets`,
`Apply SDN configuration` and `Reload networking`. All three are `command`
tasks with `changed_when: <rc> == 0`, so they report changed whenever they
succeed. This is cosmetic rather than drift, but it is exactly the class of
task the deferred `no-changed-when` lint rule targets — the apply and reload
are arguably correct as written, the subnet reconcile is worth a second look.
See the lint retirements in `docs/roadmap.md`.

Not exercised: the validation clone plan and full pipeline below. The session
turned to teardown before they were run.

**The section-VNet results are historical.** All SDN was removed from both
hosts later the same day. `prov0` was restored on `pve1` shortly after (see
below); the four section VNets were not and do not exist. The checkpoint above
still describes what the code proved when it ran.

### Phase 0 installer runs: 2026-08-05, `pve1`

Six `install-cyberlab.sh` runs, all with `--skip-sdn-bootstrap` so the
installer would not rebuild the SDN that had just been deleted. Before the
first run, stale SDN residue was cleared from the host: the
`interfaces.d/sdn` stub, `pve-ipam-state.json` (which still held five ghost
zones — `ITSec`, `CSec`, `virtnet`, `testnet`, `test` — long after their
configs were gone), `mac-cache.json`, and five orphaned `dnsmasq.*.leases`
files. `vmbr0` and the physical NICs were not touched.

| Run | Change | `host-bootstrap` | CT `800` |
|---|---|---|---|
| 1 | baseline | `changed=13` | bounced |
| 2 | baseline | `changed=12` | bounced |
| 3 | after `9e463b0` | `changed=8` | stayed up |
| 4 | after `9e463b0` | `changed=8` | stayed up |
| 5 | after `ab9762c` | `changed=2` | stayed up |
| 6 | after `ab9762c` | `changed=2` | stayed up |
| 7 | after `031629f`, no skip flags | `changed=2` | stayed up |

Every run exited zero and reported `failed=0`; API validation was
`changed=0` throughout, ending `Automation token holds all 7 required
privileges at '/'`.

Run 7 is the first with **no flags at all**. Once
`cyberlab_sdn_build_sections` defaulted to false (`031629f`), the SDN stage
became safe to leave enabled: it rebuilt the zone and `prov0` and did not
touch the classroom networks. `--skip-sdn-bootstrap` is no longer needed for
routine runs. Its SDN stage reported `changed=3` — the three known
always-changed command tasks.

**Exit zero twice would have hidden all three defects.** The signal was
`changed` on a second run against an unchanged host, which is the useful
reading of "clean" in the exit criterion — not the exit status. Runs 1 and 2
exited zero while stopping and restarting the controller, moving its address
from `10.64.62.127` to `10.64.62.74`, and re-running `apt-get install` inside
it. A criterion phrased only as "runs succeed" would have been satisfied by
that.

The remaining `changed=2` is `Reconcile the Cyberlab automation role
privileges` and `Grant the automation user its role at the root path`. Both
are `pveum` calls that write rather than compare, kept deliberately as a
reconcile pattern.

**Not proven: the wiped-host condition.** These ran against a host that kept
CT `800`, the automation user, the pools and the legacy template VMs
(`9001`–`9004`). Controller creation and the Debian 13 template-volume
discovery were therefore skipped as already-satisfied rather than exercised.
Phase 0 is met in substance and its gate stays open.

### `prov0` restore: 2026-08-05, `pve1`

`controller-bootstrap-sdn.yml` run from CT `800` at `031629f`, rebuilding the
provisioning network after the teardown. Confirmed:

- exactly one VNet, `prov0`, in zone `virtnet`
- subnet `10.30.0.0/24`, gateway `10.30.0.1`, `snat 1`, DHCP `.100`–`.199` —
  byte-identical to the pre-teardown capture
- `prov0` interface up holding `10.30.0.1/24`
- `dnsmasq@virtnet` active, bound to `10.30.0.1:53` with DHCP on `:67`
- stock `dnsmasq.service` still `disabled`, so the defect fixed in `25c3a0c`
  did not return when the zone came back
- `net.ipv4.ip_forward=1`, persisted in
  `/etc/sysctl.d/99-cyberlab-forwarding.conf`
- `vmbr0` and the default route unchanged

**The negative check is the one that matters here** and is easy to skip: zero
`t101c*` interfaces and zero `vnet0`/`vnet1`. A run that quietly rebuilt the
classroom topology would otherwise look identical in every positive check
above. A second run reported `changed=3` — the three known always-changed
command tasks — and still exactly one VNet.

The gating expressions were checked against both settings before the playbook
touched the host, confirming `all_vnets` resolves to `[prov0]` with sections
off and to all five with them on, while `declared_vnets` stays at five either
way so the name assertions keep covering section VNets.

### Template pipeline first live run: 2026-08-05, `pve1`

The validation clone and the staged pipeline had never executed against live
Proxmox. Both ran at `031629f`, once `prov0` was back.

**Run 1 — validation clone alone, against the existing template 900: FAILED,
and correctly.** `ok=20 changed=4 failed=1`, stopping at:

```text
Template 'tpl-debian13-base' expects the QEMU guest agent, but validation
clone 950 did not respond to guest-agent ping.
```

Everything around the agent worked. The clone took a DHCP lease from `prov0`
(`10.30.0.100`), answered a ping from the host with 0% loss, accepted SSH, and
reached the internet through `prov0`'s SNAT — `curl http://deb.debian.org/`
returned 200 and `apt-get update` succeeded. The failure was the agent alone:
`dpkg-query` found no `qemu-guest-agent` package in the guest, though the
hypervisor side was correct (`agent: 1`, and
`/dev/virtio-ports/org.qemu.guest_agent.0` present).

**The template was stale, not the playbook.** Template 900's disk was created
2026-05-07. The commit that made `prov0` egress work, `5dd0092`, landed
2026-05-10 — three days later. `controller-finalize-template-vm.yml` does
install `qemu-guest-agent`, but when that template was built the VM could not
reach the package repositories. It was promoted anyway, tagged
`milestone/debian13-template-promoted`, and carried `agent: 1` while being
incapable of ever passing validation.

**This is the validation gate doing exactly what it exists for**, on its first
live execution: refusing a template that cannot meet its own declared
contract. It had simply never been run against the artifact it was meant to
judge.

**Run 2 — full pipeline rebuild: PASSED.** Template 900 was backed up
(`vzdump`, 346 MB, to USB) and destroyed, since
`controller-prepare-template-vm.yml` deliberately refuses to prepare over a
promoted template and offers no override. Then
`controller-build-template-pipeline.yml -e template_name=debian13` ran
`prepare → finalize → promote → validate` end to end:

```text
pve1 : ok=100  changed=21  unreachable=0  failed=0  skipped=9
validation_passed=true
validation_clone_ipv4=10.30.0.100
```

The rebuilt template has a working guest agent — the clone answered
`qm agent ping` and `systemctl is-active qemu-guest-agent` reported `active` —
and is NIC-less as convention requires, with the NIC stripped at promotion.

**Phase 2's remaining exit criterion is the negative test:** a deliberately
broken image must fail validation. Run 1 is suggestive but not that test — it
was an accidental failure, not a planted one.

### Known gap: nothing verifies the agent before promotion

`controller-finalize-template-vm.yml` runs `systemctl enable qemu-guest-agent
|| true`, and `controller-promote-template.yml` checks nothing about the guest.
A template whose package install silently failed can still be promoted, and the
first sign of trouble arrives later at the validation gate — which is what
happened here across a three-month gap. A check at the end of finalize, before
promotion, would catch it at the point of failure instead.

---

## Current syntax-checked but not live-tested work

The following work has passed static and Ansible syntax checks but still requires live Proxmox validation:

- the deliberately-broken-image negative test (Phase 2 exit)
- `controller-build-template-pipeline.yml` for templates other than
  `debian13` — `ubuntu2604`, `parrot`, `win7`, `metasploitable2`. The Windows
  and Metasploitable entries set `agent_enabled: false`, so they exercise a
  different validation path than the one now proven.

This means the playbooks parse correctly, but live behavior is not yet proven.

---

## Live test plan: Debian 13 validation clone

Run from inside CT `800`:

```bash
cd /root/cyberlab-infra/ansible
ansible-playbook -i inventory.yml playbooks/controller-validate-template-clone.yml -e template_name=debian13
```

Expected behavior:

- source template `900` exists
- source template `900` is marked as a Proxmox template
- disposable validation clone `950` is created
- validation clone `950` starts
- validation clone reaches running state
- QEMU guest agent responds if expected
- non-loopback IPv4 address is detected if guest agent is expected
- Proxmox host can ping the validation clone IPv4

Expected source and clone:

```text
900 -> tpl-debian13-base
950 -> debian13-validation
```

---

## Live test plan: full Debian 13 pipeline

Run from inside CT `800`:

```bash
cd /root/cyberlab-infra/ansible
ansible-playbook -i inventory.yml playbooks/controller-build-template-pipeline.yml -e template_name=debian13
```

Expected pipeline:

```text
prepare -> finalize -> promote -> validate clone
```

Expected final state:

- VMID `900` is a promoted Debian 13 golden template
- VMID `950` is a disposable validation clone
- validation clone has booted and passed checks

---

## Validation clone cleanup

If validation clone `950` needs to be removed:

```bash
qm stop 950 || true
qm destroy 950 --purge
```

Validation clones are disposable.

Never treat a validation clone as a source template.

---

## Drift checks

Run this to detect old lifecycle vocabulary or obsolete template-builder paths:

```bash
git grep -nE "candidate|approved|890|9001|9002|9003|9004|data/templates.yml|template_catalog|template_env|proxmox-build-templates|build-imported-templates|create-installer-template-vms"
```

Expected output:

```text
# no output
```

Run this to confirm the current lifecycle vocabulary is present:

```bash
git grep -nE "golden template|validation clone|900-949|950-999|ansible/vars/templates.yml|controller-validate-template-clone"
```

Expected hits should include:

- `README.md`
- `docs/platform-pipeline.md`
- `docs/template-lifecycle.md`
- `docs/recovery.md`
- `docs/testing.md`
- `data/bootstrap-policy.yml`
- `ansible/vars/templates.yml`
- `ansible/playbooks/controller-build-template-pipeline.yml`
- `ansible/playbooks/controller-validate-template-clone.yml`

---

## Tagging policy

Do not tag validation clone automation as a milestone until it has passed live Proxmox runtime testing.

The next intended runtime milestone is:

```text
milestone/debian13-template-validated
```

Use that tag only after Debian 13 promotion and validation clone checks pass on real Proxmox hardware.
