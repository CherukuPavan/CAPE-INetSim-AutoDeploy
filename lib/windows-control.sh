#!/usr/bin/env bash

windows_wait_for_domain_state() {
  local want="$1" timeout="${2:-120}" elapsed=0 got
  while ((elapsed < timeout)); do
    got="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
    [[ "$got" == "$want" ]] && return 0
    sleep 2
    elapsed=$((elapsed+2))
  done
  fail "Timed out waiting for Windows domain '$DOMAIN' state '$want' (current: ${got:-unknown})"
  return 1
}

windows_start_for_cutover() {
  local state
  state="$(virsh domstate "$DOMAIN" | xargs)"
  case "$state" in
    running) ;;
    "shut off") virsh start "$DOMAIN" >/dev/null ;;
    *) fail "Unsupported Windows domain state for cutover: $state"; return 1 ;;
  esac
  windows_wait_for_domain_state running 60
}

windows_select_live_backend() {
  WINDOWS_BACKEND_USED=""
  if qga_wait "$DOMAIN" 10; then
    WINDOWS_BACKEND_USED=qemu-guest-agent
    pass "Windows control backend: QEMU Guest Agent"
    return 0
  fi
  if cape_agent_probe "$CAPE_MACHINE_IP" >/dev/null 2>&1; then
    WINDOWS_BACKEND_USED=cape-agent
    pass "Windows control backend: CAPE Agent"
    return 0
  fi
  WINDOWS_BACKEND_USED=manual-powershell
  warn "No supported zero-touch Windows execution channel is currently available"
  return 40
}

windows_configure_selected_backend() {
  case "$WINDOWS_BACKEND_USED" in
    qemu-guest-agent)
      windows_configure_via_qga "$CAPE_MACHINE_IP" "$WINDOWS_ISOLATED_MAC" "$WINDOWS_FAKE_IP" 24 "$INETSIM_IP" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT" "$CONTROL_HOST_IP"
      ;;
    cape-agent)
      windows_configure_via_cape_agent "$CAPE_MACHINE_IP" "$WINDOWS_ISOLATED_MAC" "$WINDOWS_FAKE_IP" 24 "$INETSIM_IP" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT" "$CONTROL_HOST_IP"
      WINDOWS_BACKEND_USED=cape-agent
      state_write_atomic
      ;;
    *)
      fail "Windows configuration backend is not automated: ${WINDOWS_BACKEND_USED:-none}"
      return 40
      ;;
  esac
}

windows_verify_selected_backend() {
  case "$WINDOWS_BACKEND_USED" in
    qemu-guest-agent)
      windows_verify_via_qga "$CAPE_MACHINE_IP" "$WINDOWS_ISOLATED_MAC" "$WINDOWS_FAKE_IP" "$INETSIM_IP" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT"
      ;;
    cape-agent)
      windows_verify_via_cape_agent "$CAPE_MACHINE_IP" "$WINDOWS_ISOLATED_MAC" "$WINDOWS_FAKE_IP" "$INETSIM_IP" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT"
      ;;
    *)
      fail "Cannot perform automated Windows safety verification with backend: ${WINDOWS_BACKEND_USED:-none}"
      return 40
      ;;
  esac
  pass "Windows safety gates passed: fake IP/DNS, no default route, ResultServer reachable, public IP unreachable"
}

windows_poweroff_selected_backend() {
  case "$WINDOWS_BACKEND_USED" in
    qemu-guest-agent) windows_poweroff_via_qga ;;
    cape-agent) windows_poweroff_via_cape_agent "$CAPE_MACHINE_IP" ;;
    *) virsh shutdown "$DOMAIN" >/dev/null 2>&1 || true ;;
  esac
  windows_wait_for_domain_state "shut off" 120
}

windows_manual_command() {
  local script_b64 wrapper encoded
  script_b64="$(base64 -w0 "$AUTODEPLOY_ROOT/windows/configure-inetsim.ps1")"
  wrapper="$s=[ScriptBlock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$script_b64'))); & $s -ManagementIP '$CAPE_MACHINE_IP' -IsolatedMac '$WINDOWS_ISOLATED_MAC' -FakeIP '$WINDOWS_FAKE_IP' -PrefixLength 24 -DnsIP '$INETSIM_IP' -ResultServerIP '$CAPE_RESULTSERVER_IP' -ResultServerPort $CAPE_RESULTSERVER_PORT -ControlHostIP '$CONTROL_HOST_IP' -ResultPath 'C:\Windows\Temp\cape-inetsim-autodeploy-result.json'"
  encoded="$(python3 - "$wrapper" <<'PY'
import base64,sys
print(base64.b64encode(sys.argv[1].encode("utf-16le")).decode())
PY
)"
  printf 'powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand %s\n' "$encoded"
}
