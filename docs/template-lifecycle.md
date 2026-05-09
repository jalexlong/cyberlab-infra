# Template Lifecycle

This project uses a staged template model:

- **prepared VM**: a buildable VM shell or imported image that is not yet trusted
- **finalized VM**: a configured VM that has been booted, reached, and cleaned for template use
- **golden template**: a promoted template in the `900-949` range
- **validation clone**: a disposable test clone in the `950-999` range

This prevents automation from mass-deploying broken images while avoiding a separate long-lived pre-promotion VMID range.

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

- automation
- validation
- stability
- repeatability

---

## Lifecycle states

### 1. Prepare template VM

Automation creates or imports a VM from the template catalog.

At this stage the VM is not trusted for deployment. It may use temporary bootstrap networking, temporary cloud-init settings, imported disks, installer media, or other build-only configuration.

For Debian 13, the prepare stage uses the provisioning network and static bootstrap address defined in `ansible/vars/templates.yml`.

### 2. Finalize template VM

Automation boots and configures the prepared VM until it is suitable for template promotion.

Finalization may include:

- validating boot behavior
- validating console or SSH access
- validating guest networking
- applying cloud-init behavior where supported
- installing or confirming guest-agent behavior where expected
- cleaning host keys, machine identity, cache files, and build-time state
- restoring clone-default networking to DHCP before promotion

A finalized VM is still not a classroom source until it is promoted.

### 3. Promote golden template

After finalization, automation promotes the VM into the golden template range.

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

Only promoted golden templates should be consumed by downstream deployment automation.

### 4. Validate with scratch clone

After promotion, automation should create a disposable validation clone from the golden template.

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

Validation clones prove that the promoted template can be cloned, booted, networked, and accessed safely before classroom rollout.

### 5. Consume golden template

Classroom/lab workloads may be deployed only from validated golden templates.

Deployment automation must not use prepared VMs, finalized-but-unpromoted VMs, or validation clones as source images.

---

## Validation policy

### All templates must pass

- boot
- console or SSH access, depending on template type
- login
- DHCP on the target clone-default network
- gateway reachability

### Linux templates should also pass

- correct NIC naming
- cloud-init behavior if applicable
- guest agent detection if expected
- clean machine identity before promotion
- clean SSH host keys before promotion

### Windows templates should also pass

- stable boot/reboot
- storage and network drivers working
- no immediate driver-related BSOD for required devices
- clone behavior suitable for classroom deployment

---

## Test deployment rule

A newly promoted golden template should first be deployed into a small smoke test before full section rollout.

Recommended smoke test:

- 1 teacher VM set
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
- clone-default networking should return to DHCP before promotion

---

## Source of truth

Template metadata lives in:

- `ansible/vars/templates.yml`

VMID policy lives in:

- `data/bootstrap-policy.yml`

Golden templates are referenced by deployment automation only after validation.

---

## Operational principle

**Automate preparation. Validate before and after promotion. Deploy from golden templates only.**
