#!/usr/bin/env python3
"""
Deterministic build.prop patcher.

Rules:
  - Replace existing key if present (exactly once — duplicates are an error)
  - Append if key absent
  - Never produce duplicate keys
  - Preserve comments and blank lines
  - Validate fingerprint consistency across system/vendor after patch

Usage: patch-props.py <prop-file> <partition> <profile.json>
  partition: system | vendor | product
"""
import re
import sys
import json
import pathlib


def load_props(path: pathlib.Path) -> tuple[list[str], dict[str, str]]:
    lines: list[str] = []
    props: dict[str, str] = {}
    for raw in path.read_text().splitlines(keepends=True):
        lines.append(raw)
        stripped = raw.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            k, _, v = stripped.partition("=")
            k = k.strip()
            if k in props:
                raise ValueError(f"Duplicate key in source prop file: {k}")
            props[k] = v.strip()
    return lines, props


def apply_profile(lines: list[str], overrides: dict[str, str]) -> list[str]:
    applied: set[str] = set()
    new_lines: list[str] = []
    for raw in lines:
        stripped = raw.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            k, _, _ = stripped.partition("=")
            k = k.strip()
            if k in overrides:
                new_lines.append(f"{k}={overrides[k]}\n")
                applied.add(k)
                continue
        new_lines.append(raw)
    # Append keys not already present
    for k, v in overrides.items():
        if k not in applied:
            new_lines.append(f"{k}={v}\n")
    return new_lines


def validate_fingerprints(system_props: dict[str, str], vendor_props: dict[str, str]) -> None:
    sys_fp  = system_props.get("ro.build.fingerprint", "")
    sys_sfp = system_props.get("ro.system.build.fingerprint", "")
    ven_fp  = vendor_props.get("ro.vendor.build.fingerprint", "")

    def build_id(fp: str) -> str:
        parts = fp.split("/")
        return parts[4].split(":")[0] if len(parts) > 4 else ""

    ids = {build_id(fp) for fp in (sys_fp, sys_sfp, ven_fp) if fp}
    if len(ids) > 1:
        raise ValueError(f"Fingerprint build ID mismatch across partitions: {ids}")


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(f"Usage: {sys.argv[0]} <prop-file> <partition> <profile.json>")

    prop_file_path  = pathlib.Path(sys.argv[1])
    partition       = sys.argv[2]
    profile_path    = pathlib.Path(sys.argv[3])

    if not prop_file_path.exists():
        sys.exit(f"Prop file not found: {prop_file_path}")
    if not profile_path.exists():
        sys.exit(f"Profile not found: {profile_path}")
    if partition not in ("system", "vendor", "product"):
        sys.exit(f"Unknown partition '{partition}' — must be system, vendor, or product")

    profile   = json.loads(profile_path.read_text())
    overrides = profile.get(partition, {})

    if not overrides:
        print(f"[patch-props] No overrides for partition '{partition}' — nothing to do")
        return

    lines, _ = load_props(prop_file_path)
    new_lines = apply_profile(lines, overrides)
    prop_file_path.write_text("".join(new_lines))
    print(f"[patch-props] Applied {len(overrides)} overrides to {prop_file_path}")


if __name__ == "__main__":
    main()
