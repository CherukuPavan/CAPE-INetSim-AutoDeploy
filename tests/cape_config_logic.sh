#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/targets.sh"
source "$ROOT/lib/cape-configure.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/sniffer.py" <<'PY'
import logging
log=logging.getLogger(__name__)
router_cfg=type("R",(),{"routing":type("X",(),{"route":"none"})()})()
class X:
    def f(self):
        host = self.machine.ip
        # Selects per-machine interface if available.
        interface = self.machine.interface or self.options.get("interface")
PY

patch_sniffer_capture_override "$TMP/sniffer.py"
grep -q 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2' "$TMP/sniffer.py"
grep -q 'effective_route' "$TMP/sniffer.py"
grep -q 'inetsim_capture_interface_' "$TMP/sniffer.py"
patch_sniffer_capture_override "$TMP/sniffer.py"
[[ "$(grep -c CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2 "$TMP/sniffer.py")" -eq 1 ]]
echo '[PASS] route-aware CAPE sniffer patch logic'

source "$ROOT/lib/compat.sh"
CAPE_ROOT="$TMP/cape"
mkdir -p "$CAPE_ROOT/conf" "$CAPE_ROOT/modules/auxiliary" "$CAPE_ROOT/web/analysis" "$CAPE_ROOT/lib/cuckoo/core/data"

cat >"$CAPE_ROOT/lib/cuckoo/core/data/machines.py" <<'PY'
class Machine(Base):
    locked: Mapped[bool]
    locked_changed_on: Mapped[object]
def f(stmt):
    return stmt.with_for_update(of=Machine)
PY
cat >"$CAPE_ROOT/lib/cuckoo/core/data/task.py" <<'PY'
TASK_RUNNING = "running"
TASK_DISTRIBUTED = "distributed"
TASK_COMPLETED = "completed"
TASK_DISTRIBUTED_COMPLETED = "distributed_completed"
PY
cat >"$CAPE_ROOT/lib/cuckoo/core/data/db_common.py" <<'PY'
def _utcnow_naive():
    pass
PY
cat >"$CAPE_ROOT/lib/cuckoo/core/database.py" <<'PY'
class _Database(object):
    pass
class Database:
    pass
def init_database(*args, **kwargs):
    pass
PY
cat >"$CAPE_ROOT/conf/kvm.conf" <<'EOF'
[win10]
label = win10
ip = 192.0.2.10
EOF
cat >"$CAPE_ROOT/conf/auxiliary.conf" <<'EOF'
[sniffer]
enabled = yes
EOF
cat >"$CAPE_ROOT/conf/processing.conf" <<'EOF'
[network]
enabled = yes
EOF
cat >"$CAPE_ROOT/conf/routing.conf" <<'EOF'
[routing]
route = none
enable_pcap = yes

[inetsim]
enabled = no
server = 192.0.2.2
dnsport = 53
interface = virbr1
ports =
EOF
touch "$CAPE_ROOT/web/analysis/views.py"
cp "$TMP/sniffer.py" "$CAPE_ROOT/modules/auxiliary/sniffer.py"
CAPE_TARGETS_JSON='[{"section":"win10","label":"win10","ip":"192.0.2.10","domain":"win10"}]'
CAPE_TARGETS_COUNT=1
targets_bind 0
COMPAT_NOTES=()
check_cape_layout
[[ "$COMPAT_STATUS" == plan-compatible ]]

grep -Fq 'inetsim enabled yes' "$ROOT/lib/cape-configure.sh"
grep -Fq 'inetsim server "$INETSIM_IP"' "$ROOT/lib/cape-configure.sh"
grep -Fq 'inetsim interface "$ISOLATED_BRIDGE_NAME"' "$ROOT/lib/cape-configure.sh"
grep -Fq 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2' "$ROOT/lib/validate.sh"

# Legacy route-global capture must not be adopted as route-separated.
sed 's/CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2/CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1/' "$TMP/sniffer.py" >"$CAPE_ROOT/modules/auxiliary/sniffer.py"
COMPAT_NOTES=()
check_cape_layout
[[ "$COMPAT_STATUS" == plan-only-unknown-cape-layout ]]

echo '[PASS] compatibility rejects legacy global fake-network capture semantics'
