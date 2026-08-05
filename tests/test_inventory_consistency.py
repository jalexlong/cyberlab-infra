"""Every playbook must target something inventory actually defines.

`proxmox-sdn.yml` targeted `hosts: poseidon` — a machine name absent from
inventory — and both `--syntax-check` and `bash -n` passed on it. A playbook
aimed at a nonexistent group runs zero tasks and exits successfully, which is
the worst possible failure mode for provisioning automation.
"""

from __future__ import annotations

import pytest

from conftest import PLAYBOOKS, find_play, load_playbook


def _declared_hosts(play: dict) -> list[str]:
    hosts = play.get("hosts")
    if hosts is None:
        return []
    if isinstance(hosts, list):
        raw = hosts
    else:
        raw = str(hosts).split(",")
    return [item.strip() for item in raw if str(item).strip()]


@pytest.mark.parametrize("playbook", PLAYBOOKS, ids=lambda p: p.name)
def test_playbook_targets_exist_in_inventory(playbook, targets):
    for index, play in enumerate(load_playbook(playbook)):
        # A wrapper entry (`import_playbook:`) carries no hosts of its own; the
        # playbook it pulls in is checked on its own account.
        if "import_playbook" in play:
            continue
        declared = _declared_hosts(play)
        assert declared, f"{playbook.name} play {index} declares no hosts"

        for host in declared:
            # Patterns are out of scope; a literal name is what we can verify.
            if any(ch in host for ch in "*:[]!&"):
                continue
            assert host in targets, (
                f"{playbook.name} play {index} targets '{host}', which is not a "
                f"group or host in ansible/inventory.yml. Known targets: "
                f"{', '.join(sorted(targets))}"
            )


@pytest.mark.parametrize("playbook", PLAYBOOKS, ids=lambda p: p.name)
def test_playbook_has_a_name(playbook):
    for index, play in enumerate(load_playbook(playbook)):
        if "import_playbook" in play:
            continue
        assert play.get("name"), f"{playbook.name} play {index} has no name"


@pytest.mark.parametrize("playbook", PLAYBOOKS, ids=lambda p: p.name)
def test_imported_playbooks_exist(playbook):
    """A wrapper importing a renamed or deleted playbook fails only at run time."""
    for index, play in enumerate(load_playbook(playbook)):
        imported = play.get("import_playbook")
        if not imported or "{{" in str(imported):
            continue
        resolved = (playbook.parent / str(imported)).resolve()
        assert resolved.is_file(), (
            f"{playbook.name} play {index} imports '{imported}', which does "
            f"not exist at {resolved}"
        )


def test_inventory_defines_the_groups_playbooks_rely_on(targets):
    for required in ("proxmox_hosts", "controller", "proxmox_targets"):
        assert required in targets, f"inventory.yml lost group '{required}'"


def test_referenced_vars_files_exist():
    """A missing vars_files path fails at run time, not at syntax check."""
    for playbook in PLAYBOOKS:
        for index, play in enumerate(load_playbook(playbook)):
            for entry in play.get("vars_files") or []:
                if not isinstance(entry, str) or "{{" in entry:
                    continue
                resolved = (playbook.parent / entry).resolve()
                assert resolved.is_file(), (
                    f"{playbook.name} play {index} loads vars_file '{entry}', "
                    f"which does not exist at {resolved}"
                )


def test_no_stale_environment_references():
    """Environment files named in playbooks must exist in data/environments/."""
    import re

    from conftest import REPO_ROOT

    pattern = re.compile(r"data/environments/([A-Za-z0-9_-]+)\.yml")
    for playbook in PLAYBOOKS:
        for name in set(pattern.findall(playbook.read_text())):
            path = REPO_ROOT / "data" / "environments" / f"{name}.yml"
            assert path.is_file(), (
                f"{playbook.name} references environment '{name}', but "
                f"{path.relative_to(REPO_ROOT)} does not exist"
            )


def test_slot_templates_exist_in_catalog():
    """Every slot in slots.yml must name a template the catalog defines.

    slots.yml and ansible/vars/templates.yml are separate source-of-truth
    files with no enforced relationship; a template removed from the catalog
    leaves slots pointing at nothing.
    """
    from conftest import REPO_ROOT, load_yaml

    slots = load_yaml(REPO_ROOT / "data" / "slots.yml")["slots"]
    catalog = load_yaml(REPO_ROOT / "ansible" / "vars" / "templates.yml")

    entries = catalog["templates"] if isinstance(catalog, dict) else catalog
    if isinstance(entries, dict):
        known = set(entries.keys())
    else:
        known = {str(item.get("id") or item.get("name")) for item in entries}
        known |= {str(item.get("name")) for item in entries}

    for slot_name, slot in slots.items():
        template = str(slot["template_name"])
        stem = template.removesuffix("-template")
        assert any(stem in candidate for candidate in known), (
            f"slot '{slot_name}' names template '{template}', which does not "
            f"correspond to any entry in ansible/vars/templates.yml"
        )
