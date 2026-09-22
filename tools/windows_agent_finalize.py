#!/usr/bin/env python3
"""Deferred cleanup for the temporary CAPE-Agent isolated control path.

This script is launched asynchronously through CAPE Agent only after the full
Windows hardening request has returned successfully. It waits briefly so the
HTTP response can leave over the temporary pinned route, then removes that
route and the temporary Windows Firewall rule. CAPE control then returns to the
normal management NIC.
"""
import json
from pathlib import Path
import subprocess
import sys
import time

RULE_NAME = "CAPE-INetSim-AutoDeploy isolated control"

here = Path(__file__)
cfg_path = here.with_suffix(".json")
try:
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(41)

client_ip = str(cfg.get("pinned_client_ip") or "")
delay = int(cfg.get("delay_seconds", 5))
if not client_ip:
    raise SystemExit(42)
if delay < 1 or delay > 30:
    raise SystemExit(43)

time.sleep(delay)

# Route deletion is idempotent for our purposes. Verification is performed
# afterward over the management CAPE-Agent path.
subprocess.run(
    ["route.exe", "delete", client_ip, "mask", "255.255.255.255"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    check=False,
)
subprocess.run(
    [
        "netsh.exe", "advfirewall", "firewall", "delete", "rule",
        f"name={RULE_NAME}",
    ],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    check=False,
)
raise SystemExit(0)
