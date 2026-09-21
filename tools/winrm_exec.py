#!/usr/bin/env python3
import argparse
import base64
import json
import os
import sys

p = argparse.ArgumentParser(description="Execute AutoDeploy PowerShell over an explicitly configured WinRM channel")
p.add_argument("--host", required=True)
p.add_argument("--port", required=True, type=int, choices=(5985, 5986))
p.add_argument("--username", required=True)
p.add_argument("--script", required=True)
p.add_argument("--result-path", required=True)
p.add_argument("--cert-validation", choices=("validate", "ignore"), default="validate")
p.add_argument("script_args", nargs=argparse.REMAINDER)
a = p.parse_args()

try:
    import winrm
except Exception as exc:
    print(f"pywinrm unavailable: {exc}", file=sys.stderr)
    raise SystemExit(41)

password = sys.stdin.read()
if password.endswith("\n"):
    password = password[:-1]
if not password:
    print("empty WinRM password", file=sys.stderr)
    raise SystemExit(42)

scheme = "https" if a.port == 5986 else "http"
endpoint = f"{scheme}://{a.host}:{a.port}/wsman"
session = winrm.Session(
    endpoint,
    auth=(a.username, password),
    transport="ntlm",
    server_cert_validation=a.cert_validation,
)

script = open(a.script, "rb").read()
encoded = base64.b64encode(script).decode("ascii")
args = a.script_args
if args and args[0] == "--":
    args = args[1:]

def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"

arg_text = " ".join(ps_quote(x) for x in args)
remote_script = r"C:\Windows\Temp\cape-inetsim-autodeploy-winrm.ps1"
wrapper = f"""
$ErrorActionPreference='Stop'
$bytes=[Convert]::FromBase64String('{encoded}')
[IO.File]::WriteAllBytes('{remote_script}',$bytes)
try {{
  & '{remote_script}' {arg_text}
  $rc=$LASTEXITCODE
  if ($null -eq $rc) {{ $rc=0 }}
  if (Test-Path {ps_quote(a.result_path)}) {{
    Get-Content -Raw -LiteralPath {ps_quote(a.result_path)}
  }}
  exit $rc
}}
finally {{
  Remove-Item -Force -LiteralPath '{remote_script}' -ErrorAction SilentlyContinue
}}
"""
result = session.run_ps(wrapper)
if result.std_out:
    sys.stdout.buffer.write(result.std_out)
if result.std_err:
    sys.stderr.buffer.write(result.std_err)
raise SystemExit(result.status_code)
