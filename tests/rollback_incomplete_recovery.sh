#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/deploy.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
AD_STATE_FILE="$TMP/state.env"
CAPE_MAINTENANCE_GUARD_FILE="$TMP/cape-maintenance-guard.json"
touch "$AD_STATE_FILE"

seed_discovery() {
  CAPE_ROOT=/opt/CAPEv2
  CAPE_COMMIT=0123456789abcdef0123456789abcdef01234567
  CAPE_DB_BACKEND=postgresql
  CAPE_TARGETS_JSON='[{"section":"win10","domain":"win10"}]'
  CAPE_TARGETS_COUNT=1
  CAPE_TARGETS_IDENTITY_SHA256=identity-a
  ISOLATED_SUBNET=10.77.50.0/24
  BRIDGE_IP=10.77.50.1
  INETSIM_IP=10.77.50.2
  LIBVIRT_STORAGE_POOL=default
  LIBVIRT_STORAGE_PATH=/var/lib/libvirt/images
  CAPE_INETSIM_RELEASE_TAG=v1.0.0-rc.34
  CAPE_INETSIM_RELEASE_SOURCE_BUNDLE=CAPE-INetSim-AutoDeploy-1.0.0-rc.34.tar.gz
  CAPE_INETSIM_RELEASE_SOURCE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  CAPE_INETSIM_RELEASE_SOURCE_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  RECOVERY_CALLED=no
  SERVICES_VALIDATED=no
  NEW_STATE_CREATED=no
}

targets_identity_sha256() { printf '%s\n' identity-a; }
targets_count() { printf '%s\n' 1; }
targets_bind() {
  TARGET_INDEX="$1"
  CAPE_MACHINE_SECTION=win10
  CAPE_MACHINE_LABEL=win10
  DOMAIN=win10
}
state_load() {
  DEPLOYMENT_ID=old-rollback-incomplete
  DEPLOYMENT_PHASE=rollback-incomplete
  CAPE_ROOT=/opt/CAPEv2
  CAPE_COMMIT=0123456789abcdef0123456789abcdef01234567
  CAPE_DB_BACKEND=postgresql
  CAPE_TARGETS_JSON='[{"section":"win10","domain":"win10"}]'
  CAPE_TARGETS_COUNT=1
  CAPE_TARGETS_IDENTITY_SHA256=identity-a
  CAPE_SERVICE_WAS_ACTIVE=yes
  CAPE_PROCESSOR_WAS_ACTIVE=yes
  CAPE_WEB_WAS_ACTIVE=yes
  CAPE_ROOTER_WAS_ACTIVE=yes
}
state_init_paths() { :; }
state_new_deployment_id() { DEPLOYMENT_ID=new-deployment; NEW_STATE_CREATED=yes; }
state_write_atomic() { :; }
isolated_network_defaults() { :; }
choose_isolated_bridge_name() { ISOLATED_BRIDGE_NAME=capeisim-test; }
services_capture_original_state() { :; }
services_validate_restored_state() { SERVICES_VALIDATED=yes; }
state_has_owned_kind() { return 1; }
autodeploy_rollback_internal() {
  RECOVERY_CALLED=yes
  DEPLOYMENT_PHASE=rolled-back
  return 0
}

seed_discovery
deploy_initialize_or_resume_state
[[ "$RECOVERY_CALLED" == yes ]]
[[ "$SERVICES_VALIDATED" == yes ]]
[[ "$NEW_STATE_CREATED" == yes ]]
[[ "$DEPLOYMENT_ID" == new-deployment ]]
[[ "$DEPLOYMENT_PHASE" == planned ]]
[[ "$CAPE_ROOT" == /opt/CAPEv2 ]]
[[ "$CAPE_COMMIT" == 0123456789abcdef0123456789abcdef01234567 ]]
[[ "$RELEASE_TAG" == v1.0.0-rc.34 ]]
[[ "$RELEASE_SOURCE_COMMIT" == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]

# If the ownership-aware rollback itself still fails, no fresh transaction may
# be created.
autodeploy_rollback_internal() {
  RECOVERY_CALLED=yes
  DEPLOYMENT_PHASE=rollback-incomplete
  return 1
}
seed_discovery
if deploy_initialize_or_resume_state >/dev/null 2>&1; then
  echo "rollback-incomplete recovery accepted a failed rollback engine" >&2
  exit 1
fi
[[ "$RECOVERY_CALLED" == yes ]]
[[ "$NEW_STATE_CREATED" == no ]]

# Even a zero-return rollback must not be trusted if mutable ownership remains.
autodeploy_rollback_internal() {
  RECOVERY_CALLED=yes
  DEPLOYMENT_PHASE=rolled-back
  return 0
}
state_has_owned_kind() {
  [[ "$1" == snapshot ]]
}
seed_discovery
if deploy_initialize_or_resume_state >/dev/null 2>&1; then
  echo "rollback-incomplete recovery accepted residual owned snapshot state" >&2
  exit 1
fi
[[ "$RECOVERY_CALLED" == yes ]]
[[ "$NEW_STATE_CREATED" == no ]]

grep -Fq 'Previous AutoDeploy transaction $old_id is rollback-incomplete' "$ROOT/lib/deploy.sh"
grep -Fq 'deploy_verify_recovered_transaction_clean' "$ROOT/lib/deploy.sh"
grep -Fq 'Rollback-incomplete state belongs to a different CAPE root' "$ROOT/lib/deploy.sh"
grep -Fq 'Recovered transaction still owns mutable resource kind' "$ROOT/lib/deploy.sh"

echo '[PASS] rollback-incomplete state is recovered only after ownership-safe cleanup'
