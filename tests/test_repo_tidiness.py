"""Repository hygiene invariants.

These are cheap, boring checks for the kinds of damage that accumulate quietly
and are annoying to find later. `docs/controller-lxc.md` sat in the repository
containing three stray `\\x16` bytes interleaved through a UTF-8 apostrophe,
which made the file undecodable; nothing noticed until a test tried to read it.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from conftest import REPO_ROOT

# Extensions treated as text. Anything else is left alone.
TEXT_SUFFIXES = {
    ".cfg",
    ".md",
    ".py",
    ".sh",
    ".tf",
    ".toml",
    ".txt",
    ".yaml",
    ".yml",
}

# Control characters that are legitimate in text files.
ALLOWED_CONTROL = {0x09, 0x0A, 0x0D}


def _tracked_files() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    return [REPO_ROOT / name for name in result.stdout.split("\0") if name]


TRACKED = _tracked_files()
TEXT_FILES = [
    p for p in TRACKED if p.suffix in TEXT_SUFFIXES or p.name.startswith(".")
]
SHELL_SCRIPTS = [p for p in TRACKED if p.suffix == ".sh"]


def _rel(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT))


@pytest.mark.parametrize("path", TEXT_FILES, ids=_rel)
def test_text_files_are_valid_utf8(path):
    try:
        path.read_bytes().decode("utf-8")
    except UnicodeDecodeError as exc:
        pytest.fail(
            f"{_rel(path)} is not valid UTF-8: {exc.reason} at byte {exc.start}. "
            f"This usually means an editor or paste mangled a non-ASCII "
            f"character."
        )


@pytest.mark.parametrize("path", TEXT_FILES, ids=_rel)
def test_text_files_have_no_stray_control_characters(path):
    raw = path.read_bytes()
    found = sorted({b for b in raw if b < 0x20 and b not in ALLOWED_CONTROL})
    assert not found, (
        f"{_rel(path)} contains control characters "
        f"{[hex(b) for b in found]} outside tab/newline/carriage-return."
    )


@pytest.mark.parametrize("path", TEXT_FILES, ids=_rel)
def test_text_files_end_with_a_newline(path):
    raw = path.read_bytes()
    if not raw:
        return
    assert raw.endswith(b"\n"), f"{_rel(path)} does not end with a newline"


@pytest.mark.parametrize("path", TEXT_FILES, ids=_rel)
def test_text_files_use_unix_line_endings(path):
    assert b"\r\n" not in path.read_bytes(), (
        f"{_rel(path)} contains CRLF line endings"
    )


@pytest.mark.parametrize("path", TEXT_FILES, ids=_rel)
def test_no_trailing_whitespace(path):
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return  # reported by the UTF-8 test
    offenders = [
        num
        for num, line in enumerate(text.split("\n"), 1)
        if line != line.rstrip()
    ]
    assert not offenders, (
        f"{_rel(path)} has trailing whitespace on line(s) "
        f"{', '.join(str(n) for n in offenders[:10])}"
    )


@pytest.mark.parametrize("path", SHELL_SCRIPTS, ids=_rel)
def test_shell_scripts_are_executable(path):
    assert os.access(path, os.X_OK), (
        f"{_rel(path)} is not executable; run `chmod +x {_rel(path)}` and "
        f"`git update-index --chmod=+x {_rel(path)}`"
    )


@pytest.mark.parametrize("path", SHELL_SCRIPTS, ids=_rel)
def test_shell_scripts_have_a_shebang(path):
    first = path.read_bytes().split(b"\n", 1)[0]
    assert first.startswith(b"#!"), f"{_rel(path)} has no shebang"


@pytest.mark.parametrize("path", SHELL_SCRIPTS, ids=_rel)
def test_shell_scripts_set_strict_mode(path):
    """Bootstrap scripts that silently continue past a failure are worse than
    ones that stop. Every script here already opts into strict mode; this keeps
    a new one from omitting it."""
    text = path.read_text()
    assert "set -Eeuo pipefail" in text or "set -euo pipefail" in text, (
        f"{_rel(path)} does not enable strict mode"
    )


def test_no_empty_tracked_files():
    """Empty tracked files are almost always accidents.

    The four `opentofu/*.tf` placeholders used to be exempted here. OpenTofu
    has since been dropped and they were deleted, so the exemption is gone too
    — an allowlist that outlives its reason is worse than no allowlist.
    """
    empty = sorted(
        _rel(p) for p in TRACKED if p.is_file() and p.stat().st_size == 0
    )
    assert not empty, f"Empty tracked files: {', '.join(empty)}"
