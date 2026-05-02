# Cyberlab Infra Data Model

## Purpose

This document defines the source-of-truth data model for the Cyberlab infrastructure repository.

The goals of the data model are:

* keep the infrastructure repo free of student PII
* support deterministic provisioning and permission assignment
* separate logical lab definitions from environment-specific deployment details
* support future multi-teacher growth without naming or numbering collisions
* keep phase-one operations simple enough for one teacher to run reliably

## Design principles

### 1. No student PII in git

Student names, emails, and SIS identifiers are not stored in the repository. Student accounts are generated at runtime from section definitions and policy.

### 2. Teacher-owned section instances

A section is modeled as a teacher-owned section instance, not just a course/day/block label.

Examples:

* `jlong-cyba3`
* `jlong-itsb3`
* `jlong-icsa1`

This prevents collisions in VMIDs, pools, groups, and networks when different teachers may have similarly named sections.

### 3. Logical data and environment data are separate

The repository separates:

* logical data such as teachers, sections, slots, and global policy
* environment-specific deployment data such as Proxmox nodes, VNets, subnets, and DHCP ranges

### 4. Runtime-generated student identities

Student usernames, passwords, and per-student private exports are generated at runtime and stored outside version control.

## Repository data files

### `data/teachers.yml`

Canonical teacher registry.

This file defines:

* teacher username/key
* teacher numeric ID
* teacher full name
* sections owned by that teacher

Example:

```yaml
teachers:
  jlong:
    teacher_id: 101
    full_name: "J Long"
    sections:
      - "jlong-icsa1"
      - "jlong-itsa2"
      - "jlong-itsb3"
      - "jlong-cyba3"
```

### `data/sections.yml`

Canonical logical section definitions.

Each key is a unique teacher-owned section instance.

This file defines:

* section key
* display section label
* human-friendly alias
* teacher owner
* course code and course name
* day and block
* section code
* student count
* Proxmox student group, teacher group, and shared pool naming

Example:

```yaml
sections:
  jlong-cyba3:
    display_section: "cyba3"
    alias: "Cybersecurity - A3"
    teacher_owner: "jlong"

    course_code: "cyb"
    course_name: "Cybersecurity"
    day: "A"
    block: 3

    section_code: 213
    student_count: 24

    proxmox:
      student_group: "grp-stu-jlong-cyba3"
      teacher_group: "grp-teach-jlong-cyba3"
      shared_pool: "sec-jlong-cyba3"
```

### `data/slots.yml`

Global VM slot policy.

This file defines the fixed set of VM roles used per student and teacher lab set.

Each slot defines:

* slot index
* template name
* CPU
* RAM
* disk size

Current slots:

* `atk`
* `win`
* `srv`
* `vic`
* `www`

### `data/policy.yml`

Global platform policy.

This file defines:

* VM offset ranges
* username generation policy
* password generation policy
* pool naming policy
* VM naming policy
* VMID formula
* network formula

This file is global because these rules apply across all sections unless explicitly changed later.

### `data/environments/<environment>.yml`

Environment-specific deployment mapping.

Examples:

* `data/environments/school-lab.yml`
* `data/environments/thinkcentre-lab.yml`

These files define:

* Proxmox API endpoint and default node
* section-to-node mapping
* unique VNet names
* subnet, gateway, and DHCP range

These files contain no student-specific data.

## Naming model

### Teacher key

A short unique teacher key, such as:

* `jlong`
* `asmith`

### Teacher ID

A three-digit namespace root used in VMID and network formulas.

Examples:

* `101`
* `102`

### Section key

A unique teacher-owned section instance key.

Format:

* `<teacher>-<section>`

Examples:

* `jlong-cyba3`
* `jlong-itsb3`
* `jlong-icsa1`

### Display section

A shorter human-facing section label.

Examples:

* `cyba3`
* `itsb3`
* `icsa1`

### Course codes

Recommended course identifiers:

* `ics` = Intro to Computer Science
* `its` = IT & Security
* `cyb` = Cybersecurity

## VM role model

Each student receives a five-VM lab set.

### Slot order

* `atk` = 0
* `win` = 1
* `srv` = 2
* `vic` = 3
* `www` = 4

### Slot purpose

* `atk`: student attack box
* `win`: Windows workstation or victim VM
* `srv`: Debian server VM
* `vic`: vulnerable target VM
* `www`: Debian web-facing server VM

Teachers use the same slot model for demo and support systems.

## VM offset policy

Global offsets are defined in `policy.yml`.

Current ranges:

* teacher/demo/admin: `10-49`
* shared infra/services: `50-99`
* student VM space: `100-199`
* overflow/test: `200-253`

These are global platform rules, not per-section data.

## VMID policy

### Formula

```text
vmid = teacher_id * 1000000 + section_code * 1000 + offset
```

### Meaning

* first three digits: teacher namespace
* next three digits: section code
* last three digits: local VM offset

### Example

For:

* `teacher_id = 101`
* `section_code = 213`
* student offset `100`

The VMID is:

```text
101213100
```

### Teacher VM examples

For teacher index `0` and section `jlong-cyba3`:

* `101213010` = teacher `atk`
* `101213011` = teacher `win`
* `101213012` = teacher `srv`
* `101213013` = teacher `vic`
* `101213014` = teacher `www`

### Student VM examples

For student index `0` in the same section:

* `101213100` = student `atk`
* `101213101` = student `win`
* `101213102` = student `srv`
* `101213103` = student `vic`
* `101213104` = student `www`

## Network policy

### Formula

```text
10.<teacher_id>.<section_code>.0/24
```

### Meaning

* second octet: teacher ID
* third octet: section code
* fourth octet: host address

### Example

For teacher `101` and section `213`:

```text
10.101.213.0/24
```

Gateway:

```text
10.101.213.1
```

Default DHCP range:

* start: `.100`
* end: `.199`

### Why `/24`

The platform intentionally uses `/24` section networks for readability and classroom simplicity rather than maximum address efficiency.

### VNet naming

Because Proxmox SDN object names have tighter naming limits than the rest of the model, environment files may use compact VNet identifiers.

Example:

* section `jlong-cyba3`
* VNet `t101c213`

This preserves a clean deterministic relationship between teacher ID, section code, and network object naming.

## Proxmox authorization model

### Student access

Each generated student receives:

* a Proxmox account in the `pve` realm
* a personal pool named from policy
* ACLs granting access only to that personal pool

### Teacher access

Each teacher receives:

* a Proxmox account
* teacher-specific section groups
* access to teacher/shared section pools
* optional future access to student pools in sections they own

### Group naming

Current policy uses teacher-scoped groups.

Examples:

* student group: `grp-stu-jlong-cyba3`
* teacher group: `grp-teach-jlong-cyba3`

### Pool naming

Current policy:

* student pool: `stu-<username>`
* teacher shared pool: from `sections.<section>.proxmox.shared_pool`

## Runtime-generated artifacts

The following data is generated at runtime and must not be committed:

* pseudonymous student usernames
* initial passwords
* per-student pool assignments
* printable student credential exports
* generated roster mapping artifacts

These should live under `private/`.

### Example runtime student record

```yaml
students:
  - username: "cyba3-raven-01"
    section: "jlong-cyba3"
    student_index: 0
    proxmox_pool: "stu-cyba3-raven-01"
    initial_password: "MapleRiver42"
```

## Authoritative vs derived data

### Authoritative

* `teachers.yml`
* `sections.yml`
* `slots.yml`
* `policy.yml`
* one selected environment file

### Derived

* student usernames
* student passwords
* personal pool names
* VM names
* VMIDs
* section subnet assignments in generated inventory if needed
* teacher and student runtime exports

## Current phase-one scope

This data model is optimized for phase one:

* one or a few teachers
* one school deployment
* generated pseudonymous student identities
* deterministic VMIDs and networks
* Proxmox-based student access
* teacher demo and support workflows

Future phases may add:

* external identity providers
* multi-school tenancy
* more advanced network segmentation
* richer roster import/export workflows

## Known conventions

### Section key pattern

`<teacher>-<display_section>`

### Username pattern

Defined by policy as:
`<section>-<codename>-<nn>`

Examples:

* `cyba3-raven-01`
* `itsb3-otter-02`

### VM name pattern

Defined by policy as:
`<username>-<slot>`

Examples:

* `cyba3-raven-01-atk`
* `cyba3-raven-01-win`

## Implementation note

Automation should consume authored source-of-truth files first, then generate per-run private artifacts before applying infrastructure changes.

Recommended pipeline:

1. read `teachers.yml`, `sections.yml`, `slots.yml`, `policy.yml`, and environment file
2. generate runtime student identities and passwords
3. write private exports into `private/`
4. use generated artifacts as input to OpenTofu and Ansible where needed

