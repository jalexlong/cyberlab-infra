# Handoff — two projects now, and the cache item is still owed

Continuing work in `/Users/jlong/Code/cyberlab-infra`. The 2026-09-24 session
ported the template pipeline to `pve2`, added a server-provisioning layer above
it, and built a live Minecraft server on top of that. It also narrowed the
project's scope and corrected three things the previous handoff had wrong.

**The cache item this handoff's predecessor was named for is still open.** It
was not worked on. Everything below the Minecraft section is inherited, still
accurate, and still the highest-value cyberlab work.

## Scope changed on 2026-09-24

Cyberlab is now for **your own district and your own classes** — same classes,
same subjects, same VMs, same cache, narrower audience. The prebuilt-SKU
material is parked, not deleted: the district-sysadmin question list, the BOM
and refurb-supply work (item 10), most of Phase 7. Items 6-9 are untouched by
this, because they are about whether the thing works.

This also settled the long-open question of what a deploy without the cache
does. **There are two build types** — one with the apt cache, one minimalist and
hardware-restricted. So the proxy baked into templates must be conditional on
the same signal as `install-cyberlab.sh --with-package-cache`. The conditional
is a product boundary, not a workaround.

## Reaching the hosts

    ssh -i ~/.ssh/claude-key root@10.64.62.200      # pve1 — cyberlab
    ssh -i ~/.ssh/claude-key root@10.64.62.201      # pve2 — school services

Neither resolves by name. Laptop-side playbook runs still need the key override,
because the inventory hardcodes the controller's path:

    cd ansible && ansible-playbook -i inventory.yml <playbook> \
      -e ansible_ssh_private_key_file=/Users/jlong/.ssh/claude-key

For `controller-provision-server.yml`, add `-e server_ssh_private_key=` with the
same path — the second play connects to the *guest*, not the node.

`host-bootstrap.yml` is still the exception: it targets `proxmox_hosts`, which is
`localhost` with `ansible_connection: local`, so it runs ON the node.

## Current state — measured 2026-09-24 unless noted

- `main` and `origin/main` are at **`cbac901`**. The feature branch is merged and
  deleted, locally and on origin.
- **The on-host checkouts are current.** `/root/cyberlab-infra` on `pve1` and
  CT `800`'s copy are both at `cbac901`, both clean, fast-forwarded 2026-09-24.
  They were five commits behind until then. CT `800` now carries the server
  catalog, both role task files and the discovery script, so the installer path
  can provision servers — and all four of its playbooks parse on its own
  `ansible-core 2.19.4`. **These drift silently and have twice been the thing
  that quietly broke an installer run; `git log -1` in the controller before
  trusting one.**
- Baseline: **505 collected tests**, all passing, plus `ruff`, `yamllint`,
  `shellcheck` and `ansible-lint` — the last at 0 failures / 0 warnings over 45
  files, `production` profile passing where only `basic` is required. Up from
  467/41 on 08-20.
- `pve1`: cache at **58 MB / 45 files** — still warming only by accident, up one
  file in a month. `chrony` Stratum 4, Leap Normal. CT `801` still has `net1`
  attached.
- **Both hosts rebooted unplanned around 2026-09-11.** Not a test — a site power
  event. The cache came back on its own with no hand-holding, which is better
  evidence for the reboot fix than the deliberate 08-19 cold boot was.
- Isolation: **17/17 carried forward from 2026-08-19, not re-measured this
  session.** Treat it as a claim needing re-verification, per the trap below.

### Three corrections to the previous handoff

- **`www.farmcardscode.org` is LIVE**, returning HTTP 200 on VM `500`. The note
  saying it was dark pending a GitHub Pages move was a month stale. The move
  never happened; the VM was simply brought back.
- **`pve2` was never bare.** It runs that website, and now two more guests.
- **`pve2` has 192 GB of RAM, not 128 GB.** The Minecraft handoff's hardware
  table is wrong.

## What `pve2` has now

    500  www-farmcardscode   running   the live website, cloudflared, HTTP 200
    501  mc-gate             running   Gate + Paper, tunnel up
    900  tpl-debian13        template  golden image, built and validated

`pve2` is **standalone, not clustered with `pve1`** — and that was reconsidered
this session and deliberately kept. The reasoning is now in `docs/roadmap.md`
under Cluster topology, with its own revisit triggers. The short version:
clustering would not remove the duplicate template (no shared storage means a
VMID per node either way), `pvecm add` refuses a node holding guests and `pve2`
holds a live website, and a two-node cluster has no quorum.

`pve2` carries **only** `debian13`. None of the cyberlab lab images are ever
built there.

## Minecraft — live, and nobody can join

`docs/minecraft-server.md` is the real reference. State as of 2026-09-24:

- VM `501` at `10.64.62.137`. Paper **26.2 build 129 on OpenJDK 25.0.4.1**.
- `paper@lobby` active on **127.0.0.1:30066 and nowhere else**. `gate` active,
  tunnel established.
- Verified by Minecraft server-list ping from the public internet at **both**
  `mc-gate.play.minekube.net` and `mc.farmcardscode.org`.
- **`whitelist.json` is `[]`** with `white-list` and `enforce-whitelist` true.
  The server is reachable and joinable by nobody. That is the safe intermediate
  state, deliberately.

**Java 25, not 21.** Paper 26.2 declares `java.version.minimum: 25` and is the
only version still marked `SUPPORTED`; every Java-21-era release is EOL. The
role asserts the resolved build is `STABLE`, because 26.3 exists and is `ALPHA`.

Owed next, in order: add your own account to the whitelist and confirm a
non-whitelisted account is refused; district IT sign-off before students are
admitted; VLAN segmentation; backups.

## Task 1 — bake the cache client config into the template images

Roadmap item 6. Unchanged and still the highest-value cyberlab work. The cache
warms **only by accident** — the 58 MB in it came from one hand-edited test
guest, not from normal use.

The work goes in `controller-finalize-template-vm.yml`, in the
`Finalize guest over SSH` heredoc. **It has two halves and neither is sufficient
alone** — measured, not theoretical:

1. **The proxy line.** `controller-bootstrap-package-cache.yml` already prints
   the exact string in its summary task:

       Acquire::http::Proxy "http://{{ cyberlab_cache_svc_ip }}:{{ cyberlab_cache_port }}";

2. **The sources rewrite.** Debian 13's cloud image ships
   `URIs: mirror+file:///etc/apt/mirrors/debian.list`, resolving to
   `https://deb.debian.org`. `apt-cacher-ng` answers HTTPS with
   `403 CONNECT denied`, and a CONNECT tunnel would be opaque to caching anyway.
   **Measured: with the proxy set and https sources, `apt-get update` fails
   outright and the cache stays at zero files.** Sources must become plain
   `http://` with `mirror+file` replaced by a concrete host. With both halves
   done, the same test cached 28 objects / 24 MB on first use.

   Dropping to `http` is not a downgrade — packages are GPG-signed and `apt`
   verifies regardless of transport. `docs/roadmap.md` argues this at length;
   read it before re-litigating.

**Make it conditional**, per the two build types above. A template that
unconditionally points at `10.31.0.10` breaks `apt` on every minimalist deploy.

### Three things that will bite

**Where the cache variables live.** `10.31.0.10` and `3142` are duplicated as
playbook-local vars in *three* places — `controller-bootstrap-package-cache.yml`,
`controller-bootstrap-firewall.yml`, `controller-assert-isolation.yml`. Nothing
is in `group_vars/`. Promote them rather than adding a fourth copy.

**Which address, and when.** The cache is dual-homed and the two addresses serve
different eras:

    net0  eth0  svc0   10.31.0.10    <- what lab guests use, forever
    net1  eth1  prov0  10.30.0.20    <- factory-time seeding NIC, gets stripped

The template build runs on `prov0`, so the guest doing the `apt-get install` sits
at `10.30.0.x` and cannot necessarily route to `10.31.0.10` — yet `10.31.0.10` is
the only address correct in a shipped image. **The build should use direct egress
or `10.30.0.20`; the shipped image must carry `10.31.0.10`.** Write the cache
config *after* the `apt-get install` steps.

**The cleanup block is narrower than it looks.** It does
`rm -f /etc/apt/apt.conf.d/99cyberlab-force-ipv4` — a specific filename, not a
wildcard — so a drop-in named anything else survives automatically. The real
constraint is only that the proxy must not be live during the build's own
`apt-get`.

`net1` on CT `801` is **still attached** (confirmed 2026-09-24), and there is a
standing note to `pct set 801 --delete net1` before shipping. Note that stripping
it removes the cache's only path to upstream mirrors.

## Task 2 — prove it with a real clone

The **restated Phase 2.5 exit criterion**: *a lab guest completes an install
through the cache after a cold boot of the host.* The path is proven; the package
volume has not been pushed down it.

Take a before/after reading rather than trusting `is-active` — the cache has
twice reported healthy while serving nobody:

    pct exec 801 -- du -sh /var/cache/apt-cacher-ng                  # 58M
    pct exec 801 -- find /var/cache/apt-cacher-ng -type f | wc -l    # 45

Then clone a finalized template onto a section VNet, install something
non-trivial, and confirm the file count moved. A guest that installs successfully
but leaves the count unchanged went to the internet instead — that is a failure,
and it is the failure mode the whole item exists to prevent.

## Then, in rough order of value

- **Item 7 — two `install-cyberlab.sh` runs on wiped hardware** to close Phase 0.
  Needs hardware you are willing to wipe. Fast-forward CT `800` first; it is five
  commits stale again.
- **Item 8 — pull the cable.** The physical air-gap test.
- **Item 9 — measure per-VM/per-LXC RAM on the R730** and right-size `slots.yml`.

## Incoming — network rebuild, roughly October 2026

A **Protectli VP2430** joins as a firewall appliance, itself running Proxmox,
hosting two OPNsense VMs: edge, and internal routing/segregation. VLANs on the
**Cisco CBS350-24T-4G**. The same setup gets replicated at home, so config
portability is a design goal.

Measured constraints worth not rediscovering:

- The CBS350-24T-4G is **1 GbE on every port, including its four SFP uplinks**.
  The VP2430's 2.5 GbE is stranded. The switch is the ceiling, not the appliance.
- The VP2430 is an **Intel N150, 4 cores, no SMT**. 16 GB DDR5 is generous and is
  *not* the constraint. Suricata on an N150 lands around 200-400 Mbps — run it on
  the edge WAN only, never the inter-VLAN path.
- **Keep PBS backup traffic in one VLAN** so it is L2-switched and never routed.
  Backups are the only heavy flow in the whole design.
- **The internal OPNsense must not become the cyberlab pod boundary.** Phase 5
  rejects a firewall VM as the platform boundary, and the reason still holds:
  students are taught to attack firewalls, so the mechanism enforcing their
  containment must not be the mechanism they are learning to break. OPNsense is
  right for the *services* domain, where nothing is being attacked on purpose.

## Traps worth knowing

- **The on-host checkouts drift silently.** Twice now. `git log -1` in CT `800`
  before trusting an installer run. Current as of 2026-09-24.
- **`pct exec` passes no locale, and Ansible dies on that.** Hand-running
  `pct exec 800 -- ansible-playbook ...` fails every playbook with
  `could not initialize the preferred locale: unsupported locale setting` —
  which reads exactly like a broken playbook and is not one. Prefix with
  `env LC_ALL=C.UTF-8 LANG=C.UTF-8`. The installer is unaffected:
  `run_controller_playbook()` already exports both.
- **A `systemctl start` is not a fix.** This bit the cache twice: the playbook was
  corrected but the live unit only restarted, so the next reboot lost it. Run the
  playbook.
- **Check services from the consumer's vantage point.** The host cannot reach the
  cache on `svc0` once `policy_out: DROP` applies, so a host-side curl reports a
  dead cache while a pod gets HTTP 200. This caught me again on 2026-09-24: I
  looked for `cyberlab-cache-routes.service` on the *host* and found nothing,
  because it lives inside CT `801`.
- **A byte-identity check is only true against the commit it was taken against.**
  Re-verify; don't carry the claim forward.
- **"Does it answer" is not "did it reboot."** Gate on `/proc/uptime` being small,
  not on connectivity.
- **The test suite only inspects *tracked* files.** `test_repo_tidiness.py`
  collected 33 more tests the moment `scripts/discover-guest-ip.sh` was committed,
  and failed immediately. An untracked script is invisible to it.
- **`test_docs_consistency.py` asserts every path mentioned in `docs/*.md` and
  `README.md` exists.** Doc-only edits are not automatically safe — run the
  suite after touching Markdown, not just after touching code. Note the scope is
  literally `docs/*.md` plus `README.md`: this file is tracked as of 2026-09-24
  but lives at the repo root, so its paths are **not** checked. Do not trust a
  path here the way you can trust one in `docs/`.
- **`ansible.builtin.script` merges the script's stderr into `stdout`.** Use
  `stdout_lines | last`, not the whole of `stdout`. Also: `split('\n')` does not
  work inside a YAML folded scalar — the escape does not survive.
- **`target_node` in the template catalog is now load-bearing.** Every stage ends
  the play on hosts that are not the target. Adding a node to the inventory does
  not cause work to run on it; adding a catalog entry that names it does.
- **Guests `950`/`955` on `pve1` have no `onboot`** and must be started by hand
  before any tier 2 run. `955` reliably takes `10.101.11.101` within ~90s.
- **Adding a section requires re-running the cache playbook**, not just the SDN
  one — the return routes are per-section.
- **`pve2`'s ESP is only 1 GB** and fills after roughly nine kernels. Run
  `apt autoremove` after kernel upgrades there.
- **No local dev tooling** beyond `ansible`. Build a venv in the session
  scratchpad from `requirements-dev.txt` for `pytest`, `ruff`, `yamllint` and
  `ansible-lint`. `community.proxmox` is already at `~/.ansible/collections`;
  without it every playbook reports `internal-error`. On a fresh machine
  `ansible-galaxy` also needs
  `SSL_CERT_FILE=$(venv/bin/python -c 'import certifi;print(certifi.where())')`,
  and `certifi` is **not** in `requirements-dev.txt`.
- **`ls` is aliased to `eza --icons`** and eats path arguments; use `command ls`
  or `find`.
