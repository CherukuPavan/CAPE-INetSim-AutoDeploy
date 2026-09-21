#!/usr/bin/env bash

EXTENSION_VERSION="1.0.1"
EXTENSION_ARCHIVE="CAPE-INetSim-VM-Extension-v${EXTENSION_VERSION}.tar.gz"
EXTENSION_SHA256="f3be934f08ad364d5964842d3db9bfea0f11cd40a44b76980855d692d3a34d87"
EXTENSION_URL="https://github.com/CherukuPavan/CAPE-INetSim-VM-Extension/releases/download/v${EXTENSION_VERSION}/${EXTENSION_ARCHIVE}"
EXTENSION_ROOT="${EXTENSION_ROOT:-$AD_STATE_ROOT/extension-v${EXTENSION_VERSION}}"

extension_fetch_extract() {
  local cache="$APPLIANCE_CACHE_ROOT/$EXTENSION_ARCHIVE"
  install -d -m 0755 "$APPLIANCE_CACHE_ROOT"

  # Preserve any extension-created recovery point across a crashed installer.
  # Re-extracting over .last_backup/.installed_backup would destroy rollback data.
  if [[ -x "$EXTENSION_ROOT/install.sh" ]] && {
       [[ -s "$EXTENSION_ROOT/.installed_backup" ]] ||
       [[ -s "$EXTENSION_ROOT/.last_backup" ]] ||
       [[ "$(cat "$EXTENSION_ROOT/VERSION" 2>/dev/null || true)" == "$EXTENSION_VERSION" ]];
     }; then
    return 0
  fi

  if [[ ! -f "$cache" || "$(sha256sum "$cache" | awk '{print $1}')" != "$EXTENSION_SHA256" ]]; then
    rm -f "$cache.part"
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 -o "$cache.part" "$EXTENSION_URL"
    [[ "$(sha256sum "$cache.part" | awk '{print $1}')" == "$EXTENSION_SHA256" ]] || { rm -f "$cache.part"; fail "Extension checksum mismatch"; return 1; }
    mv -f "$cache.part" "$cache"
  fi
  rm -rf "$EXTENSION_ROOT.new"
  install -d -m 0700 "$EXTENSION_ROOT.new"
  tar -xzf "$cache" -C "$EXTENSION_ROOT.new" --strip-components=1
  [[ -x "$EXTENSION_ROOT.new/install.sh" ]] || { fail "Extension archive layout invalid"; return 1; }
  [[ "$(cat "$EXTENSION_ROOT.new/VERSION" 2>/dev/null || true)" == "$EXTENSION_VERSION" ]] || { fail "Extension package version mismatch"; return 1; }
  rm -rf "$EXTENSION_ROOT"
  mv "$EXTENSION_ROOT.new" "$EXTENSION_ROOT"
}

extension_write_config() {
  local cfg="$EXTENSION_ROOT/src/inetsim-vm.conf"
  {
    printf 'CAPE_ROOT=%q\n' "$CAPE_ROOT"
    printf 'CAPE_MACHINE=%q\n' "$CAPE_MACHINE_SECTION"
    printf 'CAPE_GUEST_CONTROL_IP=%q\n' "$CAPE_MACHINE_IP"
    printf 'CAPE_RESULTSERVER_IP=%q\n' "$CAPE_RESULTSERVER_IP"
    printf 'INETSIM_SERVER_IP=%q\n' "$INETSIM_IP"
    printf 'ANALYSIS_GUEST_IP=%q\n' "$WINDOWS_FAKE_IP"
    printf 'CAPTURE_INTERFACE=%q\n' "$ISOLATED_BRIDGE_NAME"
  } >"$cfg"
  chmod 0600 "$cfg"
}

extension_install() {
  extension_fetch_extract
  (cd "$EXTENSION_ROOT" && ./install.sh --init-config >/dev/null)
  extension_write_config

  if grep -Rqs 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$CAPE_ROOT/web"; then
    # Adoption is permitted only when this transaction has an extension recovery
    # point. A pre-existing untracked installation is never silently claimed.
    if [[ -s "$EXTENSION_ROOT/.installed_backup" ]] || state_resource_owned extension "CAPE-INetSim-VM-Extension-v$EXTENSION_VERSION"; then
      (cd "$EXTENSION_ROOT" && ./scripts/verify.sh)
      state_record_resource extension "CAPE-INetSim-VM-Extension-v$EXTENSION_VERSION" installed yes "$EXTENSION_ROOT"
      state_set_phase extension-installed
      pass "Existing transaction-owned INetSim web extension validated"
      return 0
    fi
    fail "CAPE already contains an untracked INetSim VM extension marker; refusing to overwrite it"
    return 1
  fi

  (cd "$EXTENSION_ROOT" && ./scripts/verify.sh)
  (cd "$EXTENSION_ROOT" && ./install.sh --dry-run)
  (cd "$EXTENSION_ROOT" && ./install.sh --install)
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
