"""Guards for the four Phase 0 defects.

Roadmap Phase 1 exit criterion: "CI green; reintroducing any Phase 0 defect
turns it red." Each test here fails if one specific defect comes back.

The fourth defect — `raiseValueError`, a call that is syntactically valid and
only explodes at run time — is guarded by ruff rather than by a test here.
`select = ["F"]` in pyproject.toml enables F821 (undefined name), which
catches it; `python -m py_compile` does not.
"""

from __future__ import annotations

import re

from conftest import PLAYBOOK_DIR, REPO_ROOT, find_play, iter_tasks, task_module

HOST_BOOTSTRAP = PLAYBOOK_DIR / "host-bootstrap.yml"
API_VALIDATION = PLAYBOOK_DIR / "controller-validate-proxmox-api.yml"


def test_automation_token_secret_is_assigned():
    """Defect 1: the set_fact extracting the token secret was deleted.

    Proxmox exposes an API token secret only at creation time. Without this
    assignment the controller env file is written with an undefined value and
    fresh installs fail.
    """
    play = find_play(HOST_BOOTSTRAP)
    for task in iter_tasks(play):
        args = task_module(task, "set_fact")
        if isinstance(args, dict) and "automation_token_secret" in args:
            return
    raise AssertionError(
        "No set_fact assigns 'automation_token_secret' in host-bootstrap.yml. "
        "The playbook asserts on and writes this value, so without the "
        "assignment every fresh install fails."
    )


def test_automation_token_secret_assignment_is_asserted():
    """The assignment is only useful if a failed extraction is caught loudly."""
    play = find_play(HOST_BOOTSTRAP)
    for task in iter_tasks(play):
        args = task_module(task, "assert")
        if not isinstance(args, dict):
            continue
        conditions = " ".join(str(c) for c in (args.get("that") or []))
        if "automation_token_secret" in conditions:
            return
    raise AssertionError(
        "Nothing asserts that automation_token_secret was actually extracted."
    )


def test_automation_user_is_granted_its_role():
    """Defect 2a: no `pveum acl modify` ran, so the token had no privileges."""
    play = find_play(HOST_BOOTSTRAP)
    for task in iter_tasks(play):
        args = task_module(task, "command")
        argv = args.get("argv") if isinstance(args, dict) else None
        if isinstance(argv, list):
            flat = [str(item) for item in argv]
            if "acl" in flat and "modify" in flat:
                return
    raise AssertionError(
        "host-bootstrap.yml never runs `pveum acl modify`. The automation "
        "token would authenticate but hold zero privileges."
    )


def test_automation_acl_is_verified_after_granting():
    play = find_play(HOST_BOOTSTRAP)
    for task in iter_tasks(play):
        args = task_module(task, "assert")
        if not isinstance(args, dict):
            continue
        blob = str(args.get("that", "")) + str(task.get("vars", ""))
        if "acl" in blob.lower():
            return
    raise AssertionError("The ACL grant is never read back and verified.")


def test_api_validation_checks_privileges_not_just_version():
    """Defect 2b: the false green.

    `/version` is readable by any authenticated user, so reaching it proves
    only that the token exists. Validation must query effective permissions.
    """
    play = find_play(API_VALIDATION)
    urls = []
    for task in iter_tasks(play):
        args = task_module(task, "uri")
        if isinstance(args, dict) and "url" in args:
            urls.append(str(args["url"]))

    assert urls, "controller-validate-proxmox-api.yml makes no API calls"
    assert any("access/permissions" in url for url in urls), (
        "API validation never queries /access/permissions. Checking only "
        "/version passes for a token with no privileges at all — the exact "
        "false green this playbook exists to prevent."
    )


def test_api_validation_requires_specific_privileges():
    play = find_play(API_VALIDATION)
    for task in iter_tasks(play):
        required = (task.get("vars") or {}).get("required_proxmox_privs")
        if required:
            assert len(required) >= 5, (
                "required_proxmox_privs shrank to a token list; it should "
                "cover the privileges the platform actually depends on."
            )
            return
    raise AssertionError("No task asserts a required-privilege list.")


def test_automation_role_covers_validator_required_privileges():
    """The role grant and the validator's expectations must agree.

    These are two independent declarations. A privilege added to the validator
    but not to the role yields a bootstrap that succeeds and a validation that
    fails; the reverse silently over-grants.
    """
    bootstrap = find_play(HOST_BOOTSTRAP)
    role_privs = set(bootstrap["vars"]["automation_role_privs"])

    required: set[str] = set()
    for task in iter_tasks(find_play(API_VALIDATION)):
        listed = (task.get("vars") or {}).get("required_proxmox_privs")
        if listed:
            required = set(listed)
            break

    assert required, "Could not locate required_proxmox_privs in the validator"

    missing = required - role_privs
    assert not missing, (
        f"controller-validate-proxmox-api.yml requires {sorted(missing)} at "
        f"'/', but host-bootstrap.yml never grants them via "
        f"automation_role_privs. Bootstrap would succeed and validation fail."
    )


def test_no_unexpanded_shell_interpolation():
    """Defect 3: `#{VAR}` instead of `${VAR}`.

    In bash `#{VAR}` is a literal string, not a variable reference, so the
    comparison silently never matches and shellcheck does not flag it.
    """
    offenders = []
    pattern = re.compile(r"#\{[A-Za-z_][A-Za-z0-9_]*\}")
    for script in sorted((REPO_ROOT / "scripts").glob("*.sh")):
        for lineno, line in enumerate(script.read_text().splitlines(), 1):
            if pattern.search(line):
                offenders.append(f"{script.name}:{lineno}: {line.strip()}")

    assert not offenders, "Literal `#{...}` where `${...}` was meant:\n" + "\n".join(
        offenders
    )


def test_policy_username_format_is_actually_applied():
    """policy.yml claims to define the username pattern; code must consume it.

    The format was previously hardcoded in `format_student_username`, so
    editing data/policy.yml had no effect — a source-of-truth file that was
    not a source of truth.
    """
    source = (REPO_ROOT / "scripts" / "generate_runtime_artifacts.py").read_text()
    assert "username_policy.get" in source or 'username_policy["format"]' in source, (
        "generate_runtime_artifacts.py no longer reads the username format "
        "from policy.yml."
    )
    assert "<display_section>" in source, (
        "The username format tokens are no longer substituted from policy."
    )
