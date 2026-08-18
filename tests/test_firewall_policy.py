"""Invariants of the isolation firewall that are checkable without hardware.

The isolation enforced on 2026-08-07 was placed by hand, and every one of the
five traps recorded that day was silent: the host looked configured and was
not. `controller-bootstrap-firewall.yml` reproduces that work from the data
model, and `controller-assert-isolation.yml` checks it on a live host — but a
live host is exactly what CI does not have. These tests guard the properties
that can be established by reading the repository, so a regression in the rule
*shape* is caught before anyone books lab time.
"""

from __future__ import annotations

import ipaddress
import re

import pytest

from conftest import PLAYBOOK_DIR, REPO_ROOT, iter_tasks, load_playbook, load_yaml, task_module

BOOTSTRAP = PLAYBOOK_DIR / "controller-bootstrap-firewall.yml"
ASSERT_ISOLATION = PLAYBOOK_DIR / "controller-assert-isolation.yml"
PROBE_SCRIPT = REPO_ROOT / "scripts" / "isolation-probe.sh"
INSTALLER = REPO_ROOT / "scripts" / "install-cyberlab.sh"
ENVIRONMENTS = sorted((REPO_ROOT / "data" / "environments").glob("*.yml"))

# The infrastructure subnets lab space must never swallow. prov0 is the
# factory-time provisioning network and svc0 carries the package cache; a host
# DROP covering either would break template builds or the apt carve-out.
INFRA_SUBNETS = ("10.30.0.0/24", "10.31.0.0/24")


def _copy_tasks(playbook):
    for play in load_playbook(playbook):
        for task in iter_tasks(play):
            args = task_module(task, "copy")
            if isinstance(args, dict) and "dest" in args:
                yield task, args


def _written_content(playbook, dest_fragment: str) -> str:
    for _, args in _copy_tasks(playbook):
        if dest_fragment in str(args["dest"]):
            return str(args.get("content", ""))
    raise AssertionError(f"{playbook.name} writes nothing to a path containing {dest_fragment!r}")


def _section_subnets(env_path) -> list[str]:
    data = load_yaml(env_path)
    return [s["subnet"] for s in (data["environment"].get("sections") or {}).values()]


# ---------------------------------------------------------------------------
# The derived lab supernets.
#
# The hand-placed host.fw dropped 10.101.0.0/16 with a comment admitting it
# covered teacher_id 101 only. The playbook derives one /16 per teacher from
# the environment instead, which is only safe while every teacher_id stays
# above the infrastructure octets.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("env_path", ENVIRONMENTS, ids=lambda p: p.stem)
def test_derived_lab_supernets_never_cover_infrastructure(env_path):
    policy = load_yaml(REPO_ROOT / "data" / "policy.yml")["network_policy"]
    floor = int(policy["teacher_id_min"])

    for subnet in _section_subnets(env_path):
        second_octet = int(str(subnet).split(".")[1])
        supernet = ipaddress.ip_network(f"10.{second_octet}.0.0/16")

        assert second_octet >= floor, (
            f"{env_path.name} has section subnet {subnet}, whose teacher octet "
            f"{second_octet} is below teacher_id_min {floor}. The firewall "
            f"derives a host DROP for {supernet} from it, which would blackhole "
            f"infrastructure rather than isolate a classroom."
        )

        for infra in INFRA_SUBNETS:
            assert not supernet.overlaps(ipaddress.ip_network(infra)), (
                f"{env_path.name} section subnet {subnet} derives host DROP "
                f"{supernet}, which covers infrastructure network {infra}."
            )


@pytest.mark.parametrize("env_path", ENVIRONMENTS, ids=lambda p: p.stem)
def test_section_subnets_are_24s_so_the_probe_can_derive_gateways(env_path):
    """isolation-probe.sh truncates the last octet to find a section gateway."""
    for subnet in _section_subnets(env_path):
        network = ipaddress.ip_network(subnet)
        assert network.prefixlen == 24, (
            f"{env_path.name} declares {subnet}. scripts/isolation-probe.sh "
            f"derives each section's gateway by truncating the final octet, "
            f"which is exact only for /24s."
        )


# ---------------------------------------------------------------------------
# The rule set itself.
# ---------------------------------------------------------------------------
def test_lab_guest_group_does_not_permit_dns():
    """Port 53 out of a lab guest is a recursive resolver, not name resolution.

    Measured 2026-08-07: the SDN zone's dnsmasq answers recursively for every
    lab guest, so permitting 53 reopens a data-exfiltration channel that no
    egress rule touches. The live assertion catches this on a host; this
    catches it in review.
    """
    cluster_fw = _written_content(BOOTSTRAP, "cluster.fw")
    group = cluster_fw.split("[group lab-guest]")[-1]
    assert not re.search(r"dport\s+[0-9,:]*\b53\b", group), (
        "controller-bootstrap-firewall.yml permits port 53 in the lab-guest "
        "group. The zone resolver is recursive; lab guests reach the apt cache "
        "by address and need no DNS at all."
    )


def test_cache_carve_out_names_a_port_and_not_just_a_host():
    cluster_fw = _written_content(BOOTSTRAP, "cluster.fw")
    carve_outs = re.findall(r"^OUT ACCEPT -dest dc/cache.*$", cluster_fw, re.MULTILINE)
    assert carve_outs, "no package cache carve-out is written at all"
    for rule in carve_outs:
        assert "-dport" in rule, (
            f"cache carve-out {rule!r} allows a host without restricting the "
            f"port. Verified 2026-08-07 that 3142 answers and 22 does not — "
            f"allowing the host alone exposes the container's SSH to every "
            f"student in the building."
        )


def test_datacenter_policy_denies_both_directions():
    cluster_fw = _written_content(BOOTSTRAP, "cluster.fw")
    assert re.search(r"^policy_in:\s*DROP$", cluster_fw, re.MULTILINE)
    assert re.search(r"^policy_out:\s*DROP$", cluster_fw, re.MULTILINE), (
        "policy_out is the half that matters: inbound-only default-deny still "
        "lets a lab guest reach the management address, every other section, "
        "and the resolver."
    )


def test_host_dhcp_accept_precedes_the_lab_drop():
    """Ordering that fails minutes into a class rather than at boot.

    A renewing DHCP client sources from its already-leased lab address, so an
    inbound accept placed below the lab-subnet DROP works at boot and fails at
    renewal.
    """
    host_fw = _written_content(BOOTSTRAP, "host.fw")
    lines = host_fw.splitlines()

    accept = next((i for i, line in enumerate(lines) if line.startswith("IN ACCEPT -p udp -dport 67:68")), None)
    drop = next((i for i, line in enumerate(lines) if line.startswith("IN DROP -source ")), None)

    assert accept is not None, "host.fw writes no inbound DHCP accept"
    assert drop is not None, "host.fw writes no lab-subnet drop"
    assert accept < drop, (
        f"host.fw accepts inbound DHCP at line {accept + 1} but drops lab "
        f"traffic at line {drop + 1}. Rules are evaluated in order, so leases "
        f"would work at boot and fail at renewal."
    )


def test_host_fw_has_outbound_dhcp():
    """The zone's dnsmasq runs on the host, so every OFFER is host-outbound."""
    host_fw = _written_content(BOOTSTRAP, "host.fw")
    assert re.search(r"^OUT ACCEPT -p udp -dport 67:68", host_fw, re.MULTILINE), (
        "host.fw has no outbound DHCP accept. Without it dnsmasq logs "
        "'Operation not permitted' and no guest on any VNet gets an address."
    )


def test_host_egress_is_scoped_to_an_interface():
    """Unscoped host egress would let the node initiate onto student VNets.

    The host holds a gateway address on every section subnet, so an OUT ACCEPT
    with no interface is not merely "the host can reach the internet" -- it is
    also "the host can reach every lab network", which is the one direction the
    isolation design does not otherwise constrain.
    """
    host_fw = _written_content(BOOTSTRAP, "host.fw")

    egress = [
        line
        for line in host_fw.splitlines()
        if line.startswith("OUT ACCEPT") and "67:68" not in line
    ]
    assert egress, "host.fw writes no egress rules at all; the node cannot patch or fetch"

    unscoped = [line for line in egress if "-i " not in line]
    assert not unscoped, (
        "host.fw egress rules are not scoped to an interface: "
        f"{unscoped}. Scope them to the uplink, which the playbook discovers "
        "from the interface holding the management address."
    )


def test_host_egress_never_uses_the_dash_o_spelling():
    """`-o` is silently not a thing. Proxmox's parser accepts `-i` only.

    Verified against PVE::Firewall::parse_fw_rule on pve1, 2026-08-18: the only
    interface option matched is `-i <iface>`, and for an OUT rule that names the
    outgoing interface. docs/network-isolation.md carried an `-o vmbr0` example
    for months; it was never applied, and would not have done what it read like.
    """
    host_fw = _written_content(BOOTSTRAP, "host.fw")
    offenders = [
        line
        for line in host_fw.splitlines()
        if re.match(r"^(IN|OUT|FORWARD)\s", line) and re.search(r"\s-o\s", line)
    ]
    assert not offenders, (
        f"host.fw uses the `-o` interface spelling: {offenders}. Proxmox parses "
        "`-i` only; `-o` does not scope the rule to anything."
    )


def test_host_egress_opens_dns_or_nothing_resolves():
    """apt and git both fail at name resolution first, and confusingly.

    A ruleset with 443 but no 53 produces "Could not resolve host", which reads
    like a broken uplink rather than a firewall rule.
    """
    host_fw = _written_content(BOOTSTRAP, "host.fw")
    if not any(line.startswith("OUT ACCEPT") and "-dport 80,443" in line for line in host_fw.splitlines()):
        return
    # \b matters: without it this matches `-dport 5300` and the test passes
    # while DNS is shut. Caught by mutating the playbook, 2026-08-18.
    assert re.search(r"^OUT ACCEPT .*-dport 53\b", host_fw, re.MULTILINE), (
        "host.fw permits outbound HTTP/HTTPS but not DNS. Every apt and git "
        "operation resolves a name before it opens a socket."
    )


def test_host_fw_declares_no_policy_directives():
    """host.fw rejects policy_in/policy_out as unparseable — trap 3 of five."""
    host_fw = _written_content(BOOTSTRAP, "host.fw")
    assert not re.search(r"^policy_(in|out):", host_fw, re.MULTILINE), (
        "host.fw carries a policy_in/policy_out directive. Proxmox rejects "
        "those at host level as unparseable, and an unparseable host.fw is not "
        "a partially applied one — it is no host policy at all."
    )


def test_host_fw_is_written_before_cluster_fw():
    """cluster.fw is what switches enforcement on; management accepts go first."""
    order = [str(args["dest"]) for _, args in _copy_tasks(BOOTSTRAP)]
    host_index = next(i for i, dest in enumerate(order) if "host.fw" in dest)
    cluster_index = next(i for i, dest in enumerate(order) if "cluster.fw" in dest)
    assert host_index < cluster_index, (
        "controller-bootstrap-firewall.yml writes cluster.fw before host.fw. "
        "cluster.fw sets enable: 1, so this switches enforcement on during the "
        "window before the host's own SSH and 8006 accepts exist."
    )


def test_schoolnet_alias_is_guarded_by_a_conditional():
    """An alias with no value is a parse error that takes the firewall down.

    The school network is discovered from whichever interface holds the
    management address, and that lookup legitimately returns nothing when the
    controller reaches the API through a NAT or a floating address.
    """
    cluster_fw = _written_content(BOOTSTRAP, "cluster.fw")
    lines = cluster_fw.splitlines()
    schoolnet = next((i for i, line in enumerate(lines) if line.strip().startswith("schoolnet ")), None)
    assert schoolnet is not None, "cluster.fw no longer writes a schoolnet alias"

    preceding = "\n".join(lines[:schoolnet])
    assert re.search(r"{%-?\s*if\s+schoolnet_cidr\s*-?%}\s*$", preceding), (
        "the schoolnet alias is not guarded by `{% if schoolnet_cidr %}`, so a "
        "host where the management address is not held locally would get a "
        "bare `schoolnet` line — a parse error, and an unparseable cluster.fw "
        "is not a partially applied one."
    )


@pytest.mark.parametrize(
    "path",
    [BOOTSTRAP, ASSERT_ISOLATION, PROBE_SCRIPT],
    ids=lambda p: p.name,
)
def test_no_site_specific_addresses_are_hardcoded(path):
    """Phase 7 ships this to districts that are not this one.

    Infrastructure addresses (`prov0`, `svc0`) are fixed product design and may
    appear as defaults. Everything else in 10/8 is site-specific: the
    management network was hand-written as 10.64.62.0/23 on pve1 and is now
    rediscovered from whichever interface actually holds the management
    address. Lab space is derived per teacher and should never be literal.
    """
    inventory = load_yaml(REPO_ROOT / "ansible" / "inventory.yml")
    infra_octets = {
        int(str(subnet["subnet"]).split(".")[1])
        for subnet in inventory["all"]["vars"]["proxmox_sdn"]["subnets"]
    }
    policy = load_yaml(REPO_ROOT / "data" / "policy.yml")["network_policy"]
    lab_octets = set(range(int(policy["teacher_id_min"]), int(policy["teacher_id_max"]) + 1))

    offenders = sorted(
        {
            literal
            for literal in re.findall(r"\b10\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b", path.read_text())
            if int(literal) not in infra_octets and int(literal) not in lab_octets
        }
    )
    assert not offenders, (
        f"{path.name} hardcodes addresses in 10.{{{', '.join(offenders)}}}.x.x, "
        f"which is neither infrastructure ({sorted(infra_octets)}) nor derived "
        f"lab space. Site-specific addresses belong in "
        f"data/environments/<env>.yml or in runtime discovery."
    )


def test_guest_policy_joins_the_lab_guest_group():
    guest_fw = _written_content(BOOTSTRAP, "{{ item.0 }}.fw")
    assert "GROUP lab-guest" in guest_fw
    assert re.search(r"^policy_out:\s*DROP$", guest_fw, re.MULTILINE)


# ---------------------------------------------------------------------------
# Wiring. A test that never runs is worth less than no test, because it reads
# as coverage.
# ---------------------------------------------------------------------------
def _installer_playbook_constants() -> dict[str, str]:
    """Map each `readonly FOO="playbooks/bar.yml"` constant to its playbook."""
    return dict(
        re.findall(
            r'^readonly ([A-Z_]+)="(playbooks/[A-Za-z0-9_.-]+\.yml)"',
            INSTALLER.read_text(),
            re.MULTILINE,
        )
    )


def test_installer_runs_both_firewall_playbooks():
    referenced = set(_installer_playbook_constants().values())
    for playbook in (BOOTSTRAP, ASSERT_ISOLATION):
        assert f"playbooks/{playbook.name}" in referenced, (
            f"scripts/install-cyberlab.sh declares no constant for "
            f"{playbook.name}, so a fresh host would rebuild the SDN and the "
            f"cache without it. That gap is the reason this playbook exists."
        )


def test_installer_asserts_isolation_whenever_it_writes_the_firewall():
    """Writing rules and proving they are in force are separate claims."""
    installer = INSTALLER.read_text()
    body = installer.split("run_controller_firewall()", 1)
    assert len(body) == 2, "install-cyberlab.sh has no run_controller_firewall function"
    function = body[1].split("\n}", 1)[0]

    constants = _installer_playbook_constants()
    invoked = {
        constants[name]
        for name in re.findall(r"\$\{([A-Z_]+)\}", function)
        if name in constants
    }

    assert f"playbooks/{BOOTSTRAP.name}" in invoked, (
        "run_controller_firewall does not run the bootstrap playbook"
    )
    assert f"playbooks/{ASSERT_ISOLATION.name}" in invoked, (
        "run_controller_firewall must run the assertion playbook alongside the "
        "bootstrap playbook. A host whose rules were written but never checked "
        "is the exact state that shipped on 2026-08-07."
    )


def test_assert_playbook_points_at_a_probe_script_that_exists():
    text = ASSERT_ISOLATION.read_text()
    referenced = re.findall(r"scripts/([A-Za-z0-9_.-]+\.sh)", text)
    assert referenced, "the assertion playbook references no probe script"
    for name in set(referenced):
        assert (REPO_ROOT / "scripts" / name).is_file(), (
            f"controller-assert-isolation.yml runs scripts/{name}, which does "
            f"not exist. `ansible.builtin.script` fails only at run time."
        )


def test_probe_script_is_executable():
    assert PROBE_SCRIPT.stat().st_mode & 0o111, (
        f"{PROBE_SCRIPT.relative_to(REPO_ROOT)} is not executable"
    )


def test_probe_requires_a_same_section_control():
    """'Everything is blocked' is also what a guest with no network reports."""
    text = ASSERT_ISOLATION.read_text()
    assert "cyberlab_probe_peer_ip" in text, (
        "the assertion playbook accepts no control peer, so a live probe could "
        "report total isolation for a guest that simply lost its DHCP lease — "
        "which is precisely what a regenerated MAC caused on 2026-08-07."
    )
    probe = PROBE_SCRIPT.read_text()
    assert "CONTROL" in probe and "control_ok" in probe, (
        "isolation-probe.sh does not treat the control as pass/fail. A run "
        "where the control also failed proves nothing."
    )
