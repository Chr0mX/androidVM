#!/usr/bin/env python3
"""
Validate a profile JSON file against profiles/schema.json.
Adds fingerprint-consistency checks and friendlier prohibited-key errors
on top of the schema (the schema also encodes the prohibited-key rules).

Usage: profile-validator.py <profile.json>
"""
import sys
import json
import pathlib

try:
    import jsonschema
except ImportError:
    sys.exit("jsonschema not installed — run: pip3 install jsonschema")

# Keep in sync with the propertyNames prohibition pattern in profiles/schema.json
PROHIBITED_PREFIXES = ("ro.secure", "ro.debuggable", "ro.boot.", "persist.", "settings.secure.")
SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
SCHEMA_PATH = SCRIPT_DIR.parent.parent / "profiles" / "schema.json"


def check_prohibited(profile: dict) -> list[str]:
    errors = []
    for partition in ("system", "vendor", "product"):
        for key in profile.get(partition, {}):
            for prefix in PROHIBITED_PREFIXES:
                if key == prefix or key.startswith(prefix):
                    errors.append(
                        f"Prohibited key in '{partition}': {key} (matches prefix '{prefix}')"
                    )
    return errors


def check_fingerprint_consistency(profile: dict) -> list[str]:
    system = profile.get("system", {})
    vendor = profile.get("vendor", {})

    fp_sys  = system.get("ro.build.fingerprint", "")
    fp_sys2 = system.get("ro.system.build.fingerprint", "")
    fp_ven  = vendor.get("ro.vendor.build.fingerprint", "")

    def build_id(fp: str) -> str:
        parts = fp.split("/")
        return parts[4].split(":")[0] if len(parts) > 4 else ""

    def device(fp: str) -> str:
        parts = fp.split("/")
        return parts[2] if len(parts) > 2 else ""

    errors = []
    ids = {build_id(fp) for fp in (fp_sys, fp_sys2, fp_ven) if fp}
    if len(ids) > 1:
        errors.append(f"Fingerprint build ID mismatch across partitions: {ids}")

    devices = {device(fp) for fp in (fp_sys, fp_sys2, fp_ven) if fp}
    if len(devices) > 1:
        errors.append(f"Fingerprint device string mismatch across partitions: {devices}")

    if fp_sys and fp_sys2 and fp_sys != fp_sys2:
        errors.append("ro.build.fingerprint != ro.system.build.fingerprint")

    return errors


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"Usage: {sys.argv[0]} <profile.json>")

    profile_path = pathlib.Path(sys.argv[1])
    if not profile_path.exists():
        sys.exit(f"Profile not found: {profile_path}")

    if not SCHEMA_PATH.exists():
        sys.exit(f"Schema not found: {SCHEMA_PATH}")

    profile = json.loads(profile_path.read_text())
    schema  = json.loads(SCHEMA_PATH.read_text())

    # JSON Schema validation
    validator = jsonschema.Draft7Validator(schema)
    schema_errors = sorted(validator.iter_errors(profile), key=lambda e: e.path)
    if schema_errors:
        print(f"[validator] FAIL: {profile_path}", file=sys.stderr)
        for e in schema_errors:
            path = ".".join(str(p) for p in e.absolute_path) or "(root)"
            print(f"  schema error at {path}: {e.message}", file=sys.stderr)
        sys.exit(1)

    # Prohibited key check
    prohibited_errors = check_prohibited(profile)
    if prohibited_errors:
        print(f"[validator] FAIL: {profile_path}", file=sys.stderr)
        for e in prohibited_errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(1)

    # Fingerprint consistency
    fp_errors = check_fingerprint_consistency(profile)
    if fp_errors:
        print(f"[validator] FAIL: {profile_path}", file=sys.stderr)
        for e in fp_errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(1)

    print(f"[validator] OK: {profile_path}")


if __name__ == "__main__":
    main()
