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

Static checks verify that shell scripts and YAML files are syntactically valid.

These checks can be run from a normal development laptop.

Examples:

```bash
bash -n scripts/*.sh
```

```bash
python3 - <<'PY'
import yaml
from pathlib import Path

paths = [
    *Path("ansible/vars").glob("*.yml"),
    *Path("data").glob("*.yml"),
]

for path in paths:
    with path.open() as f:
        yaml.safe_load(f)
    print(f"ok: {path}")
PY
```

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
