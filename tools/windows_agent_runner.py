#!/usr/bin/env python3
"""Run one AutoDeploy PowerShell script through CAPE Agent /execpy.

The CAPE Agent execpy endpoint supplies only the Python filepath, so this runner
reads a sibling JSON file with the exact script path and argument vector. It is
uploaded only during the maintenance window and removed immediately afterward.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

here = Path(__file__)
config_path = here.with_suffix(".json")
try:
    cfg = json.loads(config_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"invalid AutoDeploy CAPE-agent runner config: {exc}", file=sys.stderr)
    raise SystemExit(41)

script = str(cfg.get("script") or "")
arguments = cfg.get("arguments")
timeout = int(cfg.get("timeout", 600))
if not script or not isinstance(arguments, list) or not all(isinstance(x, str) for x in arguments):
    print("invalid AutoDeploy CAPE-agent runner arguments", file=sys.stderr)
    raise SystemExit(42)
if timeout < 30 or timeout > 900:
    print("invalid AutoDeploy CAPE-agent runner timeout", file=sys.stderr)
    raise SystemExit(43)

windir = os.environ.get("WINDIR", r"C:\Windows")
candidates = [
    os.path.join(windir, "Sysnative", "WindowsPowerShell", "v1.0", "powershell.exe"),
    os.path.join(windir, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
]
powershell = next((p for p in candidates if os.path.isfile(p)), "powershell.exe")
cmd = [
    powershell,
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    script,
    *arguments,
]
try:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
except subprocess.TimeoutExpired:
    print("AutoDeploy PowerShell timed out", file=sys.stderr)
    raise SystemExit(124)
except Exception as exc:
    print(f"AutoDeploy PowerShell launch failed: {exc}", file=sys.stderr)
    raise SystemExit(44)

if proc.stdout:
    sys.stdout.buffer.write(proc.stdout)
if proc.stderr:
    sys.stderr.buffer.write(proc.stderr)
raise SystemExit(proc.returncode)
