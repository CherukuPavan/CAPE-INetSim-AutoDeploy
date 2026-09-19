#!/usr/bin/env bash

discover_busy_state() {
  CAPE_BUSY="unknown"; BUSY_REASON="unable to determine safely"
  case "${DOMAIN_STATE:-unknown}" in
    running|paused|blocked|pmsuspended) CAPE_BUSY="yes"; BUSY_REASON="analysis domain state is '${DOMAIN_STATE}'; treat as busy until a CAPE task-aware idle check is implemented" ;;
    "shut off"|shutoff|crashed) CAPE_BUSY="no"; BUSY_REASON="analysis domain state is '${DOMAIN_STATE}'" ;;
  esac
}

check_cape_layout() {
  COMPAT_STATUS="blocked"; COMPAT_NOTES=()
  [[ -n "${CAPE_ROOT:-}" ]] || return 0
  local f missing=()
  for f in conf/kvm.conf conf/auxiliary.conf conf/processing.conf modules/auxiliary/sniffer.py web/analysis/views.py; do [[ -e "$CAPE_ROOT/$f" ]] || missing+=("$f"); done
  if ((${#missing[@]})); then add_note "missing:${missing[*]}"; return 0; fi
  if grep -q 'capture_host_key' "$CAPE_ROOT/modules/auxiliary/sniffer.py"; then COMPAT_STATUS="plan-compatible"; add_note "capture-override:already-present"
  elif grep -q 'host = self.machine.ip' "$CAPE_ROOT/modules/auxiliary/sniffer.py"; then COMPAT_STATUS="plan-compatible"; add_note "capture-override:known-clean-pattern"
  else COMPAT_STATUS="plan-only-unknown-cape-layout"; add_note "capture-override:unknown-source-layout"; fi
  if grep -Rqs 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$CAPE_ROOT/web" 2>/dev/null; then add_note "extension:already-present"; else add_note "extension:not-present"; fi
}

discover_resources() {
  HOST_MEM_KIB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  LIBVIRT_FREE_KIB="$(df -Pk /var/lib/libvirt/images 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
}
