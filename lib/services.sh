#!/usr/bin/env bash

service_active_flag() {
  [[ -n "$1" ]] || { printf no; return; }
  if systemctl is-active --quiet "$1"; then printf yes; else printf no; fi
}

services_ensure_roles() {
  if [[ -z "${CAPE_SCHEDULER_SERVICE:-}${CAPE_PROCESSOR_SERVICE:-}${CAPE_WEB_SERVICE:-}${CAPE_ROOTER_SERVICE:-}" ]]; then
    discover_cape_service_roles
  fi
}

services_capture_original_state() {
  services_ensure_roles
  CAPE_SERVICE_WAS_ACTIVE="${CAPE_SERVICE_WAS_ACTIVE:-$(service_active_flag "${CAPE_SCHEDULER_SERVICE:-}")}"
  CAPE_PROCESSOR_WAS_ACTIVE="${CAPE_PROCESSOR_WAS_ACTIVE:-$(service_active_flag "${CAPE_PROCESSOR_SERVICE:-}")}"
  CAPE_WEB_WAS_ACTIVE="${CAPE_WEB_WAS_ACTIVE:-$(service_active_flag "${CAPE_WEB_SERVICE:-}")}"
  CAPE_ROOTER_WAS_ACTIVE="${CAPE_ROOTER_WAS_ACTIVE:-$(service_active_flag "${CAPE_ROOTER_SERVICE:-}")}"
  state_write_atomic
}

services_stop_scheduler_for_handoff() {
  services_ensure_roles
  local svc="${CAPE_SCHEDULER_SERVICE:-}"
  [[ -n "$svc" ]] || { fail "CAPE scheduler service is unknown"; return 1; }
  if systemctl is-active --quiet "$svc"; then
    systemctl stop "$svc"
    CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=yes
    state_write_atomic
  fi
  systemctl is-active --quiet "$svc" && { fail "CAPE scheduler service did not stop: $svc"; return 1; }
  pass "CAPE scheduler stopped for final configuration handoff"
}

restore_one_service() {
  local svc="$1" wanted="$2" action="${3:-restart}"
  [[ -n "$svc" ]] || return 0
  if [[ "$wanted" == yes ]]; then
    if [[ "$action" == start ]]; then
      systemctl is-active --quiet "$svc" || systemctl start "$svc"
    else
      systemctl restart "$svc"
    fi
  else
    systemctl stop "$svc" >/dev/null 2>&1 || true
  fi
}

services_restore_desired_state() {
  services_ensure_roles
  restore_one_service "${CAPE_PROCESSOR_SERVICE:-}" "${CAPE_PROCESSOR_WAS_ACTIVE:-no}"
  restore_one_service "${CAPE_WEB_SERVICE:-}" "${CAPE_WEB_WAS_ACTIVE:-no}"
  restore_one_service "${CAPE_ROOTER_SERVICE:-}" "${CAPE_ROOTER_WAS_ACTIVE:-no}" start
  restore_one_service "${CAPE_SCHEDULER_SERVICE:-}" "${CAPE_SERVICE_WAS_ACTIVE:-no}" start
  CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=no
  state_write_atomic
}

services_validate_restored_state() {
  services_ensure_roles
  local svc flag
  while IFS='|' read -r svc flag; do
    [[ -n "$svc" ]] || continue
    if [[ "$flag" == yes ]]; then
      systemctl is-active --quiet "$svc" || { fail "Expected service is not active: $svc"; return 1; }
    fi
  done <<EOF
${CAPE_SCHEDULER_SERVICE:-}|${CAPE_SERVICE_WAS_ACTIVE:-no}
${CAPE_PROCESSOR_SERVICE:-}|${CAPE_PROCESSOR_WAS_ACTIVE:-no}
${CAPE_WEB_SERVICE:-}|${CAPE_WEB_WAS_ACTIVE:-no}
${CAPE_ROOTER_SERVICE:-}|${CAPE_ROOTER_WAS_ACTIVE:-no}
EOF
}
