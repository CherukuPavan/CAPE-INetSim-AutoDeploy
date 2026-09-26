#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/windows-network-guard.sh"

python3 - "$ROOT/lib/windows-network-guard.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
assert "clean-traffic" in s
assert 'parameter",{"name":"IP","value":ip}' in s
assert "refusing to overwrite operator policy" in s
assert "state_record_intent domain-interface-filter" in s
assert "windows_management_guard_restore_if_owned" in s
assert '"shut off"|paused' in s
assert 'update_args+=(--live)' in s
assert 'windows_management_guard_exact current' in s
assert '"$state" == running || "$state" == paused' in s
PY

grep -q 'windows_management_guard_apply' "$ROOT/lib/deploy.sh"
grep -q 'firewall_enable_windows_management_guard' "$ROOT/lib/deploy.sh"
grep -q 'windows_management_guard_restore_if_owned' "$ROOT/lib/windows-vm.sh"

echo '[PASS] Windows management NIC has anti-spoof guard lifecycle'

grep -Fq 'snapshot does not preserve the Windows management anti-spoof guard' "$ROOT/lib/validate.sh"
grep -Fq '"$WINDOWS_MGMT_FILTER_NAME"' "$ROOT/lib/validate.sh"
