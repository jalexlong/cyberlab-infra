#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import random
import sys
from pathlib import Path
from typing import Any

import yaml


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{path} did not contain a YAML mapping")
    return data


def dump_yaml(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, sort_keys=False, allow_unicode=True)

def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def read_existing_students(path: Path) -> dict[str, dict[str, Any]]:
    if not path.exists():
        return {}
    data = load_yaml(path)
    students = data.get("students", [])
    result: dict[str, dict[str, Any]] = {}
    for student in students:
        username = student.get("username")
        if isinstance(username, str):
            result[username] = student
    return result


def format_student_username(display_section: str, codename: str, ordinal: int) -> str:
    return f"{display_section}-{codename}-{ordinal:02d}"


def generate_password(rng: random.Random, words1: list[str], words2: list[str]) -> str:
    return f"{rng.choice(words1).title()}{rng.choice(words2).title()}{rng.randint(10, 99)}"


def section_sort_key(section_key: str, section_data: dict[str, Any]) -> tuple[str, int, str]:
    day = str(section_data.get("day", "Z"))
    block = int(section_data.get("block", 99))
    alias = str(section_data.get("alias", section_key))
    return (day, block, alias)


def validate_inputs(
    teachers: dict[str, Any],
    sections: dict[str, Any],
    environment_sections: dict[str, Any],
    ) -> None:
    teacher_ids: set[int] = set()
    section_codes: set[int] = set()

    for teacher_key, teacher_data in teachers.items():
        teacher_id = teacher_data.get("teacher_id")
        if not isinstance(teacher_id, int):
            raise ValueError(f"Teacher {teacher_key} is missing integer teacher_id")
        if teacher_id in teacher_ids:
            raise ValueError(f"Duplicate teacher_id detected: {teacher_id}")
        teacher_ids.add(teacher_id)

    for section_key, section_data in sections.items():
        teacher = section_data.get("teacher")
        if teacher not in teachers:
            raise ValueError(f"Section {section_key} references unknown teacher {teacher}")

        section_code = section_data.get("section_code")
        if not isinstance(section_code, int):
            raise ValueError(f"Section {section_key} is missing integer section_code")
        if section_code in section_codes:
            raise ValueError(f"Duplicate section_code detected: {section_code}")
        section_codes.add(section_code)

        student_count = section_data.get("student_count")
        if not isinstance(student_count, int) or student_count < 0:
            raiseValueError(f"Section {section_key} has invalid student_count")

    for section_key in environment_sections:
        if section_key not in sections:
            raise ValueError(
                    f"Environment references section {section_key}, but it is missing from sections.yml"
            )


def build_runtime_artifacts(
        teachers_data: dict[str, Any],
        sections_data: dict[str, Any],
        policy_data: dict[str, Any],
        environment_data: dict[str, Any],
        existing_students: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, str]]]:
    teachers = teachers_data["teachers"]
    sections = sections_data["sections"]
    env_sections = environment_data["environment"]["sections"]

    validate_inputs(teachers, sections, env_sections)

    username_policy = policy_data.get("username_policy", {})
    password_policy = policy_data.get("password_policy", {})
    pool_policy = policy_data.get("pool_policy", {})

    # NOTE: Replace these with larger curated wordlists later.
    codenames = [
           "raven", "otter", "maple", "ember", "falcon", "cedar", "harbor", "comet",
        "badger", "lumen", "atlas", "echo", "pine", "nova", "cinder", "glade",
        "thunder", "quartz", "aurora", "river", "apex", "moss", "forge", "drift",
        "hawk", "sable", "summit", "onyx", "spruce", "dawn", "solace", "flux",
    ]
    pass_words_1 = [
        "maple", "tiger", "river", "silver", "ember", "forest", "copper", "ocean",
        "falcon", "cedar", "aurora", "quartz", "glacier", "thunder", "harbor",
    ]
    pass_words_2 = [
        "river", "ocean", "forge", "field", "ember", "summit", "harbor", "grove",
        "stone", "comet", "trail", "shore", "glade", "spark", "echo",
    ]

    student_pool_format = str(pool_policy.get("student_pool_format", "stu-<username>"))
    password_mode = str(password_policy.get("mode", "runtime_generated"))

    generated_students: list[dict[str, Any]] = []
    credentials_rows: list[dict[str, str]] = []
    used_usernames: set[str] = set()

    sorted_sections = sorted(
        env_sections.keys(),
        key=lambda key: section_sort_key(key, sections[key]),
    )

    for section_key in sorted_sections:
        section = sections[section_key]
        display_section = str(section["display_section"])
        student_count = int(section["student_count"])
        teacher = str(section["teacher"])

        teacher_record = teachers.get(teacher, {})
        teacher_id = int(teacher_record["teacher_id"])
        section_code = int(section["section_code"])

        if student_count > len(codenames):
            raise ValueError(
                f"Section {section_key} needs {student_count} students but only "
                f"{len(codenames)} codenames are available"
            )

        for idx in range(student_count):
            ordinal = idx + 1
            codename = codenames[idx]
            username = format_student_username(display_section, codename, ordinal)

            if username in used_usernames:
                raise ValueError(f"Duplicate generated username detected: {username}")
            used_usernames.add(username)

            existing = existing_students.get(username)
            if existing and "initial_password" in existing:
                initial_password = str(existing["initial_password"])
            else:
                if password_mode != "runtime_generated":
                    raise ValueError(f"Unsupported password mode: {password_mode}")
                seed = f"{teacher_id}-{section_code}-{idx}"
                rng = random.Random(seed)
                initial_password = generate_password(rng, pass_words_1, pass_words_2)

            proxmox_pool = student_pool_format.replace("<username>", username)

            record = {
                "username": username,
                "section": section_key,
                "student_index": idx,
                "proxmox_pool": proxmox_pool,
                "initial_password": initial_password,
            }
            generated_students.append(record)

            credentials_rows.append(
                {
                    "section": section_key,
                    "display_section": display_section,
                    "username": username,
                    "initial_password": initial_password,
                    "student_index": str(idx),
                    "teacher": teacher,
                }
            )

    generated_teachers: list[dict[str, Any]] = []
    for section_key in sorted_sections:
        section = sections[section_key]
        teacher = str(section["teacher"])
        generated_teachers.append(
            {
                "username": teacher,
                "section": section_key,
                "teacher_index": 0,
            }
        )

    students_yml = {
        "students": generated_students,
        "teachers": generated_teachers,
    }

    return students_yml, credentials_rows


def write_credentials_csv(path: Path, rows: list[dict[str, str]]) -> None:
    ensure_dir(path.parent)
    fieldnames = [
        "section",
        "display_section",
        "username",
        "initial_password",
        "student_index",
        "teacher",
    ]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_credentials_md(path: Path, rows: list[dict[str, str]]) -> None:
    ensure_dir(path.parent)
    with path.open("w", encoding="utf-8") as f:
        f.write("# Student Credentials\n\n")
        current_section = None
        for row in rows:
            section = row["section"]
            if section != current_section:
                current_section = section
                f.write(f"## {section}\n\n")
                f.write("| Username | Initial Password | Student Index |\n")
                f.write("|---|---|---|\n")
            f.write(
                f"| `{row['username']}` | `{row['initial_password']}` | {row['student_index']} |\n"
            )
        f.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate runtime student artifacts for Cyberlab")
    parser.add_argument(
        "--env",
        required=True,
        help="Environment name, e.g. school-lab or demo-lab",
    )
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Path to the repository root (default: current directory)",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    data_dir = repo_root / "data"
    private_generated_dir = repo_root / "private" / "generated"

    teachers_path = data_dir / "teachers.yml"
    sections_path = data_dir / "sections.yml"
    policy_path = data_dir / "policy.yml"
    env_path = data_dir / "environments" / f"{args.env}.yml"

    students_generated_path = private_generated_dir / "students.yml"
    credentials_csv_path = private_generated_dir / "credentials.csv"
    credentials_md_path = private_generated_dir / "credentials.md"

    teachers_data = load_yaml(teachers_path)
    sections_data = load_yaml(sections_path)
    policy_data = load_yaml(policy_path)
    environment_data = load_yaml(env_path)

    existing_students = read_existing_students(students_generated_path)

    students_yml, credentials_rows = build_runtime_artifacts(
        teachers_data=teachers_data,
        sections_data=sections_data,
        policy_data=policy_data,
        environment_data=environment_data,
        existing_students=existing_students,
    )

    ensure_dir(private_generated_dir)
    dump_yaml(students_generated_path, students_yml)
    write_credentials_csv(credentials_csv_path, credentials_rows)
    write_credentials_md(credentials_md_path, credentials_rows)

    print(f"Wrote {students_generated_path}")
    print(f"Wrote {credentials_csv_path}")
    print(f"Wrote {credentials_md_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main()) 
