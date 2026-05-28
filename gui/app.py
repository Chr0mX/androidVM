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
    serial_log = ROOT / "run" / f"{name}-serial.log"
    log_tail = ""
    if serial_log.exists():
        try:
            with serial_log.open("rb") as f:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - 8192))
                log_tail = f.read().decode("utf-8", errors="replace")
        except OSError:
            log_tail = "(could not read serial log)"
    return render_template("detail.html", inst=inst, log_tail=log_tail)


@app.route("/instances/<name>/<action>", methods=["POST"])
def instance_action(name, action):
    if action not in {"start", "stop", "restart", "reset", "delete", "expand"}:
        return jsonify({"error": "invalid action"}), 400

    if action == "expand":
        size = request.form.get("size", "").strip()
        if not size:
            return "<pre>size is required</pre>", 400
        r = run_cli("instance", "expand", name, size, "--apply", timeout=300)
        if r.returncode != 0:
            return f"<pre>{r.stderr or r.stdout}</pre>", 500
        return redirect(url_for("instance_detail", name=name))

    # start runs the VM in the foreground; for the GUI we want it backgrounded
    args = ["instance", action, name]
    if action == "start":
        # Boot in headless mode so the Flask process doesn't block; user can
        # connect via SPICE/VNC/ADB from the instance detail page.
        # We background the subprocess and return immediately.
        # The android-vm CLI handles its own PID file when --headless is used.
        subprocess.Popen(
            ["bash", str(CLI), "start", name, "--headless"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            cwd=str(ROOT), start_new_session=True,
        )
        return redirect(url_for("instance_detail", name=name))

    r = run_cli(*args, timeout=60)
    if r.returncode != 0 and action != "stop":
        # stop returning non-zero when already stopped is fine
        return f"<pre>{r.stderr or r.stdout}</pre>", 500

    if action == "delete":
        return redirect(url_for("index"))
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
