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
