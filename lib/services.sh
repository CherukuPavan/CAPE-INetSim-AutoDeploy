#!/usr/bin/env bash

CAPE_SERVICE_READY_TIMEOUT="${CAPE_SERVICE_READY_TIMEOUT:-60}"
CAPE_SERVICE_READY_POLL="${CAPE_SERVICE_READY_POLL:-1}"
ROUTING_SYSCTL_FILE="/etc/sysctl.d/99-cape-inetsim-autodeploy-routing.conf"

service_active_flag() {
  if systemctl is-active --quiet "$1"; then printf yes; else printf no; fi
}

service_enabled_flag() {
  if systemctl is-enabled --quiet "$1" 2>/dev/null; then printf yes; else printf no; fi
}

routing_forwarding_apply() {
  local current
  current="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)"
  [[ "$current" == 0 || "$current" == 1 ]] || {
    fail "Could not read host net.ipv4.ip_forward"
    return 1
  }

  if [[ -z "${HOST_IPV4_FORWARD_WAS:-}" ]]; then
    HOST_IPV4_FORWARD_WAS="$current"
    state_write_atomic
  fi

  if [[ -e "$ROUTING_SYSCTL_FILE" ]] &&
     ! state_resource_owned routing-sysctl-file "$ROUTING_SYSCTL_FILE" &&
     ! state_resource_intended routing-sysctl-file "$ROUTING_SYSCTL_FILE"; then
    fail "Routing sysctl path exists but is not AutoDeploy-owned: $ROUTING_SYSCTL_FILE"
    return 1
  fi

  if ! state_resource_owned routing-sysctl-file "$ROUTING_SYSCTL_FILE"; then
    state_record_intent routing-sysctl-file "$ROUTING_SYSCTL_FILE" creating "net.ipv4.ip_forward=1"
    cat >"$ROUTING_SYSCTL_FILE" <<'EOF'
# CAPE-INetSim-AutoDeploy: CAPE Rooter requires IPv4 forwarding for route=inetsim.
net.ipv4.ip_forward = 1
EOF
    chmod 0644 "$ROUTING_SYSCTL_FILE"
    state_record_resource routing-sysctl-file "$ROUTING_SYSCTL_FILE" created yes "net.ipv4.ip_forward=1"
  fi

  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == 1 ]] || {
    fail "Host IPv4 forwarding did not become active"
    return 1
  }

  state_record_resource routing-sysctl-runtime net.ipv4.ip_forward enabled yes "before=${HOST_IPV4_FORWARD_WAS:-unknown}"
  state_write_atomic
  pass "Host IPv4 forwarding is enabled persistently for CAPE route=inetsim"
}

routing_forwarding_verify() {
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == 1 ]] || return 1
  [[ -f "$ROUTING_SYSCTL_FILE" ]] || return 1
  grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$ROUTING_SYSCTL_FILE"
}

routing_forwarding_rollback() {
  if state_resource_owned routing-sysctl-file "$ROUTING_SYSCTL_FILE"; then
    rm -f "$ROUTING_SYSCTL_FILE"
    state_record_resource routing-sysctl-file "$ROUTING_SYSCTL_FILE" removed-by-rollback yes ""
  fi

  if state_resource_owned routing-sysctl-runtime net.ipv4.ip_forward; then
    case "${HOST_IPV4_FORWARD_WAS:-}" in
      0|1)
        sysctl -w "net.ipv4.ip_forward=$HOST_IPV4_FORWARD_WAS" >/dev/null
        state_record_resource routing-sysctl-runtime net.ipv4.ip_forward restored yes "value=$HOST_IPV4_FORWARD_WAS"
        ;;
      *)
        fail "Original net.ipv4.ip_forward state is unavailable"
        return 1
        ;;
    esac
  fi
  state_write_atomic
}

services_capture_original_state() {
  CAPE_SERVICE_WAS_ACTIVE="${CAPE_SERVICE_WAS_ACTIVE:-$(service_active_flag cape.service)}"
  CAPE_PROCESSOR_WAS_ACTIVE="${CAPE_PROCESSOR_WAS_ACTIVE:-$(service_active_flag cape-processor.service)}"
  CAPE_WEB_WAS_ACTIVE="${CAPE_WEB_WAS_ACTIVE:-$(service_active_flag cape-web.service)}"
  CAPE_ROOTER_WAS_ACTIVE="${CAPE_ROOTER_WAS_ACTIVE:-$(service_active_flag cape-rooter.service)}"
  CAPE_ROOTER_WAS_ENABLED="${CAPE_ROOTER_WAS_ENABLED:-$(service_enabled_flag cape-rooter.service)}"
  HOST_IPV4_FORWARD_WAS="${HOST_IPV4_FORWARD_WAS:-$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)}"
  state_write_atomic
}

services_stop_scheduler_for_handoff() {
  if systemctl is-active --quiet cape.service; then
    systemctl stop cape.service
    CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=yes
    state_write_atomic
  fi
  systemctl is-active --quiet cape.service && {
    fail "CAPE scheduler service did not stop"
    return 1
  }
  pass "CAPE scheduler stopped for final configuration handoff"
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

services_activate_deployment_state() {
  systemctl cat cape-rooter.service >/dev/null 2>&1 || {
    fail "cape-rooter.service is required for route=inetsim"
    return 1
  }

  routing_forwarding_apply || return 1

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

  systemctl enable cape-rooter.service >/dev/null
  systemctl restart cape-rooter.service
  services_wait_expected_active cape-rooter.service "$CAPE_SERVICE_READY_TIMEOUT" || return 1

  if [[ "${CAPE_SERVICE_WAS_ACTIVE:-no}" == yes ]]; then
    systemctl start cape.service
  else
    systemctl stop cape.service >/dev/null 2>&1 || true
  fi

  CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=no
  state_write_atomic
  pass "CAPE Rooter is enabled/active and IPv4 forwarding is ready for route=inetsim"
}

services_restore_desired_state() {
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
  if [[ "${CAPE_ROOTER_WAS_ENABLED:-no}" == yes ]]; then
    systemctl enable cape-rooter.service >/dev/null 2>&1 || true
  else
    systemctl disable cape-rooter.service >/dev/null 2>&1 || true
  fi

  if [[ "${CAPE_SERVICE_WAS_ACTIVE:-no}" == yes ]]; then
    systemctl start cape.service
  else
    systemctl stop cape.service >/dev/null 2>&1 || true
  fi

  CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=no
  state_write_atomic
}

services_validate_restored_state() {
  local svc flag
  for svc in cape.service cape-processor.service cape-web.service; do
    case "$svc" in
      cape.service) flag="${CAPE_SERVICE_WAS_ACTIVE:-no}" ;;
      cape-processor.service) flag="${CAPE_PROCESSOR_WAS_ACTIVE:-no}" ;;
      cape-web.service) flag="${CAPE_WEB_WAS_ACTIVE:-no}" ;;
    esac
    if [[ "$flag" == yes ]]; then
      services_wait_expected_active "$svc" "$CAPE_SERVICE_READY_TIMEOUT" || return 1
    fi
  done
}

services_validate_deployment_state() {
  services_validate_restored_state || return 1

  systemctl is-active --quiet cape-rooter.service || {
    fail "cape-rooter.service is not active; route=inetsim cannot function"
    return 1
  }
  systemctl is-enabled --quiet cape-rooter.service || {
    fail "cape-rooter.service is not enabled persistently"
    return 1
  }
  routing_forwarding_verify || {
    fail "Host IPv4 forwarding prerequisite for route=inetsim is not active/persistent"
    return 1
  }
}
