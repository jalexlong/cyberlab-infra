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

## Design principles

### 1. Automation with validation gates

Automation is required, but automation alone is not enough.

Every major layer must support:

- prepare or build
- validate
- promote
- deploy
- smoke test

Broken assumptions should be caught before scale deployment.

### 2. One cohesive platform

Cyberlab should remain one cohesive platform.

Environment-specific differences should be handled by:

- runtime detection
- explicit variables
- preflight checks
- operator overrides

The project should not split into separate `schoollab`, `homelab`, and `demolab` variants.

### 3. Environment isolation

Each environment must be explicitly selected and independently reproducible.

Examples:

- school lab
- home lab
- demo lab

No environment should depend on hidden hardcoded host IPs or ad hoc file edits.

### 4. Dedicated automation identity

Automation must use a dedicated non-human Proxmox identity.

It must not depend on:

- a teacher account
- a desktop username
- a reusable personal admin login

### 5. Principle of least privilege

The platform should minimize privileges where practical, while recognizing that some bootstrap tasks require root-level control on the Proxmox host.

Privilege boundaries should be explicit.

### 6. Promote only validated artifacts

Templates, SDN definitions, and deployment workflows should not be considered deployment-ready until they pass validation.

### 7. Reproducibility over convenience

Every required step should live in:

- code
- configuration
- documentation

Not in memory.

---

## Environment model

The platform supports multiple operating environments without becoming multiple products.

Each environment may define or discover:

- Proxmox API endpoint
- Proxmox default node
- controller management bridge
- controller VLAN tag
- local DNS servers
- VNet names
- subnet/gateway/DHCP ranges
- section-to-node mapping

Environment selection and runtime detection must be shared by:

- installer scripts
- Ansible
- OpenTofu
- runtime artifact generation
- validation workflows

---

## VMID allocation policy

The Cyberlab platform uses reserved VMID ranges by purpose.

VMIDs are not assigned ad hoc.

The source of truth for VMID allocation is:

- `data/bootstrap-policy.yml`

This policy exists to keep infrastructure, templates, validation clones, and classroom workloads clearly separated and collision-resistant across rebuilds.

### Reserved classes

#### Infrastructure and services

Infrastructure and service systems live in:

```text
800-899
```

Current assignments:

- `800`: Cyberlab automation controller LXC
- `801`: reserved for future apt-cache or package mirror service

These systems manage or support the platform and are not classroom workloads.

#### Golden templates

Golden templates live in:

```text
900-949
```

Current assignments:

- `900`: `tpl-debian13-base`
- `901`: `tpl-ubuntu2604-base`
- `902`: `tpl-parrot-base`
- `903`: `tpl-win7-base`
- `904`: `tpl-metasploitable2-base`

A VM in this range is not deployment-safe merely because it exists. It becomes deployment-safe only after the staged template pipeline prepares, finalizes, validates, and promotes it.

#### Validation clones

Validation clones live in:

```text
950-999
```

Current assignments:

- `950`: Debian 13 validation clone
- `951`: Ubuntu 26.04 validation clone
- `952`: Parrot validation clone
- `953`: Windows 7 validation clone
- `954`: Metasploitable 2 validation clone

Validation clones are disposable scratch VMs. They exist to prove that a promoted template can be cloned, booted, networked, and accessed safely before wider lab deployment.

#### Classroom workloads

Teacher and student lab VMs use the structured Cyberlab VMID scheme and live in a dedicated high-range namespace.

```text
100000000-999999999
```

The current classroom VMID formula is:

```text
vmid = teacher_id * 1000000 + section_code * 1000 + offset
```

This range is governed by the platform's structured encoding model and must remain disjoint from:

- infrastructure
- golden templates
- validation clones

### Operational rules

- VMIDs must be chosen from the appropriate reserved range only.
- Infrastructure VMIDs must not be reused for templates or classroom workloads.
- Golden template VMIDs must not be reused for validation clones.
- Validation clone VMIDs must not be reused for source templates.
- Classroom workloads must be deployed only from validated golden templates.
- If VMID policy changes, update these together:
  - `data/bootstrap-policy.yml`
  - `ansible/vars/templates.yml`
  - deployment documentation
  - template lifecycle documentation

---

## Identity and secret model

### Automation identity

A dedicated Proxmox account must exist for platform automation.

Recommended name:

- `cyberlab-automation@pve`

This identity is separate from:

- teacher identities
- student identities
- personal administrative identities

### API token

Each environment should use a separate API token for the automation identity.

Recommended token ID:

- `automation`

Example:

- `cyberlab-automation@pve!automation`

### Secret handling

Secrets must not be embedded in public data model files.

They should be stored in:

- local-only private files
- Ansible Vault
- environment variables provided securely at runtime

Examples:

- API token secrets
- SSH private keys
- bootstrap credentials

Generated secrets and generated environment-local files must not be committed.

---

## Pipeline overview

The platform is built in five layers:

- **Phase 0A:** Host bootstrap
- **Phase 0B:** Automation controller bootstrap
- **Phase 1:** Control-plane bootstrap
- **Phase 2:** Template factory
- **Phase 3:** Runtime generation
- **Phase 4:** Deployment and smoke testing

Each phase has defined inputs, outputs, and validation criteria.

---

# Phase 0A: Host bootstrap

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
- create or rotate API token for automation identity when required
- configure required sudoers/NOPASSWD rules only where necessary
- establish SSH trust path for the automation controller

## Outputs

- host reachable by automation
- API token available to the controller
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

# Phase 0B: Automation controller bootstrap

## Goal

Create a dedicated automation LXC that runs the Cyberlab repo and Ansible playbooks.

## Inputs

- bootstrapped Proxmox host
- bootstrap policy
- detected or overridden controller network settings
- SSH public key for operator/controller access

## Actions

- discover controller management bridge, VLAN, DNS, and resolver constraints
- generate local-only controller network vars
- create or update the automation controller LXC
- inject usable DNS into the controller
- install required packages inside the controller
- install git, ansible, and python tooling
- clone or update the Cyberlab repo
- create private working directories
- store secrets securely for later phases

## Outputs

- dedicated automation LXC
- repo available inside the controller
- platform tooling installed in a controlled environment
- future automation no longer depends on running directly from the Proxmox host

## Validation

- controller LXC boots
- controller has IPv4
- controller has a default route
- controller can resolve package repositories
- controller can run package updates
- operator/controller SSH path works
- Ansible works
- repo is present and current

---

# Phase 1: Control-plane bootstrap

## Goal

Build the Proxmox-side platform primitives required to host lab resources.

## Inputs

- bootstrapped Proxmox host
- bootstrapped automation controller
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

# Phase 2: Template factory

## Goal

Build and validate the VM templates used for lab deployment.

## Core rule

Templates must use a **prepare -> finalize -> promote -> validate** lifecycle.

Automation must not deploy from newly built or unvalidated images.

## Source of truth

Template metadata lives in:

- `ansible/vars/templates.yml`

The current staged template pipeline is:

1. `controller-prepare-template-vm.yml`
2. `controller-finalize-template-vm.yml`
3. `controller-promote-template.yml`

The wrapper playbook is:

- `controller-build-template-pipeline.yml`

## Golden templates

Golden templates live in:

```text
900-949
```

Current assignments:

- `900`: `tpl-debian13-base`
- `901`: `tpl-ubuntu2604-base`
- `902`: `tpl-parrot-base`
- `903`: `tpl-win7-base`
- `904`: `tpl-metasploitable2-base`

## Validation clones

Validation clones live in:

```text
950-999
```

Current assignments:

- `950`: Debian 13 validation clone
- `951`: Ubuntu 26.04 validation clone
- `952`: Parrot validation clone
- `953`: Windows 7 validation clone
- `954`: Metasploitable 2 validation clone

## Actions

- prepare template VM
- validate boot path
- validate console or SSH access
- validate login
- validate NIC presence
- validate DHCP behavior
- validate gateway reachability
- validate guest agent if required
- validate cloud-init behavior if required
- restore clone-default networking to DHCP before promotion
- promote finalized VM to golden template
- create validation clone
- validate clone behavior before classroom deployment

## Outputs

- validated golden templates
- consistent template metadata
- deployment-safe VMIDs for downstream deployment automation

## Validation

### All templates

- boot cleanly
- console or SSH path works
- login works
- DHCP works on clone-default network
- gateway ping works

### Linux templates

- cloud-init behavior correct if applicable
- guest agent installed and detected if expected
- machine identity cleaned before promotion
- SSH host keys cleaned before promotion

### Windows templates

- stable boot/reboot
- storage and NIC drivers correct
- no blocking BSOD for required devices

---

# Phase 3: Runtime generation

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

# Phase 4: Deployment and smoke testing

## Goal

Deploy validated lab resources from golden templates into a selected environment.

## Inputs

- golden templates
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

## Smoke test policy

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

## SDN validation rule

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

## Cloud image rule

Cloud images are not equivalent to manually installed templates.

When using a cloud image:

- cloud-init settings must be explicit
- DHCP behavior must be verified
- local access must be verified
- image suitability must be validated before promotion
- final clone-default networking should be restored to DHCP before promotion

Imported cloud images must not skip finalization or post-promotion validation.

---

## Failure handling rule

If template preparation, finalization, promotion, SDN build, or deployment fails:

- do not continue scaling
- stop at the current phase
- correct the issue
- revalidate the phase
- only then continue

A failed prepared or finalized VM must not be promoted to a golden template.

A failed smoke test must not become a full rollout.

---

## Operational rule of thumb

**Automate preparation. Validate before and after promotion. Deploy golden templates only.**
