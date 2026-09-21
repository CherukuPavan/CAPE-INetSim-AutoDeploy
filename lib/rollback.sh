#!/usr/bin/env bash

ROLLBACK_FAILURES=0
ROLLBACK_CRITICAL_FAILURES=0

rollback_try() {
  local label="$1"; shift
  info "Rollback: $label"
  if ! "$@"; then
    fail "Rollback step failed: $label"
    ROLLBACK_FAILURES=$((ROLLBACK_FAILURES+1))
    return 0
  fi
}

rollback_try_critical() {
  local before="$ROLLBACK_FAILURES"
  rollback_try "$@"
  if ((ROLLBACK_FAILURES > before)); then
    ROLLBACK_CRITICAL_FAILURES=$((ROLLBACK_CRITICAL_FAILURES+1))
  fi
}

rollback_cutover_resources_exist() {
  [[ -n "${SAFETY_SNAPSHOT:-}" || -n "${WINDOWS_ISOLATED_MAC:-}" ]] && return 0
  state_has_owned_kind cape-file && return 0
  state_has_owned_kind extension && return 0
  state_has_owned_kind windows-config && return 0
  state_has_owned_kind domain-interface && return 0
  state_has_owned_kind snapshot && return 0
  return 1
}

rollback_prepare_cape_maintenance() {
  rollback_cutover_resources_exist || return 0
  [[ -f "$CAPE_MAINTENANCE_GUARD_FILE" ]] && return 0
  if systemctl is-active --quiet cape.service || systemctl is-active --quiet cape-processor.service; then
    cape_wait_and_acquire_maintenance "${ROLLBACK_WAIT_SECONDS:-3600}"
  fi
}

rollback_restore_cutover() {
  rollback_cutover_resources_exist || return 0

  if [[ -d "${EXTENSION_ROOT:-}" ]]; then
    rollback_try_critical "restore extension-protected CAPE web files" extension_rollback
  fi

  if state_has_owned_kind cape-file; then
    rollback_try_critical "restore CAPE configuration/source files" cape_restore_integration_files
  fi

  if [[ -n "${SAFETY_SNAPSHOT:-}" || -n "${WINDOWS_ISOLATED_MAC:-}" ]]; then
    rollback_try_critical "restore Windows pre-deployment snapshot/hardware" windows_rollback_to_safety
  fi

  # Keep scheduling closed until every deployment-owned staged network resource
  # is removed. Releasing the DB guard or restarting cape.service before that
  # point creates a race in which a new task could start while rollback is still
  # dismantling its network.
  if systemctl is-active --quiet cape.service; then
    rollback_try_critical "stop CAPE scheduler before rollback resource removal" services_stop_scheduler_for_handoff
  fi
}

rollback_remove_staged_resources() {
  rollback_try "remove AutoDeploy INetSim VM/disk" inetsim_vm_rollback
  rollback_try "remove AutoDeploy host firewall guard" firewall_rollback
  rollback_try "remove AutoDeploy isolated libvirt network" isolated_network_rollback
}

rollback_finish_cape_handoff() {
  if ((ROLLBACK_CRITICAL_FAILURES > 0)); then
    warn "Critical rollback restoration failed; preserving CAPE maintenance ownership and leaving scheduler closed"
    return 0
  fi

  if [[ -f "$CAPE_MAINTENANCE_GUARD_FILE" ]]; then
    rollback_try_critical "release CAPE maintenance lock" cape_release_maintenance
  fi
  if ((ROLLBACK_CRITICAL_FAILURES == 0)); then
    rollback_try_critical "restore original CAPE service states" services_restore_desired_state
  fi
}

autodeploy_rollback_internal() {
  ROLLBACK_FAILURES=0
  ROLLBACK_CRITICAL_FAILURES=0
  rollback_prepare_cape_maintenance || {
    fail "Could not acquire a task-safe CAPE rollback point"
    return 1
  }
  rollback_restore_cutover
  rollback_remove_staged_resources
  rollback_finish_cape_handoff

  if ((ROLLBACK_FAILURES == 0)); then
    state_set_phase rolled-back
    pass "Rollback completed"
    return 0
  fi

  DEPLOYMENT_PHASE=rollback-incomplete
  state_write_atomic
  fail "Rollback incomplete: $ROLLBACK_FAILURES step(s) require attention"
  return 1
}
