#!/usr/bin/env python3
"""Request a forced Windows shutdown after CAPE Agent has returned HTTP 200.

This helper is intentionally tiny. It is launched asynchronously by CAPE Agent;
a short delay lets the spawn response reach the host before Windows begins
shutdown. The host then verifies the libvirt domain reaches "shut off".
"""
from pathlib import Path
import subprocess
import time

# Do not leave deployment tooling inside the configured guest/snapshots.
try:
    Path(__file__).unlink()
except Exception:
    pass

time.sleep(2)
subprocess.Popen(
    ["shutdown.exe", "/s", "/t", "0", "/f"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
