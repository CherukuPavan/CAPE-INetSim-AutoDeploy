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

# Host-side Python wrapper. runtime.sh upgrades AD_HOST_PYTHON with full
# validation, but low-level libraries/tests may call this before discovery.
ad_python() {
  local py="${AD_HOST_PYTHON:-}"
  if [[ -z "$py" || ! -x "$py" ]]; then
    py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
  fi
  [[ -n "$py" && -x "$py" ]] || { fail "No usable host Python interpreter found"; return 127; }
  "$py" "$@"
}

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
