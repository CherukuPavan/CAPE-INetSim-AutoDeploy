#!/usr/bin/env bash

cape_runtime_python() {
  local svc pid exe
  for svc in cape cape-processor cape-web; do
    pid="$(systemctl show "$svc" -p MainPID --value 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]]; then
      exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
      if [[ -x "$exe" ]]; then printf '%s\n' "$exe"; return 0; fi
    fi
  done
  command -v python3
}

patch_sniffer_capture_override() {
  local file="$1"
  if grep -q 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1' "$file"; then return 0; fi
  python3 - "$file" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read()
old='''        host = self.machine.ip\n        # Selects per-machine interface if available.\n'''
new='''        # CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1\n        capture_host_key = f"capture_host_{self.machine.label}"\n        host = self.options.get(capture_host_key) or self.machine.ip\n        if host != self.machine.ip:\n            log.info("Using packet-capture host override %s=%s", capture_host_key, host)\n        # Selects per-machine interface if available.\n'''
if old not in s:
    raise SystemExit('known sniffer source block not found; refusing patch')
if s.count(old)!=1:
    raise SystemExit('sniffer source block is not unique; refusing patch')
open(p,'w').write(s.replace(old,new,1))
PY
}

cape_backup_integration_files() {
  local rel
  for rel in modules/auxiliary/sniffer.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
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
  [[ -n "${FINAL_SNAPSHOT:-}" ]] || { fail "Final running snapshot is not set"; return 1; }
  [[ -n "${ISOLATED_BRIDGE_NAME:-}" ]] || { fail "Isolated bridge name is not set"; return 1; }
  [[ -n "${WINDOWS_FAKE_IP:-}" ]] || { fail "Windows fake-Internet IP is not set"; return 1; }

  cape_backup_integration_files
  patch_sniffer_capture_override "$CAPE_ROOT/modules/auxiliary/sniffer.py"

  python3 "$edit" "$CAPE_ROOT/conf/auxiliary.conf" sniffer "capture_host_${CAPE_MACHINE_LABEL}" "$WINDOWS_FAKE_IP"
  python3 "$edit" "$CAPE_ROOT/conf/kvm.conf" "$CAPE_MACHINE_SECTION" snapshot "$FINAL_SNAPSHOT"
  python3 "$edit" "$CAPE_ROOT/conf/kvm.conf" "$CAPE_MACHINE_SECTION" interface "$ISOLATED_BRIDGE_NAME"
  python3 "$edit" "$CAPE_ROOT/conf/processing.conf" network dnswhitelist no
  python3 "$edit" "$CAPE_ROOT/conf/processing.conf" network ipwhitelist no
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" routing route none
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" routing enable_pcap yes

  local py
  py="$(cape_runtime_python)"
  "$py" -m py_compile "$CAPE_ROOT/modules/auxiliary/sniffer.py"

  grep -Fq "capture_host_${CAPE_MACHINE_LABEL} = $WINDOWS_FAKE_IP" "$CAPE_ROOT/conf/auxiliary.conf"
  grep -A120 -F "[$CAPE_MACHINE_SECTION]" "$CAPE_ROOT/conf/kvm.conf" | grep -m1 -Fq "snapshot = $FINAL_SNAPSHOT"
  grep -A120 -F "[$CAPE_MACHINE_SECTION]" "$CAPE_ROOT/conf/kvm.conf" | grep -m1 -Fq "interface = $ISOLATED_BRIDGE_NAME"

  state_record_resource cape-file "$CAPE_ROOT/modules/auxiliary/sniffer.py" modified yes "capture-host-override"
  state_record_resource cape-file "$CAPE_ROOT/conf/auxiliary.conf" modified yes "capture_host_${CAPE_MACHINE_LABEL}=$WINDOWS_FAKE_IP"
  state_record_resource cape-file "$CAPE_ROOT/conf/kvm.conf" modified yes "snapshot=$FINAL_SNAPSHOT interface=$ISOLATED_BRIDGE_NAME"
  state_record_resource cape-file "$CAPE_ROOT/conf/processing.conf" modified yes "dnswhitelist=no ipwhitelist=no"
  state_record_resource cape-file "$CAPE_ROOT/conf/routing.conf" modified yes "route=none enable_pcap=yes"
  state_set_phase cape-configured
}

cape_restore_integration_files() {
  local rel
  for rel in modules/auxiliary/sniffer.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
    if restore_backup_file "$CAPE_ROOT/$rel" "$rel"; then
      state_record_resource cape-file "$CAPE_ROOT/$rel" restored yes ""
    fi
  done
  local py
  py="$(cape_runtime_python)"
  "$py" -m py_compile "$CAPE_ROOT/modules/auxiliary/sniffer.py"
}
