# Cyberlab Platform Pipeline

## Purpose

This document defines the end-to-end lifecycle for rebuilding the Cyberlab platform from a clean Proxmox VE install to a functioning instructional cyber range.

The goal is not just automation. The goal is **repeatable, validated automation**.

This pipeline exists to prevent the platform from drifting into a state where:
- some steps live in memory
- some steps live in shell history
- some steps are automated incorrectly
- some environments work only because they were manually repaired

The platform should be rebuildable on demand with predictable results.

---

## Design Principles

### 1. Automation with validation gates
Automation is required, but automation alone is not enough.

Every major layer must support:
- **build**
- **validate**
- **promote**
- **deploy**

Broken assumptions should be caught before scale deployment.

### 2. Environment isolation
Each environment must be explicitly selected and independently reproducible.

Examples:
- `school-lab`
- `demo-lab`

No environment should depend on hidden hardcoded host IPs or ad hoc file edits.

### 3. Dedicated automation identity
Automation must use a dedicated non-human Proxmox identity.

It must not depend on:
- a teacher account
- a desktop username
- a reusable personal admin login

### 4. Principle of least privilege
The platform should minimize privileges where practical, while recognizing that some bootstrap tasks require root-level control on the Proxmox host.

Privilege boundaries should be explicit.

### 5. Promote only validated artifacts
Templates, SDN definitions, and deployment workflows should not be considered production-ready until they pass validation.

### 6. Reproducibility over convenience
Every required step should live in:
- code
- configuration
- documentation

Not in memory.

---

## Environment Model

The platform supports multiple independent environments.

Each environment must define:
- Proxmox API endpoint
- Proxmox default node
- approved template VMIDs
- section-to-node mapping
- VNet names
- subnet/gateway/DHCP range

Examples:
- `data/environments/school-lab.yml`
- `data/environments/demo-lab.yml`

Environment selection must be explicit and shared by:
- Ansible
- OpenTofu
- runtime artifact generation
- validation workflows

---

## VMID Allocation Policy

The Cyberlab platform uses reserved VMID ranges by purpose. VMIDs are not assigned ad hoc.

The source of truth for VMID allocation is:

- `data/bootstrap-policy.yml`

This policy exists to keep infrastructure, templates, and classroom workloads clearly separated and collision-resistant across rebuilds.

### Reserved Classes

#### Infrastructure controllers
Used for automation/control-plane systems such as the Cyberlab automation LXC.

Example:
- `800 = cyberlab-ctrl`

These systems manage the platform and are not classroom workloads.

#### Shared infrastructure
Used for future support systems such as:
- monitoring
- backup helpers
- internal mirrors
- logging or utility services

These remain separate from both templates and classroom deployments.

#### Candidate templates
Candidate templates live in a reserved candidate range and must be validated before promotion.

Examples:
- `8901 = parrot-candidate`
- `8902 = win7-candidate`
- `8903 = debian13-candidate`
- `8904 = metasploitable2-candidate`

Candidate templates must never be consumed directly by section deployment automation.

#### Approved templates
Approved templates live in a separate reserved range and are the only templates that may be consumed by OpenTofu and environment deployment workflows.

Examples:
- `9001 = parrot-template`
- `9002 = win7-template`
- `9003 = debian13-template`
- `9004 = metasploitable2-template`

#### Classroom workloads
Teacher and student lab VMs use the structured Cyberlab VMID scheme and live in a dedicated high-range namespace.

This range is governed by the platform’s structured encoding model and must remain disjoint from:
- infrastructure
- candidate templates
- approved templates

### Operational Rules

- VMIDs must be chosen from the appropriate reserved range only.
- Candidate template VMIDs must never be used for deployment targets.
- Approved template VMIDs must never be reused for non-template systems.
- Infrastructure/controller VMIDs should remain stable across rebuilds whenever practical.
- If VMID policy changes, the following must be updated together:
  - `data/bootstrap-policy.yml`
  - `data/templates.yml`
  - environment files
  - deployment documentation

### Purpose

This policy makes the platform easier to:
- rebuild
- audit
- troubleshoot
- scale across multiple teachers and environments

---

## Identity and Secret Model

### Automation Identity

A dedicated Proxmox account must exist for platform automation.

Recommended name:
- `cyberlab-automation@pve`

This identity is separate from:
- teacher identities
- student identities
- personal administrative identities

### API Token

Each environment should use a separate API token for the automation identity.

Recommended token ID:
- `automation`

Examples:
- `cyberlab-automation@pve!automation` for school-lab
- a separate token for demo-lab

### Secret Handling

Secrets must not be embedded in public data model files.

They should be stored in:
- Ansible Vault
- environment-specific private files
- or environment variables provided securely at runtime

Examples:
- API token secrets
- SSH private keys
- bootstrap credentials

---

## Pipeline Overview

The platform is built in five layers:

- **Phase 0A:** Host bootstrap
- **Phase 0B:** Automation controller bootstrap
- **Phase 1:** Control-plane bootstrap
- **Phase 2:** Template factory
- **Phase 3:** Runtime generation
- **Phase 4:** Deployment and smoke testing

Each phase has defined inputs, outputs, and validation criteria.

---

# Phase 0A: Host Bootstrap

## Goal

Turn a fresh Proxmox VE install into a host that is ready for Cyberlab control-plane automation.

## Inputs

- clean Proxmox VE install
- one bootstrap administrative login
- network connectivity
- storage configured
- SSH access to the host

## Actions

- apply repository/package baseline
- install required host packages
- validate storage names used by automation
- validate bridge/network prerequisites
- create dedicated Proxmox automation identity
- create API token for automation identity
- configure required sudoers/NOPASSWD rules only where necessary
- establish SSH trust path for the automation controller

## Outputs

- host reachable by automation
- API token available
- required host packages installed
- host ready for controller bootstrap

## Validation

- SSH works to the host
- Proxmox API token works
- required commands exist:
  - `pveum`
  - `pvesh`
  - `qm`
  - `pct`
  - `dnsmasq` if SDN DHCP is required
- storage targets referenced by automation exist

---

# Phase 0B: Automation Controller Bootstrap

## Goal

Create a dedicated automation LXC that runs Ansible, OpenTofu, and the Cyberlab repo.

## Inputs

- bootstrapped Proxmox host
- bootstrap policy
- SSH public key for operator access
- environment selection

## Actions

- create the automation controller LXC
- install required packages inside it
- install git, ansible, python tooling, and OpenTofu
- clone or update the Cyberlab repo
- create private working directories
- configure environment selection helpers
- store secrets securely for later phases

## Outputs

- dedicated automation LXC
- repo available inside the controller
- platform tooling installed in a controlled environment
- future automation no longer depends on running directly from the Proxmox host

## Validation

- controller LXC boots
- operator can SSH into it
- ansible works
- tofu works
- repo is present and current
- environment selection works cleanly

---

# Phase 1: Control-Plane Bootstrap

## Goal

Build the Proxmox-side platform primitives required to host lab resources.

## Inputs

- bootstrapped Proxmox host
- bootstrapped automation controller
- selected environment file
- automation identity and token
- Ansible inventory for target environment

## Actions

- create Proxmox groups
- create Proxmox pools
- assign ACLs
- create SDN zone
- create VNets
- create subnets
- configure DHCP ranges through IPAM/SDN
- apply SDN changes
- verify dnsmasq-backed SDN services are active
- create any environment-specific service groupings

## Outputs

- zone exists
- VNets exist
- subnet/DHCP definitions exist
- ACLs and pools exist
- host-side SDN interfaces are present

## Validation

- zone present in `/etc/pve/sdn/zones.cfg`
- VNets present in `/etc/pve/sdn/vnets.cfg`
- subnets present in `/etc/pve/sdn/subnets.cfg`
- VNet interfaces exist on host
- DHCPDISCOVER receives DHCPOFFER on a test VNet
- pool/group/ACL state matches intended model

---

# Phase 2: Template Factory

## Goal

Build and validate the VM templates used for lab deployment.

## Core Rule

Templates must use a **candidate → approved** lifecycle.

Automation must not deploy from newly built images without validation.

## Candidate vs Approved

### Candidate templates
Candidate VMIDs live in the `89xx` range.

Examples:
- `8901` parrot-candidate
- `8902` win7-candidate
- `8903` debian13-candidate
- `8904` metasploitable2-candidate

### Approved templates
Approved VMIDs live in the `90xx` range.

Examples:
- `9001` parrot-template
- `9002` win7-template
- `9003` debian13-template
- `9004` metasploitable2-template

OpenTofu and deployment automation may only consume approved templates.

## Template Sources

Template metadata lives in:
- `data/templates.yml`

Template build paths include:
- imported qcow2 images
- imported VMDK images
- installer-based candidates

## Actions

- build candidate template VM
- validate boot
- validate console
- validate login
- validate NIC presence
- validate DHCP on a known-good test VNet
- validate gateway reachability
- validate guest agent if required
- validate cloud-init behavior if required
- promote candidate to approved template

## Outputs

- validated approved templates
- consistent template metadata
- deployment-safe VMIDs for environment files

## Validation

### All templates
- boot cleanly
- console works
- login works
- DHCP works on a test VNet
- gateway ping works

### Linux templates
- cloud-init behavior correct if applicable
- guest agent installed and detected if expected

### Windows templates
- stable boot/reboot
- storage and NIC drivers correct
- no blocking BSOD for required devices

---

# Phase 3: Runtime Generation

## Goal

Generate environment-specific runtime artifacts from the declarative data model.

## Inputs

- `data/teachers.yml`
- `data/sections.yml`
- `data/slots.yml`
- `data/policy.yml`
- selected environment file
- private secrets storage path

## Actions

- generate student identities
- generate student pools
- generate runtime mappings
- generate any private artifacts needed for downstream automation

## Outputs

- generated students artifact
- generated runtime data in `private/`
- deterministic deployment inputs

## Validation

- generated section keys match environment section keys
- username scheme matches policy
- student count matches section definitions
- pool names and expected VM names are deterministic

---

# Phase 4: Deployment and Smoke Testing

## Goal

Deploy validated lab resources from approved templates into a selected environment.

## Inputs

- approved templates
- validated SDN control plane
- generated runtime artifacts
- selected environment file

## Actions

- deploy a smoke test first
- validate teacher and one student deployment
- validate pools and ACL visibility
- validate VM boot
- validate DHCP/network reachability
- validate section isolation
- scale to full section only after smoke test passes

## Smoke Test Policy

A fresh environment should never first be tested by deploying a full section.

Recommended smoke test:
- 1 teacher VM set
- 1 student
- 2 to 3 slots only

Example:
- `jlong-srv`
- `cyba3-raven-01-srv`
- `cyba3-raven-01-atk`

## Outputs

- proven section deployment path
- validated teacher/student access model
- full section deployment only after smoke test success

## Validation

- student sees only their own pool
- teacher sees intended shared resources
- same-section VMs can communicate as expected
- unintended cross-section visibility does not exist
- VM naming and VMIDs match deterministic policy

---

## SDN Validation Rule

Creating SDN objects is not sufficient.

Every environment must prove:
- zone exists
- VNet exists
- subnet exists
- DHCP range exists
- dnsmasq-backed service is active
- VNet interface exists on host
- DHCPDISCOVER receives DHCPOFFER on the VNet

This must be verified before blaming templates or deployment code for missing network connectivity.

---

## Cloud Image Rule

Cloud images are not equivalent to manually installed templates.

When using a cloud image:
- cloud-init settings must be explicit
- DHCP behavior must be verified
- local access must be verified
- image suitability must be validated before promotion

Imported cloud images should never skip candidate validation.

---

## Failure Handling Rule

If a candidate template, SDN build, or deployment step fails:

- do not continue scaling
- stop at the current phase
- correct the issue
- revalidate the phase
- only then continue

A failed candidate must not be promoted.

A failed smoke test must not become a full rollout.

---

## Operational Rule of Thumb

**Automate build. Validate before promotion. Deploy approved artifacts only.**
