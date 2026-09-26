#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/cape-runtime.sh"

cape_post_sha_for_rel() {
  case "$1" in
    modules/auxiliary/sniffer.py) printf '%s\n' "${CAPE_POST_SHA_SNIFFER:-}" ;;
    conf/auxiliary.conf) printf '%s\n' "${CAPE_POST_SHA_AUXILIARY:-}" ;;
    conf/kvm.conf) printf '%s\n' "${CAPE_POST_SHA_KVM:-}" ;;
    conf/processing.conf) printf '%s\n' "${CAPE_POST_SHA_PROCESSING:-}" ;;
    conf/routing.conf) printf '%s\n' "${CAPE_POST_SHA_ROUTING:-}" ;;
    *) return 1 ;;
  esac
}

cape_capture_post_hashes() {
  CAPE_POST_SHA_SNIFFER="$(sha256sum "$CAPE_ROOT/modules/auxiliary/sniffer.py" | awk '{print $1}')"
  CAPE_POST_SHA_AUXILIARY="$(sha256sum "$CAPE_ROOT/conf/auxiliary.conf" | awk '{print $1}')"
  CAPE_POST_SHA_KVM="$(sha256sum "$CAPE_ROOT/conf/kvm.conf" | awk '{print $1}')"
  CAPE_POST_SHA_PROCESSING="$(sha256sum "$CAPE_ROOT/conf/processing.conf" | awk '{print $1}')"
  CAPE_POST_SHA_ROUTING="$(sha256sum "$CAPE_ROOT/conf/routing.conf" | awk '{print $1}')"
  state_write_atomic
}

cape_assert_owned_files_unchanged() {
  local rel expected current failures=0
  for rel in modules/auxiliary/sniffer.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
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
  if grep -q 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2' "$file"; then return 0; fi
  python3 - "$file" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding="utf-8").read()
old='''        host = self.machine.ip\n        # Selects per-machine interface if available.\n        interface = self.machine.interface or self.options.get("interface")\n'''
new='''        host = self.machine.ip\n        # CAPE_INETSIM_AUTODEPLOY_CAPTURE_V2
        # Keep normal CAPE capture for ordinary routes. Only explicit
        # route=inetsim moves capture to the dedicated post-DNAT bridge.
        interface = self.machine.interface or self.options.get("interface")
        if str(self.task.route or "").lower() == "inetsim":
            inetsim_interface = self.options.get("inetsim_capture_interface", "")
            if inetsim_interface:
                interface = inetsim_interface
                log.info("Using route-scoped INetSim capture interface %s", interface)
'''
if old not in s:
    raise SystemExit("known sniffer source block not found; refusing patch")
if s.count(old)!=1:
    raise SystemExit("sniffer source block is not unique; refusing patch")
open(p,"w",encoding="utf-8").write(s.replace(old,new,1))
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
  [[ -n "${ISOLATED_BRIDGE_NAME:-}" ]] || { fail "Isolated bridge name is not set"; return 1; }
  [[ -n "${INETSIM_IP:-}" ]] || { fail "INetSim server address is not set"; return 1; }
  [[ "${CAPE_TARGETS_COUNT:-0}" -gt 0 ]] || { fail "No CAPE analysis targets are available for configuration"; return 1; }

  # Route-scoped architecture: do not rewrite the Windows guest, KVM capture
  # interface, or sniffer host. CAPE's existing per-task route selector remains
  # authoritative. We only register the dedicated INetSim appliance as CAPE's
  # native route=inetsim backend.
  cape_backup_integration_files

  patch_sniffer_capture_override "$CAPE_ROOT/modules/auxiliary/sniffer.py"
  python3 "$edit" "$CAPE_ROOT/conf/auxiliary.conf" sniffer inetsim_capture_interface "$ISOLATED_BRIDGE_NAME"

  python3 "$edit" "$CAPE_ROOT/conf/processing.conf" network dnswhitelist no
  python3 "$edit" "$CAPE_ROOT/conf/processing.conf" network ipwhitelist no
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim enabled yes
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim server "$INETSIM_IP"
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim dnsport 53
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" inetsim interface "$ISOLATED_BRIDGE_NAME"
  python3 "$edit" "$CAPE_ROOT/conf/routing.conf" routing enable_pcap yes

  local saved="${TARGET_INDEX:-}" i
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    targets_bind "$i"
    [[ -n "${FINAL_SNAPSHOT:-}" ]] || { fail "Route-neutral CAPE snapshot is not set for $CAPE_MACHINE_SECTION"; return 1; }
    [[ "$FINAL_SNAPSHOT" == "$CAPE_MACHINE_SNAPSHOT" ]] || {
      fail "Route-scoped mode must preserve the original CAPE snapshot for $CAPE_MACHINE_SECTION"
      return 1
    }
    TARGET_PHASE=cape-configured
    targets_capture_bound "$i"
  done

  state_record_resource cape-file "$CAPE_ROOT/modules/auxiliary/sniffer.py" modified yes "route-scoped-inetsim-capture"
  state_record_resource cape-file "$CAPE_ROOT/conf/auxiliary.conf" modified yes "inetsim-capture-interface=$ISOLATED_BRIDGE_NAME"
  state_record_resource cape-file "$CAPE_ROOT/conf/processing.conf" modified yes "dnswhitelist=no ipwhitelist=no"
  state_record_resource cape-file "$CAPE_ROOT/conf/routing.conf" modified yes "native-route=inetsim server=$INETSIM_IP interface=$ISOLATED_BRIDGE_NAME"
  cape_capture_post_hashes
  state_set_phase cape-configured

  if [[ "$saved" =~ ^[0-9]+$ ]]; then targets_bind "$saved"; else targets_bind 0; fi
}
cape_restore_integration_files() {
  local rel expected current backup backup_sha failures=0
  for rel in modules/auxiliary/sniffer.py conf/auxiliary.conf conf/kvm.conf conf/processing.conf conf/routing.conf; do
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
  "$py" -m py_compile "$CAPE_ROOT/modules/auxiliary/sniffer.py"
  ((failures == 0))
}
