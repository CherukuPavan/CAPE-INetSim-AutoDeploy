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
class X:
    def f(self):
        host = self.machine.ip
        # Selects per-machine interface if available.
        interface = self.machine.interface or self.options.get("interface")
PY
patch_sniffer_capture_override "$TMP/sniffer.py"
grep -q 'CAPE_INETSIM_ROUTE_AWARE_CAPTURE_V2' "$TMP/sniffer.py"
grep -q 'capture_host_key = f"capture_host_{self.machine.label}"' "$TMP/sniffer.py"
patch_sniffer_capture_override "$TMP/sniffer.py"
[[ "$(grep -c CAPE_INETSIM_ROUTE_AWARE_CAPTURE_V2 "$TMP/sniffer.py")" -eq 1 ]]
echo '[PASS] exact-match CAPE sniffer patch logic'

# Compatibility must reject non-unique/partial source anchors rather than
# claiming a source layout is safe to patch.
source "$ROOT/lib/compat.sh"
CAPE_ROOT="$TMP/cape"
mkdir -p "$CAPE_ROOT/conf" "$CAPE_ROOT/modules/auxiliary" "$CAPE_ROOT/modules/machinery" "$CAPE_ROOT/web/analysis" \
  "$CAPE_ROOT/lib/cuckoo/core/data" "$CAPE_ROOT/lib/cuckoo/common" "$CAPE_ROOT/lib/cuckoo/core"
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
cat >"$CAPE_ROOT/lib/cuckoo/common/abstracts.py" <<'PY'
class LibVirtMachinery:
    def start(self, label=None):
        """Starts a virtual machine.
        """
        vm_info = self.db.view_machine_by_label(label)
        snapshot = None
        snapshot_list = vm.snapshotListNames(flags=0)
        # If a snapshot is configured try to use it.
        if vm_info.snapshot and vm_info.snapshot in snapshot_list:
            log.debug("Using snapshot %s for virtual machine %s", vm_info.snapshot, label)
            snapshot = vm.snapshotLookupByName(vm_info.snapshot, flags=0)
        else:
            snapshot = self._get_snapshot(label, vm)
PY
cat >"$CAPE_ROOT/lib/cuckoo/core/machinery_manager.py" <<'PY'
class MachineryManager:
    def start_machine(self, machine: Machine) -> None:
        if (
            True
        ):
            pass
        with self.machine_lock:
            self.machinery.start(machine.label)
PY
cat >"$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py" <<'PY'
class AnalysisManager:
    def machine_running(self):
        with self.db.session.begin():
            self.machinery_manager.start_machine(self.machine)
PY
cat >"$CAPE_ROOT/modules/machinery/kvm.py" <<'PY'
class KVM:
    def start(self, label):
        super(KVM, self).start(label)
        machine = self.db.view_machine_by_label(label)
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

[inetsim]
enabled = no
server = 192.0.2.2
dnsport = 53
interface = virbr1
EOF
touch "$CAPE_ROOT/web/analysis/views.py"
cp "$TMP/sniffer.py" "$CAPE_ROOT/modules/auxiliary/sniffer.py"
CAPE_TARGETS_JSON='[{"section":"win10","label":"win10","ip":"192.0.2.10","domain":"win10"}]'
CAPE_TARGETS_COUNT=1
targets_bind 0
COMPAT_NOTES=()
check_cape_layout
[[ "$COMPAT_STATUS" == plan-compatible ]]

patch_libvirt_route_snapshot_override "$CAPE_ROOT/lib/cuckoo/common/abstracts.py"
patch_machinery_manager_route_start "$CAPE_ROOT/lib/cuckoo/core/machinery_manager.py"
patch_analysis_manager_route_start "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py"
patch_kvm_route_snapshot "$CAPE_ROOT/modules/machinery/kvm.py"
grep -Fq 'CAPE_INETSIM_ROUTE_SNAPSHOT_OVERRIDE_V1' "$CAPE_ROOT/lib/cuckoo/common/abstracts.py"
grep -Fq 'CAPE_INETSIM_MACHINERY_ROUTE_START_V1' "$CAPE_ROOT/lib/cuckoo/core/machinery_manager.py"
grep -Fq 'CAPE_INETSIM_ANALYSIS_ROUTE_START_V1' "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py"
grep -Fq 'CAPE_INETSIM_KVM_ROUTE_SNAPSHOT_V1' "$CAPE_ROOT/modules/machinery/kvm.py"

# A vague host assignment without the exact neighboring source line is unsafe.
sed '/Selects per-machine interface/d' "$TMP/sniffer.py" | sed '/CAPE_INETSIM_ROUTE_AWARE_CAPTURE_V2/d' >"$CAPE_ROOT/modules/auxiliary/sniffer.py"
COMPAT_NOTES=()
check_cape_layout
[[ "$COMPAT_STATUS" == plan-only-unknown-cape-layout ]]

# Missing required config sections must safe-stop before any CAPE mutation.
printf '[wrong]\nvalue = 1\n' >"$CAPE_ROOT/conf/routing.conf"
COMPAT_NOTES=()
check_cape_layout
[[ "$COMPAT_STATUS" == plan-only-unknown-cape-layout ]]

grep -Fq 'routing enable_pcap yes' "$ROOT/lib/cape-configure.sh"
grep -Fq 'inetsim enabled yes' "$ROOT/lib/cape-configure.sh"
grep -Fq 'inetsim server "$INETSIM_IP"' "$ROOT/lib/cape-configure.sh"
grep -Fq 'inetsim interface "$ISOLATED_BRIDGE_NAME"' "$ROOT/lib/cape-configure.sh"
grep -Fq 'CAPE packet capture is disabled' "$ROOT/lib/validate.sh"

grep -Fq 'cape_capture_post_hashes' "$ROOT/lib/cape-configure.sh"
grep -Fq 'Refusing to rollback CAPE file changed after AutoDeploy' "$ROOT/lib/cape-configure.sh"
grep -Fq 'cape_assert_owned_files_unchanged' "$ROOT/lib/deploy.sh"
grep -Fq 'CAPE commit changed since deployment' "$ROOT/bin/cape-inetsim-repair"
grep -Fq 'cape_assert_owned_files_unchanged' "$ROOT/bin/cape-inetsim-repair"
grep -Fq 'refusing repair overwrite' "$ROOT/bin/cape-inetsim-repair"

# Missing maintenance API symbols must also safe-stop.
cat >"$CAPE_ROOT/conf/routing.conf" <<'EOF'
[routing]
route = none

[inetsim]
enabled = no
server = 192.0.2.2
dnsport = 53
interface = virbr1
EOF
cp "$TMP/sniffer.py" "$CAPE_ROOT/modules/auxiliary/sniffer.py"
sed -i '/TASK_DISTRIBUTED_COMPLETED/d' "$CAPE_ROOT/lib/cuckoo/core/data/task.py"
COMPAT_NOTES=()
check_cape_layout
[[ "$COMPAT_STATUS" == plan-only-unknown-cape-layout ]]

python3 - "$ROOT/bin/cape-inetsim-repair" <<'PY'
import sys
s=open(sys.argv[1],encoding="utf-8").read()
assert s.index("check_cape_layout") < s.index("# Non-disruptive recovery first.")
assert s.index("cape_assert_owned_files_unchanged") < s.index("# Non-disruptive recovery first.")
PY
