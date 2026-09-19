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

require_root_for_plan() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fail "--plan requires root only so libvirt/systemd state can be read consistently."
    echo "Run: sudo ./install --plan"
    return 1
  fi
}

add_error(){ DISCOVERY_ERRORS+=("$*"); }
add_note(){ COMPAT_NOTES+=("$*"); }
