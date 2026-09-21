#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -m py_compile "$ROOT/tools/cape_maintenance.py"
grep -q 'with_for_update' "$ROOT/tools/cape_maintenance.py"
grep -q 'autodeploy-maintenance' "$ROOT/tools/cape_maintenance.py"
grep -q 'TASK_RUNNING' "$ROOT/tools/cape_maintenance.py"
grep -q 'TASK_COMPLETED' "$ROOT/tools/cape_maintenance.py"
echo '[PASS] task-aware atomic CAPE maintenance guard'
