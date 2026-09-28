#!/usr/bin/env bash

DEPLOY_WAIT_SECONDS="${DEPLOY_WAIT_SECONDS:-3600}"

deploy_required_commands() {
  local -a missing=()
  local cmd
  for cmd in virsh qemu-img virt-install curl flock ip systemctl tar sha256sum base64 timeout; do
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
  [[ -n "${CAPE_SCHEDULER_SERVICE:-}" ]] || {
    fail "CAPE scheduler service could not be discovered"
    return 1
  }
  systemctl is-active --quiet "$CAPE_SCHEDULER_SERVICE" || {
    fail "CAPE scheduler service must be active before deployment: $CAPE_SCHEDULER_SERVICE"
    return 1
  }
  [[ -n "${CAPE_PYTHON:-}" && -x "$CAPE_PYTHON" ]] || {
    fail "Validated CAPE Python interpreter was not discovered"
    return 1
  }
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
  state_set_phase isolated-network-ready
  inetsim_copy_appliance_disk "$artifact"
  inetsim_define_domain
  state_set_phase appliance-defined
  inetsim_configure_guest
  inetsim_verify_host
  state_set_phase staged
}

deploy_windows_cutover() {
  cape_wait_and_acquire_maintenance "$DEPLOY_WAIT_SECONDS"
  state_set_phase maintenance-acquired

  windows_stop_for_cutover
  windows_create_safety_snapshot
  windows_attach_isolated_nic
  state_set_phase windows-nic-attached

  windows_start_for_cutover
  windows_select_live_backend
  windows_configure_selected_backend
  windows_verify_selected_backend
  state_set_phase windows-configured

  windows_poweroff_selected_backend
  windows_create_working_snapshot
  state_set_phase windows-working-snapshot

  windows_start_for_cutover
  windows_select_live_backend
  windows_verify_selected_backend
  windows_create_running_snapshot
  state_set_phase windows-running-snapshot
  windows_poweroff_selected_backend
}

deploy_cape_cutover() {
  validate_rooter_ready
  cape_configure_inetsim
  extension_install
  validate_deployment_structural

  # The scheduler remained alive only to preserve ResultServer access while the
  # guest was configured. All CAPE machines are DB-locked at this point.
  services_stop_scheduler_for_handoff
  cape_release_maintenance
  services_restore_desired_state
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
  export CAPE_INETSIM_LOCK_HELD=1
  run_discovery
  inventory_write
  deployment_decision_engine

  case "${DEPLOYMENT_DECISION:-fresh}" in
    existing-valid)
      pass "Existing AutoDeploy installation is healthy; no changes required"
      return 0
      ;;
    existing-repaired)
      pass "Existing AutoDeploy installation was repaired/upgraded successfully"
      return 0
      ;;
    recovered-for-redeploy)
      # Rollback can restore CAPE/libvirt state, so rediscover everything before
      # choosing fresh resource names, routes, snapshots or interpreters.
      run_discovery
      inventory_write
      ;;
  esac

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

  deploy_stage_non_disruptive
  deploy_windows_cutover
  deploy_cape_cutover

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
