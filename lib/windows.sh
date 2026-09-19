#!/usr/bin/env bash

probe_tcp(){ timeout 1 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }

discover_windows_backends() {
  QGA_AVAILABLE="no"; WINRM_AVAILABLE="no"; CAPE_AGENT_REACHABLE="no"; WINDOWS_BACKEND="manual-powershell-fallback"
  if [[ -n "${DOMAIN:-}" ]] && virsh qemu-agent-command "$DOMAIN" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
    QGA_AVAILABLE="yes"; WINDOWS_BACKEND="qemu-guest-agent"
  elif [[ -n "${CAPE_MACHINE_IP:-}" ]] && { probe_tcp "$CAPE_MACHINE_IP" 5985 || probe_tcp "$CAPE_MACHINE_IP" 5986; }; then
    WINRM_AVAILABLE="yes"; WINDOWS_BACKEND="winrm"
  fi
  if [[ -n "${CAPE_MACHINE_IP:-}" ]] && probe_tcp "$CAPE_MACHINE_IP" 8000; then CAPE_AGENT_REACHABLE="yes"; fi
}
