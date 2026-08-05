# Bootstrap Checklist

This checklist defines the minimum steps and validation points required to turn a fresh Proxmox VE install into a Cyberlab-ready platform host and automation controller.

It is intentionally practical. It should be usable during:
- first-time installation
- rebuilds
- migration to new hardware
- troubleshooting failed bootstrap runs

---

## Goal

At the end of this checklist, you should have:

- a working Proxmox VE host
- a dedicated Cyberlab automation identity and API token
- a dedicated automation controller LXC
- the Cyberlab repo cloned into the controller
- Ansible available in the controller
- environment selection working
- the platform ready for SDN, templates, and deployment phases

---

## Required Inputs

Before beginning, have these ready:

### Host information
- Proxmox host IP or hostname
- Proxmox node name
- management bridge name
- storage target names

### Access
- bootstrap administrative login to Proxmox host
- SSH keypair for the operator or automation controller
- ability to SSH to the Proxmox host

### Environment information
- target environment name
  - `school-lab`
  - `demo-lab`
- environment file path
- expected VNet/subnet naming model

### Repo access
- Git remote URL for the Cyberlab repo
- credentials or SSH key needed to clone the repo

---

# Phase 0-minus: Capture before a deliberate teardown

Skip this section on a genuinely fresh host. It applies when wiping a host
that has been used before — including the exploratory build that preceded the
current architecture.

The point is not to preserve data. It is to preserve the **facts** a rebuild
needs and nobody remembers: which bridge carries management traffic, what the
storage is actually called, which VMIDs were in use, what the SDN zone was
named. Those are exactly the Required Inputs above, and rediscovering them
costs more than capturing them.

```bash
# On the Proxmox host, with the USB stick mounted.
mkdir -p /mnt/usb
./scripts/capture-host-state.sh --dest /mnt/usb/pve1-$(date +%Y%m%d)
```

The script is read-only — it creates and modifies nothing on the host.

Options:

| Flag | Effect | When |
|---|---|---|
| *(none)* | Config, facts, and `/etc/pve/priv/`. Small and fast. | The normal case for a development host |
| `--with-guests` | Also `vzdump` every VM and container | Only if a specific guest is worth keeping |
| `--no-secrets` | Skip `/etc/pve/priv/` | A district deployment, or any destination you do not control |

`/etc/pve/priv/` — API token secrets and cluster keys — **is captured by
default**, so that restoring the capture yields a working environment rather
than one you are locked out of. That is the right default for a development
host, where the cost of being unable to revert is higher than the cost of keys
sitting on a stick in a drawer.

Two consequences worth being deliberate about:

- **If you ever actually restore from a capture, rotate the credentials
  afterwards.** The README's secrets hygiene section applies from that point
  on; a restored token has been off-host and should be treated accordingly.
- **The USB stick is now credential-bearing.** Store it like a key, not like a
  scratch disk.

For a host whose keys should not leave it, pass `--no-secrets`. The rebuild
regenerates everything in `priv/` regardless, so excluding it costs only the
ability to revert.

## Verify the capture before wiping anything

An unverified capture is not a capture. Confirm it landed and is readable
**from a second machine**, not just from the host you are about to erase:

```bash
cat /mnt/usb/pve1-*/MANIFEST.txt
cat /mnt/usb/pve1-*/facts/pvesm-status.txt     # storage names
cat /mnt/usb/pve1-*/facts/ip-addr.txt          # bridge and address layout
ls /mnt/usb/pve1-*/config/pve/qemu-server/     # VM configs
umount /mnt/usb
```

Then fill in the Required Inputs above **from the capture**, not from memory,
and proceed to Phase 0A.

## Captures currently on the hosts (2026-08-05)

Taken before the SDN teardown. Both are **still on the hosts they describe**,
which does not satisfy the rule above — they have not been verified from a
second machine, and a wipe would take the capture with it.

| Host | Path | Size |
|---|---|---|
| `pve1` (10.64.62.200) | `/root/cyberlab-capture-pre-sdn-teardown` | ~668 KB |
| `pve2` (10.64.62.201) | `/root/cyberlab-capture-pve2-pre-sdn-teardown` | ~60 KB |

Both include `/etc/pve/priv/`, so both are credential-bearing.

**`pve2`'s capture is not replaceable.** Under `www-farmcardscode/` it holds
the Cloudflare tunnel credentials (`cert.pem`, the tunnel JSON, `config.yml`)
and `/etc/farmcardscode.env` for the decommissioned `www.farmcardscode.org`.
None of that is in the site's GitHub repo — the repo has the application, not
its deployment identity. Together with VM `500`'s snapshot
`pre-decommission-20260805`, also on `pve2`, it is the only path back to a
running site. Copy it off before `pve2` is wiped.

### Known gap in captures taken before `ebc4c1a`

`capture-host-state.sh` recorded subnets from `/cluster/sdn/subnets`, which is
not a real endpoint — Proxmox addresses subnets per VNet. Affected captures
contain the string `No 'get' handler defined for '/cluster/sdn/subnets'` in
`facts/sdn-subnets.txt` instead of any gateway, DHCP range or SNAT flag. The
`pve1` capture above was backfilled by hand and is complete. The raw
`/etc/pve/sdn/*.cfg` files under `config/pve/` were never affected and remain
the authoritative record.

---

# Phase 0A: Proxmox Host Bootstrap

## 1. Fresh host validation

Confirm:

- Proxmox VE installed successfully
- host boots cleanly
- management network is reachable
- package repositories are configured appropriately
- storage exists and is usable

### Check
```bash
hostname
pveversion -v
ip a
pvesm status

