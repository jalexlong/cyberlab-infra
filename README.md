```text
██████╗██╗   ██╗██████╗ ███████╗██████╗ ██╗      █████╗ ██████╗
██╔════╝╚██╗ ██╔╝██╔══██╗██╔════╝██╔══██╗██║     ██╔══██╗██╔══██╗
██║      ╚████╔╝ ██████╔╝█████╗  ██████╔╝██║     ███████║██████╔╝
██║       ╚██╔╝  ██╔══██╗██╔══╝  ██╔══██╗██║     ██╔══██║██╔══██╗
╚██████╗   ██║   ██████╔╝███████╗██║  ██║███████╗██║  ██║██████╔╝
 ╚═════╝   ╚═╝   ╚═════╝ ╚══════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═════╝

[ PROXMOX CYBERLAB INFRA ]---[ IaC | OPS | LAB AUTOMATION | RBAC ]
```

# Proxmox Cyberlab Infra

Infrastructure-as-code and operations repository for a teacher-operated virtual cybersecurity lab built on Proxmox VE.

## What this is

Proxmox Cyberlab Infra defines the **data model, automation, and deployment logic** for a browser-accessible cyber range designed for classroom use.

The platform is being built first for a single-teacher deployment, with a longer-term goal of supporting broader access for under-resourced Arkansas school districts, community volunteer labor, e-waste awareness, refurbished hardware reuse, and student engagement in CS/cybersecurity programs.

This repository focuses on:

- deterministic infrastructure definitions
- low-PII operational design
- student/teacher access boundaries in Proxmox
- reproducible VM provisioning from golden templates
- environment portability between school lab, home lab, and small test hardware
- operator-friendly rebuild and recovery paths

## Current tested checkpoint

The current working checkpoint is tagged:

- `milestone/debian13-template-promoted`

At this checkpoint, the platform can bootstrap the Cyberlab controller LXC, validate controller networking before package install, establish SSH/API trust, rotate the Proxmox API token when needed, bootstrap SDN, create the provisioning VNet, and promote the Debian 13 golden template.

Current platform contract:

- `800-899`: Cyberlab infrastructure and services
- `900-949`: promoted golden templates
- `950-999`: scratch validation clones
- `100000000-999999999`: deterministic teacher/student classroom workloads

## Current architecture

### Primary Proxmox node

- `pve1`

### Automation controller

- CTID `800`
- runs the repo clone
- runs Ansible playbooks
- holds the controller SSH key
- holds local-only Proxmox API secret material
- controls the Proxmox host through SSH and API

### Networking

- SDN zone: `virtnet`
- provisioning VNet: `prov0`
- provisioning subnet: `10.30.0.0/24`
- provisioning gateway: `10.30.0.1`
- Debian 13 static bootstrap IP: `10.30.0.10`

Template clone-default networking should return to DHCP before promotion.

## Phase one goals

- bootstrap a fresh Proxmox host into a Cyberlab-ready platform
- create and validate the automation controller
- establish trusted SSH/API access
- create the internal SDN provisioning network
- maintain a clean golden template catalog
- promote validated base templates
- generate pseudonymous student identities at runtime
- provision student and teacher VMs from golden templates
- assign Proxmox users, groups, pools, and ACLs from code
- isolate sections cleanly
- keep operations simple enough for one teacher to run reliably

## Template catalog

Template metadata lives in:

- `ansible/vars/templates.yml`

Current assigned/reserved template IDs:

- `900`: `tpl-debian13-base`
- `901`: `tpl-ubuntu2604-base`
- `902`: `tpl-parrot-base`
- `903`: `tpl-win7-base`
- `904`: `tpl-metasploitable2-base`

Current validation clone IDs:

- `950`: Debian 13 validation clone
- `951`: Ubuntu 26.04 validation clone
- `952`: Parrot validation clone
- `953`: Windows 7 validation clone
- `954`: Metasploitable 2 validation clone

The canonical staged template pipeline is:

1. `ansible/playbooks/controller-prepare-template-vm.yml`
2. `ansible/playbooks/controller-finalize-template-vm.yml`
3. `ansible/playbooks/controller-promote-template.yml`

The wrapper is:

- `ansible/playbooks/controller-build-template-pipeline.yml`

Example from inside CT `800`:

```bash
cd /root/cyberlab-infra/ansible
ansible-playbook -i inventory.yml playbooks/controller-build-template-pipeline.yml -e template_name=debian13
```

## Repository layout

```text
cyberlab-infra/
├── README.md
├── docs/
│   ├── data-model.md
│   ├── platform-pipeline.md
│   └── template-lifecycle.md
│   ├── recovery.md
│   └── testing.md
├── data/
│   ├── bootstrap-policy.yml
│   ├── teachers.yml
│   ├── sections.yml
│   ├── slots.yml
│   ├── policy.yml
│   └── environments/
│       ├── school-lab.yml
│       └── thinkcentre-lab.yml
├── ansible/
│   ├── inventory.yml
│   ├── playbooks/
│   └── vars/
│       └── templates.yml
├── scripts/
├── private/
│   ├── credentials/
│   ├── exports/
│   ├── generated/
│   ├── local/
│   ├── secrets/
│   └── .gitignore
└── opentofu/
```

## Source-of-truth files

### `data/bootstrap-policy.yml`

Canonical bootstrap and VMID policy.

Defines:

- controller CTID
- controller baseline settings
- automation identity defaults
- infrastructure VMID range
- golden template VMID range
- validation clone VMID range
- classroom workload VMID range

### `ansible/vars/templates.yml`

Canonical golden template catalog.

Defines:

- stable template IDs
- template names
- template VMIDs
- validation clone VMIDs
- build method
- image source
- target node
- hardware profile
- provisioning network settings
- clone-default network settings

### `data/teachers.yml`

Canonical teacher registry.

Defines:

- teacher key
- teacher ID
- full name
- owned sections

### `data/sections.yml`

Canonical logical section definitions.

Defines:

- teacher-owned section instance key
- course/day/block metadata
- section code
- student count
- Proxmox group/pool naming

### `data/slots.yml`

Global slot policy for the standard VM roles.

Current slots:

- `atk`
- `win`
- `srv`
- `vic`
- `www`

### `data/policy.yml`

Global platform policy.

Defines:

- VM offset policy
- username generation pattern
- password generation policy
- pool naming policy
- VM naming policy
- VMID formula
- network formula

### `data/environments/*.yml`

Environment-specific deployment mapping.

Defines:

- Proxmox API host
- target node or nodes
- VNet names
- subnets
- gateways
- DHCP ranges

## Core design decisions

### One platform, multiple environments

This project should remain one cohesive Cyberlab platform.

School, home, and demo differences should be handled through:

- runtime detection
- explicit variables
- preflight checks
- operator overrides
- environment-specific config

They should not become separate platform variants.

### No student PII in git

Student identities are generated at runtime and stored only in `private/` artifacts.

This repo does not store:

- student real names
- student emails
- student SIS IDs
- committed passwords
- committed private roster mappings

### Teacher-owned section instances

Sections are keyed as unique teacher-owned instances.

Examples:

- `jlong-cyba3`
- `jlong-itsb3`
- `jlong-icsa1`

### Deterministic classroom VMIDs

```text
vmid = teacher_id * 1000000 + section_code * 1000 + offset
```

Example:

- teacher `101`
- section `213`
- offset `100`
- resulting VMID: `101213100`

### Simple `/24` classroom networks

```text
10.<teacher_id>.<section_code>.0/24
```

Example:

- `10.101.213.0/24`

This favors readability and classroom clarity over maximum address efficiency.

## Runtime-generated artifacts

The following are generated outside version control:

- student usernames
- student passwords
- private roster exports
- generated student inventory records
- generated controller network vars
- local-only environment overrides
- local-only API token secrets

These belong in:

- `private/credentials/`
- `private/exports/`
- `private/generated/`
- `private/local/`
- `private/secrets/`

## Secrets hygiene

Do not commit generated secrets or environment-specific generated files.

Examples that must remain local-only:

- Proxmox API token secrets
- controller SSH private keys
- generated controller network vars
- private roster exports
- generated student credentials

Previously exposed API tokens should be considered compromised and rotated.

## Status

This repository is in active build-out.

The current working milestone proves:

- host bootstrap
- controller bootstrap
- controller network detection
- controller DNS injection
- controller preflight before package install
- API token handoff and rotation behavior
- SSH trust from controller to host
- SDN bootstrap
- provisioning VNet creation
- Debian 13 template promotion

## Next milestones

- add validation clone automation
- expand template support beyond Debian 13
- refactor OpenTofu to consume the current model
- refactor Ansible to consume generated runtime student artifacts
- add snapshot and rollback controls
- validate student and teacher access flows end to end
- test validation clone automation on live Proxmox hardware

## Notes for future me

Do not solve every scaling problem before the MVP works.

The phase-one target is:

- one teacher
- a few real sections
- repeatable provisioning
- stable permissions
- safe recovery
- clear documentation

Everything else can layer on later.
