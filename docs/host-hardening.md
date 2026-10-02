# Hardening pve1

pve1's management plane had the same gaps pve2's had on 2026-09-29: SSH
accepted passwords and root logins from anywhere, the web UI answered any
source the firewall let through, rpcbind listened on `0.0.0.0:111`, and no
account had two-factor. pve2 was hardened that day by `school-services-infra`;
this brings pve1 to the same standard.

**Status: written 2026-10-01, not yet applied.** The repository work was done
off site; everything below needs a wired and a wireless connection on campus.

---

## What changes

| Layer | Before | After | Where |
|---|---|---|---|
| Firewall, SSH / 8006 / ICMP | accepted from any source | from the `management` IP set only | `controller-bootstrap-firewall.yml` |
| sshd | passwords, root by password | keys only; `root` and `jlong` only; nobody from outside the management networks | `host-hardening.yml --tags access` |
| pveproxy (8006, 3128) | any source | management networks and loopback only | `host-hardening.yml --tags access` |
| rpcbind | listening on `:111` | stopped and masked, after checking for NFS | `host-hardening.yml --tags services` |
| fail2ban | none | web UI logins: 5 failures in 10 min bans that address for 15 min | `host-hardening.yml --tags fail2ban` |
| Two-factor | none | TOTP on `root@pam` and `jlong@pam` | by hand, in the web UI |

The management networks are declared once, in
`data/environments/school-lab.yml` under `proxmox.management_sources`: the
wired building LAN `10.64.62.0/23` and the school wireless `10.60.0.0/22`.
Whole subnets, because every administrator address is DHCP with no
reservations. The firewall, sshd and pveproxy all read that one list.

Three layers, each enough on its own to keep a non-management source out, so a
mistake in one is not an exposure.

**Not changed:** pve1's Proxmox users, groups, pools and the automation token.
On pve2 those were cluster-era leftovers and were removed; on pve1 they are
the cyberlab's data model.

### Things that must keep working, and are checked

- **Controller CT 800** logs in to pve1 as root by key and calls the API on
  8006. Both are checked from inside the container before either playbook
  disarms its dead-man switch. The firewall playbook also refuses to run if
  the address it arrives from is outside the management networks, so it
  cannot cut off the run writing the rules.
- **The administrator** logs in as root (claude-key) and jlong (ssh-agent) over
  wired and wireless, and reaches the web UI over both.
- **Lab guests** are unaffected: they were already dropped at the host
  (`IN DROP -source 10.101.0.0/16`) and filtered at their own taps.

### Also fixed: pve2 was in the blast radius

`proxmox_targets` lists pve2 so the template pipeline can build
`debian13-pve2`, but the SDN, firewall, package-cache and isolation-assertion
playbooks ran on every host in that group. `install-cyberlab.sh
--with-firewall` would have tried to write the cyberlab's `cluster.fw` over
pve2's (it would most likely have failed to log in, since pve2's root no
longer trusts the controller key). Each of those playbooks, and
`host-hardening.yml`, now ends on any node the environment file does not name.
`tests/test_firewall_policy.py` holds them to that.

---

## Applying it, on site

Both dead-man switches roll back after 10 minutes unless the run that armed
them verifies and disarms them. If a run dies part-way, wait out the timer
rather than fixing by hand.

1. **Update both checkouts.** pve1's `/root/cyberlab-infra` and CT 800's. They
   drift silently; check `git log -1` in each against `main`.
2. **Firewall, from CT 800.**
   ```sh
   cd /root/cyberlab-infra/ansible
   ansible-playbook -i inventory.yml playbooks/controller-bootstrap-firewall.yml --check --diff
   ansible-playbook -i inventory.yml playbooks/controller-bootstrap-firewall.yml
   ansible-playbook -i inventory.yml playbooks/controller-assert-isolation.yml
   ```
   Read the `--check --diff` first: the only host.fw change should be the
   three management rules gaining `-source +dc/management`, and cluster.fw
   gaining the `management` IP set.
3. **Host hardening, from the laptop, wired and wireless both connected**, with
   jlong's key in ssh-agent (`ssh-add -l`):
   ```sh
   cd ~/Code/cyberlab-infra/ansible
   K="-e ansible_ssh_private_key_file=$HOME/.ssh/claude-key"
   ansible-playbook -i inventory-platform.yml playbooks/host-hardening.yml $K --tags services
   ansible-playbook -i inventory-platform.yml playbooks/host-hardening.yml $K --tags access
   ansible-playbook -i inventory-platform.yml playbooks/host-hardening.yml $K --tags fail2ban
   ```
   The access run stops before changing anything if `/etc/default/pveproxy`
   already holds settings it does not manage (certificates, ciphers, a listen
   address), rather than deleting them.
4. **TOTP, in pve1's web UI.** *Datacenter -> Permissions -> Two Factor -> Add
   -> TOTP*, once for `root@pam` and once for `jlong@pam`. Same authenticator
   as pve2's, with descriptions that say which host. Log out and back in as
   each before closing the enrolment session.
5. **Record it here**: the date, and that each step passed.

### If it goes wrong

- **Locked out of SSH and the web UI from both networks:** wait 10 minutes for
  the dead-man switch. If it already disarmed, the iDRAC console
  (`idrac-f8m4282`, see school-services-infra `docs/idrac-hardening.md`) is the
  way in; remove `/etc/ssh/sshd_config.d/10-cyberlab.conf` and
  `/etc/default/pveproxy`, then restart `ssh` and `pveproxy`.
- **The controller can no longer reach pve1:** CT 800's address is outside the
  management networks. The playbooks check for this, but if its address changed
  after the run, either give it one inside `10.64.62.0/23` or add its network
  to `management_sources`.

---

## Accounts found on pve1, 2026-10-02

`root@pam`, `jlong@pam`, `jlong@pve`, `ansible@pam` and
`cyberlab-automation@pve`. No student accounts exist, so the per-student
Proxmox login the data model once described is not live anywhere. None had
two-factor before step 4.
