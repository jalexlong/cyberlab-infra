# Template Lifecycle

This project uses a two-stage template model:

- **candidate templates** are newly built and not yet trusted for lab deployment
- **approved templates** are validated and safe for OpenTofu to consume

This prevents automation from mass-deploying broken images.

---

## Why this exists

Home-lab testing showed that automation can successfully build and deploy infrastructure while still propagating bad assumptions:

- unvalidated imported images
- incomplete cloud-init behavior
- missing DHCP/network verification
- guest agent assumptions
- boot/display/controller mismatches

The school-lab demonstrated the opposite pattern:

- validated templates
- known-good SDN/DHCP behavior
- smoother VM rollout

The goal of this lifecycle is to combine both strengths:

- **automation**
- **stability**

---

## States

### Candidate
A candidate template is an image that has been:

- downloaded or imported
- installed if needed
- prepared enough to boot

But it has **not yet passed validation**.

Candidate VMIDs live in the `89xx` range.

Examples:
- `8901` parrot-candidate
- `8902` win7-candidate
- `8903` debian13-candidate
- `8904` metasploitable2-candidate

### Approved
An approved template is a candidate that has passed validation and is safe for section deployment.

Approved VMIDs live in the `90xx` range.

Examples:
- `9001` parrot-template
- `9002` win7-template
- `9003` debian13-template
- `9004` metasploitable2-template

Only approved templates should be referenced by OpenTofu environment files.

---

## Lifecycle

### 1. Build candidate
Automation creates or imports a candidate VM.

Examples:
- import qcow2 image
- import VMDK
- create installer-based VM shell
- perform manual OS install if needed

### 2. Validate candidate
Before promotion, the candidate must pass its validation checklist.

Typical checks:
- boots cleanly
- console works
- login works
- NIC appears
- DHCP works on a test VNet
- default route is present
- gateway ping works
- guest agent works if required
- cloud-init works if required

### 3. Promote candidate
Once validated, the candidate is promoted to its approved template identity.

Promotion may be done by:
- converting the validated candidate to template form
- cloning/moving it to the approved VMID
- renaming it to the approved template name

### 4. Consume approved template
OpenTofu and downstream automation may only use approved templates.

---

## Validation policy

### All templates must pass
- boot
- console
- login
- DHCP on a test VNet
- gateway reachability

### Linux templates should also pass
- correct NIC naming
- cloud-init behavior if applicable
- guest agent if expected

### Windows templates should also pass
- stable boot/reboot
- storage/network drivers working
- no immediate driver-related BSOD for required devices

---

## Test deployment rule

A newly approved template should first be deployed into a **small smoke test** before full section rollout.

Recommended smoke test:
- 1 teacher VM
- 1 student
- 2 to 3 slots only

Example:
- `jlong-srv`
- `cyba3-raven-01-srv`
- `cyba3-raven-01-atk`

Only after smoke test success should a full section deployment proceed.

---

## SDN rule

Creating SDN objects is not enough.

Validation must confirm:
- zone exists
- VNet exists
- subnet exists
- DHCP range exists
- dnsmasq is serving
- DHCPDISCOVER receives DHCPOFFER

---

## Cloud image rule

Cloud images are not equivalent to fully installed lab templates.

When using cloud images:
- cloud-init must be explicitly configured
- DHCP behavior must be tested
- guest access must be verified
- image suitability must be validated before promotion

---

## Source of truth

Template metadata lives in:

- `data/templates.yml`

Approved templates are referenced in environment and slot mappings only after validation.

---

## Operational principle

**Automate build. Validate before promotion. Deploy approved images only.**

