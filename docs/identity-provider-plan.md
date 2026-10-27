# Identity provider: Keycloak for the cyberlab

A plan for a Keycloak server of the cyberlab's own, on `pve1`, as **the** way
teachers and the administrator sign in to the platform: Proxmox (an OpenID
Connect realm) now, Guacamole when Phase 6 builds it.

**Written:** 2026-10-27
**Status:** **a plan, nothing built.** No playbook, no data file, no VMID has
changed. It **replaces a decision**: the roadmap deferred an identity provider
until a district required federation. On 2026-10-27 the administrator decided
otherwise: Keycloak is the main way in to the cyberlab's infrastructure,
**required, part of every install**, not an option. `docs/roadmap.md`
("Identity provider") records the change and points here.

---

## Why

- **It secures the infrastructure.** Passwords, second factors, lock-outs
  and who-belongs-to-what in one place, instead of a local password per
  Proxmox account (`proxmox-users.yml` today) and, later, another per
  Guacamole account. A second teacher (`asmith` in `data/teachers.yml`) gets
  one account, not one per system.
- **The same stack as the school's services.** `pve2` runs a Keycloak for
  school staff (its `auth.md` in school-services-infra). The administrator
  runs both, and learns one stack, not two.
- **It is the shape the roadmap already expected.** Guacamole's OIDC
  extension layers on its DB auth; a district's own directory, if one is
  ever wanted, is brokered in Keycloak. Neither needs a redesign.

### The roadmap's reasons to wait, answered

| Reason given | Now |
|---|---|
| Keycloak wants ~2 GB, real money on a 16-32 GB node | An unprivileged LXC with no Docker (below): no second kernel, and its RAM capped to what it uses. Small enough for a future appliance on its own hardware |
| OIDC pushes toward HTTPS, and an offline box has no public CA | A public certificate, issued through Cloudflare's DNS and installed on the node (below). Renewal needs the internet; that is the part still open for an offline appliance |
| No district needs federation at pilot scale | Still true, and no longer the reason: this is for securing our own infrastructure |

---

## Separate from `pve2`'s Keycloak, entirely

Not a realm on the staff server. Two servers, nothing shared: no database, no
admin account, no realm, no network path, no upgrade schedule.

| | `pve2` (school services) | `pve1` (cyberlab) |
|---|---|---|
| Secures | the school's services and their infrastructure | the self-contained cyberlab platform |
| Guest | a VM: public, so the hardest boundary | an unprivileged LXC: internal only, behind its own firewall, and light enough for an appliance |
| Reached | publicly, through Cloudflare tunnels (`auth.farmcardscode.org`) | **internally only**, on the school LAN; never published, never through a tunnel |
| Depends on the internet | yes | **no**: the platform must sign in with the uplink down |

- **Two service domains** (`pve1` and `pve2` "are not clustered — decided:
  two service domains", `docs/roadmap.md`). Identity is the most
  load-bearing thing a domain has; sharing it would cross them.
- **Different people, different threat model.** The staff server holds
  district staff and must never hold a student. The cyberlab is where
  students attack things by design; its identity server sits next to that,
  and a mistake here must not reach staff sign-in.
- **A realm separates less than it looks.** Realms keep users and clients
  apart, but share one process, one database, one master-realm administrator
  and one upgrade.
- **The appliance must carry its own.** A unit in another district cannot
  depend on `auth.farmcardscode.org`.
- **One benefit of having two:** this one can take each Keycloak upgrade
  first, a week before the staff server.

---

## Who signs in where

| Person | Proxmox | Guacamole (Phase 6) | Keycloak account |
|---|---|---|---|
| Administrator | through the `cyberlab` realm (`root@pam` kept as break-glass) | through Keycloak | yes, with a second factor |
| Teacher | through the `cyberlab` realm, to their sections' pools | through Keycloak, their sections | yes, with a second factor |
| Student | **never** (the roadmap retired per-student Proxmox identity) | Guacamole DB auth, for now | **not yet** (below) |
| Automation (`cyberlab-automation@pve`) | API token, unchanged | REST API, unchanged | no |

Students stay on Guacamole's DB auth, with the pseudonymous accounts the
control plane generates (`<section>-<codename>-<nn>`). Moving them is a
separate decision with its own conditions ("Later", below).

---

## Proxmox's OpenID Connect realm

Proxmox VE supports an OpenID Connect realm natively (*Datacenter ›
Permissions › Realms › Add › OpenID Connect Server*, or `pveum realm add`):
it discovers the provider from its issuer URL, can create users at first
sign-in, and can take group membership from a claim. It becomes the
**default** realm on the sign-in page.

Settings, as a playbook would apply them:

| Option | Value | Why |
|---|---|---|
| realm | `cyberlab` | users become `jlong@cyberlab` |
| `issuer-url` | `https://<keycloak>/realms/cyberlab` | |
| `client-id` / `client-key` | `proxmox` / generated secret | a confidential client in Keycloak, secret root-only |
| `username-claim` | `username` | `jlong@cyberlab`, not an opaque subject ID |
| `autocreate` | on | a teacher Keycloak knows needs no `pveum user add` |
| `groups-claim` | `groups` | Keycloak's group-membership mapper puts them there |
| `groups-autocreate` | **off** | Proxmox groups, and their ACLs, stay made by code; a typo in Keycloak cannot invent one |
| `groups-overwrite` | **on** | a teacher removed from a group in Keycloak loses it in Proxmox at their next sign-in |
| `default` | on | the sign-in page offers this realm first |

**Group names.** Proxmox appends the realm to a claimed group's name: the
Keycloak group `grp-teachers` arrives as `grp-teachers-cyberlab`. So the
Proxmox groups the ACLs name become `grp-teachers-cyberlab` and
`grp-teach-<teacher>-<section>-cyberlab`, made by `proxmox-groups.yml` and
granted by `proxmox-acls.yml`, and the Keycloak groups are the names already
in `data/sections.yml` (`teacher_group`). An admin group (`grp-admins`) gets
`Administrator` on `/`.

**What Proxmox does not do:** it reads groups only at sign-in, and an open
web UI keeps renewing its own session ticket without asking Keycloak again.
Disabling someone in Keycloak stops their next sign-in, not the session they
already have. To cut someone off at once, also disable their Proxmox user
(`pveum user modify <user>@cyberlab --enable 0`); the playbook that removes a
teacher should do both.

**Break-glass, permanently:** `root@pam` keeps its password (on the offline
USB) and stays usable from the console and the school LAN. The `pam` and
`pve` realms are never removed, and no other `@pve` or `@pam` login is kept.
If Keycloak is down, its certificate expires or its clock drifts, Proxmox is
still reachable as root.

---

## The server

### Reusing the shape of school-services' `auth` role

| | School services (`pve2`) | Cyberlab (`pve1`), proposed |
|---|---|---|
| Guest | VM 509 | **an unprivileged LXC**, like the controller and the package cache; propose CTID `806`, added to the infrastructure assignments in `data/bootstrap-policy.yml` |
| Keycloak and PostgreSQL | Docker images, pinned | **Debian's PostgreSQL and Keycloak's release zip** (pinned, checksummed), no Docker: Docker in an LXC needs nesting, which loosens the container's confinement. The same versions as `pve2`'s; the factory vendors the zip and the package cache holds the packages, so nothing is fetched at a site |
| In front | nginx, two hostnames via Cloudflare tunnels | nginx on the school LAN only, with a public certificate issued through Cloudflare's DNS (below) |
| Admin console | its own hostname behind Cloudflare Access | its own port, which the firewall opens only from the management sources |
| Secrets | generated once, root-only, never printed; Keycloak's file vault | same |
| Configuration | community.general keycloak modules against `127.0.0.1`, signed in as the bootstrap client | same |
| Accounts | a staff list outside the repository | **`data/teachers.yml`**: teacher IDs and sections are already committed and are not student data; no addresses needed |
| Mail | Mailgun, for set-up links | **none.** A first password is generated, root-only, handed over on site, and must be changed (with an authenticator app) at first sign-in |
| Built by | the provisioning playbook from school-services' catalog | a controller playbook, `controller-bootstrap-identity.yml`, run from the controller by `scripts/install-cyberlab.sh` on **every** install, after the firewall and before anything that signs in through it |

The realm settings carry over unchanged in kind: registration off, brute-force
protection (temporary lock-outs, never permanent), a password policy, a second
factor required at first sign-in, sign-in events kept 30 days, short admin
sessions. Teacher sessions here can be short too (a working day): nothing
runs on a classroom board.

### Network position

The users are the administrator and teachers, on the school LAN, and
`pve1` itself, which fetches the issuer's keys and tokens. Students and pod
VNets must never reach it, and nothing outside the school reaches it at all.

- **Proposed: its own address on `vmbr0`,** like the controller, with a
  per-guest default-deny firewall written by
  `controller-bootstrap-firewall.yml`: inbound 443 from the school LAN
  (`10.64.62.0/23`), the admin port from the management sources only, SSH
  from the controller. Model A already puts the unit on the LAN; this is one
  more address on it.
- **Not on `svc0`.** The package cache is there because pods must reach it;
  this is the opposite.
- **No tunnel, no port forward, no public DNS.** Unlike `pve2`'s, this one
  is never published.
- **A new row in `controller-assert-isolation.yml`:** a pod guest reaching
  the identity server is *blocked*, on every port. It is the third
  infrastructure service on the box, and `docs/network-isolation.md` already
  warns that carve-outs arriving unexamined is how isolation becomes fiction.
- **Decide alongside Phase 6's access LXC**, which faces the same users. If
  Guacamole ends up behind a reverse proxy on the LAN, Keycloak can sit
  behind the same one instead of holding its own LAN address.

### Certificates and time

- **A public certificate, issued through Cloudflare.** `farmcardscode.org`'s
  DNS is on Cloudflare, so a certificate for the identity server's name can
  be issued by Let's Encrypt with a DNS challenge through Cloudflare's API:
  nothing is published and no port is opened. Proxmox, browsers and
  Chromebooks trust it with nothing installed, which also takes away the
  roadmap's block on ever moving students.
- **Not Cloudflare's Origin CA.** Its certificates are trusted only by
  Cloudflare's own proxy, which this server is never behind; Proxmox would
  refuse the issuer and every browser would warn.
- **Issued off the node, then installed.** The Cloudflare API token (DNS
  edit, this zone only) stays where the certificate is made (`pve1`'s own
  ACME client has a Cloudflare DNS plugin, or the administrator's machine);
  the identity server never holds it. A playbook copies the certificate and
  key in (key root-only) and reloads nginx.
- **The name must resolve on the LAN** to the container's address: an entry
  in the school's DNS, or a public record pointing at a private address
  (some resolvers refuse those; test from a teacher laptop and from `pve1`).
  The name is site data, not committed here.
- **Renewal needs the internet.** Let's Encrypt certificates last 90 days, with
  shorter lifetimes announced, so renewal is automated and needs the uplink every few
  weeks. Fine for the school's own unit. For an offline appliance at another
  district it is still open: that district's own domain and renewal, or a
  private CA after all.
- **Time.** OIDC tokens fail on a wrong clock. The container takes `pve1`'s
  clock; the roadmap's offline time source applies to this too.

### Backups and recovery

The identity server holds teacher accounts and second-factor secrets.
Include its CTID in whatever backs up the controller, and dump PostgreSQL
before each Keycloak upgrade. A lost identity server costs teachers their
sign-in until rebuilt, never the platform: `root@pam` and the automation
token do not depend on it (`docs/recovery.md` gains a line saying so).

---

## Later, each with its own decision

1. **A district's own directory** (district sale): Keycloak brokers to the
   district's Google or Microsoft sign-in, so teachers use their district
   accounts; the cyberlab's groups stay in Keycloak. The server is already
   there.
2. **Students in Keycloak**, only once Chromebooks can trust the certificate
   and only with the pseudonymous usernames the control plane generates: no
   email, no names, no SIS IDs (`tests/test_no_student_pii.py` would need to
   cover whatever the control plane hands Keycloak). Password resets would
   be the teacher's, in the admin console or through the control plane.

---

## Order of work

1. Record the decision in `docs/roadmap.md` (done with this page).
2. Reserve CTID `806` in `data/bootstrap-policy.yml`.
3. Choose the name; add its LAN DNS entry; issue its certificate through
   Cloudflare's DNS and set up renewal where the token lives.
4. Write `controller-bootstrap-identity.yml` (the unprivileged LXC,
   PostgreSQL, Keycloak from the vendored zip, nginx with the certificate,
   the realm, groups from `data/sections.yml`, accounts from
   `data/teachers.yml`, the `proxmox` client) and its firewall rows; run it
   from `scripts/install-cyberlab.sh` on every install.
5. Add the isolation row (pods to identity server: blocked) and run
   `controller-assert-isolation.yml`.
6. Add the `cyberlab` OIDC realm to Proxmox as the default, with
   groups-autocreate off and the `-cyberlab` group names made and granted by
   `proxmox-groups.yml` and `proxmox-acls.yml`. Sign in as the administrator
   through it; confirm `root@pam` still works.
7. Retire the local `@pve` teacher and admin accounts once each person has
   signed in through the realm.
8. Phase 6: Guacamole's OIDC extension, the same realm, a `guacamole` client.
9. Record it: `docs/recovery.md` (break-glass), `README.md`, and this page's
   status.
