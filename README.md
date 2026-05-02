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

The platform is being built first for a single-teacher deployment, with a longer-term goal of supporting broader access for under-resourced Arkansas school districts.

This repository focuses on:

* deterministic infrastructure definitions
* low-PII operational design
* student/teacher access boundaries in Proxmox
* reproducible VM provisioning from templates
* environment portability between school lab and small test hardware

## Phase one goals

* define teachers, sections, slots, and policy as source-of-truth YAML
* generate pseudonymous student identities at runtime
* provision student and teacher VMs from templates
* assign Proxmox users, groups, pools, and ACLs from code
* isolate sections cleanly
* keep operations simple enough for one teacher to run reliably

## Current architecture

### Hypervisor

* Proxmox VE

### Provisioning

* OpenTofu

### Access and operations

* Ansible

### Templates

* Parrot
* Windows 7
* Debian 13
* Metasploitable2

## Repository layout

```text
cyberlab-infra/
├── README.md
├── docs/
│   └── data-model.md
├── data/
│   ├── teachers.yml
│   ├── sections.yml
│   ├── slots.yml
│   ├── policy.yml
│   └── environments/
│       ├── school-lab.yml
│       └── thinkcentre-lab.yml
├── private/
│   ├── credentials/
│   ├── exports/
│   ├── local/
│   └── .gitignore
├── opentofu/
└── ansible/
```

## Source-of-truth files

### `data/teachers.yml`

Canonical teacher registry.

Defines:

* teacher key
* teacher ID
* full name
* owned sections

### `data/sections.yml`

Canonical logical section definitions.

Defines:

* teacher-owned section instance key
* course/day/block metadata
* section code
* student count
* Proxmox group/pool naming

### `data/slots.yml`

Global slot policy for the five standard VM roles.

Current slots:

* `atk`
* `win`
* `srv`
* `vic`
* `www`

### `data/policy.yml`

Global platform policy.

Defines:

* VM offset policy
* username generation pattern
* password generation policy
* pool naming policy
* VM naming policy
* VMID formula
* network formula

### `data/environments/*.yml`

Environment-specific deployment mapping.

Defines:

* Proxmox API host
* target node(s)
* VNet names
* subnets
* gateways
* DHCP ranges

## Core design decisions

### No student PII in git

Student identities are generated at runtime and stored only in `private/` artifacts.

### Teacher-owned section instances

Sections are keyed as unique teacher-owned instances.

Examples:

* `jlong-cyba3`
* `jlong-itsb3`
* `jlong-icsa1`

### Deterministic VMIDs

```text
vmid = teacher_id * 1000000 + section_code * 1000 + offset
```

Example:

* teacher `101`
* section `213`
* offset `100`
* resulting VMID: `101213100`

### Simple `/24` classroom networks

```text
10.<teacher_id>.<section_code>.0/24
```

Example:

* `10.101.213.0/24`

This favors readability and classroom clarity over maximum address efficiency.

## Runtime-generated artifacts

The following are generated outside version control:

* student usernames
* student passwords
* private roster exports
* generated student inventory records
* local-only environment overrides if needed

These belong in:

* `private/credentials/`
* `private/exports/`
* `private/local/`

## What this repo does not store

* student real names
* student emails
* student SIS IDs
* committed passwords
* committed private roster mappings

## Status

This repository is in active phase-one design and build-out.

Current focus:

* finalize the data model
* keep the automation aligned to that model
* produce a stable MVP for one teacher’s students before expanding scope

## Next milestones

* finalize source-of-truth YAML schema
* refactor OpenTofu to consume the new model
* refactor Ansible to consume generated runtime student artifacts
* add snapshot and rollback controls
* validate student and teacher access flows end to end

## Notes for future me

Do not solve every scaling problem before the MVP works.

The phase-one target is:

* one teacher
* a few real sections
* repeatable provisioning
* stable permissions
* safe recovery
* clear documentation

Everything else can layer on later.

