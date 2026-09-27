#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/bin/cape-inetsim-selftest"
grep -Fq -- '--package ps1 --route "$route"' "$S"
grep -Fq 'submit_ps1 inetsim' "$S"
grep -Fq 'submit_ps1 internet' "$S"
grep -Fq 'wait_task_reported' "$S"
grep -Fq 'positive task has no INetSim DNS events' "$S"
grep -Fq 'positive task has no INetSim HTTP events' "$S"
grep -Fq 'positive task has no non-empty PCAP' "$S"
grep -Fq 'acceptance_reports.py' "$S"
grep -Fq 'CAPE_INETSIM_E2E_REQUIRED' "$ROOT/lib/deploy.sh"
grep -Fq 'cape-inetsim-selftest' "$ROOT/lib/deploy.sh"
grep -Fq 'cape-inetsim-selftest' "$ROOT/bin/cape-inetsim-repair"
grep -Fq -- '--selftest) MODE=selftest' "$ROOT/install"
grep -Fq 'exec bash "$AUTODEPLOY_ROOT/bin/cape-inetsim-selftest"' "$ROOT/install"

echo "[PASS] deployment and repair require real CAPE DNS/HTTP/PCAP/report self-test"
