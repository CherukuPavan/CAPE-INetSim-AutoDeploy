#!/usr/bin/env bash

EXTENSION_VERSION="1.0.1"
EXTENSION_ARCHIVE="CAPE-INetSim-VM-Extension-v${EXTENSION_VERSION}.tar.gz"
EXTENSION_SHA256="f3be934f08ad364d5964842d3db9bfea0f11cd40a44b76980855d692d3a34d87"
EXTENSION_URL="https://github.com/CherukuPavan/CAPE-INetSim-VM-Extension/releases/download/v${EXTENSION_VERSION}/${EXTENSION_ARCHIVE}"
EXTENSION_ROOT="${EXTENSION_ROOT:-$AD_STATE_ROOT/extension-v${EXTENSION_VERSION}}"
EXTENSION_VENDOR_ROOT="${EXTENSION_VENDOR_ROOT:-$AUTODEPLOY_ROOT/vendor/CAPE-INetSim-VM-Extension-v${EXTENSION_VERSION}}"

extension_fetch_extract() {
  if [[ -d "$EXTENSION_VENDOR_ROOT" ]]; then
    [[ "$(cat "$EXTENSION_VENDOR_ROOT/VERSION" 2>/dev/null || true)" == "$EXTENSION_VERSION" ]] || {
      fail "Vendored extension VERSION does not match requested $EXTENSION_VERSION"
      return 1
    }
    ad_python - "$EXTENSION_VENDOR_ROOT/ORIGIN.json" "$EXTENSION_VERSION" <<'PY'
import json,sys
p,version=sys.argv[1:]
d=json.load(open(p))
assert d["repository"]=="CherukuPavan/CAPE-INetSim-VM-Extension"
assert d["version"]==version
assert len(d["source_commit"])==40
PY
    rm -rf "$EXTENSION_ROOT.new"
    install -d -m 0700 "$EXTENSION_ROOT.new"
    cp -a "$EXTENSION_VENDOR_ROOT/." "$EXTENSION_ROOT.new/"
    rm -f "$EXTENSION_ROOT.new/ORIGIN.json"
    rm -rf "$EXTENSION_ROOT"
    mv "$EXTENSION_ROOT.new" "$EXTENSION_ROOT"
    pass "Using source-pinned vendored INetSim extension v$EXTENSION_VERSION"
    return 0
  fi

  local cache="$APPLIANCE_CACHE_ROOT/$EXTENSION_ARCHIVE"
  install -d -m 0755 "$APPLIANCE_CACHE_ROOT"
  if [[ ! -f "$cache" || "$(sha256sum "$cache" | awk '{print $1}')" != "$EXTENSION_SHA256" ]]; then
    curl --fail --location --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors -o "$cache.part" "$EXTENSION_URL"
    [[ "$(sha256sum "$cache.part" | awk '{print $1}')" == "$EXTENSION_SHA256" ]] || { rm -f "$cache.part"; fail "Extension checksum mismatch"; return 1; }
    mv -f "$cache.part" "$cache"
  fi
  rm -rf "$EXTENSION_ROOT.new"
  install -d -m 0700 "$EXTENSION_ROOT.new"
  tar -xzf "$cache" -C "$EXTENSION_ROOT.new" --strip-components=1
  [[ -x "$EXTENSION_ROOT.new/install.sh" ]] || { fail "Extension archive layout invalid"; return 1; }
  rm -rf "$EXTENSION_ROOT"
  mv "$EXTENSION_ROOT.new" "$EXTENSION_ROOT"
}

extension_write_config() {
  cat >"$EXTENSION_ROOT/src/inetsim-vm.conf" <<EOF2
CAPE_ROOT=$CAPE_ROOT
CAPE_MACHINE=$CAPE_MACHINE_SECTION
CAPE_GUEST_CONTROL_IP=$CAPE_MACHINE_IP
CAPE_RESULTSERVER_IP=$CAPE_RESULTSERVER_IP
INETSIM_SERVER_IP=$INETSIM_IP
ANALYSIS_GUEST_IP=$WINDOWS_FAKE_IP
CAPTURE_INTERFACE=$ISOLATED_BRIDGE_NAME
EOF2
  chmod 0600 "$EXTENSION_ROOT/src/inetsim-vm.conf"
}

extension_install() {
  extension_fetch_extract
  (cd "$EXTENSION_ROOT" && ./install.sh --init-config >/dev/null)
  extension_write_config
  (cd "$EXTENSION_ROOT" && ./scripts/verify.sh)
  (cd "$EXTENSION_ROOT" && ./install.sh --dry-run)
  (cd "$EXTENSION_ROOT" && ./install.sh --install)
  grep -Rqs 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$CAPE_ROOT/web" || { fail "Extension route-none marker missing after install"; return 1; }
  state_record_resource extension "CAPE-INetSim-VM-Extension-v$EXTENSION_VERSION" installed yes "$EXTENSION_ROOT"
  state_set_phase extension-installed
}

extension_rollback() {
  [[ -d "$EXTENSION_ROOT" ]] || return 0
  if ! state_resource_owned extension "CAPE-INetSim-VM-Extension-v$EXTENSION_VERSION" && [[ ! -s "$EXTENSION_ROOT/.installed_backup" ]]; then
    return 0
  fi
  (cd "$EXTENSION_ROOT" && ./scripts/rollback.sh --check)
  (cd "$EXTENSION_ROOT" && printf 'RESTORE\n' | ./scripts/rollback.sh --restore)
  state_record_resource extension "CAPE-INetSim-VM-Extension-v$EXTENSION_VERSION" removed-by-rollback yes "$EXTENSION_ROOT"
}
