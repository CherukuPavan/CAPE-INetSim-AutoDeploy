#!/usr/bin/env python3
"""Run one AutoDeploy PowerShell script through CAPE Agent /execpy.

The runner emits a versioned result envelope on stdout. This is deliberately
independent of CAPE Agent response-schema details: older agents may return HTTP
200 without child exit status, while newer agents may wrap stdout in base64.
The host validates this envelope instead of trusting the Agent's JSON schema.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys

ENVELOPE_PREFIX = "CAPE_INETSIM_RUNNER_V1:"

here = Path(__file__)
config_path = here.with_suffix(".json")

def emit(returncode, stdout=b"", stderr=b"", result_path="", runner_error=""):
    result = b""
    result_present = False
    if result_path:
        try:
            p = Path(result_path)
            if p.is_file():
                result = p.read_bytes()
                result_present = True
        except Exception as exc:
            if not runner_error:
                runner_error = f"could not read result file: {exc}"
    doc = {
        "schema": 1,
        "returncode": int(returncode),
        "stdout_b64": base64.b64encode(stdout or b"").decode("ascii"),
        "stderr_b64": base64.b64encode(stderr or b"").decode("ascii"),
        "result_present": bool(result_present),
        "result_b64": base64.b64encode(result).decode("ascii") if result_present else "",
        "runner_error": str(runner_error or ""),
    }
    payload = base64.b64encode(
        json.dumps(doc, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")
    sys.stdout.write(ENVELOPE_PREFIX + payload + "\n")
    sys.stdout.flush()

try:
    cfg = json.loads(config_path.read_text(encoding="utf-8"))
except Exception as exc:
    emit(41, runner_error=f"invalid AutoDeploy CAPE-agent runner config: {exc}")
    raise SystemExit(41)

script = str(cfg.get("script") or "")
arguments = cfg.get("arguments")
timeout = int(cfg.get("timeout", 600))
if not script or not isinstance(arguments, list) or not all(isinstance(x, str) for x in arguments):
    emit(42, runner_error="invalid AutoDeploy CAPE-agent runner arguments")
    raise SystemExit(42)
if timeout < 30 or timeout > 900:
    emit(43, runner_error="invalid AutoDeploy CAPE-agent runner timeout")
    raise SystemExit(43)

result_path = ""
for i, value in enumerate(arguments[:-1]):
    if value.lower() == "-resultpath":
        result_path = arguments[i + 1]
        break

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
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
except subprocess.TimeoutExpired as exc:
    emit(
        124,
        stdout=exc.stdout or b"",
        stderr=exc.stderr or b"",
        result_path=result_path,
        runner_error="AutoDeploy PowerShell timed out",
    )
    raise SystemExit(124)
except Exception as exc:
    emit(44, result_path=result_path, runner_error=f"AutoDeploy PowerShell launch failed: {exc}")
    raise SystemExit(44)

emit(
    proc.returncode,
    stdout=proc.stdout or b"",
    stderr=proc.stderr or b"",
    result_path=result_path,
)
raise SystemExit(proc.returncode)
