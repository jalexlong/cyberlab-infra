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

The script makes no changes to host configuration. The only things it writes
are the capture directory and its own run transcript under `/var/log/cyberlab`.

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

## Captures of the 2026-08-05 teardown

Taken before all SDN was removed, then archived off both hosts. **The hosts are
now wipeable** — nothing below depends on them surviving.

Each capture exists in three places: on the host under `/root/`, on a USB stick
written from that host, and on the laptop under `~/cyberlab-captures/20260805/`.
Only the last two survive a wipe.

| Host | USB contents | Size |
|---|---|---|
| `pve1` | `cyberlab-capture-pre-sdn-teardown.tar.gz` | 35 KB |
| `pve2` | `cyberlab-capture-pve2-pre-sdn-teardown.tar.gz` | 3.3 KB |
| `pve2` | `vzdump-qemu-500-2026_08_05-*.vma.zst` | 702 MB |

Archived as `tar.gz` rather than copied as directory trees because the sticks
are vfat, which cannot hold Unix ownership or mode bits — and `/etc/pve/priv/`
is captured, so those bits matter. Each stick carries a `README.txt` and a
`SHA256SUMS`.

**Both sticks and the laptop copy are credential-bearing.** They hold
`/etc/pve/priv/` — API token secrets, `pve-root-ca.key`, `shadow.cfg`. Store
them like keys, and rotate credentials after any actual restore.

Verified by reading back **from the sticks** on a second machine: checksums
match, the archives extract, and the Required Inputs above are all present —
storage names, the `vmbr0` address, VMIDs in use, and the SDN zone name.

### The website is backed up, not just its config

`pve2`'s capture holds the deployment identity of the decommissioned
`www.farmcardscode.org` — Cloudflare tunnel credentials and
`/etc/farmcardscode.env`. None of that is in the site's GitHub repo, which
holds the application and not its identity.

The `vzdump` alongside it is the VM itself. Note what it is: **the current
stopped state, with `cloudflared` and `farmcardscode` disabled.** A `vzdump`
does not include VM snapshots, so `pre-decommission-20260805` — the running
site — is not in the archive. Restoring gives a working but idle VM:

```bash
qmrestore vzdump-qemu-500-*.vma.zst 500
qm start 500
# inside the guest:
systemctl enable --now farmcardscode cloudflared
```

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

