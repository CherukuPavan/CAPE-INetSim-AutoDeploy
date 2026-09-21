#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/windows-network-guard.sh"

declare -A OWNED=()
socket_active=no
service_active=no
bindings_mode=empty

state_record_intent() { :; }
state_write_atomic() { :; }
state_resource_owned() {
  [[ "${OWNED[$1:$2]:-no}" == yes ]]
}
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
    start)
      [[ "$1" == virtnwfilterd.socket ]] || return 1
      socket_active=yes
      ;;
    stop)
      case "$1" in
        virtnwfilterd.socket) socket_active=no ;;
        virtnwfilterd.service) service_active=no ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

windows_management_guard_available() {
  if [[ "$socket_active" == yes ]]; then
    service_active=yes
    return 0
  fi
  return 1
}

virsh() {
  if [[ "$1" == nwfilter-binding-list ]]; then
    printf '%s\n' ' Port Dev' '----------'
    [[ "$bindings_mode" == present ]] && printf '%s\n' ' vnet9'
    return 0
  fi
  return 1
}

MANAGEMENT_NWFILTER_AVAILABLE=activatable
NWFILTER_RUNTIME_MODE=modular-socket
nwfilter_runtime_prepare
[[ "$socket_active" == yes ]]
[[ "$service_active" == yes ]]
state_resource_owned libvirt-service virtnwfilterd.socket
state_resource_owned libvirt-service virtnwfilterd.service
[[ "$MANAGEMENT_NWFILTER_AVAILABLE" == yes ]]
[[ "$NWFILTER_RUNTIME_MODE" == ready ]]

bindings_mode=empty
nwfilter_runtime_rollback
[[ "$socket_active" == no ]]
[[ "$service_active" == no ]]
! state_resource_owned libvirt-service virtnwfilterd.socket
! state_resource_owned libvirt-service virtnwfilterd.service

# If a binding appears while AutoDeploy is active, rollback must preserve the
# runtime instead of risking disruption to an operator-owned filter consumer.
OWNED=()
socket_active=no
service_active=no
bindings_mode=empty
MANAGEMENT_NWFILTER_AVAILABLE=activatable
NWFILTER_RUNTIME_MODE=modular-socket
nwfilter_runtime_prepare
bindings_mode=present
nwfilter_runtime_rollback
[[ "$socket_active" == yes ]]
[[ "$service_active" == yes ]]
! state_resource_owned libvirt-service virtnwfilterd.socket
! state_resource_owned libvirt-service virtnwfilterd.service

grep -Fq 'nwfilter_runtime_prepare' "$ROOT/lib/deploy.sh"
grep -Fq 'nwfilter_runtime_rollback' "$ROOT/lib/rollback.sh"
grep -Fq 'yes|activatable' "$ROOT/lib/deploy.sh"

echo '[PASS] modular nwfilter runtime activation is transactional and rollback-safe'
