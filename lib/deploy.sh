#!/usr/bin/env bash

DEPLOY_WAIT_SECONDS="${DEPLOY_WAIT_SECONDS:-3600}"

deploy_phase_rank() {
  case "$1" in
    planned) echo 10 ;;
    isolated-network-ready) echo 20 ;;
    appliance-defined) echo 30 ;;
    appliance-configured) echo 40 ;;
    staged) echo 50 ;;
    maintenance-acquired) echo 60 ;;
    windows-nic-attached) echo 70 ;;
    windows-configured) echo 80 ;;
    windows-running-snapshot|windows-working-snapshot) echo 90 ;;
    windows-snapshots-ready) echo 100 ;;
    cape-configured) echo 110 ;;
    extension-installed) echo 120 ;;
    handoff-complete) echo 130 ;;
    committed) echo 140 ;;
    *) echo -1 ;;
  esac
}

deploy_phase_at_least() {
  local current want cr wr
  current="${DEPLOYMENT_PHASE:-}"
  want="$1"
  cr="$(deploy_phase_rank "$current")"
  wr="$(deploy_phase_rank "$want")"
  [[ "$cr" -ge 0 && "$wr" -ge 0 && "$cr" -ge "$wr" ]]
}

deploy_phase_is_resumable() {
  [[ "$(deploy_phase_rank "${DEPLOYMENT_PHASE:-}")" -ge 0 ]]
}

deploy_required_commands() {
  local -a missing=()
  local cmd
  for cmd in python3 virsh qemu-img virt-install curl flock ip systemctl tar sha256sum base64 timeout; do
    have "$cmd" || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    fail "Missing required host command(s): ${missing[*]}"
    return 1
  fi
}

deploy_assert_supported_environment() {
  if ((${#DISCOVERY_ERRORS[@]})); then
    fail "Discovery has blocking findings:"
    printf '  - %s\n' "${DISCOVERY_ERRORS[@]}" >&2
    return 1
  fi
  [[ "${COMPAT_STATUS:-}" == plan-compatible ]] || {
    fail "CAPE source layout is not approved for mutation: ${COMPAT_STATUS:-unknown}"
    return 1
  }
  [[ "${LIBVIRT_URI:-}" == qemu:///system ]] || {
    fail "AutoDeploy requires the system libvirt instance (found: ${LIBVIRT_URI:-unknown})"
    return 1
  }
  [[ "${CAPE_MACHINE_PLATFORM,,}" == windows* ]] || {
    fail "Selected CAPE machine is not a Windows analysis VM: ${CAPE_MACHINE_PLATFORM:-unknown}"
    return 1
  }
  [[ -n "${MANAGEMENT_NETWORK_NAME:-}" ]] || { fail "Management libvirt network is unknown"; return 1; }
  [[ -n "${CAPE_RESULTSERVER_IP:-}" && "${CAPE_RESULTSERVER_PORT:-}" =~ ^[0-9]+$ ]] || {
    fail "CAPE ResultServer path could not be derived"
    return 1
  }

  # A brand-new deployment needs the scheduler/ResultServer alive so the
  # management path can be proven before Windows is changed. A resumed
  # transaction may legitimately have cape.service stopped at handoff.
  if [[ ! -f "$AD_STATE_FILE" ]]; then
    systemctl is-active --quiet cape.service || {
      fail "cape.service must be active before a new deployment"
      return 1
    }
    if grep -q 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1' "$CAPE_ROOT/modules/auxiliary/sniffer.py" 2>/dev/null; then
      fail "An untracked AutoDeploy sniffer patch already exists; refusing to claim or overwrite it"
      return 1
    fi
    if grep -Rqs 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$CAPE_ROOT/web" 2>/dev/null; then
      fail "An untracked CAPE-INetSim VM extension is already installed; refusing to claim or overwrite it"
      return 1
    fi
  fi

  deploy_required_commands
  appliance_manifest_validate "$APPLIANCE_MANIFEST" >/dev/null || {
    fail "Generalized INetSim appliance is not a published, checksum-pinned release artifact"
    return 1
  }
}

deploy_reset_resource_state() {
  ISOLATED_NETWORK_NAME=""
  ISOLATED_BRIDGE_NAME=""
  LIBVIRT_STORAGE_POOL=""
  LIBVIRT_STORAGE_PATH=""
  INETSIM_DOMAIN_NAME=""
  INETSIM_DISK_PATH=""
  INETSIM_MANAGEMENT_MAC=""
  INETSIM_ISOLATED_MAC=""
  WINDOWS_ISOLATED_NIC_MODEL=""
  WINDOWS_ISOLATED_MAC=""
  WINDOWS_BACKEND_USED=""
  WINDOWS_ORIGINAL_DOMAIN_STATE=""
  SAFETY_SNAPSHOT=""
  WORKING_SNAPSHOT=""
  FINAL_SNAPSHOT=""
  CAPE_SERVICE_WAS_ACTIVE=""
  CAPE_PROCESSOR_WAS_ACTIVE=""
  CAPE_WEB_WAS_ACTIVE=""
  CAPE_ROOTER_WAS_ACTIVE=""
  CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=no
}

deploy_initialize_or_resume_state() {
  local d_root="$CAPE_ROOT" d_commit="$CAPE_COMMIT" d_section="$CAPE_MACHINE_SECTION"
  local d_label="$CAPE_MACHINE_LABEL" d_ip="$CAPE_MACHINE_IP" d_domain="$DOMAIN"
  local d_mgmt_net="$MANAGEMENT_NETWORK_NAME" d_rs_ip="$CAPE_RESULTSERVER_IP"
  local d_rs_port="$CAPE_RESULTSERVER_PORT" d_control="$CONTROL_HOST_IP"
  local d_snapshot="$CAPE_MACHINE_SNAPSHOT" d_subnet="$ISOLATED_SUBNET"
  local d_bridge_ip="$BRIDGE_IP" d_inetsim_ip="$INETSIM_IP" d_fake="$WINDOWS_FAKE_IP"

  if [[ -f "$AD_STATE_FILE" ]]; then
    state_load
    if [[ "${DEPLOYMENT_PHASE:-}" != rolled-back ]]; then
      deploy_phase_is_resumable || {
        fail "Existing state is not a resumable deployment phase: ${DEPLOYMENT_PHASE:-unknown}"
        return 1
      }
      [[ "$CAPE_ROOT" == "$d_root" ]] || { fail "Existing deployment state belongs to a different CAPE root"; return 1; }
      [[ "$CAPE_MACHINE_SECTION" == "$d_section" ]] || { fail "Existing deployment state belongs to a different CAPE machine"; return 1; }
      [[ "$DOMAIN" == "$d_domain" ]] || { fail "Existing deployment state belongs to a different libvirt domain"; return 1; }
      [[ "$CAPE_COMMIT" == "$d_commit" ]] || { fail "CAPE commit changed during/after deployment; use verify/repair compatibility flow"; return 1; }
      CAPE_MACHINE_SNAPSHOT="${ORIGINAL_CAPE_SNAPSHOT:-}"
      pass "Resuming deployment state $DEPLOYMENT_ID at phase ${DEPLOYMENT_PHASE:-unknown}"
      return 0
    fi
  fi

  CAPE_ROOT="$d_root"; CAPE_COMMIT="$d_commit"; CAPE_MACHINE_SECTION="$d_section"
  CAPE_MACHINE_LABEL="$d_label"; CAPE_MACHINE_IP="$d_ip"; DOMAIN="$d_domain"
  MANAGEMENT_NETWORK_NAME="$d_mgmt_net"; CAPE_RESULTSERVER_IP="$d_rs_ip"
  CAPE_RESULTSERVER_PORT="$d_rs_port"; CONTROL_HOST_IP="$d_control"
  CAPE_MACHINE_SNAPSHOT="$d_snapshot"; ORIGINAL_CAPE_SNAPSHOT="$d_snapshot"
  ISOLATED_SUBNET="$d_subnet"; BRIDGE_IP="$d_bridge_ip"; INETSIM_IP="$d_inetsim_ip"; WINDOWS_FAKE_IP="$d_fake"
  deploy_reset_resource_state
  ORIGINAL_CAPE_SNAPSHOT="$d_snapshot"

  state_init_paths
  state_new_deployment_id
  DEPLOYMENT_PHASE=planned
  isolated_network_defaults
  choose_isolated_bridge_name
  state_write_atomic
  services_capture_original_state
  pass "Initialized deployment transaction $DEPLOYMENT_ID"
}

deploy_stage_non_disruptive() {
  local artifact
  info "Staging isolated network and generalized INetSim appliance; CAPE analyses are not interrupted."
  artifact="$(appliance_fetch "$APPLIANCE_MANIFEST")"

  isolated_network_apply
  if ! deploy_phase_at_least isolated-network-ready; then
    state_set_phase isolated-network-ready
  fi

  inetsim_copy_appliance_disk "$artifact"
  inetsim_define_domain
  if ! deploy_phase_at_least appliance-defined; then
    state_set_phase appliance-defined
  fi

  inetsim_configure_guest
  if ! deploy_phase_at_least appliance-configured; then
    state_set_phase appliance-configured
  fi

  inetsim_verify_host
  if ! deploy_phase_at_least staged; then
    state_set_phase staged
  fi
}

deploy_validate_staged_resources() {
  local artifact
  artifact="$(appliance_fetch "$APPLIANCE_MANIFEST")"
  isolated_network_apply
  inetsim_copy_appliance_disk "$artifact"
  inetsim_define_domain
  virsh start "$INETSIM_DOMAIN_NAME" >/dev/null 2>&1 || true
  qga_wait "$INETSIM_DOMAIN_NAME" 60 || { fail "INetSim appliance QGA unavailable during resume"; return 1; }
  inetsim_verify_host
}

deploy_ensure_maintenance() {
  if [[ -f "$CAPE_MAINTENANCE_GUARD_FILE" ]]; then
    cape_verify_maintenance_guard || {
      fail "Existing CAPE maintenance guard does not safely belong to this deployment"
      return 1
    }
    if ! deploy_phase_at_least maintenance-acquired; then
      state_record_resource cape-maintenance all-machines acquired yes "$CAPE_MAINTENANCE_GUARD_FILE"
      state_set_phase maintenance-acquired
    fi
    pass "Verified existing CAPE maintenance ownership"
    return 0
  fi

  cape_wait_and_acquire_maintenance "$DEPLOY_WAIT_SECONDS"
  if ! deploy_phase_at_least maintenance-acquired; then
    state_set_phase maintenance-acquired
  fi
}

deploy_verify_windows_nic() {
  [[ -n "${WINDOWS_ISOLATED_MAC:-}" ]] || { fail "Windows isolated NIC MAC is missing from deployment state"; return 1; }
  state_resource_owned domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC" || {
    fail "Windows isolated NIC is not owned by this deployment"
    return 1
  }
  windows_find_isolated_mac | grep -Fqi "$WINDOWS_ISOLATED_MAC" || {
    fail "Deployment-owned Windows isolated NIC is missing from persistent domain XML"
    return 1
  }
}

deploy_verify_safety_snapshot() {
  [[ -n "${SAFETY_SNAPSHOT:-}" ]] || { fail "Pre-change safety snapshot is missing from state"; return 1; }
  state_resource_owned snapshot "$DOMAIN:$SAFETY_SNAPSHOT" || { fail "Safety snapshot is not deployment-owned"; return 1; }
  windows_snapshot_exists "$SAFETY_SNAPSHOT" || { fail "Safety snapshot is missing from libvirt"; return 1; }
}

deploy_finish_windows_snapshots() {
  local state
  state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"

  if [[ "${WINDOWS_BACKEND_USED:-}" == manual-powershell ]]; then
    if [[ -z "${FINAL_SNAPSHOT:-}" ]] || ! windows_snapshot_exists "$FINAL_SNAPSHOT"; then
      [[ "$state" == running ]] || {
        fail "Manual Windows fallback was completed but the guest is no longer running before its CAPE snapshot was captured"
        return 1
      }
      validate_windows_result_file
      windows_create_running_snapshot
      state_set_phase windows-running-snapshot
    fi

    state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
    [[ "$state" == "shut off" ]] || windows_poweroff_selected_backend
    windows_create_working_snapshot
    state_set_phase windows-working-snapshot
  else
    if [[ -z "${WORKING_SNAPSHOT:-}" ]] || ! windows_snapshot_exists "$WORKING_SNAPSHOT"; then
      state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
      [[ "$state" == "shut off" ]] || windows_poweroff_selected_backend
      windows_create_working_snapshot
      state_set_phase windows-working-snapshot
    fi

    if [[ -z "${FINAL_SNAPSHOT:-}" ]] || ! windows_snapshot_exists "$FINAL_SNAPSHOT"; then
      windows_start_for_cutover
      windows_select_live_backend
      windows_verify_selected_backend
      windows_create_running_snapshot
      state_set_phase windows-running-snapshot
    fi

    state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
    [[ "$state" == "shut off" ]] || windows_poweroff_selected_backend
  fi

  [[ "$(snapshot_state_memory "$WORKING_SNAPSHOT")" == "shutoff|no" ]] || {
    fail "Configured rollback snapshot is not a shutoff/no-memory snapshot"
    return 1
  }
  [[ "$(snapshot_state_memory "$FINAL_SNAPSHOT")" == "running|internal" ]] || {
    fail "CAPE analysis snapshot is not running-state with internal memory"
    return 1
  }
  state_set_phase windows-snapshots-ready
}

deploy_windows_cutover() {
  deploy_ensure_maintenance

  if ! deploy_phase_at_least windows-nic-attached; then
    windows_stop_for_cutover
    windows_create_safety_snapshot
    windows_attach_isolated_nic
    state_set_phase windows-nic-attached
  else
    deploy_verify_safety_snapshot
    deploy_verify_windows_nic
  fi

  if ! deploy_phase_at_least windows-configured; then
    windows_start_for_cutover
    windows_select_live_backend
    windows_configure_selected_backend
    windows_verify_selected_backend
    state_set_phase windows-configured
  else
    validate_windows_result_file
  fi

  if ! deploy_phase_at_least windows-snapshots-ready; then
    deploy_finish_windows_snapshots
  else
    [[ "$(snapshot_state_memory "$WORKING_SNAPSHOT")" == "shutoff|no" ]]
    [[ "$(snapshot_state_memory "$FINAL_SNAPSHOT")" == "running|internal" ]]
  fi
}

deploy_cape_cutover() {
  if ! deploy_phase_at_least cape-configured; then
    deploy_ensure_maintenance
    cape_configure_inetsim
  else
    validate_cape_configuration
  fi

  if ! deploy_phase_at_least extension-installed; then
    deploy_ensure_maintenance
    extension_install
  fi

  validate_deployment_structural

  if ! deploy_phase_at_least handoff-complete; then
    # If the guard still exists, no new CAPE task can race this handoff.
    if [[ -f "$CAPE_MAINTENANCE_GUARD_FILE" ]]; then
      cape_verify_maintenance_guard
      services_stop_scheduler_for_handoff
      cape_release_maintenance
    elif ! deploy_phase_at_least extension-installed; then
      fail "CAPE maintenance ownership disappeared before configuration handoff"
      return 1
    fi

    services_restore_desired_state
    state_set_phase handoff-complete
  fi

  validate_deployment_services
}

deploy_rollback_after_error() {
  local rc="$1"
  trap - ERR INT TERM
  set +e
  echo
  fail "Deployment failed (exit $rc). Starting ownership-aware rollback."
  if [[ -f "$AD_STATE_FILE" ]]; then
    state_load >/dev/null 2>&1 || true
    autodeploy_rollback_internal
  fi
  set -e
  exit "$rc"
}

deploy_handle_signal() {
  deploy_rollback_after_error 130
}

deploy_run() {
  require_root
  transaction_lock_acquire
  run_discovery
  deploy_assert_supported_environment
  deploy_initialize_or_resume_state

  if [[ "${DEPLOYMENT_PHASE:-}" == committed ]]; then
    validate_deployment_structural
    validate_deployment_services
    pass "Deployment is already committed and validates successfully"
    return 0
  fi

  trap 'deploy_rollback_after_error $?' ERR
  trap deploy_handle_signal INT TERM

  if ! deploy_phase_at_least staged; then
    deploy_stage_non_disruptive
  else
    deploy_validate_staged_resources
  fi

  if ! deploy_phase_at_least windows-snapshots-ready; then
    deploy_windows_cutover
  fi

  if ! deploy_phase_at_least handoff-complete; then
    deploy_cape_cutover
  else
    validate_deployment_structural
    validate_deployment_services
  fi

  state_set_phase committed
  trap - ERR INT TERM
  echo
  pass "CAPE-INetSim-AutoDeploy deployment committed"
  kv "CAPE machine:" "$CAPE_MACHINE_SECTION"
  kv "INetSim server:" "$INETSIM_IP"
  kv "Windows fake IP:" "$WINDOWS_FAKE_IP"
  kv "isolated network:" "$ISOLATED_NETWORK_NAME"
  kv "capture bridge:" "$ISOLATED_BRIDGE_NAME"
  kv "running snapshot:" "$FINAL_SNAPSHOT"
}
