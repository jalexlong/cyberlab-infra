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

## Multi-node rule

The pipeline runs on more than one Proxmox node, and which node does the work is
decided by the **catalog**, not by the inventory.

Every stage runs against the whole `proxmox_targets` group and then ends the play
on any host that is not the entry's `target_node`. Adding a node to the inventory
therefore does not cause work to run on it; adding a catalog entry that names it
does.

This gate is load-bearing rather than cosmetic. `target_node` was present in the
catalog from the beginning and **read by nothing** — harmless only for as long as
`proxmox_targets` held exactly one host. Adding `pve2` without it would have
built every template on both nodes at once, and at the promote stage that is not
recoverable: `qm template` is irreversible.

### Each node needs its own build of the same image

`pve1` and `pve2` are **standalone nodes, not cluster members** — there is no
corosync configuration on either. A template promoted on one is invisible to the
other, and nothing can be cloned or migrated between them through the API.

So the same operating system appears as two catalog entries, one per node, rather
than one entry with two targets:

| Entry | Node | Network | Addressing |
|---|---|---|---|
| `debian13` | `pve1` | `prov0` | static `bootstrap_ip` |
| `debian13-pve2` | `pve2` | `vmbr0` | district DHCP |

### Two things differ per node, and both are catalog fields

**Where the SSH key comes from.** `pve1` keeps it inside controller CT `800`;
`pve2` has no such container, so the key is a file on the node. Selected by
`ssh_pubkey_source` (`controller_ct` or `host_file`).

**How the guest's address is found.** With a `bootstrap_ip` the address is known
before the guest boots. Without one it is discovered by
`scripts/discover-guest-ip.sh`, which resolves the guest's MAC to an IPv4 address
through the host's neighbour table.

Discovery cannot use the QEMU guest agent for a first build: Debian's
genericcloud image does not ship `qemu-guest-agent`, and the finalize stage is
what installs it. The script tries the agent first anyway, because it does work
on every later run, then falls back to the neighbour table, and only sweeps the
host's own subnets as a last resort.

---

## From template to running server

Promotion is not the end of the road. A golden template is a source image; a
running server is cloned from one and then specialised.

```
ansible/vars/templates.yml  ->  golden template  (VMID 900-949, per node)
ansible/vars/servers.yml    ->  running server   (VMID 500-599, cloned from one)
```

`ansible/playbooks/controller-provision-server.yml` clones a promoted template
into a server VMID, applies the resource shape from the server catalog, and hands
the guest to a role task file under `ansible/tasks/server-roles/`.

The provisioning playbook runs in two plays on purpose. The first runs on the
Proxmox node and does everything needing `qm`. The second runs against the guest
itself, so role task files use ordinary modules instead of the SSH heredocs the
finalize stage is forced into. Finalize has no choice — it runs while the guest
is still being cleaned for imaging. A provisioned server is a normal host and is
treated as one.

It asserts that a server and its template target the same node, because the
not-a-cluster constraint above would otherwise surface as a confusing
"template not found" on a node that is behaving correctly.

See `docs/minecraft-server.md` for the first role built on this.

---

## Source of truth

Template metadata lives in:

- `ansible/vars/templates.yml`

Server metadata lives in:

- `ansible/vars/servers.yml`

VMID policy lives in:

- `data/bootstrap-policy.yml`

Golden templates are referenced by deployment automation only after validation.

---

## Operational principle

**Automate preparation. Validate before and after promotion. Deploy from golden templates only.**
