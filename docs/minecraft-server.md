# Minecraft Server Program

School-sanctioned Minecraft servers that approved students reach from the public
internet, doubling as a hands-on environment for learning server administration.

This is a separate program from the cyberlab, sharing the same hardware. It runs
on `pve2`; the cyberlab runs on `pve1`.

---

## Guiding principle

**Nothing on the school side accepts an inbound connection.** The tunnel is
dialed outbound from inside, the same model the website's `cloudflared` tunnel
already uses. Access control is identity-based — a verified Minecraft account
plus a whitelist — never IP-based, because students connect from home networks,
phones and carrier NAT.

Students administer their own servers. They never touch the tunnel, the proxy,
the edge firewall, or the hypervisors.

---

## Architecture

```
internet ──(outbound Minekube Connect tunnel)──> Gate ──> Paper backends
                                                          (bound to 127.0.0.1)
```

| Component | Choice | Why |
|---|---|---|
| Tunnel | Minekube Connect (hosted) | Outbound-only, no firewall changes |
| Front door | Gate proxy, Connect enabled | One place for tunnel, auth and routing |
| Backends | Paper, loopback-bound | Never directly reachable from outside |
| Identity | Gate `onlineMode: true`; Paper `online-mode=false` + Velocity modern forwarding | Gate authenticates with Mojang and forwards a signed identity; Paper trusts only that |
| Whitelist | Paper `white-list=true`, `enforce-whitelist=true` | Meaningful *because* forwarding prevents username spoofing |

### The identity pairing is the part to get right

`online-mode=false` on a Paper backend does **not** mean authentication is
skipped. It means the backend delegates authentication to Gate and accepts only
identities carrying Gate's Velocity forwarding signature. Binding the backend to
`127.0.0.1` is what makes that safe.

Getting this pair wrong in the other direction — a backend reachable from the
network *and* `online-mode=false` — would let anyone join as any username, which
makes the whitelist worthless. The two settings are a pair; do not change one
without the other.

---

## Provisioning

The server is built by the server catalog, not by hand.

```bash
cd ansible
ansible-playbook -i inventory.yml playbooks/controller-provision-server.yml \
  -e server_name=mc-gate
```

From a workstation rather than the controller, add the key overrides the
inventory does not carry:

```bash
  -e ansible_ssh_private_key_file=$HOME/.ssh/claude-key \
  -e server_ssh_private_key=$HOME/.ssh/claude-key
```

This clones the `debian13-pve2` golden template, applies the resource shape from
`ansible/vars/servers.yml`, and runs the role at
`ansible/tasks/server-roles/minecraft.yml` against the guest.

It requires the template to exist first:

```bash
ansible-playbook -i inventory.yml \
  playbooks/controller-build-template-pipeline.yml -e template_name=debian13-pve2
```

### Two things provisioning will not do for you

**It will not start Gate.** Starting Gate opens the Connect tunnel, which is the
moment the server becomes reachable from the internet. The role leaves the unit
`enabled` but stopped. Start it deliberately:

```bash
systemctl start gate
```

or pass `-e mc_start_gate=true` when you mean it.

**It will not supply `connect.json`.** That file holds the endpoint token, is a
credential, and is never committed. Place it at
`/opt/minecraft/gate/connect.json`, mode `600`, before the tunnel will
authenticate.

---

## Versions, and how they were chosen

Checked against the upstream APIs on 2026-09-24 rather than assumed.

| Thing | Value | Note |
|---|---|---|
| Gate | v0.74.11 | The current release; asset `gate_0.74.11_linux_amd64` |
| Paper | 26.2, build resolved at install time | The only version still marked `SUPPORTED` |
| Java | `openjdk-25-jre-headless` | Paper 26.2 declares `java.version.minimum: 25` |

**Java 25, not 21.** This corrects the assumption the project started from.
Every Paper version that runs on Java 21 is already end-of-life — 1.21.11's
support ended 2026-06-15, 26.1.2's ended 2026-07-26. Running a student-facing
server on an unsupported branch to avoid a Java bump would be the wrong trade.
`openjdk-25-jre-headless` is in Debian 13 trixie proper, so this needs no
backport and no third-party repository.

**Paper 26.3 exists and is channel `ALPHA`.** The role asserts the resolved
build is `STABLE` and fails otherwise, so a future version bump cannot silently
put students on an alpha.

**The PaperMC v2 API is gone** — it returns `410`. The role uses
`https://fill.papermc.io/v3/`, which also yields a SHA-256, so the jar is
verified rather than trusted.

---

## Ports

| Port | Use |
|---|---|
| 25565/tcp | Gate local listener, LAN testing only. The Connect tunnel does not need it |
| 25567 | Reserved: Gate's Geyser listener when Bedrock is enabled |
| 19132/udp | Reserved: Bedrock clients, if ever served directly |
| 30066/tcp | `lobby` Paper backend, bound to `127.0.0.1` |
| 30067+ | Student backends, assigned sequentially |

The 30066 start is convention, not requirement: it sits clear of the
25565–25567 range Minecraft, Gate and Geyser use by default. Any unused port
works as long as the catalog's backend entry and the backend's `server-port`
agree — both are written from the same catalog value, so they cannot drift.

---

## Adding a backend

Add an entry under `role_vars.backends` in `ansible/vars/servers.yml` and re-run
the provisioning playbook. The templated `paper@.service` unit means a new
backend needs a directory and a catalog entry, not a new unit file.

The Velocity forwarding secret is generated once, stored at
`/opt/minecraft/forwarding.secret` mode `0600`, and reused. It is never
regenerated on a re-run — doing so would break every backend at once, since Gate
and Paper must agree on it exactly.

The whitelist is seeded empty and then left alone (`force: false`), so players
added through the console survive a re-provision.

---

## Not done yet

These are open and matter in roughly this order.

1. **District IT sign-off**, before any student is admitted. A persistent
   outbound tunnel bypasses the perimeter by design, which is exactly what
   network policy governs. Building the VM does not require sign-off; admitting
   students does.
2. **A neutral Connect endpoint name.** The endpoint is public — it is part of
   the address players type. `role_vars.connect_endpoint` is deliberately
   unset (`CHANGE-ME`) and the role refuses to run until it is set.
3. **VLAN segmentation.** `pve2` has no firewall enabled and a flat network, so
   any guest can currently reach the Proxmox and iDRAC management interfaces.
   The VM may test on the flat network but must move to its own VLAN before
   students are admitted.
4. **Backups.** `pve2` is a single non-redundant SSD carrying Proxmox, the live
   website, and this server. Proxmox Backup Server on `pve1` is the plan.
5. **Bedrock** via Gate's Geyser, after Java is proven end to end.
6. **Roster-driven whitelist sync** — student submits a username, teacher
   approves, a script regenerates the whitelist. A good student project.
7. **Pelican Panel** for most students, Proxmox LXC for advanced ones.

## Compliance

Minecraft usernames tied to real students fall under FERPA. Students under 13
bring COPPA and parental consent into scope. Chat logs are retained for
moderation, and CoreProtect is planned for grief rollback. Students need
personal Java or Bedrock accounts — Minecraft Education cannot join these
servers.
