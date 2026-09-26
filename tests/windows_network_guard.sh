#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/windows-network-guard.sh"

# Keep the legacy ownership-aware guard helpers for safe rollback/recovery of
# RC.44 deployments, but the route-scoped deployment path must not apply them.
python3 - "$ROOT/lib/windows-network-guard.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
assert "clean-traffic" in s
assert 'state_record_intent domain-interface-filter' in s
assert "windows_management_guard_restore_if_owned" in s
PY

! grep -Fq 'windows_management_guard_apply' <(
  python3 - "$ROOT/lib/deploy.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
a=s.index("deploy_windows_target_cutover()")
b=s.index("deploy_windows_cutover()",a)
print(s[a:b])
PY
)

! grep -Fq 'firewall_enable_windows_management_guard' <(
  python3 - "$ROOT/lib/deploy.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
a=s.index("deploy_windows_target_cutover()")
b=s.index("deploy_windows_cutover()",a)
print(s[a:b])
PY
)

grep -q 'windows_management_guard_restore_if_owned' "$ROOT/lib/windows-vm.sh"

echo '[PASS] legacy management guard remains recoverable but is not applied by route-scoped deployment'
