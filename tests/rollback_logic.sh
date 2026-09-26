#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT/lib/rollback.sh" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
main=s[s.index("autodeploy_rollback_internal()"):]
a=main.index("rollback_restore_cutover")
b=main.index("rollback_remove_staged_resources")
c=main.index("rollback_finish_cape_handoff")
assert a < b < c, "rollback teardown/handoff ordering regressed"

prepare=s[s.index("rollback_prepare_cape_maintenance()"):s.index("rollback_restore_cutover()")]
assert "services_stop_scheduler_for_handoff" in prepare
assert "cape_wait_and_acquire_maintenance" in prepare
assert prepare.index("services_stop_scheduler_for_handoff") < prepare.index("cape_wait_and_acquire_maintenance"), "scheduler must stop before rollback maintenance acquire"

restore=s[s.index("rollback_restore_cutover()"):s.index("rollback_remove_staged_resources()")]
assert "cape_release_maintenance" not in restore
assert "services_restore_desired_state" not in restore
assert "services_stop_scheduler_for_handoff" in restore

remove=s[s.index("rollback_remove_staged_resources()"):s.index("rollback_finish_cape_handoff()")]
assert "ROLLBACK_CRITICAL_FAILURES > 0" in remove
assert "preserving containment firewall/network/appliance resources for safe retry" in remove
assert remove.index("ROLLBACK_CRITICAL_FAILURES > 0") < remove.index("firewall_rollback")
assert "routing_forwarding_rollback" not in remove

finish=s[s.index("rollback_finish_cape_handoff()"):s.index("autodeploy_rollback_internal()")]
assert "ROLLBACK_CRITICAL_FAILURES" in finish
assert "routing_forwarding_rollback" in finish
assert finish.index("cape_release_maintenance") < finish.index("routing_forwarding_rollback")
assert finish.index("routing_forwarding_rollback") < finish.index("services_restore_desired_state")
assert "preserving CAPE maintenance ownership and leaving scheduler closed" in finish
PY

grep -Fq 'intentionally left the analysis VM shut off for network safety' "$ROOT/lib/windows-vm.sh"
grep -Fq 'local maintenance_needed=no' "$ROOT/lib/rollback.sh"
grep -Fq 'services_stop_scheduler_for_handoff || return 1' "$ROOT/lib/rollback.sh"

echo '[PASS] rollback keeps scheduling closed until network teardown is complete'
