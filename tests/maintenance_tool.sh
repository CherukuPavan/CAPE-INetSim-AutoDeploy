#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -m py_compile "$ROOT/tools/cape_maintenance.py"
grep -q 'with_for_update' "$ROOT/tools/cape_maintenance.py"
grep -q 'maintenance_locked_changed_on' "$ROOT/tools/cape_maintenance.py"
grep -q 'deployment_id' "$ROOT/tools/cape_maintenance.py"
grep -q 'a.action=="verify"' "$ROOT/tools/cape_maintenance.py"
grep -q 'm.locked=True' "$ROOT/tools/cape_maintenance.py"
! grep -q 'm.status="autodeploy-maintenance"' "$ROOT/tools/cape_maintenance.py"
grep -q 'TASK_RUNNING' "$ROOT/tools/cape_maintenance.py"
grep -q 'TASK_COMPLETED' "$ROOT/tools/cape_maintenance.py"
echo '[PASS] task-aware atomic CAPE maintenance guard uses lock ownership marker'

grep -Fq 'pending-guard-partial-state' "$ROOT/tools/cape_maintenance.py"
grep -Fq 'recovered":True' "$ROOT/tools/cape_maintenance.py"
grep -Fq 'local user_dir="/tmp/cape-inetsim-autodeploy-$DEPLOYMENT_ID"' "$ROOT/lib/maintenance.sh"
grep -Fq 'verify --label "$CAPE_MACHINE_LABEL"' "$ROOT/lib/maintenance.sh"

grep -Fq 'REPAIR_CAPE_ACTIVE" == yes || "$REPAIR_PROCESSOR_ACTIVE" == yes' "$ROOT/bin/cape-inetsim-repair"
grep -Fq 'cape-processor may still be reporting a' "$ROOT/bin/cape-inetsim-repair"

grep -Fq 'MODEL_STATUS_ENUMS=set(getattr(Task.__table__.c.status.type,"enums",()) or ())' "$ROOT/tools/cape_maintenance.py"
grep -Fq 'ACTIVE=tuple(s for s in ACTIVE_CANDIDATES if not MODEL_STATUS_ENUMS or s in MODEL_STATUS_ENUMS)' "$ROOT/tools/cape_maintenance.py"
grep -Fq 'cape-maintenance.log' "$ROOT/lib/maintenance.sh"

grep -Fq 'local user_tool="$user_dir/cape_maintenance.py"' "$ROOT/lib/maintenance.sh"
grep -Fq 'install -m 0500 -o "$CAPE_SERVICE_USER" "$AUTODEPLOY_ROOT/tools/cape_maintenance.py" "$user_tool"' "$ROOT/lib/maintenance.sh"
grep -Fq '"$CAPE_RUNTIME_PYTHON" "$user_tool" "$action"' "$ROOT/lib/maintenance.sh"
