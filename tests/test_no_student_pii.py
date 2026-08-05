"""Guard the boundary between student ordinals and student identity.

Only `student_count` -- an integer -- may describe students anywhere in
`data/`, which is tracked by git. No student name, ID, email, or roster may
ever be committed, and the pseudonymous credentials this platform generates
(`private/generated/students.yml`, `credentials.csv`, `credentials.md`) must
never be tracked either.

The mapping between a real student and a generated username/password is
never held by this system at all. It is the teacher's responsibility, kept in
whatever roster or SIS the school already runs under its own compliance
obligations -- see the "Student identity boundary" section of
docs/data-model.md.

These tests exist because "no student PII in git" was previously a stated
intention with nothing enforcing it. A new field can be added to sections.yml
by someone who has never read that intention; a failing test is what actually
stops them.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

from conftest import REPO_ROOT, load_yaml

DATA_DIR = REPO_ROOT / "data"

# Key names that would indicate a real student is being named, identified, or
# contacted. Deliberately broad: a false positive here costs one line added
# to this set with a reason; a false negative costs a student's real name in
# git history forever.
FORBIDDEN_KEYS = {
    "students",
    "roster",
    "student_name",
    "student_names",
    "student_email",
    "student_emails",
    "student_id",
    "first_name",
    "last_name",
    "legal_name",
    "preferred_name",
    "date_of_birth",
    "dob",
    "birth_date",
    "ssn",
    "social_security_number",
    "parent_email",
    "parent_name",
    "guardian_email",
    "guardian_name",
    "home_address",
    "phone_number",
    "phone",
}

ALLOWED_SECTION_KEYS = {
    "display_section",
    "alias",
    "teacher",
    "course_code",
    "course_name",
    "day",
    "block",
    "section_code",
    "student_count",
    "proxmox",
}

ALLOWED_SECTION_PROXMOX_KEYS = {
    "student_group",
    "teacher_group",
    "shared_pool",
}


def _walk(node: Any, path: Path, offenders: list[str]) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(key, str) and key.lower() in FORBIDDEN_KEYS:
                offenders.append(f"{path.relative_to(REPO_ROOT)}: forbidden key '{key}'")
            _walk(value, path, offenders)
    elif isinstance(node, list):
        for item in node:
            _walk(item, path, offenders)


def test_no_student_identifying_keys_in_tracked_data():
    """Recursively scan every tracked YAML file under data/ for PII-shaped keys.

    student_count is the only permitted student-related field, and it is an
    integer. Nothing under data/ should ever hold a name, ID, or contact
    detail for an individual student.
    """
    offenders: list[str] = []
    for path in sorted(DATA_DIR.rglob("*.yml")):
        _walk(load_yaml(path), path, offenders)

    assert not offenders, (
        "Student-identifying keys found in tracked data files. Student "
        "identity must never enter version control -- see the "
        "'Student identity boundary' section of docs/data-model.md.\n"
        + "\n".join(offenders)
    )


def test_sections_yaml_has_no_unexpected_keys():
    """sections.yml is authoritative and committed. A new key here must be a
    deliberate, reviewed decision -- this is what forces that, rather than a
    roster-shaped addition landing silently because it happened to avoid the
    keyword blocklist above.
    """
    data = load_yaml(REPO_ROOT / "data" / "sections.yml")
    offenders: list[str] = []

    for section_key, section in data["sections"].items():
        unexpected = set(section) - ALLOWED_SECTION_KEYS
        if unexpected:
            offenders.append(f"sections.yml[{section_key}]: unexpected keys {sorted(unexpected)}")

        proxmox = section.get("proxmox")
        if isinstance(proxmox, dict):
            unexpected_p = set(proxmox) - ALLOWED_SECTION_PROXMOX_KEYS
            if unexpected_p:
                offenders.append(
                    f"sections.yml[{section_key}].proxmox: unexpected keys {sorted(unexpected_p)}"
                )

    assert not offenders, "\n".join(offenders)


def test_private_generated_artifacts_are_never_tracked():
    """Prove the exclusion holds rather than trusting it.

    private/.gitignore already excludes generated student data, but a
    gitignore is advisory -- `git add -f` overrides it. This checks what git
    actually has tracked, which is what a clone and every CI run sees.
    """
    result = subprocess.run(
        ["git", "ls-files", "private/"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    tracked = [line for line in result.stdout.splitlines() if line]
    allowed = {"private/.gitignore", "private/generated/.gitignore"}
    offenders = [f for f in tracked if f not in allowed]

    assert not offenders, (
        "Files are tracked under private/ that must never be committed -- "
        "this is exactly where generated student credentials are written:\n"
        + "\n".join(offenders)
    )
