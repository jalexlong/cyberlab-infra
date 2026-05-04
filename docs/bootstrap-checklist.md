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

