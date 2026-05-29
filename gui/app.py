#!/usr/bin/env python3
"""Flask web UI for android-vm. Manages instances by shelling out to the CLI.

State lives in instances/*.json on disk — Flask just renders and dispatches.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from flask import Flask, jsonify, redirect, render_template, request, url_for

ROOT = Path(os.environ.get("ANDROID_VM_ROOT", Path(__file__).resolve().parent.parent))
CLI = ROOT / "android-vm"

app = Flask(__name__, template_folder=str(Path(__file__).parent / "templates"),
            static_folder=str(Path(__file__).parent / "static"))


def run_cli(*args: str, timeout: int = 30) -> subprocess.CompletedProcess:
    """Invoke `android-vm <args>` and return the result."""
    return subprocess.run(
        ["bash", str(CLI), *args],
        capture_output=True, text=True, timeout=timeout, cwd=str(ROOT),
    )


def read_tail(path: Path, n: int = 8192) -> str:
    """Return the last ``n`` bytes of a file, or "" if it doesn't exist."""
    if not path.exists():
        return ""
    try:
        with path.open("rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - n))
            return f.read().decode("utf-8", errors="replace")
    except OSError:
        return "(could not read log)"


def is_running(name: str) -> bool:
    """Mirror instance.sh's instance_running: PID file present + process alive."""
    pid_file = ROOT / "run" / f"{name}.pid"
    try:
        pid = int(pid_file.read_text().strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def error_page(message: str, detail: str = "", code: int = 500,
               heading: str = "", back_name: str = ""):
    """Render a friendly error page so failed actions are never silent."""
    return render_template("error.html", message=message, detail=detail,
                           heading=heading, back_name=back_name), code


def list_instances() -> list[dict]:
    """Return instance list parsed from `android-vm instance list --json`."""
    r = run_cli("instance", "list", "--json")
    if r.returncode != 0 or not r.stdout.strip():
        return []
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return []


def list_choices() -> dict:
    """Return dropdown options for the create form."""
    def names_from(dirpath: Path, exclude=("schema.json",)) -> list[str]:
        if not dirpath.exists():
            return []
        return sorted(
            p.stem for p in dirpath.glob("*.json") if p.name not in exclude
        )

    return {
        "device_profiles": names_from(ROOT / "profiles"),
        "vm_profiles":     names_from(ROOT / "config" / "vm-profiles"),
        "distros":         names_from(ROOT / "androiddistro"),
    }


# ── Routes ────────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html", instances=list_instances())


@app.route("/api/instances")
def api_instances():
    return jsonify(list_instances())


@app.route("/instances/new", methods=["GET", "POST"])
def create_instance():
    if request.method == "POST":
        name           = request.form.get("name",           "").strip()
        device_profile = request.form.get("device_profile", "").strip()
        vm_profile     = request.form.get("vm_profile",     "").strip()
        distro         = request.form.get("distro",         "").strip()
        if not all([name, device_profile, vm_profile, distro]):
            return render_template("new.html",
                                   choices=list_choices(),
                                   error="All fields are required",
                                   form=request.form), 400
        r = run_cli("instance", "create", name,
                    "--profile", device_profile,
                    "--vm-profile", vm_profile,
                    "--distro", distro)
        if r.returncode != 0:
            return render_template("new.html",
                                   choices=list_choices(),
                                   error=r.stderr or r.stdout or "create failed",
                                   form=request.form), 400
        return redirect(url_for("instance_detail", name=name))
    return render_template("new.html", choices=list_choices(),
                           error=None, form={})


@app.route("/instances/<name>")
def instance_detail(name):
    instances = {i["name"]: i for i in list_instances()}
    if name not in instances:
        return redirect(url_for("index"))
    inst = instances[name]
    log_tail = read_tail(ROOT / "run" / f"{name}-serial.log")
    return render_template("detail.html", inst=inst, log_tail=log_tail)


@app.route("/instances/<name>/<action>", methods=["POST"])
def instance_action(name, action):
    if action not in {"start", "stop", "restart", "reset", "delete", "expand"}:
        return jsonify({"error": "invalid action"}), 400

    if action == "expand":
        size = request.form.get("size", "").strip()
        if not size:
            return error_page("A size is required (e.g. +4G or 16G).",
                              code=400, back_name=name)
        r = run_cli("instance", "expand", name, size, "--apply", timeout=300)
        if r.returncode != 0:
            return error_page(f"Could not expand '{name}'.",
                              detail=r.stderr or r.stdout, back_name=name)
        return redirect(url_for("instance_detail", name=name))

    if action == "start":
        return _start_instance(name)

    r = run_cli("instance", action, name, timeout=60)
    if r.returncode != 0 and action != "stop":
        # stop returning non-zero when already stopped is fine.
        return error_page(f"Could not {action} '{name}'.",
                          detail=r.stderr or r.stdout, back_name=name)

    if action == "delete":
        return redirect(url_for("index"))
    return redirect(url_for("instance_detail", name=name))


def _start_instance(name):
    """Boot the VM headless and confirm it actually came up.

    The old version fire-and-forgot the subprocess with output sent to
    /dev/null, so any failure (no disk built, missing OVMF, no host GL)
    looked exactly like success — the button "did nothing". Here we:
      1. pre-flight the disk so the common "not built yet" case is clear,
      2. capture the launcher's output so pre-boot errors are visible,
      3. verify QEMU stayed up so immediate crashes are reported.
    """
    disk = ROOT / "instances" / name / "disk.qcow2"
    if not disk.exists():
        return error_page(
            f"Instance '{name}' has no disk image yet, so there is nothing "
            "to boot. Build it once on the command line:",
            detail=f"bash scripts/set-profile.sh {name}",
            code=409, heading="Disk not built", back_name=name)

    if is_running(name):
        return redirect(url_for("instance_detail", name=name))

    # boot.sh backgrounds QEMU and returns promptly. Capture its output to a
    # launch log so pre-boot failures (die messages on stderr) are recoverable.
    launch_log = ROOT / "run" / f"{name}-launch.log"
    launch_log.parent.mkdir(parents=True, exist_ok=True)
    with launch_log.open("wb") as lf:
        proc = subprocess.Popen(
            ["bash", str(CLI), "start", name, "--headless"],
            stdout=lf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
            cwd=str(ROOT), start_new_session=True,
        )
    try:
        rc = proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        rc = 0  # launcher unexpectedly still attached — assume it's coming up
    if rc != 0:
        return error_page(
            f"Failed to start '{name}' (launcher exited {rc}).",
            detail=read_tail(launch_log), back_name=name)

    # QEMU launched; make sure it didn't exit on the spot (bad OVMF, no GL …).
    time.sleep(1.5)
    if not is_running(name):
        detail = (read_tail(ROOT / "run" / f"{name}-serial.log")
                  or read_tail(launch_log)
                  or "(no output captured)")
        return error_page(
            f"'{name}' started but the VM exited immediately. This usually "
            "means QEMU could not initialise — most often no host OpenGL "
            "(profiles use gtk,gl=on) or a missing OVMF firmware.",
            detail=detail, heading="VM exited immediately", back_name=name)

    return redirect(url_for("instance_detail", name=name))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--debug", action="store_true")
    args = p.parse_args()
    print(f"android-vm GUI on http://{args.host}:{args.port}/  (root={ROOT})",
          file=sys.stderr)
    app.run(host=args.host, port=args.port, debug=args.debug)


if __name__ == "__main__":
    main()
