"""Shared helpers for the repository invariant tests.

These tests read the repository as data. They never contact Proxmox, so they
are safe to run anywhere, which is the point: the defects they guard against
were all discoverable without hardware and none of them were caught by
`--syntax-check` or `bash -n`.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any, Iterator

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
ANSIBLE_DIR = REPO_ROOT / "ansible"
PLAYBOOK_DIR = ANSIBLE_DIR / "playbooks"
INVENTORY = ANSIBLE_DIR / "inventory.yml"
SCRIPTS_DIR = REPO_ROOT / "scripts"

# scripts/ is not a package; this is what lets a test import
# generate_runtime_artifacts.py directly to exercise its behaviour, rather
# than only grepping its source text as test_phase0_regressions.py does.
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

PLAYBOOKS = sorted(PLAYBOOK_DIR.glob("*.yml"))

# Ansible always resolves these regardless of inventory contents.
IMPLICIT_TARGETS = {"all", "localhost", "127.0.0.1"}


def load_yaml(path: Path) -> Any:
    return yaml.safe_load(path.read_text())


def load_playbook(path: Path) -> list[dict[str, Any]]:
    """Return the plays in a playbook, tolerating an empty file."""
    data = load_yaml(path)
    if not data:
        return []
    return [play for play in data if isinstance(play, dict)]


def iter_tasks(play: dict[str, Any]) -> Iterator[dict[str, Any]]:
    """Yield every task in a play, descending into blocks.

    Covers pre_tasks/tasks/post_tasks/handlers and block/rescue/always, so a
    task cannot escape a check simply by being nested.
    """
    for section in ("pre_tasks", "tasks", "post_tasks", "handlers"):
        yield from _iter_task_list(play.get(section) or [])


def _iter_task_list(tasks: Any) -> Iterator[dict[str, Any]]:
    if not isinstance(tasks, list):
        return
    for task in tasks:
        if not isinstance(task, dict):
            continue
        yield task
        for nested in ("block", "rescue", "always"):
            yield from _iter_task_list(task.get(nested) or [])


def task_module(task: dict[str, Any], name: str) -> Any:
    """Return a task's args for `name`, whether written FQCN or bare."""
    for key in (f"ansible.builtin.{name}", name):
        if key in task:
            return task[key]
    return None


def find_play(path: Path, index: int = 0) -> dict[str, Any]:
    plays = load_playbook(path)
    assert plays, f"{path.name} contains no plays"
    return plays[index]


def inventory_targets() -> set[str]:
    """Every group and host name declared in inventory.yml."""
    names: set[str] = set(IMPLICIT_TARGETS)

    def walk(node: Any) -> None:
        if not isinstance(node, dict):
            return
        for key, value in node.items():
            if key == "vars":
                continue
            if key == "hosts" and isinstance(value, dict):
                names.update(value.keys())
            elif key == "children" and isinstance(value, dict):
                for group_name, group_body in value.items():
                    names.add(group_name)
                    walk(group_body)
            else:
                names.add(key)
                walk(value)

    walk(load_yaml(INVENTORY))
    return names


@pytest.fixture(scope="session")
def targets() -> set[str]:
    return inventory_targets()
