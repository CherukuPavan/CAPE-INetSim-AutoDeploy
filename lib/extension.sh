#!/usr/bin/env bash

EXTENSION_VERSION="1.0.1"
EXTENSION_RELEASE_ASSET_SHA256="f3be934f08ad364d5964842d3db9bfea0f11cd40a44b76980855d692d3a34d87"
EXTENSION_BUNDLED_ROOT="${EXTENSION_BUNDLED_ROOT:-$AUTODEPLOY_ROOT/vendor/CAPE-INetSim-VM-Extension-v${EXTENSION_VERSION}}"
EXTENSION_ROOT="${EXTENSION_ROOT:-$AD_STATE_ROOT/extension-v${EXTENSION_VERSION}}"

extension_fetch_extract() {
  # The exact v1.0.1 runtime is vendored inside the checksum-pinned AutoDeploy
  # source bundle. A random target host must never need credentials for the
  # separate private extension development repository.
  [[ -d "$EXTENSION_BUNDLED_ROOT" ]] || {
    fail "Bundled INetSim extension runtime is missing"
    return 1
  }
  [[ -s "$EXTENSION_BUNDLED_ROOT/RUNTIME-SHA256SUMS" ]] || {
    fail "Bundled INetSim extension checksum manifest is missing"
    return 1
  }

  if ! (cd "$EXTENSION_BUNDLED_ROOT" && sha256sum -c RUNTIME-SHA256SUMS >/dev/null); then
    fail "Bundled INetSim extension runtime checksum verification failed"
    return 1
  fi
  [[ "$(cat "$EXTENSION_BUNDLED_ROOT/VERSION" 2>/dev/null || true)" == "$EXTENSION_VERSION" ]] || {
    fail "Bundled INetSim extension version mismatch"
    return 1
  }

  # Preserve any extension-created recovery point across a crashed installer.
  # Re-copying over .last_backup/.installed_backup would destroy rollback data.
  if [[ -x "$EXTENSION_ROOT/install.sh" ]] && {
       [[ -s "$EXTENSION_ROOT/.installed_backup" ]] ||
       [[ -s "$EXTENSION_ROOT/.last_backup" ]] ||
       [[ "$(cat "$EXTENSION_ROOT/VERSION" 2>/dev/null || true)" == "$EXTENSION_VERSION" ]];
     }; then
    return 0
  fi

  rm -rf "$EXTENSION_ROOT.new"
  install -d -m 0700 "$EXTENSION_ROOT.new"
  cp -a "$EXTENSION_BUNDLED_ROOT/." "$EXTENSION_ROOT.new/"
  chmod 0755 "$EXTENSION_ROOT.new/install.sh" "$EXTENSION_ROOT.new"/scripts/*.sh
  chmod 0755 "$EXTENSION_ROOT.new/scripts/prepare_install_candidate.py" 2>/dev/null || true

  [[ -x "$EXTENSION_ROOT.new/install.sh" ]] || { fail "Bundled extension layout invalid"; return 1; }
  [[ "$(cat "$EXTENSION_ROOT.new/VERSION" 2>/dev/null || true)" == "$EXTENSION_VERSION" ]] || {
    fail "Bundled extension package version mismatch"
    return 1
  }

  rm -rf "$EXTENSION_ROOT"
  mv "$EXTENSION_ROOT.new" "$EXTENSION_ROOT"
}

extension_write_config() {
  local cfg="$EXTENSION_ROOT/src/inetsim-vm.conf"
  # The extension modifies one shared CAPE web surface. Its environment
  # verifier needs one representative managed machine plus the shared INetSim
  # endpoint; AutoDeploy itself performs the authoritative per-machine checks
  # across the complete CAPE_TARGETS_JSON set.
  local saved="${TARGET_INDEX:-}"
  (( $(targets_count) > 0 )) || { fail "No managed CAPE targets exist for extension configuration"; return 1; }
  targets_bind 0
  {
    printf 'CAPE_ROOT=%q\n' "$CAPE_ROOT"
    printf 'CAPE_MACHINE=%q\n' "$CAPE_MACHINE_SECTION"
    printf 'CAPE_DOMAIN=%q\n' "$DOMAIN"
    printf 'CAPE_GUEST_CONTROL_IP=%q\n' "$CAPE_MACHINE_IP"
    printf 'CAPE_RESULTSERVER_IP=%q\n' "$CAPE_RESULTSERVER_IP"
    printf 'INETSIM_SERVER_IP=%q\n' "$INETSIM_IP"
    printf 'ANALYSIS_GUEST_IP=%q\n' "$WINDOWS_FAKE_IP"
    printf 'CAPTURE_INTERFACE=%q\n' "$ISOLATED_BRIDGE_NAME"
  } >"$cfg"
  chmod 0600 "$cfg"
  if [[ "$saved" =~ ^[0-9]+$ ]]; then targets_bind "$saved"; fi
  return 0
}

extension_run_logged() {
  local stage="$1"
  shift
  local log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-extension-${stage}.log"
  (cd "$EXTENSION_ROOT" && "$@") > >(tee "$log") 2>&1
}

extension_install() {
  extension_fetch_extract
  (cd "$EXTENSION_ROOT" && ./install.sh --init-config >/dev/null)
  extension_write_config

  if grep -Rqs 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$CAPE_ROOT/web"; then
    # Adoption is permitted only when this transaction has an extension recovery
    # point. A pre-existing untracked installation is never silently claimed.
    if [[ -s "$EXTENSION_ROOT/.installed_backup" ]] || state_resource_owned extension "CAPE-INetSim-VM-Extension-v$EXTENSION_VERSION"; then
      extension_run_logged verify ./scripts/verify.sh
      state_record_resource extension "CAPE-INetSim-VM-Extension-v$EXTENSION_VERSION" installed yes "$EXTENSION_ROOT"
      state_set_phase extension-installed
      pass "Existing transaction-owned INetSim web extension validated"
      return 0
    fi
    fail "CAPE already contains an untracked INetSim VM extension marker; refusing to overwrite it"
    return 1
  fi

  (cd "$EXTENSION_ROOT" && ./scripts/verify.sh)
  extension_run_logged dry-run ./install.sh --dry-run
  extension_run_logged install ./install.sh --install
  grep -Rqs 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$CAPE_ROOT/web" || { fail "Extension route-none marker missing after install"; return 1; }
  [[ -s "$EXTENSION_ROOT/.installed_backup" ]] || { fail "Extension installed without a protected recovery-point reference"; return 1; }
  state_record_resource extension "CAPE-INetSim-VM-Extension-v$EXTENSION_VERSION" installed yes "$EXTENSION_ROOT"
  state_set_phase extension-installed
}

extension_rollback() {
  [[ -d "$EXTENSION_ROOT" ]] || return 0
  if ! state_resource_owned extension "CAPE-INetSim-VM-Extension-v$EXTENSION_VERSION" &&
     [[ ! -s "$EXTENSION_ROOT/.installed_backup" && ! -s "$EXTENSION_ROOT/.last_backup" ]]; then
    return 0
  fi
  (cd "$EXTENSION_ROOT" && ./scripts/rollback.sh --check)
  (cd "$EXTENSION_ROOT" && printf 'RESTORE\n' | ./scripts/rollback.sh --restore)
  state_record_resource extension "CAPE-INetSim-VM-Extension-v$EXTENSION_VERSION" removed-by-rollback yes "$EXTENSION_ROOT"
}
