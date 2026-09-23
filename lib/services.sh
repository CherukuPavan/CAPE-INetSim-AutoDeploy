#!/usr/bin/env bash

CAPE_SERVICE_READY_TIMEOUT="${CAPE_SERVICE_READY_TIMEOUT:-60}"
CAPE_SERVICE_READY_POLL="${CAPE_SERVICE_READY_POLL:-1}"

service_active_flag() {
  if systemctl is-active --quiet "$1"; then printf yes; else printf no; fi
}

services_capture_original_state() {
  CAPE_SERVICE_WAS_ACTIVE="${CAPE_SERVICE_WAS_ACTIVE:-$(service_active_flag cape.service)}"
  CAPE_PROCESSOR_WAS_ACTIVE="${CAPE_PROCESSOR_WAS_ACTIVE:-$(service_active_flag cape-processor.service)}"
  CAPE_WEB_WAS_ACTIVE="${CAPE_WEB_WAS_ACTIVE:-$(service_active_flag cape-web.service)}"
  CAPE_ROOTER_WAS_ACTIVE="${CAPE_ROOTER_WAS_ACTIVE:-$(service_active_flag cape-rooter.service)}"
  state_write_atomic
}

services_stop_scheduler_for_handoff() {
  if systemctl is-active --quiet cape.service; then
    systemctl stop cape.service
    CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=yes
    state_write_atomic
  fi
  systemctl is-active --quiet cape.service && { fail "CAPE scheduler service did not stop"; return 1; }
  pass "CAPE scheduler stopped for final configuration handoff"
}

services_restore_desired_state() {
  # Processor/web are restarted before the scheduler so configuration syntax and
  # reporting surfaces settle before queued analyses can resume.
  if [[ "${CAPE_PROCESSOR_WAS_ACTIVE:-no}" == yes ]]; then
    systemctl restart cape-processor.service
  else
    systemctl stop cape-processor.service >/dev/null 2>&1 || true
  fi

  if [[ "${CAPE_WEB_WAS_ACTIVE:-no}" == yes ]]; then
    systemctl restart cape-web.service
  else
    systemctl stop cape-web.service >/dev/null 2>&1 || true
  fi

  if [[ "${CAPE_ROOTER_WAS_ACTIVE:-no}" == yes ]]; then
    systemctl is-active --quiet cape-rooter.service || systemctl start cape-rooter.service
  else
    systemctl stop cape-rooter.service >/dev/null 2>&1 || true
  fi

  if [[ "${CAPE_SERVICE_WAS_ACTIVE:-no}" == yes ]]; then
    systemctl start cape.service
  else
    systemctl stop cape.service >/dev/null 2>&1 || true
  fi

  CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=no
  state_write_atomic
}

services_wait_expected_active() {
  local svc="$1"
  local timeout="${2:-$CAPE_SERVICE_READY_TIMEOUT}"
  local poll="${CAPE_SERVICE_READY_POLL:-1}"
  local elapsed=0 state="unknown"

  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || timeout=60
  [[ "$poll" =~ ^[1-9][0-9]*$ ]] || poll=1

  while ((elapsed < timeout)); do
    if systemctl is-active --quiet "$svc"; then
      return 0
    fi
    if systemctl is-failed --quiet "$svc"; then
      state="$(systemctl is-active "$svc" 2>/dev/null || true)"
      fail "Expected CAPE service entered failed state during handoff: $svc (state=${state:-unknown})"
      return 1
    fi
    sleep "$poll"
    elapsed=$((elapsed+poll))
  done

  state="$(systemctl is-active "$svc" 2>/dev/null || true)"
  fail "Timed out waiting for expected CAPE service readiness: $svc after ${timeout}s (state=${state:-unknown})"
  return 1
}

services_validate_restored_state() {
  local svc flag
  for svc in cape.service cape-processor.service cape-web.service cape-rooter.service; do
    case "$svc" in
      cape.service) flag="${CAPE_SERVICE_WAS_ACTIVE:-no}" ;;
      cape-processor.service) flag="${CAPE_PROCESSOR_WAS_ACTIVE:-no}" ;;
      cape-web.service) flag="${CAPE_WEB_WAS_ACTIVE:-no}" ;;
      cape-rooter.service) flag="${CAPE_ROOTER_WAS_ACTIVE:-no}" ;;
    esac
    if [[ "$flag" == yes ]]; then
      services_wait_expected_active "$svc" "$CAPE_SERVICE_READY_TIMEOUT" || return 1
    fi
  done
}
