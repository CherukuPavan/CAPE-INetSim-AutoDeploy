#!/usr/bin/env bash
set -euo pipefail
trap 'echo "[FAIL] cape_config_logic.sh line $LINENO: $BASH_COMMAND" >&2' ERR
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
cat >"$CAPE_ROOT/lib/cuckoo/core/startup.py" <<'PY'
def init_routing():
    if routing.inetsim.enabled and routing.inetsim.interface and not _skip_rooter:
        is_nic_available = rooter("nic_available", routing.inetsim.interface)["output"]
        if routing.routing.auto_rt:
            rooter("flush_rttable", routing.routing.rt_table)
            rooter("init_rttable", routing.routing.rt_table, routing.routing.internet)
PY

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
cat >"$CAPE_ROOT/web/templates/analysis/network/index.html" <<'EOF'
<ul id="networkTabs"></ul>
EOF
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
grep -Fq 'routing route none' "$ROOT/lib/cape-configure.sh"
grep -Fq 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2' "$ROOT/lib/validate.sh"
grep -Fq 'inetsim_capture_host_${CAPE_MACHINE_LABEL}" "$CAPE_MACHINE_IP"' "$ROOT/lib/cape-configure.sh"
grep -Fq 'cape_probe_inetsim_rooter_all' "$ROOT/lib/validate.sh"
grep -Fq 'rooter(command, iface)' "$ROOT/lib/cape-configure.sh"
grep -Fq 'def inetsim_enable(' "$ROOT/lib/cape-configure.sh"
grep -Fq 'grep -Eq' "$ROOT/lib/cape-configure.sh"

# Legacy RC44 route-global capture remains rejected for normal deploys.
cat >"$CAPE_ROOT/modules/auxiliary/sniffer.py" <<'PY'
import logging
log=logging.getLogger(__name__)
class X:
    def f(self):
        # CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1
        capture_host_key = f"capture_host_{self.machine.label}"
        host = self.options.get(capture_host_key) or self.machine.ip
        if host != self.machine.ip:
            log.info("Using packet-capture host override %s=%s", capture_host_key, host)
        # Selects per-machine interface if available.
        interface = self.machine.interface or self.options.get("interface")
PY
COMPAT_NOTES=()
unset CAPE_INETSIM_ALLOW_LEGACY_UPGRADE || true
check_cape_layout
[[ "$COMPAT_STATUS" == plan-only-unknown-cape-layout ]]

# Explicit repair migration may upgrade only this exact known legacy source.
CAPE_INETSIM_ALLOW_LEGACY_UPGRADE=yes
export CAPE_INETSIM_ALLOW_LEGACY_UPGRADE
COMPAT_NOTES=()
check_cape_layout
[[ "$COMPAT_STATUS" == plan-compatible ]]
patch_sniffer_capture_override "$CAPE_ROOT/modules/auxiliary/sniffer.py"
[[ "$(grep -Fc CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2 "$CAPE_ROOT/modules/auxiliary/sniffer.py")" -eq 1 ]]
! grep -Fq CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1 "$CAPE_ROOT/modules/auxiliary/sniffer.py"
grep -Fq 'effective_route == "inetsim"' "$CAPE_ROOT/modules/auxiliary/sniffer.py"

# Migration must put the normal/original CAPE snapshot back in kvm.conf.
grep -Fq 'snapshot "$NORMAL_SNAPSHOT"' "$ROOT/lib/cape-configure.sh"
! grep -Fq 'snapshot "$FINAL_SNAPSHOT"' "$ROOT/lib/cape-configure.sh"
grep -Fq 'Normal-route CAPE snapshot is not set' "$ROOT/lib/cape-configure.sh"

echo '[PASS] compatibility rejects unowned legacy capture but permits explicit owned RC44 route migration'
