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


nwfilter_definition_roots() {
  if [[ -n "${NWFILTER_DEFINITION_ROOT:-}" ]]; then
    printf '%s\n' "$NWFILTER_DEFINITION_ROOT"
    return 0
  fi
  printf '%s\n' /etc/libvirt/nwfilter /usr/share/libvirt/nwfilter
}

nwfilter_find_definition() {
  local target="$1" root path
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    path="$root/$target.xml"
    [[ -r "$path" ]] || continue
    if python3 - "$path" "$target" <<'PY'
import sys,xml.etree.ElementTree as ET
path,target=sys.argv[1:]
try:
    root=ET.parse(path).getroot()
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if root.tag=="filter" and root.get("name")==target else 1)
PY
    then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(nwfilter_definition_roots)
  return 1
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

ad_safe_token() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}
