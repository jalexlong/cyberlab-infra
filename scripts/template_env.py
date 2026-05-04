#!/usr/bin/env python3
import sys
import shlex
from pathlib import Path

import yaml


def shell_quote(value):
    if isinstance(value, bool):
        value = "true" if value else "false"
    elif value is None:
        value = ""
    else:
        value = str(value)
    return shlex.quote(value)


def main():
    if len(sys.argv) != 3:
        print("usage: template_env.py <templates.yml> <template_key>", file=sys.stderr)
        sys.exit(1)

    templates_file = Path(sys.argv[1])
    template_key = sys.argv[2]

    data= yaml.safe_load(templates_file.read_text())
    template = data["templates"][template_k3y]

    build = template.get("build", {})
    candidate = template.get("candidate", {})
    approved = template.get("approved", {})

    env = {
        "TEMPLATE_KEY": template_key,
        "DISPLAY_NAME": template.get("display_name"),
        "SOURCE_TYPE": template.get("source_type"),
        "SOURCE_URL": template.get("source_url"),
        "DRIVER_ISO_URL": template.get("driver_iso_url"),
        "CANDIDATE_VMID": candidate.get("vmid"),
        "CANDIDATE_NAME": candidate.get("name"),
        "APPROVED_VMID": approved.get("vmid"),
        "APPROVED_NAME": approved.get("name"),
        "BUILD_METHOD": build.get("method"),
        "OS_TYPE": build.get("os_type"),
        "CPU": build.get("cpu"),
        "MEMORY_MB": build.get("memory_mb"),
        "DISK_GB": build.get("disk_gb"),
        "SCSIHW": build.get("scsihw"),
        "NET_MODEL": build.get("net_model"),
        "BRIDGE": build.get("bridge"),
        "AGENT_EXPECTED": build.get("agent_expected"),
        "CLOUD_INIT": build.get("cloud_init"),
        "BIOS": build.get("bios"),
        "MACHINE": build.get("machine"),
        "DISK_BUS": build.get("disk_bus"),
    }

    for key, value in env.items():
        if value is not None:
            print(f"export {key}={shell_quote(value)}")


if __name__ == "__main__":
    main()
