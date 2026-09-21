#!/usr/bin/env bash
set -o pipefail

AD_NAME="CAPE-INetSim-AutoDeploy"
AD_VERSION="$(cat "${AUTODEPLOY_ROOT}/VERSION" 2>/dev/null || echo unknown)"

pass(){ printf '[PASS] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
fail(){ printf '[FAIL] %s\n' "$*"; }
info(){ printf '[INFO] %s\n' "$*"; }
kv(){ printf '%-32s %s\n' "$1" "$2"; }
have(){ command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "This operation requires root so CAPE/libvirt state can be handled consistently."
    return 1
  fi
}

require_root_for_plan() {
  require_root || {
    echo "Run: sudo ./install --plan"
    return 1
  }
}

add_error(){ DISCOVERY_ERRORS+=("$*"); }
add_note(){ COMPAT_NOTES+=("$*"); }

ad_safe_token() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}
