# Handoff — the cache item is done; next session starts at "Start here"

Continuing work in `/Users/jlong/Code/cyberlab-infra`. The 2026-09-24 session
ported the template pipeline to `pve2`, added a server-provisioning layer above
it, and built a live Minecraft server on top of that. It also narrowed the
project's scope and corrected three things the previous handoff had wrong.

**Updated 2026-10-20, end of session:** the cache item is done and proven with a
real clone. The current-state section below is re-measured as of that date.
**Next session: read "Start here" first.**

## Start here — next session

Nothing is running or half-done. No dead-man timer is armed, and 950/955 and
900 are stopped. Pick from this list, which is grouped by what each item needs:

1. **You alone, about 5 minutes: TOTP** for `root@pam` and `jlong@pam` in pve1's
   web UI. It needs your phone.
2. **Your decision, then remote work:**
   - **CT 800 → pve2 host key.** The recommendation is to trust pve2's host key
     in CT 800, not to drop pve2 from the inventory. This repo still builds
     pve2's `debian13-pve2` template until `school-services-infra` takes that
     over. The fix ends the exit 4 on every pipeline run.
   - **When to delete the old template backup** (path below).
3. **Remote and safe, can start immediately:**
   - **Item 9:** measure per-VM and per-LXC RAM on pve1, then right-size
     `slots.yml`. It is read-only, but needs a pod running for a while to give
     a real number.
   - **Phase 2's remaining templates, Juice Shop and Metasploitable3.** The
     pipeline works on pve1 again; it was broken 08-07 to 10-20.
4. **Needs you at the hardware. Do these in one visit, outside class time,
   after the network rebuild if that is close:**
   - **Cold boot:** reboot pve1, then confirm a clone can still install a
     package through the cache.
   - **Item 8: pull the cable.**
5. **Blocked on wipeable hardware: item 7**, two `install-cyberlab.sh` runs.
   This closes Phase 0.

The recommended order is 1-2, then item 9, then the hardware visit, then the
Phase 2 templates.

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

`host-bootstrap.yml` is still the exception: it targets `proxmox_hosts`, which is
`localhost` with `ansible_connection: local`, so it runs ON the node.

## Current state — measured 2026-10-20 unless noted

- `main` and `origin/main` are at **`1fd3e75`**, and the working tree is clean.
- **All three checkouts are at `1fd3e75`:** the laptop, `/root/cyberlab-infra`
  on `pve1`, and CT `800`'s copy. **These drift silently and have twice been the
  thing that quietly broke an installer run; `git log -1` in the controller
  before trusting one.**
- Baseline: **508 tests**, all passing, plus `ruff`, `yamllint`, `shellcheck`
  and `ansible-lint`, all clean before every push this session.
- `pve1` cache: **92 MB / 82 files**. It is now seeded on purpose by template
  builds, not only by accident. CT `801` still has `net1` attached, which is
  what the seeding path uses.
- `pve1` guests: `900` (the new cache-build template), `950`/`955` (isolation
  probes), and `9001`-`9004` (older templates), all stopped.
- Isolation: **17/17, re-measured 2026-10-20**, both tiers.
- **Both hosts rebooted unplanned around 2026-09-11.** Not a test — a site power
  event. The cache came back on its own with no hand-holding, which is better
  evidence for the reboot fix than the deliberate 08-19 cold boot was.

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

## Minecraft moved to its own repository — 2026-09-28

The server catalog, provisioning playbook, server roles and Minecraft server
moved to **`school-services-infra`** (private), with their history. Work on
pve2's services happens there; its own docs and memory are the reference.

What stays here: the template pipeline still builds pve2's `debian13-pve2`
template, so that catalog entry, pve2's inventory line and
`scripts/discover-guest-ip.sh` remain until a pve2 template build exists in the
new repository.

**pve1's `cyberlab` pool shrank the same day.** `mirror-3` was removed with
`zpool remove` and its two SSDs (bays 7 and 8) moved to pve2 as the backup
mirror. The pool is three mirrors, 5.44 TB, fully redundant; scrub clean.

## Done 2026-10-20 — the cache item, and two firewall defects it uncovered

**Task 1 (roadmap item 6) is done.** `controller-finalize-template-vm.yml`
rewrites Debian 13's sources to plain `http`, runs the build's own `apt` through
the cache's `prov0` address (`10.30.0.20`) so building a template seeds the
cache, and ships `/etc/apt/apt.conf.d/90cyberlab-package-cache` naming
`10.31.0.10:3142`. A verification step refuses to shut the guest down if its apt
config does not match its build type.

**The build type is one key: `proxmox.package_cache` in the environment file.**
Finalize reads it, `install-cyberlab.sh` reads it before running anything, and
the cache playbook refuses to build without it. `--with-package-cache` now only
asserts that the environment agrees. The cache addresses live once, in
`ansible/group_vars/all.yml`.

**Task 2 passed, short of a cold boot.** Template `900` was rebuilt through the full
pipeline (validate stage skipped, since its VMID `950` is the isolation probe).
Cache: 58 MB / 45 files before, 85 MB / 72 after the build. A clone on
`t101c011`, firewalled as a lab guest, installed `nmap`; cache 92 MB / 82.
Isolation re-measured the same day: **17/17**, both tiers. Not done: an install
after a cold boot of the host.

**The old template is backed up** at
`/var/lib/vz/dump/vzdump-qemu-900-2026_10_20-13_16_09.vma.zst` on `pve1`.
Delete it once the new one has seen some use.

Two defects, both dating from the 2026-08-07 firewall, both fixed:

- **The host could not reach `prov0`.** `policy_out: DROP` covers the host, and
  nothing allowed it onto `prov0`, so finalize timed out SSHing to a healthy
  build guest. **No template could be built on `pve1` since 08-07**; the last
  build was 08-05. Now tcp/22 and ICMP to `provnet` on `prov0` only.
- **New per-guest `.fw` files could not be written.** pmxcfs refuses a chmod to
  `0600`, which Ansible's `copy` applies on the way in, so any new lab guest
  failed the firewall playbook with the dead-man switch left armed.
  `unsafe_writes` does not fix it. Policy is now staged under
  `/root/cyberlab-fw-staging` and installed with a compare and `cat >`.

## Then

See "Start here" at the top. It replaced this list on 2026-10-20.

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
  before trusting an installer run. Current as of 2026-10-20.
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
- **Nothing can `chmod 0600` inside `/etc/pve`.** pmxcfs refuses it, so
  `ansible.builtin.copy` fails on any new or changed file there, even with
  `unsafe_writes`. Stage the file elsewhere and install it with `cat >`, as the
  firewall playbook now does.
- **The host needs an explicit OUT rule for every VNet it opens connections
  onto.** `policy_out: DROP` covers the host itself, and a missing rule looks
  like a dead guest, not a firewall drop.
- **A failed firewall run leaves `cyberlab-fw-deadman.timer` armed**, which rolls
  the firewall back after 10 minutes. Check
  `systemctl list-timers | grep deadman` after any failure.
- **A background job's exit status can be the wrapper's.** Read the playbook's
  recap line, not the shell's exit code.
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
