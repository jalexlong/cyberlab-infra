"""Documentation must not point at files that do not exist.

`README.md` and `docs/data-model.md` both referenced
`data/environments/thinkcentre-lab.yml` long after it stopped existing. Nothing
caught it, because nothing was looking. A stranger following the docs — which
is the stated Phase 7 goal — would have hit it immediately.
"""

from __future__ import annotations

import re

import pytest

from conftest import REPO_ROOT

DOCS = sorted((REPO_ROOT / "docs").glob("*.md")) + [REPO_ROOT / "README.md"]

# Repo-relative paths under a known top-level directory.
PATH_PATTERN = re.compile(
    r"\b((?:docs|data|ansible|scripts|tests|opentofu|private)"
    r"/[A-Za-z0-9_./-]+\.(?:yml|yaml|md|sh|py|tf|txt|cfg))"
)

# Paths that are deliberately referenced without existing. Keep this list short
# and justified; an entry here is a claim that the reference is intentional.
ALLOWED_ABSENT = {
    # Forward reference: the lab scenario catalog is Phase 4 work.
    "data/labs.yml",
    # Historical reference: removed in favour of ansible/vars/templates.yml,
    # and the roadmap describes that removal.
    "data/templates.yml",
}


@pytest.mark.parametrize("doc", DOCS, ids=lambda p: p.name)
def test_documented_paths_exist(doc):
    missing = []
    for match in sorted(set(PATH_PATTERN.findall(doc.read_text()))):
        if match in ALLOWED_ABSENT:
            continue
        if not (REPO_ROOT / match).exists():
            missing.append(match)

    assert not missing, (
        f"{doc.relative_to(REPO_ROOT)} references paths that do not exist: "
        f"{', '.join(missing)}. Either fix the reference or, if it is a "
        f"deliberate forward or historical reference, add it to "
        f"ALLOWED_ABSENT in this test with a justification."
    )


def test_allowed_absent_list_stays_honest():
    """An entry that now exists should be removed from the allowlist."""
    stale = [p for p in sorted(ALLOWED_ABSENT) if (REPO_ROOT / p).exists()]
    assert not stale, (
        f"These paths are in ALLOWED_ABSENT but now exist: {', '.join(stale)}. "
        f"Remove them so the exemption does not outlive its reason."
    )


@pytest.mark.parametrize("doc", DOCS, ids=lambda p: p.name)
def test_relative_doc_links_resolve(doc):
    """Markdown links between docs must resolve."""
    link_pattern = re.compile(r"\[[^\]]+\]\(([^)#:]+(?:\.md)?)(?:#[^)]*)?\)")
    broken = []
    for target in sorted(set(link_pattern.findall(doc.read_text()))):
        if target.startswith(("http", "mailto:", "/")):
            continue
        resolved = (doc.parent / target).resolve()
        if not resolved.exists():
            broken.append(target)

    assert not broken, (
        f"{doc.relative_to(REPO_ROOT)} has links that do not resolve: "
        f"{', '.join(broken)}"
    )
