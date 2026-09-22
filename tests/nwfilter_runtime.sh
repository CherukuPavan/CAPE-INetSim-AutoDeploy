#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/windows-network-guard.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/nwfilter"
cat >"$TMP/nwfilter/no-mac-spoofing.xml" <<'EOF'
<filter name='no-mac-spoofing'/>
EOF
cat >"$TMP/nwfilter/no-ip-spoofing.xml" <<'EOF'
<filter name='no-ip-spoofing'/>
EOF
cat >"$TMP/nwfilter/clean-traffic.xml" <<'EOF'
<filter name='clean-traffic'>
  <filterref filter='no-mac-spoofing'/>
  <filterref filter='no-ip-spoofing'/>
</filter>
EOF
NWFILTER_DEFINITION_ROOT="$TMP/nwfilter"

declare -A OWNED=()
declare -A LOADED=()
socket_active=no
socket_enabled=no
service_active=no
service_start_loads=yes
bindings_mode=empty

state_record_intent() { :; }
state_write_atomic() { :; }
state_resource_owned() { [[ "${OWNED[$1:$2]:-no}" == yes ]]; }
state_record_resource() {
  local kind="$1" name="$2" action="$3" created="$4"
  case "$action" in
    activated|applied|recovered-applied)
      [[ "$created" == yes ]] && OWNED["$kind:$name"]=yes
      ;;
    restored|released|removed|deleted)
      OWNED["$kind:$name"]=no
      ;;
  esac
}

systemctl() {
  local op="$1"; shift
  case "$op" in
    is-active)
      [[ "${1:-}" == --quiet ]] && shift
      case "${1:-}" in
        virtnwfilterd.socket) [[ "$socket_active" == yes ]] ;;
        virtnwfilterd.service) [[ "$service_active" == yes ]] ;;
        *) return 1 ;;
      esac
      ;;
    is-enabled)
      [[ "${1:-}" == --quiet ]] && shift
      [[ "${1:-}" == virtnwfilterd.socket && "$socket_enabled" == yes ]]
      ;;
    enable)
      [[ "$1" == virtnwfilterd.socket ]] || return 1
      socket_enabled=yes
      ;;
    disable)
      [[ "$1" == virtnwfilterd.socket ]] || return 1
      socket_enabled=no
      ;;
    start)
      case "$1" in
        virtnwfilterd.socket) socket_active=yes ;;
        virtnwfilterd.service)
          service_active=yes
          if [[ "$service_start_loads" == yes ]]; then
            LOADED[no-mac-spoofing]=yes
            LOADED[no-ip-spoofing]=yes
            LOADED[clean-traffic]=yes
          fi
          ;;
        *) return 1 ;;
      esac
      ;;
    stop)
      case "$1" in
        virtnwfilterd.socket) socket_active=no ;;
        virtnwfilterd.service) service_active=no ;;
        *) return 1 ;;
      esac
      ;;
    show)
      # After shifting the operation, arguments are:
      #   -p LoadState --value UNIT
      case "${4:-}" in
        virtnwfilterd.socket|virtnwfilterd.service) echo loaded; return 0 ;;
      esac
      return 1
      ;;
    *) return 1 ;;
  esac
}

virsh() {
  case "$1" in
    nwfilter-info)
      [[ "${LOADED[$2]:-no}" == yes ]]
      ;;
    nwfilter-define)
      local path="$2" name
      name="$(python3 - "$path" <<'PY'
import sys,xml.etree.ElementTree as ET
print(ET.parse(sys.argv[1]).getroot().get("name",""))
PY
)"
      [[ -n "$name" ]] || return 1
      LOADED["$name"]=yes
      ;;
    nwfilter-binding-list)
      printf '%s\n' ' Port Dev' '----------'
      [[ "$bindings_mode" == present ]] && printf '%s\n' ' vnet9'
      ;;
    *) return 1 ;;
  esac
}

windows_management_guard_available() {
  virsh nwfilter-info clean-traffic >/dev/null 2>&1
}

# Case 1: explicit modular service start loads the packaged definitions.
MANAGEMENT_NWFILTER_AVAILABLE=activatable
NWFILTER_RUNTIME_MODE=modular-socket
nwfilter_runtime_prepare
[[ "$socket_active" == yes ]]
[[ "$socket_enabled" == yes ]]
[[ "$service_active" == yes ]]
[[ "${LOADED[clean-traffic]:-no}" == yes ]]
state_resource_owned libvirt-unit-enable virtnwfilterd.socket
state_resource_owned libvirt-service virtnwfilterd.socket
state_resource_owned libvirt-service virtnwfilterd.service
[[ "$MANAGEMENT_NWFILTER_AVAILABLE" == yes ]]
[[ "$NWFILTER_RUNTIME_MODE" == ready ]]

bindings_mode=empty
nwfilter_runtime_rollback
[[ "$socket_active" == no ]]
[[ "$socket_enabled" == no ]]
[[ "$service_active" == no ]]
! state_resource_owned libvirt-unit-enable virtnwfilterd.socket
! state_resource_owned libvirt-service virtnwfilterd.socket
! state_resource_owned libvirt-service virtnwfilterd.service

# Case 2: modular service starts but does not expose definitions. AutoDeploy
# must load the exact packaged dependency closure through nwfilter-define.
OWNED=()
LOADED=()
socket_active=no
socket_enabled=no
service_active=no
service_start_loads=no
bindings_mode=empty
MANAGEMENT_NWFILTER_AVAILABLE=activatable
NWFILTER_RUNTIME_MODE=modular-socket
nwfilter_runtime_prepare
[[ "${LOADED[no-mac-spoofing]:-no}" == yes ]]
[[ "${LOADED[no-ip-spoofing]:-no}" == yes ]]
[[ "${LOADED[clean-traffic]:-no}" == yes ]]
[[ "$MANAGEMENT_NWFILTER_AVAILABLE" == yes ]]
[[ "$NWFILTER_RUNTIME_MODE" == ready ]]

# Loading package/operator-owned XML definitions must never mark them as
# AutoDeploy-created persistent filters eligible for undefine.
! state_resource_owned libvirt-nwfilter-definition clean-traffic
! state_resource_owned libvirt-nwfilter-definition no-mac-spoofing
! state_resource_owned libvirt-nwfilter-definition no-ip-spoofing

# If a binding appears while AutoDeploy is active, rollback must preserve the
# runtime instead of risking disruption to an operator-owned filter consumer.
bindings_mode=present
nwfilter_runtime_rollback
[[ "$socket_active" == yes ]]
[[ "$socket_enabled" == yes ]]
[[ "$service_active" == yes ]]
! state_resource_owned libvirt-unit-enable virtnwfilterd.socket
! state_resource_owned libvirt-service virtnwfilterd.socket
! state_resource_owned libvirt-service virtnwfilterd.service

# Case 3: non-modular/legacy runtime can reload a packaged definition closure
# without changing service/socket state.
OWNED=()
LOADED=()
socket_active=no
socket_enabled=no
service_active=no
bindings_mode=empty
MANAGEMENT_NWFILTER_AVAILABLE=activatable
NWFILTER_RUNTIME_MODE=definition-reload
nwfilter_runtime_prepare
[[ "${LOADED[clean-traffic]:-no}" == yes ]]
[[ "$socket_active" == no ]]
[[ "$service_active" == no ]]

grep -Fq 'nwfilter_runtime_prepare' "$ROOT/lib/deploy.sh"
grep -Fq 'nwfilter_runtime_rollback' "$ROOT/lib/rollback.sh"
grep -Fq 'yes|activatable' "$ROOT/lib/deploy.sh"
grep -Fq 'nwfilter-define' "$ROOT/lib/windows-network-guard.sh"

echo '[PASS] nwfilter runtime activation/reload is transactional, dependency-aware and rollback-safe'
