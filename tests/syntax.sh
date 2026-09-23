#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in "$ROOT/install" "$ROOT"/lib/*.sh "$ROOT"/bin/* "$ROOT"/tests/*.sh; do
  bash -n "$f"
done

[[ -x "$ROOT/install" ]] || { echo "[FAIL] install entrypoint is not executable" >&2; exit 1; }
for f in "$ROOT"/bin/cape-inetsim-*; do
  [[ -x "$f" ]] || { echo "[FAIL] operator entrypoint is not executable: $f" >&2; exit 1; }
done
VENDOR="$ROOT/vendor/CAPE-INetSim-VM-Extension-v1.0.2"
for f in "$VENDOR/install.sh" "$VENDOR"/scripts/*.sh; do
  bash -n "$f"
done
python3 -m py_compile "$VENDOR/scripts/prepare_install_candidate.py" "$VENDOR/src/inetsim_vm_logic.py" "$VENDOR/tests/test_django_candidate_ui.py"

grep -Fq 'source "$ROOT/lib/qga.sh"' "$ROOT/bin/cape-inetsim-verify"
grep -Fq 'source "$ROOT/lib/windows-management-dhcp.sh"' "$ROOT/bin/cape-inetsim-verify"

if command -v pwsh >/dev/null 2>&1; then
  for f in "$ROOT"/windows/*.ps1; do
    PS_PARSE_FILE="$f" pwsh -NoProfile -NonInteractive -Command '
      $tokens=$null; $errors=$null
      [System.Management.Automation.Language.Parser]::ParseFile($env:PS_PARSE_FILE,[ref]$tokens,[ref]$errors) | Out-Null
      if($errors.Count){ $errors | ForEach-Object { Write-Error $_.Message }; exit 1 }
    '
  done
fi

grep -Fq 'legacy_network_stack' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq 'legacy_network_stack' "$ROOT/windows/verify-inetsim.ps1"
grep -Fq 'Get-WmiObject Win32_NetworkAdapterConfiguration' "$ROOT/windows/configure-inetsim.ps1"
grep -Fq 'Get-WmiObject Win32_NetworkAdapterConfiguration' "$ROOT/windows/verify-inetsim.ps1"


echo "[PASS] shell/Python/PowerShell syntax, verifier dependencies and legacy Windows guards"
