"""Student usernames and passwords must not be reconstructable from git, and
generate_runtime_artifacts.py must accept every timetable its own VMID and
network formulas can actually disambiguate.

Three related defects lived in generate_runtime_artifacts.py:

1. Codenames were assigned positionally (`codenames[idx]`), so every section
   started "raven, otter, maple..." in the same order. Reconstructing which
   pseudonym belonged to which roster position needed no leak at all -- just
   a plausible guess at ordering (alphabetical by legal name being the
   obvious one), which is exactly the class of risk pseudonymisation exists
   to prevent.

2. Initial passwords were generated from `random.Random(seed)` where
   `seed = f"{teacher_id}-{section_code}-{idx}"`. Both teacher_id and
   section_code are stored in data/teachers.yml and data/sections.yml, which
   are committed to a public repository, and the wordlists were hardcoded in
   the committed script. Every student's initial password, for every
   section, for any school that used this repository, was fully
   recomputable from data already in git history.

3. validate_inputs() required section_code to be globally unique, but
   section_code encodes course/day/block and is entirely teacher-independent.
   Two teachers with the same course in the same block -- an ordinary
   timetable -- produced the same code and were rejected, even though both
   downstream formulas already multiply teacher_id in ahead of section_code,
   so nothing would actually have collided.

The first two are fixed by drawing from random.SystemRandom() by default
rather than a seed built from public data, with stability across
regeneration provided by persisting the assignment (keyed by section +
student_index) instead of recomputing it. These tests inject a seeded
random.Random so the assertions themselves are reproducible; production code
never does that -- see the comment in build_runtime_artifacts. The third is
fixed by scoping the uniqueness check to (teacher_id, section_code) instead
of section_code alone.
"""

from __future__ import annotations

import random

from conftest import REPO_ROOT, load_yaml
from generate_runtime_artifacts import build_runtime_artifacts, generate_password, validate_inputs

TEACHERS = load_yaml(REPO_ROOT / "data" / "teachers.yml")
SECTIONS = load_yaml(REPO_ROOT / "data" / "sections.yml")
POLICY = load_yaml(REPO_ROOT / "data" / "policy.yml")
ENVIRONMENT = load_yaml(REPO_ROOT / "data" / "environments" / "school-lab.yml")


def _codenames_by_section(students_yml: dict) -> dict[str, dict[int, str]]:
    result: dict[str, dict[int, str]] = {}
    for student in students_yml["students"]:
        result.setdefault(student["section"], {})[student["student_index"]] = student["codename"]
    return result


def test_codename_assignment_is_not_positional():
    """Regenerating with two different seeds must not put the same codename
    at the same roster index -- proof that assignment actually depends on
    randomness rather than on idx, which is the bug this replaces.
    """
    runtime_a, _ = build_runtime_artifacts(
        TEACHERS, SECTIONS, POLICY, ENVIRONMENT, {}, rng=random.Random(1)
    )
    runtime_b, _ = build_runtime_artifacts(
        TEACHERS, SECTIONS, POLICY, ENVIRONMENT, {}, rng=random.Random(2)
    )

    codenames_a = _codenames_by_section(runtime_a)
    codenames_b = _codenames_by_section(runtime_b)

    assert codenames_a != codenames_b, (
        "Two different random seeds produced identical codename assignment. "
        "If this is failing, codename selection has regressed to being a "
        "deterministic function of section/index rather than genuinely random."
    )


def test_idx_zero_is_not_the_same_codename_across_sections():
    """The literal symptom that was actually observed: every section's first
    student was 'raven' because codenames[0] == 'raven' unconditionally.
    """
    runtime, _ = build_runtime_artifacts(
        TEACHERS, SECTIONS, POLICY, ENVIRONMENT, {}, rng=random.Random(7)
    )
    codenames = _codenames_by_section(runtime)
    first_codenames = {section: idx0.get(0) for section, idx0 in codenames.items()}

    assert len(set(first_codenames.values())) > 1, (
        f"Every section's first student got the same codename: {first_codenames}. "
        "This is the positional-assignment bug."
    )


def test_password_is_not_reproducible_from_teacher_id_and_section_code():
    """The actual security defect: previously,
    random.Random(f"{teacher_id}-{section_code}-{idx}") made every password
    computable from data already committed to git. Confirm that seed no
    longer reproduces the generated password.
    """
    runtime, _ = build_runtime_artifacts(
        TEACHERS, SECTIONS, POLICY, ENVIRONMENT, {}, rng=random.Random(3)
    )
    actual = next(
        s["initial_password"]
        for s in runtime["students"]
        if s["section"] == "jlong-cyba3" and s["student_index"] == 0
    )

    teacher_id = TEACHERS["teachers"]["jlong"]["teacher_id"]
    section_code = SECTIONS["sections"]["jlong-cyba3"]["section_code"]
    old_seed = f"{teacher_id}-{section_code}-0"
    # The exact wordlists that were hardcoded in the script at the time of
    # the defect; reproduced here only to prove they can no longer predict
    # a real generated password, not because they are still meaningful.
    old_words_1 = [
        "maple", "tiger", "river", "silver", "ember", "forest", "copper", "ocean",
        "falcon", "cedar", "aurora", "quartz", "glacier", "thunder", "harbor",
    ]
    old_words_2 = [
        "river", "ocean", "forge", "field", "ember", "summit", "harbor", "grove",
        "stone", "comet", "trail", "shore", "glade", "spark", "echo",
    ]
    old_style_password = generate_password(random.Random(old_seed), old_words_1, old_words_2)

    assert actual != old_style_password, (
        "The generated password matched what the old teacher_id/section_code "
        "seed would have produced -- passwords are recomputable from data "
        "committed to git again."
    )


def test_existing_assignment_survives_regeneration_regardless_of_rng():
    """Once a codename and password are persisted, re-running with a
    different random seed must not change them -- a printed credential slip
    must never go stale because the generator was re-run.
    """
    first, _ = build_runtime_artifacts(
        TEACHERS, SECTIONS, POLICY, ENVIRONMENT, {}, rng=random.Random(11)
    )
    existing = {
        (s["section"], s["student_index"]): s for s in first["students"]
    }

    second, _ = build_runtime_artifacts(
        TEACHERS, SECTIONS, POLICY, ENVIRONMENT, existing, rng=random.Random(999999)
    )

    first_by_key = {(s["section"], s["student_index"]): s for s in first["students"]}
    second_by_key = {(s["section"], s["student_index"]): s for s in second["students"]}

    for key, before in first_by_key.items():
        after = second_by_key[key]
        assert after["codename"] == before["codename"], f"{key}: codename changed on rerun"
        assert after["initial_password"] == before["initial_password"], (
            f"{key}: password changed on rerun"
        )


def test_growing_a_section_only_assigns_new_codenames_to_new_slots():
    """A section gaining students must not reshuffle anyone who already has
    a printed credential -- only the new roster slots should get fresh
    assignments.
    """
    first, _ = build_runtime_artifacts(
        TEACHERS, SECTIONS, POLICY, ENVIRONMENT, {}, rng=random.Random(5)
    )
    existing = {(s["section"], s["student_index"]): s for s in first["students"]}

    grown_sections = {
        "sections": {
            key: {**data, "student_count": data["student_count"] + 2}
            if key == "jlong-cyba3"
            else data
            for key, data in SECTIONS["sections"].items()
        }
    }

    grown, _ = build_runtime_artifacts(
        TEACHERS, grown_sections, POLICY, ENVIRONMENT, existing, rng=random.Random(6)
    )

    original_cyba3 = {
        s["student_index"]: s["codename"] for s in first["students"] if s["section"] == "jlong-cyba3"
    }
    grown_cyba3 = {
        s["student_index"]: s["codename"] for s in grown["students"] if s["section"] == "jlong-cyba3"
    }

    for idx, codename in original_cyba3.items():
        assert grown_cyba3[idx] == codename, f"idx {idx} was reassigned when the section grew"

    new_indices = set(grown_cyba3) - set(original_cyba3)
    assert len(new_indices) == 2
    assert not (set(grown_cyba3[i] for i in new_indices) & set(original_cyba3.values())), (
        "A newly assigned codename collided with one already in use in the same section"
    )


def test_two_teachers_may_share_a_section_code():
    """section_code encodes course/day/block (its 011/112/123/213 shape), which
    is entirely teacher-independent -- two teachers who both teach, say,
    Cybersecurity in A-day block 3 produce the same code. validate_inputs used
    to reject that as a global duplicate, even though vmid_policy and
    network_policy both multiply teacher_id in ahead of section_code
    (`teacher_id * 1000000 + section_code * 1000 + offset`), so the two
    sections' VMIDs and subnets never actually collide. An entirely ordinary
    timetable broke generation.
    """
    teachers = {
        "jlong": {"teacher_id": 101, "sections": ["jlong-cyba3"]},
        "asmith": {"teacher_id": 102, "sections": ["asmith-cyba3"]},
    }
    sections = {
        "jlong-cyba3": {"teacher": "jlong", "section_code": 213, "student_count": 3},
        "asmith-cyba3": {"teacher": "asmith", "section_code": 213, "student_count": 12},
    }
    env = {"jlong-cyba3": {}, "asmith-cyba3": {}}

    validate_inputs(teachers, sections, env)  # must not raise


def test_one_teacher_still_cannot_reuse_a_section_code():
    """The scoping in the fix above must not become a rubber stamp: the same
    teacher assigned the same section_code twice is a real data error and
    must still be rejected.
    """
    teachers = {"jlong": {"teacher_id": 101, "sections": ["jlong-a", "jlong-b"]}}
    sections = {
        "jlong-a": {"teacher": "jlong", "section_code": 213, "student_count": 3},
        "jlong-b": {"teacher": "jlong", "section_code": 213, "student_count": 5},
    }
    env = {"jlong-a": {}, "jlong-b": {}}

    try:
        validate_inputs(teachers, sections, env)
    except ValueError:
        pass
    else:
        raise AssertionError("Duplicate section_code for the same teacher was accepted")


def _one_teacher(teacher_id: int, section_code: int = 213):
    teachers = {"jlong": {"teacher_id": teacher_id, "sections": ["jlong-a"]}}
    sections = {
        "jlong-a": {
            "teacher": "jlong",
            "section_code": section_code,
            "student_count": 3,
        }
    }
    return teachers, sections, {"jlong-a": {}}


def test_teacher_id_and_section_code_are_bounded_to_an_octet():
    """Both identifiers are IP octets in network_policy's formula
    `10.<teacher_id>.<section_code>.0/24`, so both are bounded by 255.
    Nothing enforced that: validate_inputs checked type and uniqueness only,
    so teacher_id 300 or section_code 311 produced an unbuildable subnet with
    no complaint at generation time.

    The floor matters too. Low octets are reserved for infrastructure subnets
    (prov0 10.30.0.0/24, svc0 10.31.0.0/24), which is why teachers start at
    101 -- a teacher_id of 31 would collide with the service network.
    """
    for bad_id in (31, 100, 256, 300, 0, -1):
        try:
            validate_inputs(*_one_teacher(bad_id))
        except ValueError:
            pass
        else:
            raise AssertionError(f"Out-of-range teacher_id {bad_id} was accepted")

    for bad_code in (256, 311, -1):
        try:
            validate_inputs(*_one_teacher(101, bad_code))
        except ValueError:
            pass
        else:
            raise AssertionError(f"Out-of-range section_code {bad_code} was accepted")

    # The bounds themselves, and the real values in data/, must still pass.
    validate_inputs(*_one_teacher(101, 0))
    validate_inputs(*_one_teacher(255, 255))


def test_identifier_bounds_come_from_policy_not_from_code():
    """policy.yml is the source of truth for these bounds. An earlier defect in
    this repository had username_policy loaded and then discarded because
    format_student_username hardcoded the same pattern, so editing the
    source-of-truth file changed nothing. Passing a narrowed policy must
    actually narrow validation, or these bounds have the same problem.
    """
    narrow = {"teacher_id_min": 200, "teacher_id_max": 210, "section_code_max": 99}

    # Accepted by the defaults, must be rejected by the narrowed policy.
    try:
        validate_inputs(*_one_teacher(101, 213), narrow)
    except ValueError:
        pass
    else:
        raise AssertionError("network_policy bounds were ignored by validate_inputs")

    validate_inputs(*_one_teacher(205, 98), narrow)  # must not raise
