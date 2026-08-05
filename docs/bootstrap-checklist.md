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
- Ansible and OpenTofu available in the controller
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
| *(none)* | Config and facts only. Small and fast. | The normal case for a disposable host |
| `--with-guests` | Also `vzdump` every VM and container | Only if a specific guest is worth keeping |
| `--with-secrets` | Also copy `/etc/pve/priv/` | Rarely. See below |

`/etc/pve/priv/` is **excluded by default**. It holds API token secrets and
cluster keys, the rebuild regenerates all of it, and the usual destination for
this capture is a USB stick that then lives in a drawer. Per the secrets
hygiene section of the README, any previously exposed token should be treated
as compromised and rotated rather than restored.

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

