# Cyberlab Recovery Guide

This guide covers common partial-failure states during Cyberlab bootstrap, controller setup, SDN creation, and template promotion.

The goal is to recover safely without guessing, deleting the wrong resource, or corrupting a known-good template.

---

## General recovery rules

- Stop at the failed phase.
- Do not continue scaling after a failed validation.
- Prefer inspection before deletion.
- Do not delete secrets unless intentionally rotating them.
- Do not deploy classroom workloads from an unvalidated golden template.
- Re-run the smallest safe phase after correcting the issue.

---

## CT 800 exists but has no network

Symptoms:

- CT `800` starts but cannot reach the network.
- `apt-get update` fails inside the controller.
- DNS or default route checks fail during bootstrap.

Inspect from the Proxmox host:

```bash
pct status 800
pct config 800
pct exec 800 -- ip addr
pct exec 800 -- ip route
pct exec 800 -- cat /etc/resolv.conf
```

Likely causes:

- wrong bridge
- missing VLAN tag
- dead/default PVID network
- unusable DNS injected into the CT
- DHCP unavailable on the selected network

Recovery:

1. Confirm the intended management bridge and VLAN.
2. Re-run controller network detection or provide explicit overrides.
3. Re-run the installer without deleting unrelated platform state.

Useful overrides:

```bash
CYBERLAB_CONTROLLER_BRIDGE=vmbr0
CYBERLAB_CONTROLLER_VLAN=<vlan-id>
CYBERLAB_CONTROLLER_DNS="10.64.32.29 10.64.32.31 10.64.32.32"
```

Home-lab note:

If Proxmox is connected to a trunk port, untagged CT traffic may land on a dead or jail VLAN. Set `CYBERLAB_CONTROLLER_VLAN` explicitly.

School-lab note:

Do not fall back to public DNS. Use approved school DNS servers.

---

## CT 800 DNS failure

Symptoms:

- CT has an IP address and default route.
- `ping` to an IP works.
- name resolution fails.
- `apt-get update` fails with resolver errors.

Inspect:

```bash
pct exec 800 -- cat /etc/resolv.conf
pct exec 800 -- getent hosts deb.debian.org
pct exec 800 -- resolvectl status || true
```

Likely causes:

- loopback DNS copied from the host
- school network blocking public DNS
- invalid DNS server selected
- stale generated controller network vars

Recovery:

1. Set explicit DNS with `CYBERLAB_CONTROLLER_DNS`.
2. Re-run the installer network/bootstrap phase.
3. Confirm DNS inside CT `800`.

School DNS defaults:

```text
10.64.32.29
10.64.32.31
10.64.32.32
```

Avoid using `10.64.32.30` unless it has been confirmed valid.

---

## Wrong controller VLAN detected

Symptoms:

- CT `800` starts.
- CT has no DHCP lease.
- Host networking works.
- CT networking fails only from inside the container.

Inspect:

```bash
ip route
bridge vlan show
pct config 800
```

Recovery:

Use an explicit VLAN override:

```bash
CYBERLAB_CONTROLLER_VLAN=<vlan-id>
```

If no VLAN tag is intended, use:

```bash
CYBERLAB_CONTROLLER_VLAN=none
```

Then re-run the installer.

---

## API token exists but controller secret is missing

Symptoms:

- Proxmox token exists.
- Controller cannot authenticate to the Proxmox API.
- Secret file is missing inside CT `800`.

Expected behavior:

The host bootstrap should rotate the API token when the token exists but the controller secret is missing.

Recovery:

Run the installer with explicit token rotation:

```bash
./scripts/install-cyberlab.sh --rotate-api-token
```

Then validate API access from the controller.

Security note:

If a token secret was ever committed or exposed, treat it as compromised and rotate it.

---

## `prov0` already exists

Symptoms:

- SDN bootstrap reports that `prov0` already exists.
- Installer fails while creating SDN objects.

Inspect:

```bash
pvesh get /cluster/sdn/zones
pvesh get /cluster/sdn/vnets
pvesh get /cluster/sdn/subnets
cat /etc/pve/sdn/zones.cfg
cat /etc/pve/sdn/vnets.cfg
cat /etc/pve/sdn/subnets.cfg
```

Recovery:

If the existing SDN objects match Cyberlab policy, prefer idempotent re-apply rather than deletion.

Expected provisioning network:

```text
zone: virtnet
vnet: prov0
subnet: 10.30.0.0/24
gateway: 10.30.0.1
```

If the existing objects are wrong, remove only the incorrect Cyberlab SDN objects after confirming they are not in use.

---

## Debian 13 template VM exists but promotion failed

Symptoms:

- VMID `900` exists.
- It may or may not be marked as a template.
- The promotion playbook failed partway through.

Inspect:

```bash
qm status 900
qm config 900
```

Check whether VMID `900` is already a template:

```bash
qm config 900 | grep -i template || true
```

Recovery:

If VMID `900` is a good finalized Debian 13 VM but not a template, re-run promotion:

```bash
cd /root/cyberlab-infra/ansible
ansible-playbook -i inventory.yml playbooks/controller-promote-template.yml -e template_name=debian13
```

If VMID `900` is broken or partially configured, remove it only after confirming no classroom workloads depend on it.

---

## Validation clone exists and needs cleanup

Symptoms:

- VMID `950` exists.
- Validation clone blocks a new validation run.
- Clone is stale from a previous test.

Inspect:

```bash
qm status 950
qm config 950
```

Recovery:

If the clone is disposable and not needed:

```bash
qm stop 950 || true
qm destroy 950 --purge
```

Then re-run validation.

Never treat a validation clone as a source template.

---

## Final recovery checklist

After recovery, validate controller networking:

```bash
pct exec 800 -- ip addr
pct exec 800 -- ip route
pct exec 800 -- getent hosts deb.debian.org
pct exec 800 -- apt-get update
```

Then validate platform state:

```bash
pvesh get /cluster/sdn/zones
pvesh get /cluster/sdn/vnets
qm config 900
```

Only continue to classroom deployment after the failed phase passes validation.
