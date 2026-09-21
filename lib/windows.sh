#!/usr/bin/env bash

probe_tcp(){ timeout 1 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }

discover_windows_backends() {
  QGA_AVAILABLE="unknown"
  WINRM_AVAILABLE="unknown"
  CAPE_AGENT_REACHABLE="unknown"
  WINDOWS_BACKEND="deferred-probe"

  # A powered-off guest cannot prove that guest-side services are absent.
  # Defer backend selection until the safe cutover boot rather than incorrectly
  # falling back to manual PowerShell.
  case "${DOMAIN_STATE:-unknown}" in
    running|paused|blocked)
      ;;
    *)
      return 0
      ;;
  esac

  QGA_AVAILABLE="no"; WINRM_AVAILABLE="no"; CAPE_AGENT_REACHABLE="no"
  if [[ -n "${DOMAIN:-}" ]] && virsh qemu-agent-command "$DOMAIN" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    QGA_AVAILABLE="yes"
    WINDOWS_BACKEND="qemu-guest-agent"
    return 0
  fi

  if [[ -n "${CAPE_MACHINE_IP:-}" ]] && { probe_tcp "$CAPE_MACHINE_IP" 5985 || probe_tcp "$CAPE_MACHINE_IP" 5986; }; then
    WINRM_AVAILABLE="yes"
    WINDOWS_BACKEND="winrm-candidate"
  fi

  # CAPE Agent is accepted only when its runtime identity reports the execpy
  # feature and Administrator context. The deploy path uses only /store,
  # /execpy and /retrieve with a fixed AutoDeploy runner; it never uses the
  # unrestricted command endpoint.
  if [[ -n "${CAPE_MACHINE_IP:-}" ]] && declare -F cape_agent_probe >/dev/null 2>&1 &&
     cape_agent_probe "$CAPE_MACHINE_IP" >/dev/null 2>&1; then
    CAPE_AGENT_REACHABLE="yes"
    [[ "$WINDOWS_BACKEND" == winrm-candidate ]] || WINDOWS_BACKEND="cape-agent-execpy-candidate"
  elif [[ -n "${CAPE_MACHINE_IP:-}" ]] && probe_tcp "$CAPE_MACHINE_IP" 8000; then
    CAPE_AGENT_REACHABLE="reachable-unverified"
  fi

  case "$WINDOWS_BACKEND" in
    winrm-candidate|cape-agent-execpy-candidate) ;;
    *) WINDOWS_BACKEND="zero-touch-unavailable" ;;
  esac
}
