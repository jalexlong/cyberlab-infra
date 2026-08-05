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

**These SDN results are now historical.** All SDN was removed from both hosts
later the same day, so `prov0` and the section VNets no longer exist. The
checkpoint above still describes what the code proved when it ran.

---

## Current syntax-checked but not live-tested work

The following work has passed static and Ansible syntax checks but still requires live Proxmox validation:

- validation clone automation
- `controller-validate-template-clone.yml`
- updated `controller-build-template-pipeline.yml` stage:
  - prepare
  - finalize
  - promote
  - validate clone

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
