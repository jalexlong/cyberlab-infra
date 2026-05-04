# Automation Controller LXC

## Purpose

The Automation Controller LXC is the dedicated control-plane runner for the Cyberlab platform.

It exists so that Cyberlab automation is **not** run directly from the Proxmox hypervisor and does **not** depend on a teacher workstation or personal machine.

The controller LXC is the system that runs:

- Ansible
- OpenTofu
- supporting Python tooling
- the Cyberlab repo
- environment selection helpers
- validation and deployment commands

This makes the platform easier to:

- rebuild
- document
- support
- migrate to new hardware
- hand off to other teachers or administrators

---

## Why a Dedicated Controller Exists

Running automation directly on the Proxmox host would work, but it is not the preferred operational model for Cyberlab.

The Proxmox node should remain focused on being:

- the hypervisor
- the SDN host
- the API endpoint
- the system being managed

The controller LXC should remain focused on being:

- the automation runner
- the repo host
- the operator interface
- the place where Ansible and OpenTofu are installed

This separation provides a cleaner trust boundary and better operational hygiene.

---

## Responsibilities

The controller LXC is responsible for:

- cloning and updating the Cyberlab repo
- storing environment-aware automation tooling
- running Ansible playbooks
- running OpenTofu plans and applies
- storing private generated artifacts
- storing environment-specific secrets securely
- providing a stable shell environment for operators
- serving as the main execution environment for bootstrap and deployment workflows

---

## Non-Responsibilities

The controller LXC is **not** responsible for being:

- a Proxmox hypervisor
- a classroom VM
- a teacher workstation
- a storage node
- a manually customized long-lived snowflake system

It should remain small, understandable, and rebuildable.

---

## Recommended Characteristics

The controller LXC should follow the policy defined in:

- `data/bootstrap-policy.yml`

Recommended defaults:

- CTID: `800`
- hostname: `cyberlab-ctrl`
- template: `debian-13-standard`
- unprivileged: `true`
- bridge: `vmbr0`
- cores: `2`
- memory: `4096 MB`
- disk: `32 GB`
- start on boot: `true`

These values are defaults, not immutable requirements, but they should remain stable unless there is a good documented reason to change them.

---

## Why Debian 13

Debian 13 is a good fit for the controller because it is:

- stable
- well supported
- easy to automate
- appropriate for Ansible/OpenTofu/python tooling
- modern enough for current package ecosystems

The controller is not a classroom payload image. It is an automation appliance.

---

## Networking Model

The controller LXC should live on the **management network**, not on a classroom VNet.

It should attach to:
- `vmbr0` or the environmentâ€™s designated management bridge

It should **not** attach to:
- section VNets
- student-facing SDN networks
- instructional lab segments

This keeps the controller separate from classroom traffic and avoids accidental dependency on the lab plane.

### Addressing

A stable management IP is preferred.

That can be:
- static addressing
- or a DHCP reservation

The key requirement is that the controller should remain predictably reachable.

---

## Access Model

Operators should access the controller by:

- SSH
- Proxmox console if needed for recovery

The controller should not rely on ad hoc interactive use from the Proxmox host.

### Typical operator flow

An operator should:
1. SSH into the controller
2. select an environment
3. run the appropriate Cyberlab command or wrapper
4. validate results
5. exit

---

## Software Installed in the Controller

The controller should contain the minimum toolset necessary to operate the platform.

Typical packages and tools include:

- git
- curl
- sudo
- python3
- python3-yaml
- ansible
- OpenTofu
- openssh-client

Additional tooling may be added as required, but the controller should not become a general-purpose utility VM.

---

## Repo Layout in the Controller

The Cyberlab repo should be cloned into a stable operator path.

Recommended:

- `~/cyberlab-infra`

This repo should include:

- `data/`
- `docs/`
- `scripts/`
- `ansible/`
- `opentofu/`
- `private/` or equivalent non-public workspace

The controller should be treated as the canonical automation runtime, not necessarily the canonical Git origin.

---

## Secrets Handling

Secrets should be stored on the controller, not spread across teacher workstations or random shell histories.

Examples:

- API token secrets
- Ansible Vault files
- SSH private keys used for automation
- generated private runtime artifacts

Secrets must not be stored in public config files inside the repo.

Preferred options:
- Ansible Vault
- environment-specific private files
- restricted-permission local storage

---

## Relationship to the Proxmox Automation Identity

The controller uses the dedicated Proxmox automation identity defined by platform policy.

Recommended Proxmox identity:
- `cyberlab-automation@pve`

Recommended token ID:
- `automation`

The controller consumes this identity to perform:
- SDN configuration
- ACL/group/pool creation
- template and deployment operations

This identity is separate from:
- teacher accounts
- student accounts
- personal administrative accounts

---

## Rebuild Philosophy

The controller must be rebuildable.

This is a hard requirement.

If the controller is lost, replaced, or corrupted, the platform should be able to recreate it with:

- the bootstrap policy
- the bootstrap playbook
- the repo
- environment-specific secrets

The controller should never become irreplaceable.

---

## Operational Rule

If a controller is heavily customized by hand and cannot be recreated from documented automation, it has failed its design purpose.

The controller should always remain:

- replaceable
- documented
- version-controlled in behavior
- minimally stateful

---

## Validation Criteria

A controller LXC is considered ready when:

- it boots cleanly
- it is reachable by SSH
- the Cyberlab repo is present
- `ansible --version` works
- `tofu version` works
- environment selection works
- private workspace exists
- secrets can be loaded securely
- it can reach the Proxmox API target for the selected environment

---

## Summary

The Automation Controller LXC is the dedicated operational home of Cyberlab automation.

It exists to make the platform:

- cleaner
- safer
- more professional
- easier to rebuild
- easier to share with other educators

It is not optional platform clutter. It is part of the architecture.

