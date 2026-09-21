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
    windows-snapshots-ready|windows-all-ready) echo 100 ;;
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
  for cmd in python3 virsh qemu-img virt-install curl flock ip systemctl tar gzip sha256sum base64 timeout nft; do
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
  [[ "${CAPE_DB_BACKEND:-unknown}" == postgresql ]] || {
    fail "v1.0 automated live cutover currently requires CAPE PostgreSQL for atomic scheduler maintenance locking (found: ${CAPE_DB_BACKEND:-unknown}); safe stop, no mutation."
    return 1
  }
  [[ "${CAPE_TARGETS_COUNT:-0}" =~ ^[0-9]+$ && "${CAPE_TARGETS_COUNT:-0}" -gt 0 ]] || {
    fail "No CAPE Windows analysis targets were discovered"
    return 1
  }
  python3 - "${CAPE_TARGETS_JSON:-[]}" <<'PY' || {
import json,sys
a=json.loads(sys.argv[1])
assert a, "empty target set"
for d in a:
    platform=str(d.get("platform") or "windows-unspecified").lower()
    assert platform.startswith("windows"), f"{d.get('section','?')}: not a Windows CAPE analysis machine"
    assert d.get("domain"), f"{d.get('section','?')}: no libvirt domain"
    assert d.get("snapshot_capable")=="yes", f"{d.get('section','?')}: qcow2 internal snapshots not proven"
    assert d.get("analysis_snapshot_status") in ("proven","not-configured"), f"{d.get('section','?')}: existing CAPE snapshot is not safe/proven"
    assert d.get("management_network"), f"{d.get('section','?')}: management network unknown"
    assert d.get("management_bridge"), f"{d.get('section','?')}: management bridge unknown"
    assert d.get("management_mac"), f"{d.get('section','?')}: management MAC unknown"
    assert d.get("resultserver_ip"), f"{d.get('section','?')}: ResultServer IP unknown"
    assert str(d.get("resultserver_port","")).isdigit(), f"{d.get('section','?')}: ResultServer port invalid"
    assert d.get("fake_ip"), f"{d.get('section','?')}: fake-Internet IP was not planned"
PY
    fail "One or more CAPE analysis VMs failed the multi-machine safety preflight"
    return 1
  }
  case "${MANAGEMENT_NWFILTER_AVAILABLE:-no}" in
    yes|activatable) ;;
    *)
      fail "libvirt clean-traffic nwfilter is neither ready nor safely activatable"
      return 1
      ;;
  esac
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
  INETSIM_DOMAIN_NAME="cape-inetsim-appliance"
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
  CAPE_POST_SHA_SNIFFER=""
  CAPE_POST_SHA_AUXILIARY=""
  CAPE_POST_SHA_KVM=""
  CAPE_POST_SHA_PROCESSING=""
  CAPE_POST_SHA_ROUTING=""
  CAPE_SERVICE_WAS_ACTIVE=""
  CAPE_PROCESSOR_WAS_ACTIVE=""
  CAPE_WEB_WAS_ACTIVE=""
  CAPE_ROOTER_WAS_ACTIVE=""
  CAPE_SCHEDULER_STOPPED_BY_AUTODEPLOY=no
}

deploy_initialize_or_resume_state() {
  local d_root="$CAPE_ROOT" d_commit="$CAPE_COMMIT" d_db="$CAPE_DB_BACKEND"
  local d_targets_json="${CAPE_TARGETS_JSON:-[]}"
  local d_targets_identity
  d_targets_identity="$(targets_identity_sha256)"
  local d_subnet="$ISOLATED_SUBNET" d_bridge_ip="$BRIDGE_IP" d_inetsim_ip="$INETSIM_IP"
  local d_storage_pool="${LIBVIRT_STORAGE_POOL:-}" d_storage_path="${LIBVIRT_STORAGE_PATH:-}"

  if [[ -f "$AD_STATE_FILE" ]]; then
    state_load
    if [[ "${DEPLOYMENT_PHASE:-}" != rolled-back ]]; then
      deploy_phase_is_resumable || {
        fail "Existing state is not a resumable deployment phase: ${DEPLOYMENT_PHASE:-unknown}"
        return 1
      }
      [[ "$CAPE_ROOT" == "$d_root" ]] || { fail "Existing deployment state belongs to a different CAPE root"; return 1; }
      [[ "$CAPE_COMMIT" == "$d_commit" ]] || { fail "CAPE commit changed during/after deployment; use verify/repair compatibility flow"; return 1; }
      [[ "$CAPE_DB_BACKEND" == "$d_db" ]] || { fail "CAPE database backend changed during/after deployment; refusing resume"; return 1; }
      [[ "${CAPE_TARGETS_IDENTITY_SHA256:-}" == "$d_targets_identity" ]] || {
        fail "Enabled CAPE analysis-machine identity changed during/after deployment; refusing unsafe resume"
        return 1
      }
      CAPE_TARGETS_COUNT="$(targets_count)"
      ((CAPE_TARGETS_COUNT > 0)) || { fail "Deployment state contains no CAPE analysis targets"; return 1; }
      targets_bind 0
      if deploy_phase_at_least cape-configured; then
        cape_assert_owned_files_unchanged || return 1
      fi
      pass "Resuming deployment state $DEPLOYMENT_ID at phase ${DEPLOYMENT_PHASE:-unknown} for $CAPE_TARGETS_COUNT CAPE machine(s)"
      return 0
    fi
  fi

  CAPE_ROOT="$d_root"
  CAPE_COMMIT="$d_commit"
  CAPE_DB_BACKEND="$d_db"
  CAPE_TARGETS_JSON="$d_targets_json"
  CAPE_TARGETS_COUNT="$(targets_count)"
  CAPE_TARGETS_IDENTITY_SHA256="$d_targets_identity"
  ISOLATED_SUBNET="$d_subnet"
  BRIDGE_IP="$d_bridge_ip"
  INETSIM_IP="$d_inetsim_ip"
  deploy_reset_resource_state
  LIBVIRT_STORAGE_POOL="$d_storage_pool"
  LIBVIRT_STORAGE_PATH="$d_storage_path"
  targets_bind 0

  state_init_paths
  state_new_deployment_id
  DEPLOYMENT_PHASE=planned
  isolated_network_defaults
  choose_isolated_bridge_name
  state_write_atomic
  services_capture_original_state
  pass "Initialized deployment transaction $DEPLOYMENT_ID for $CAPE_TARGETS_COUNT CAPE analysis machine(s)"
}

deploy_stage_non_disruptive() {
  local artifact
  info "Staging isolated network and generalized INetSim appliance; CAPE analyses are not interrupted."
  nwfilter_runtime_prepare
  artifact="$(appliance_fetch "$APPLIANCE_MANIFEST")"

  isolated_network_apply
  firewall_apply
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
  nwfilter_runtime_prepare
  artifact="$(appliance_fetch "$APPLIANCE_MANIFEST")"
  isolated_network_apply
  firewall_apply
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
  if [[ -z "${WORKING_SNAPSHOT:-}" ]] || ! windows_snapshot_exists "$WORKING_SNAPSHOT"; then
    state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
    [[ "$state" == "shut off" ]] || windows_poweroff_selected_backend
    windows_create_working_snapshot
  fi

  if [[ -z "${FINAL_SNAPSHOT:-}" ]] || ! windows_snapshot_exists "$FINAL_SNAPSHOT"; then
    windows_start_for_cutover
    windows_select_live_backend
    windows_verify_selected_backend
    windows_create_running_snapshot
  fi

  state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
  [[ "$state" == "shut off" ]] || windows_poweroff_selected_backend

  [[ "$(snapshot_state_memory "$WORKING_SNAPSHOT")" == "shutoff|no" ]] || {
    fail "Configured rollback snapshot is not a shutoff/no-memory snapshot for $CAPE_MACHINE_SECTION"
    return 1
  }
  [[ "$(snapshot_state_memory "$FINAL_SNAPSHOT")" == "running|internal" ]] || {
    fail "CAPE analysis snapshot is not running-state with internal memory for $CAPE_MACHINE_SECTION"
    return 1
  }
  target_state_set_phase snapshots-ready
}

deploy_windows_target_cutover() {
  case "${TARGET_PHASE:-discovered}" in
    discovered)
      info "Preparing CAPE analysis VM $CAPE_MACHINE_SECTION ($DOMAIN)"
      windows_stop_for_cutover
      windows_create_safety_snapshot
      windows_management_guard_apply
      windows_attach_isolated_nic
      target_state_set_phase nic-attached
      # Re-render the shared host guard with every target whose management
      # anti-spoof protection is now active. This preserves previously protected
      # machines while adding the current one.
      firewall_enable_windows_management_guard
      ;;
    nic-attached|configured|snapshots-ready|cape-configured)
      deploy_verify_safety_snapshot
      windows_management_guard_verify
      deploy_verify_windows_nic
      firewall_apply
      ;;
    *)
      fail "Unknown per-target deployment phase for $CAPE_MACHINE_SECTION: ${TARGET_PHASE:-missing}"
      return 1
      ;;
  esac

  if [[ "${TARGET_PHASE:-}" == nic-attached ]]; then
    windows_start_for_cutover
    windows_select_live_backend
    windows_configure_selected_backend
    windows_verify_selected_backend
    target_state_set_phase configured
  elif [[ "${TARGET_PHASE:-}" == configured || "${TARGET_PHASE:-}" == snapshots-ready || "${TARGET_PHASE:-}" == cape-configured ]]; then
    validate_windows_result_file
  fi

  if [[ "${TARGET_PHASE:-}" == configured ]]; then
    deploy_finish_windows_snapshots
  elif [[ "${TARGET_PHASE:-}" == snapshots-ready || "${TARGET_PHASE:-}" == cape-configured ]]; then
    [[ "$(snapshot_state_memory "$WORKING_SNAPSHOT")" == "shutoff|no" ]]
    [[ "$(snapshot_state_memory "$FINAL_SNAPSHOT")" == "running|internal" ]]
  fi

  pass "CAPE analysis VM prepared: $CAPE_MACHINE_SECTION -> $DOMAIN"
}

deploy_windows_cutover() {
  deploy_ensure_maintenance
  local i
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    targets_bind "$i"
    deploy_windows_target_cutover
    targets_capture_bound "$i"
    state_write_atomic
  done
  targets_bind 0
  state_set_phase windows-all-ready
}

deploy_validate_all_cape_configuration() {
  local saved="${TARGET_INDEX:-}" i failures=0
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    targets_bind "$i"
    validate_cape_configuration || failures=$((failures+1))
  done
  [[ "$saved" =~ ^[0-9]+$ ]] && targets_bind "$saved"
  ((failures == 0))
}

deploy_cape_cutover() {
  if ! deploy_phase_at_least cape-configured; then
    deploy_ensure_maintenance
    cape_configure_inetsim
  else
    deploy_validate_all_cape_configuration
  fi

  if ! deploy_phase_at_least extension-installed; then
    deploy_ensure_maintenance
    extension_install
  fi

  validate_deployment_structural

  if ! deploy_phase_at_least handoff-complete; then
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

  if ! deploy_phase_at_least windows-all-ready; then
    deploy_windows_cutover
  else
    local i
    for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
      targets_bind "$i"
      deploy_windows_target_cutover
    done
    targets_bind 0
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
  kv "managed CAPE machines:" "${CAPE_TARGETS_COUNT:-0}"
  kv "INetSim server:" "$INETSIM_IP"
  kv "isolated network:" "$ISOLATED_NETWORK_NAME"
  kv "capture bridge:" "$ISOLATED_BRIDGE_NAME"
  echo "Managed analysis VMs:"
  targets_summary_lines | sed 's/^/  /'
}
