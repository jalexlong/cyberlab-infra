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

### Gate and the tunnel

**Provisioning will not start Gate unless asked.** Starting Gate opens the
Connect tunnel, which is the moment the server becomes reachable from the
internet. The role leaves the unit `enabled` but stopped unless you pass
`-e mc_start_gate=true`. A re-run never stops a running Gate, and a config
change restarts Gate only if it is already running (`systemctl try-restart`),
so the flag matters only for the first start.

**Gate writes `connect.json` itself** on first registration of an unclaimed
endpoint name, at `/opt/minecraft/gate/connect.json`. That file is the endpoint
credential, and Gate writes it world-readable, so the role forces mode `600` on
every run. It is never committed.

### Re-running is safe

Re-running provisioning against an existing server keeps its NIC MAC address,
so its DHCP lease survives, and leaves Paper alone unless something the role
owns has changed. Paper expands `server.properties` and
`config/paper-global.yml` with its full defaults at startup, so the role sets
individual keys rather than writing either file: `server.properties` key by
key, and `paper-global.yml` merged and compared as data. A second run in a row
reports no changes and restarts nothing. Keys the role does not own can be
edited by hand and survive.

---

## Versions, and how they were chosen

Checked against the upstream APIs on 2026-09-24 rather than assumed.

| Thing | Value | Note |
|---|---|---|
| Gate | v0.74.11 | The current release; asset `gate_0.74.11_linux_amd64` |
| Paper | 26.2, build resolved at install time | The only version still marked `SUPPORTED` |
| Java | `openjdk-25-jre-headless` | Paper 26.2 declares `java.version.minimum: 25` |
| ViaVersion | 5.12.0, from Modrinth | Lets newer clients join; see below |

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

**ViaVersion is how new clients get in.** The vanilla launcher auto-updates
players to the newest Minecraft release, and Paper's build for a new release
stays `ALPHA` for weeks — 26.2 took six from first build to `STABLE`. Without a
translation layer, every Minecraft release locks everyone out until Paper
catches up; 26.3 did exactly that on 2026-09-28. ViaVersion runs on each
backend and lets clients newer than the server join it.

Plugins come from the `modrinth_plugins` list in the catalog, pinned by version
and held to the same bar as Paper: the role requires a `release` build that
loads on Paper and lists the server's Minecraft version, and verifies the
SHA-512. Each lands as `plugins/<slug>.jar`, so a bump replaces the old jar.
Removing an entry does not delete its jar.

---

## Ports

| Port | Use |
|---|---|
| 25565/tcp | Gate local listener, LAN testing only. The Connect tunnel does not need it |
| 25567 | Reserved: Gate's Geyser listener when Bedrock is enabled |
| 19132/udp | Reserved: Bedrock clients, if ever served directly |
| 30066/tcp | `lobby` Paper backend, bound to `127.0.0.1` |
| 30067+ | Student backends, assigned sequentially |
| 31066+ | RCON for each backend, at its game port + 1000, bound to `127.0.0.1` |

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

If it is exposed — printed in a terminal, pasted into a chat, committed — rotate
it deliberately, which rewrites Gate and every backend in one run and restarts
them together. Anyone online is disconnected and can rejoin straight away:

```bash
ansible-playbook -i inventory.yml playbooks/controller-provision-server.yml \
  -e server_name=mc-gate -e mc_rotate_forwarding_secret=true
```

`/opt/minecraft/gate/config.yml` contains the secret, so do not `cat` it in a
shared or recorded session. Rotated 2026-09-28 after exactly that.

The whitelist is seeded empty and then left alone (`force: false`), so players
added over RCON survive a re-provision.

---

## Administering a running backend

Each backend has RCON enabled on loopback, with a password generated once into
`/opt/minecraft/rcon/<backend>.password` (root, `0600`) and written into that
backend's `server.properties`. RCON is plaintext; binding to the backend's
loopback `server-ip` is what makes it acceptable.

The client is `rconclt` from Debian's `rcon` package. The role writes
`/etc/rcon.conf` (root, `0600`) with one section per backend, generated from the
same password files, so the section name is the backend name. Run it as root:

```bash
rconclt lobby whitelist add SomePlayer
rconclt lobby whitelist list
rconclt lobby list
```

Run as any other user it fails with `No such server: lobby`: the config file is
unreadable to them, and `rconclt` silently skips config files it cannot open.

`whitelist add` by name stores the account's real Mojang UUID, not an
offline-mode one: Paper resolves profiles as online because Velocity forwarding
runs in online mode. Checked 2026-09-28 against Mojang's API.



---

## Whitelist requests

Students request access through a Google Form. Its response Sheet runs
`scripts/minecraft-whitelist-form.gs`, which looks up each Java username with
Mojang and fills in the account's UUID and canonical name. Nothing is approved
automatically.

**Keep the form and Sheet in the district Google Workspace, shared with no one.**
They link real students to Minecraft accounts, which is FERPA-covered, and none
of it belongs in this repository.

### The form

Settings: *Responses → Collect email addresses → Verified*, and restrict
responses to the district domain. Signing in identifies the student, so the form
needs no name field.

| Question | Type | Notes |
|---|---|---|
| `Which edition of Minecraft do you play?` | Multiple choice, required | `Java Edition (PC/Mac)`, `Bedrock Edition (console, phone, Windows store)` |
| `Minecraft Java username` | Short answer, required | Response validation: regular expression, matches `^[A-Za-z0-9_]{3,16}$` |
| `Class period` | Dropdown, optional | Whatever helps you match rows to classes |

Help text for the username question — this is the mistake that actually
happens, so say it plainly:

> The name shown in the top corner of the Minecraft Launcher, or on your
> profile at minecraft.net. It is 3–16 letters, numbers or underscores with no
> spaces. It is **not** your Xbox or Microsoft gamertag.

Question titles must match the `QUESTION_` constants at the top of the script
exactly; the script stops with an error naming the one it cannot find.

### Setting up the Sheet

1. From the form's *Responses* tab, link it to a new Sheet.
2. In the Sheet, *Extensions → Apps Script*, paste the script, save.
3. Run `installTrigger` once from the editor and accept the permission prompt.
   It installs the submit trigger and adds the `UUID`, `Canonical name`,
   `Lookup status`, `Checked at` and `Approved` columns.
4. Reload the Sheet. A *Whitelist* menu appears.

`Lookup status` is one of `OK`, `Not a Java username`, `No such Java account`,
`Bedrock: not supported yet`, `Duplicate of row N`, or a transient failure.
Apps Script fetches from Google's shared addresses, which Mojang may rate-limit;
*Whitelist → Recheck unresolved rows* retries only the transient ones.

### Approving

A lookup proves the account exists, not that the student owns it. The strong
check is a refused join: ask the student to try `mc.farmcardscode.org` once, and
the lobby log records their verified identity:

```
UUID of player ExamplePlayer is 00000000-0000-4000-8000-000000000000
Disconnecting ExamplePlayer (...): You are not whitelisted on this server!
```

```bash
grep -E "UUID of player|not whitelisted" /opt/minecraft/servers/lobby/logs/latest.log
```

Tick *Approved* for rows whose UUID matches, then *Whitelist → Export approved
as rconclt commands*.

### Applying the whitelist

The export is one `rconclt` line per approved player. Paste them into a root
shell on the server; no restart, players already listed are untouched, and
re-adding someone is harmless:

```bash
ssh cyberlab@<mc-gate address>
sudo -i
rconclt lobby whitelist add ExamplePlayer
rconclt lobby whitelist list
```

Removing a player is `rconclt lobby whitelist remove <name>`; unticking
*Approved* in the Sheet does not remove anyone.

---

## Not done yet

These are open and matter in roughly this order.

1. **District IT sign-off**, before any student is admitted. A persistent
   outbound tunnel bypasses the perimeter by design, which is exactly what
   network policy governs. Building the VM does not require sign-off; admitting
   students does.
2. **VLAN segmentation.** `pve2` has no firewall enabled and a flat network, so
   any guest can currently reach the Proxmox and iDRAC management interfaces.
   The VM may test on the flat network but must move to its own VLAN before
   students are admitted.
3. **Backups.** `pve2` is a single non-redundant SSD carrying Proxmox, the live
   website, and this server. Proxmox Backup Server on `pve1` is the plan.
4. **Bedrock** via Gate's Geyser, after Java is proven end to end.
5. **Roster-driven whitelist sync.** The request form and lookup exist (see
   Whitelist requests); pushing approved rows to the server automatically
   waits on RCON. A good student project.
6. **Pelican Panel** for most students, Proxmox LXC for advanced ones.

## Compliance

Minecraft usernames tied to real students fall under FERPA. Students under 13
bring COPPA and parental consent into scope. Chat logs are retained for
moderation, and CoreProtect is planned for grief rollback. Students need
personal Java or Bedrock accounts — Minecraft Education cannot join these
servers.
