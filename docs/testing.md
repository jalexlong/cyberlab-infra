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
- the isolation firewall's rule *shape* (`tests/test_firewall_policy.py`): that
  port 53 stays out of the `lab-guest` group, that the package cache carve-out
  names a port and not just a host, that `host.fw` accepts inbound DHCP above
  the lab-subnet DROP, that `host.fw` is written before `cluster.fw`, and that
  a derived teacher `/16` can never cover `prov0` or `svc0`

Static checks do not prove that Proxmox operations work.

**A caveat that cost real time, worth knowing before writing more of these.**
`--syntax-check` and `ansible-lint` both pass a playbook whose Jinja is
silently wrong, because neither evaluates it. A `regex_replace` backreference
written `'\1'` substitutes correctly through a direct filter call and comes
back as the uninterpreted text `\1` through `map()` — and `regex_replace`
returns a string either way, so the firewall file is still written, just with
garbage in it. Where a derivation matters, exercise it: build a throwaway
playbook that feeds the real expression realistic fixtures and asserts the
result. That is how the two `\1` defects in the firewall playbooks were caught
before they reached a host.

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
- network isolation, in two tiers (below)

#### Isolation checks

`controller-assert-isolation.yml` is the only check here that is safe to run
against a production host at any time — tier 1 is read-only:

```bash
cd ansible
ansible-playbook -i inventory.yml playbooks/controller-assert-isolation.yml
```

That asserts configuration only: the firewall enabled and running on the legacy
backend, both datacenter policies `DROP`, the `lab-guest` group present with a
port-scoped cache carve-out and no port 53, one host DROP per teacher `/16`,
inbound DHCP ordered above it, and — per lab guest — `firewall=1` on the NIC,
a matching `<vmid>.fw` on disk, and permission for its own section subnet and
no other.

Since 2026-08-18 it also asserts the half of the cache carve-out that lives
outside the firewall: `cyberlab-cache-routes.service` active, `apt-cacher-ng`
bound on the svc0 address rather than loopback, and a return route present for
every section. That was added because permitting the carve-out and the carve-out
working came apart across a reboot — see `docs/network-isolation.md`.

Tier 2 sends real packets from inside a guest and needs a running lab guest
with the QEMU guest agent plus a second guest in the same section. **Start them
first** — `950` and `955` carry no `onboot`, so every host reboot leaves them
stopped, and each needs roughly a minute to take a DHCP lease before the probe
will work:

```bash
ansible-playbook -i inventory.yml playbooks/controller-assert-isolation.yml \
  -e cyberlab_probe_vmid=950 -e cyberlab_probe_peer_ip=10.101.11.101
```

**Tier 1 passing is not the same claim as tier 2 passing.** Configuration and
enforcement came apart on 2026-08-07 and that is the reason both exist. The
same-section peer is the control, and it must be guest-to-guest: the section
gateway is the host, which the lab-subnet DROP blocks deliberately, so using
the gateway reports a broken firewall when the firewall is correct.

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

**Phase 2's negative test was then run deliberately — see below.** Run 1 above
is suggestive but is not that test: it was an accidental failure, not a planted
one.

### Phase 2 negative test: a broken image must fail validation

Run 2026-08-05 on `pve1`. The fixture is not synthetic. The stale template of
2026-05-07 — the real one, with no `qemu-guest-agent` — was kept as a `vzdump`
and restored as VMID `900` on purpose.

That makes it a better test than damaging a good image would be, because it is
the exact shape a bad build actually takes: `qmrestore` preserves the template
flag, so the fixture comes back with `template: 1`, `agent: 1`, and no NIC. It
is correct in every way a configuration check can see, and wrong only inside
the guest.

| | Result |
|---|---|
| Broken image | `ok=20 changed=4 failed=1`, exit 2 |
| Good image (control) | `ok=26 changed=4 failed=0`, exit 0, `validation_passed=true` |

Same playbook, same host, same `prov0` — only the image differed. **The control
is the half that makes this meaningful**: a gate that fails everything would
have produced the first line and taught nothing.

Failure was at the guest agent:

```text
Template 'tpl-debian13-base' expects the QEMU guest agent, but validation
clone 950 did not respond to guest-agent ping.
```

**Reproducing it.** Both `vzdump` archives live on the `pve1` USB stick and are
distinguished only by timestamp, so its `README.txt` labels which is which:

```text
vzdump-qemu-900-2026_08_05-11_25_42.vma.zst   BROKEN — the negative-test fixture
vzdump-qemu-900-2026_08_05-12_28_35.vma.zst   GOOD   — restore this one
```

Restore the broken one as `900`, run
`controller-validate-template-clone.yml -e template_name=debian13`, confirm it
fails, then restore the good one and confirm it passes. Running only the first
half proves less than it appears to.

**What this does not cover.** Only the guest-agent assertion has been driven to
failure. The non-loopback IPv4 requirement and the host-to-clone ping have only
ever been observed passing. An image that boots with a working agent but no
usable address would exercise those, and has not been tried.

### Closed: promotion is now gated on a working guest agent (`a835073`)

The gap above is fixed. `controller-finalize-template-vm.yml` verifies over SSH
that `qemu-guest-agent` is installed and enabled, and refuses to continue
otherwise; the `|| true` that swallowed the enable failure is gone.

That check lives at the end of finalize because it is the last point the guest
can be inspected. `controller-promote-template.yml` cannot examine a stopped
guest and must not boot one to try — finalize truncates `/etc/machine-id` and
removes the SSH host keys as its final act, so booting would regenerate them
into every clone. Promote instead guards the path that skips finalize: a VM
still running has its agent pinged, and the `agent:` flag in its config must
match the catalog.

**Both directions were tested on `pve1`, because a gate that has only ever
passed is not proven — which is the whole lesson of the run above.**

Negative — VM `900` prepared but not finalized, left running with no agent:

```text
Require a responding guest agent before promoting a running VM
fatal: [pve1]: FAILED!
pve1 : ok=8  changed=0  failed=1
```

Afterwards `qm config 900` still had no `template:` line: promotion was
blocked, and nothing was half-applied on the way out.

Positive — full pipeline on the same VM:

```text
Require the guest agent before the template can be promoted
  msg: qemu-guest-agent is installed and enabled in tpl-debian13-base.
pve1 : ok=101  changed=14  failed=0
validation_passed=true
```

In that passing run promote's running-VM ping **skipped**, because finalize had
already stopped the guest. That is the expected path and the reason the
finalize check is the authoritative one rather than a convenience.

---

### Firewall applied from the repository: 2026-08-18/19, `pve1`

The first run of `controller-bootstrap-firewall.yml` outside check mode, and
the runs around it. Recorded because three separate things were learned from a
sequence that was expected to be uneventful.

**The apply itself was uneventful, and that was earned.** Two `--check --diff`
runs (2026-08-10, 2026-08-18) had established that the generated set differed
from the hand-placed one only in comments plus one unreferenced alias, and that
both guests already carried `firewall=1` so no NIC would be touched. It applied
cleanly and `controller-assert-isolation.yml` passed both tiers afterwards.

**The host had no internet, and the firewall had taken it.** `policy_out: DROP`
is inherited by the host, and `host.fw` carried no `OUT` rule but DHCP, so from
2026-08-07 `pve1` could not resolve a name, reach an apt mirror, clone from
GitHub, or ping `1.1.1.1`. Eleven days, unnoticed, because inbound SSH is
unaffected and CT `800` sits unfiltered on the bridge. Fixed by uplink-scoped
host egress rules; verified afterwards that pods still get `blocked` on both
internet probe rows, so the fix took nothing from lab isolation.

**The package cache broke across two reboots.** First the route unit and
`apt-cacher-ng` both lost a race with `ifupdown`; then, a day later, the same
failure recurred because the repair had been applied to the live container only
in part — the drop-in was written by hand, the route unit merely restarted.
Running the playbook is what made it stick. Two things generalise:

- **Only tier 2 caught the original failure.** Tier 1 read rule text, the
  container was `running`, and `systemctl is-active` said `active` while
  `apt-cacher-ng` served nobody. Tier 1 now checks the binding, so the next
  occurrence is caught without a live guest.
- **A `systemctl start` is not a fix.** It restores a service and changes
  nothing about the next boot.

~~**Still owed:** the corrected `cyberlab-cache-routes.service` has never
booted.~~ **Settled 2026-08-19 — see the cold boot below.**

---

### Cold boot on untouched state: 2026-08-19, `pve1`

The test the two previous entries kept deferring. `pve1` was rebooted
deliberately at 13:21 CDT and answered again about three and a half minutes
later. **Nothing was touched by hand after the reboot** before the checks ran,
which is the whole point of the run — every previous green result on this host
followed a session that had just finished adjusting it.

Checked in the handoff's order, cache first because it was the least proven:

| Check | Expected | Observed |
| --- | --- | --- |
| `cyberlab-cache-routes.service` | `active` | `active` |
| classroom routes in CT `801` | 4 | 4 |
| `apt-cacher-ng` bind | `10.31.0.10:3142` | `10.31.0.10`, `10.30.0.20`, `127.0.0.1` |
| host name resolution | resolves | `github.com` → `140.82.114.3` |
| host ICMP egress | replies | `1.1.1.1`, 0% loss, ~13ms |
| `chrony` | one source, Stratum 4 | `time.cloudflare.com`, Stratum 4, Leap Normal |
| isolation tier 1 | PASS | PASS |
| isolation tier 2 | 17/17 incl. control | 17/17 incl. control |

**The route unit booted correctly for the first time**, and the container's
journal shows precisely why (stamps are UTC; 18:24 UTC is the 13:24 CDT boot):

    18:24:39.013951  Finished networking.service
    18:24:39.018061  Starting cyberlab-cache-routes.service
    18:24:39.194157  Finished cyberlab-cache-routes.service
    18:24:39.198149  Starting apt-cacher-ng.service

Against the 2026-08-17 failure, where the unit started 1.3s *before*
`networking.service` finished and `ip` reported `Nexthop has invalid gateway`,
it now starts 4ms *after* it finishes. `apt-cacher-ng` is ordered behind the
routes and bound its `svc0` address rather than falling back to loopback, so
neither of the two 08-17 casualties recurred. `After=network-online.target`
alone was the bug; ordering on the unit that actually configures the interface
is the fix, and this is the first evidence of it under real boot conditions.

**Tier 2 recorded `package cache 10.31.0.10:3142 reachable` from inside guest
`950`** — the cache proven from the consumer's vantage point after a cold boot,
not from the host, which cannot open that connection at all once `policy_out:
DROP` applies.

Guests `950`/`955` were started by hand, as expected: neither carries `onboot`.
`955` took `10.101.11.101` within about 90 seconds, as documented.

**What this run does and does not establish.** It establishes that the firewall,
the host's egress, the pinned time source and the cache all come back on their
own, from repository-written configuration, with no operator present. It does
**not** establish the restated Phase 2.5 criterion, which asks for a lab guest
completing a full install through the cache after a cold boot. The path is now
proven; the package volume has not been pushed down it.

**One process note.** The first attempt to wait for the host to return matched
immediately and reported `up 22 hours` — SSH answered 15 seconds after `systemctl
reboot` was issued, because the host had not gone down yet. A liveness check that
only asks "does it answer" cannot distinguish "back" from "not yet gone." The
second attempt required `/proc/uptime` below a threshold, which is what actually
proves a fresh boot.

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
