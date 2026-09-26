#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/cape-runtime.sh"

cape_post_sha_for_rel() {
  case "$1" in
    modules/auxiliary/sniffer.py) printf '%s\n' "${CAPE_POST_SHA_SNIFFER:-}" ;;
    lib/cuckoo/common/abstracts.py) printf '%s\n' "${CAPE_POST_SHA_ABSTRACTS:-}" ;;
    lib/cuckoo/core/machinery_manager.py) printf '%s\n' "${CAPE_POST_SHA_MACHINERY_MANAGER:-}" ;;
    lib/cuckoo/core/analysis_manager.py) printf '%s\n' "${CAPE_POST_SHA_ANALYSIS_MANAGER:-}" ;;
    modules/machinery/kvm.py) printf '%s\n' "${CAPE_POST_SHA_KVM_MODULE:-}" ;;
    conf/auxiliary.conf) printf '%s\n' "${CAPE_POST_SHA_AUXILIARY:-}" ;;
    conf/kvm.conf) printf '%s\n' "${CAPE_POST_SHA_KVM:-}" ;;
    conf/processing.conf) printf '%s\n' "${CAPE_POST_SHA_PROCESSING:-}" ;;
    conf/routing.conf) printf '%s\n' "${CAPE_POST_SHA_ROUTING:-}" ;;
    *) return 1 ;;
  esac
}

cape_capture_post_hashes() {
  CAPE_POST_SHA_SNIFFER="$(sha256sum "$CAPE_ROOT/modules/auxiliary/sniffer.py" | awk '{print $1}')"
  CAPE_POST_SHA_ABSTRACTS="$(sha256sum "$CAPE_ROOT/lib/cuckoo/common/abstracts.py" | awk '{print $1}')"
  CAPE_POST_SHA_MACHINERY_MANAGER="$(sha256sum "$CAPE_ROOT/lib/cuckoo/core/machinery_manager.py" | awk '{print $1}')"
  CAPE_POST_SHA_ANALYSIS_MANAGER="$(sha256sum "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py" | awk '{print $1}')"
  CAPE_POST_SHA_KVM_MODULE="$(sha256sum "$CAPE_ROOT/modules/machinery/kvm.py" | awk '{print $1}')"
  CAPE_POST_SHA_AUXILIARY="$(sha256sum "$CAPE_ROOT/conf/auxiliary.conf" | awk '{print $1}')"
  CAPE_POST_SHA_KVM="$(sha256sum "$CAPE_ROOT/conf/kvm.conf" | awk '{print $1}')"
  CAPE_POST_SHA_PROCESSING="$(sha256sum "$CAPE_ROOT/conf/processing.conf" | awk '{print $1}')"
  CAPE_POST_SHA_ROUTING="$(sha256sum "$CAPE_ROOT/conf/routing.conf" | awk '{print $1}')"
  state_write_atomic
}

cape_assert_owned_files_unchanged() {
  local rel expected current failures=0
  for rel in modules/auxiliary/sniffer.py lib/cuckoo/common/abstracts.py lib/cuckoo/core/machinery_manager.py lib/cuckoo/core/analysis_manager.py modules/machinery/kvm.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
    expected="$(cape_post_sha_for_rel "$rel" 2>/dev/null || true)"
    [[ -n "$expected" ]] || continue
    current="$(sha256sum "$CAPE_ROOT/$rel" 2>/dev/null | awk '{print $1}' || true)"
    if [[ "$current" != "$expected" ]]; then
      fail "CAPE file changed after AutoDeploy committed it; refusing to overwrite operator/update drift: $rel"
      failures=$((failures+1))
    fi
  done
  ((failures == 0))
}

patch_sniffer_capture_override() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding="utf-8").read()
marker="CAPE_INETSIM_ROUTE_AWARE_CAPTURE_V2"
if s.count(marker)==1:
    raise SystemExit(0)
if s.count(marker)>1:
    raise SystemExit("route-aware sniffer marker is ambiguous")
old_v1='''        # CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1
        capture_host_key = f"capture_host_{self.machine.label}"
        host = self.options.get(capture_host_key) or self.machine.ip
        if host != self.machine.ip:
            log.info("Using packet-capture host override %s=%s", capture_host_key, host)
        # Selects per-machine interface if available.
        interface = self.machine.interface or self.options.get("interface")
'''
upstream='''        host = self.machine.ip
        # Selects per-machine interface if available.
        interface = self.machine.interface or self.options.get("interface")
'''
new='''        # CAPE_INETSIM_ROUTE_AWARE_CAPTURE_V2
        task_route = str(getattr(self.task, "route", "") or "").strip().lower()
        if task_route == "inetsim":
            capture_host_key = f"inetsim_capture_host_{self.machine.label}"
            capture_interface_key = f"inetsim_capture_interface_{self.machine.label}"
            host = self.options.get(capture_host_key) or self.machine.ip
            interface = (
                self.options.get(capture_interface_key)
                or self.machine.interface
                or self.options.get("interface")
            )
            log.info(
                "Using route=inetsim packet-capture override %s=%s %s=%s",
                capture_host_key,
                host,
                capture_interface_key,
                interface,
            )
        else:
            host = self.machine.ip
            interface = self.machine.interface or self.options.get("interface")
'''
if old_v1 in s:
    if s.count(old_v1)!=1:
        raise SystemExit("legacy sniffer override is not unique")
    s=s.replace(old_v1,new,1)
elif upstream in s:
    if s.count(upstream)!=1:
        raise SystemExit("upstream sniffer source block is not unique")
    s=s.replace(upstream,new,1)
else:
    raise SystemExit("known sniffer source block not found; refusing patch")
open(p,"w",encoding="utf-8").write(s)
PY
}

patch_libvirt_route_snapshot_override() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding="utf-8").read()
marker="CAPE_INETSIM_ROUTE_SNAPSHOT_OVERRIDE_V1"
if marker in s:
    raise SystemExit(0)
old='''    def start(self, label=None):
        """Starts a virtual machine.
'''
new='''    def start(self, label=None, snapshot_override=None):
        # CAPE_INETSIM_ROUTE_SNAPSHOT_OVERRIDE_V1
        """Starts a virtual machine.
'''
if s.count(old)!=1:
    raise SystemExit("LibVirtMachinery.start signature anchor is not unique")
s=s.replace(old,new,1)
old='''            # If a snapshot is configured try to use it.
            if vm_info.snapshot and vm_info.snapshot in snapshot_list:
                log.debug("Using snapshot %s for virtual machine %s", vm_info.snapshot, label)
                snapshot = vm.snapshotLookupByName(vm_info.snapshot, flags=0)
            else:
                snapshot = self._get_snapshot(label, vm)
'''
new='''            # AutoDeploy may select the fake-Internet running snapshot only
            # for an explicit route=inetsim task. Other routes keep the
            # machine's normal configured snapshot.
            if snapshot_override:
                if snapshot_override not in snapshot_list:
                    raise CuckooMachineError(
                        f"Requested route-specific snapshot {snapshot_override} does not exist for {label}"
                    )
                log.debug("Using route-specific snapshot %s for virtual machine %s", snapshot_override, label)
                snapshot = vm.snapshotLookupByName(snapshot_override, flags=0)
            elif vm_info.snapshot and vm_info.snapshot in snapshot_list:
                log.debug("Using snapshot %s for virtual machine %s", vm_info.snapshot, label)
                snapshot = vm.snapshotLookupByName(vm_info.snapshot, flags=0)
            else:
                snapshot = self._get_snapshot(label, vm)
'''
if s.count(old)!=1:
    raise SystemExit("LibVirtMachinery snapshot-selection anchor is not unique")
s=s.replace(old,new,1)
open(p,"w",encoding="utf-8").write(s)
PY
}

patch_kvm_route_snapshot() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding="utf-8").read()
marker="CAPE_INETSIM_KVM_ROUTE_SNAPSHOT_V1"
if marker in s:
    raise SystemExit(0)
old='''    def start(self, label):
        super(KVM, self).start(label)
        machine = self.db.view_machine_by_label(label)
'''
new='''    def _inetsim_snapshot_for_label(self, label):
        # CAPE_INETSIM_KVM_ROUTE_SNAPSHOT_V1
        manager = self.options.get(self.module_name)
        for machine_id in manager.get("machines", []):
            opts = self.options.get(str(machine_id).strip())
            if opts.get(self.LABEL) == label:
                return str(opts.get("inetsim_snapshot", "") or "").strip()
        return ""

    def start_for_task(self, label, route=None):
        snapshot_override = None
        if str(route or "").strip().lower() == "inetsim":
            snapshot_override = self._inetsim_snapshot_for_label(label)
            if not snapshot_override:
                raise CuckooMachineError(
                    f"route=inetsim requested for {label}, but no inetsim_snapshot is configured"
                )
        self.start(label, snapshot_override=snapshot_override)

    def start(self, label, snapshot_override=None):
        super(KVM, self).start(label, snapshot_override=snapshot_override)
        machine = self.db.view_machine_by_label(label)
'''
if s.count(old)!=1:
    raise SystemExit("KVM.start anchor is not unique")
s=s.replace(old,new,1)
open(p,"w",encoding="utf-8").write(s)
PY
}

patch_machinery_manager_route_start() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding="utf-8").read()
marker="CAPE_INETSIM_MACHINERY_ROUTE_START_V1"
if marker in s:
    raise SystemExit(0)
old='''    def start_machine(self, machine: Machine) -> None:
        if (
'''
new='''    def start_machine(self, machine: Machine, route=None) -> None:
        # CAPE_INETSIM_MACHINERY_ROUTE_START_V1
        if (
'''
if s.count(old)!=1:
    raise SystemExit("MachineryManager.start_machine signature anchor is not unique")
s=s.replace(old,new,1)
old='''        with self.machine_lock:
            self.machinery.start(machine.label)
'''
new='''        with self.machine_lock:
            start_for_task = getattr(self.machinery, "start_for_task", None)
            if callable(start_for_task):
                start_for_task(machine.label, route=route)
            else:
                self.machinery.start(machine.label)
'''
if s.count(old)!=1:
    raise SystemExit("MachineryManager.start_machine body anchor is not unique")
s=s.replace(old,new,1)
open(p,"w",encoding="utf-8").write(s)
PY
}

patch_analysis_manager_route_start() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding="utf-8").read()
marker="CAPE_INETSIM_ANALYSIS_ROUTE_START_V1"
if marker in s:
    raise SystemExit(0)
old='''                self.machinery_manager.start_machine(self.machine)
'''
new='''                # CAPE_INETSIM_ANALYSIS_ROUTE_START_V1
                self.machinery_manager.start_machine(self.machine, route=self.task.route)
'''
if s.count(old)!=1:
    raise SystemExit("AnalysisManager machine-start anchor is not unique")
s=s.replace(old,new,1)
open(p,"w",encoding="utf-8").write(s)
PY
}

cape_backup_integration_files() {
  local rel
  for rel in modules/auxiliary/sniffer.py lib/cuckoo/common/abstracts.py lib/cuckoo/core/machinery_manager.py lib/cuckoo/core/analysis_manager.py modules/machinery/kvm.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
    backup_file_once "$CAPE_ROOT/$rel" "$rel"
    # Mark the file as transaction-managed immediately after its protected
    # backup exists. A crash during later multi-file edits must still cause
    # rollback to restore every touched CAPE file.
    state_record_resource cape-file "$CAPE_ROOT/$rel" planned-modification yes "backup=$AD_BACKUP_ROOT/$DEPLOYMENT_ID/$rel"
  done
}

cape_configure_inetsim() {
  local edit="$AUTODEPLOY_ROOT/tools/ini_edit.py"
  [[ -x "$edit" || -f "$edit" ]] || { fail "INI editor missing"; return 1; }
  [[ -n "${ISOLATED_BRIDGE_NAME:-}" ]] || { fail "Isolated bridge name is not set"; return 1; }
  [[ "${CAPE_TARGETS_COUNT:-0}" -gt 0 ]] || { fail "No CAPE analysis targets are available for configuration"; return 1; }

  cape_backup_integration_files
  patch_sniffer_capture_override "$CAPE_ROOT/modules/auxiliary/sniffer.py"
  patch_libvirt_route_snapshot_override "$CAPE_ROOT/lib/cuckoo/common/abstracts.py"
  patch_machinery_manager_route_start "$CAPE_ROOT/lib/cuckoo/core/machinery_manager.py"
  patch_analysis_manager_route_start "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py"
  patch_kvm_route_snapshot "$CAPE_ROOT/modules/machinery/kvm.py"

  local saved="${TARGET_INDEX:-}" i
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    targets_bind "$i"
    [[ -n "${NORMAL_SNAPSHOT:-}" ]] || { fail "Normal-route running snapshot is not set for $CAPE_MACHINE_SECTION"; return 1; }
    [[ -n "${FINAL_SNAPSHOT:-}" ]] || { fail "INetSim running snapshot is not set for $CAPE_MACHINE_SECTION"; return 1; }
    [[ -n "${WINDOWS_FAKE_IP:-}" ]] || { fail "Windows fake-Internet IP is not set for $CAPE_MACHINE_SECTION"; return 1; }

    python3 "$edit" "$CAPE_ROOT/conf/auxiliary.conf" sniffer "inetsim_capture_host_${CAPE_MACHINE_LABEL}" "$WINDOWS_FAKE_IP"
    python3 "$edit" "$CAPE_ROOT/conf/auxiliary.conf" sniffer "inetsim_capture_interface_${CAPE_MACHINE_LABEL}" "$ISOLATED_BRIDGE_NAME"
    python3 "$edit" "$CAPE_ROOT/conf/kvm.conf" "$CAPE_MACHINE_SECTION" snapshot "$NORMAL_SNAPSHOT"
    python3 "$edit" "$CAPE_ROOT/conf/kvm.conf" "$CAPE_MACHINE_SECTION" inetsim_snapshot "$FINAL_SNAPSHOT"
    python3 "$edit" "$CAPE_ROOT/conf/kvm.conf" "$CAPE_MACHINE_SECTION" interface "$MANAGEMENT_BRIDGE_NAME"

    grep -Fq "inetsim_capture_host_${CAPE_MACHINE_LABEL} = $WINDOWS_FAKE_IP" "$CAPE_ROOT/conf/auxiliary.conf"
    grep -Fq "inetsim_capture_interface_${CAPE_MACHINE_LABEL} = $ISOLATED_BRIDGE_NAME" "$CAPE_ROOT/conf/auxiliary.conf"
    local machine_block
    machine_block="$(grep -A160 -F "[$CAPE_MACHINE_SECTION]" "$CAPE_ROOT/conf/kvm.conf" || true)"
    grep -m1 -Fq "snapshot = $NORMAL_SNAPSHOT" <<<"$machine_block"
    grep -m1 -Fq "inetsim_snapshot = $FINAL_SNAPSHOT" <<<"$machine_block"
    grep -m1 -Fq "interface = $MANAGEMENT_BRIDGE_NAME" <<<"$machine_block"

    TARGET_PHASE=cape-configured
    targets_capture_bound "$i"
  done

  python3 "$edit" "$CAPE_ROOT/conf/processing.conf" network dnswhitelist no
  python3 "$edit" "$CAPE_ROOT/conf/processing.conf" network ipwhitelist no
  # Keep a fail-closed default, but let each submitted task choose its route.
  # The dedicated fake-Internet path is CAPE's native route=inetsim.
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" routing route none
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" routing enable_pcap yes
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim enabled yes
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim server "$INETSIM_IP"
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim dnsport 53
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim interface "$ISOLATED_BRIDGE_NAME"

  local py
  py="$(cape_runtime_python)"
  "$py" -m py_compile \
    "$CAPE_ROOT/modules/auxiliary/sniffer.py" \
    "$CAPE_ROOT/lib/cuckoo/common/abstracts.py" \
    "$CAPE_ROOT/lib/cuckoo/core/machinery_manager.py" \
    "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py" \
    "$CAPE_ROOT/modules/machinery/kvm.py"

  state_record_resource cape-file "$CAPE_ROOT/modules/auxiliary/sniffer.py" modified yes "route-aware-capture"
  state_record_resource cape-file "$CAPE_ROOT/lib/cuckoo/common/abstracts.py" modified yes "route-specific-snapshot-override"
  state_record_resource cape-file "$CAPE_ROOT/lib/cuckoo/core/machinery_manager.py" modified yes "route-aware-machine-start"
  state_record_resource cape-file "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py" modified yes "route-forwarded-to-machinery"
  state_record_resource cape-file "$CAPE_ROOT/modules/machinery/kvm.py" modified yes "route-inetsim-snapshot-selection"
  state_record_resource cape-file "$CAPE_ROOT/conf/auxiliary.conf" modified yes "per-machine-route-aware-capture=${CAPE_TARGETS_COUNT}"
  state_record_resource cape-file "$CAPE_ROOT/conf/kvm.conf" modified yes "managed-machines=${CAPE_TARGETS_COUNT} normal+inetsim-snapshots"
  state_record_resource cape-file "$CAPE_ROOT/conf/processing.conf" modified yes "dnswhitelist=no ipwhitelist=no"
  state_record_resource cape-file "$CAPE_ROOT/conf/routing.conf" modified yes "route=none enable_pcap=yes"
  cape_capture_post_hashes
  state_set_phase cape-configured

  if [[ "$saved" =~ ^[0-9]+$ ]]; then targets_bind "$saved"; else targets_bind 0; fi
}
cape_restore_integration_files() {
  local rel expected current backup backup_sha failures=0
  for rel in modules/auxiliary/sniffer.py lib/cuckoo/common/abstracts.py lib/cuckoo/core/machinery_manager.py lib/cuckoo/core/analysis_manager.py modules/machinery/kvm.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
    backup="$AD_BACKUP_ROOT/${DEPLOYMENT_ID}/$rel"
    [[ -e "$backup" ]] || continue
    backup_sha="$(sha256sum "$backup" | awk '{print $1}')"
    current="$(sha256sum "$CAPE_ROOT/$rel" 2>/dev/null | awk '{print $1}' || true)"
    expected="$(cape_post_sha_for_rel "$rel" 2>/dev/null || true)"

    if [[ "$current" == "$backup_sha" ]]; then
      state_record_resource cape-file "$CAPE_ROOT/$rel" restored yes "already-predeployment"
      continue
    fi
    if [[ -n "$expected" && "$current" != "$expected" ]]; then
      fail "Refusing to rollback CAPE file changed after AutoDeploy: $rel"
      failures=$((failures+1))
      continue
    fi
    if restore_backup_file "$CAPE_ROOT/$rel" "$rel"; then
      state_record_resource cape-file "$CAPE_ROOT/$rel" restored yes ""
    else
      failures=$((failures+1))
    fi
  done
  local py
  py="$(cape_runtime_python)"
  "$py" -m py_compile \
    "$CAPE_ROOT/modules/auxiliary/sniffer.py" \
    "$CAPE_ROOT/lib/cuckoo/common/abstracts.py" \
    "$CAPE_ROOT/lib/cuckoo/core/machinery_manager.py" \
    "$CAPE_ROOT/lib/cuckoo/core/analysis_manager.py" \
    "$CAPE_ROOT/modules/machinery/kvm.py"
  ((failures == 0))
}
