#!/usr/bin/env bash

# Classify and safely handle prior AutoDeploy state before a new deployment.

deployment_existing_phase() {
  [[ -f "$AD_STATE_FILE" ]] || { printf 'fresh\n'; return; }
  (
    state_load >/dev/null 2>&1 || exit 2
    printf '%s\n' "${DEPLOYMENT_PHASE:-unknown}"
  ) || printf 'invalid\n'
}

deployment_recover_owned_previous_state() {
  info "Recovering previous AutoDeploy transaction before redeployment"
  (
    state_load
    autodeploy_rollback_internal
  )
}

deployment_decision_engine() {
  DEPLOYMENT_DECISION="$(deployment_existing_phase)"
  case "$DEPLOYMENT_DECISION" in
    fresh|rolled-back)
      DEPLOYMENT_DECISION=fresh
      ;;
    committed)
      info "Existing committed AutoDeploy installation detected; validating before migration"
      if "$AUTODEPLOY_ROOT/bin/cape-inetsim-verify"; then
        DEPLOYMENT_DECISION=existing-valid
        return 0
      fi
      warn "Existing installation failed verification; attempting safe repair/upgrade"
      if "$AUTODEPLOY_ROOT/bin/cape-inetsim-repair"; then
        DEPLOYMENT_DECISION=existing-repaired
        return 0
      fi
      warn "Repair did not restore health; performing ownership-aware rollback before fresh redeploy"
      deployment_recover_owned_previous_state
      DEPLOYMENT_DECISION=recovered-for-redeploy
      ;;
    rollback-incomplete|planned|isolated-network-ready|appliance-defined|appliance-configured|staged|maintenance-acquired|windows-nic-attached|windows-configured|windows-working-snapshot|windows-running-snapshot|cape-configured)
      warn "Interrupted/broken deployment state detected: $DEPLOYMENT_DECISION"
      deployment_recover_owned_previous_state
      DEPLOYMENT_DECISION=recovered-for-redeploy
      ;;
    invalid|unknown|"")
      fail "Existing AutoDeploy state is invalid or unsupported; refusing to mutate unowned resources"
      return 1
      ;;
    *)
      warn "Unknown previous phase '$DEPLOYMENT_DECISION'; attempting ownership-aware recovery"
      deployment_recover_owned_previous_state
      DEPLOYMENT_DECISION=recovered-for-redeploy
      ;;
  esac
  export DEPLOYMENT_DECISION
}
