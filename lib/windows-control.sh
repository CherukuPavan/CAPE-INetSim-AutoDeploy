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
  if windows_winrm_ready "$CAPE_MACHINE_IP" >/dev/null 2>&1; then
    WINDOWS_BACKEND_USED=winrm
    pass "Windows control backend: approved WinRM"
    return 0
  fi
  if cape_agent_wait "$CAPE_MACHINE_IP" 45 >/dev/null 2>&1; then
    WINDOWS_BACKEND_USED=cape-agent-execpy
    pass "Windows control backend: constrained CAPE Agent execpy"
    return 0
  fi
  WINDOWS_BACKEND_USED=""
  fail "No supported zero-touch Windows control channel is available for $CAPE_MACHINE_SECTION/$DOMAIN (QGA, approved WinRM, or CAPE Agent execpy/admin required)"
  return 40
}

windows_configure_selected_backend() {
  case "$WINDOWS_BACKEND_USED" in
    qemu-guest-agent)
      windows_configure_via_qga "$CAPE_MACHINE_IP" "$WINDOWS_ISOLATED_MAC" "$WINDOWS_FAKE_IP" 24 "$INETSIM_IP" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT" "$CONTROL_HOST_IP"
      ;;
    winrm)
      windows_configure_via_winrm "$CAPE_MACHINE_IP" "$WINDOWS_ISOLATED_MAC" "$WINDOWS_FAKE_IP" 24 "$INETSIM_IP" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT" "$CONTROL_HOST_IP"
      ;;
    cape-agent-execpy)
      windows_configure_via_cape_agent "$CAPE_MACHINE_IP" "$WINDOWS_ISOLATED_MAC" "$WINDOWS_FAKE_IP" 24 "$INETSIM_IP" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT" "$CONTROL_HOST_IP"
      ;;
    manual-powershell)
      windows_configure_via_manual_callback
      ;;
    *)
      fail "Unknown Windows configuration backend: ${WINDOWS_BACKEND_USED:-none}"
      return 40
      ;;
  esac
}

windows_verify_selected_backend() {
  case "$WINDOWS_BACKEND_USED" in
    qemu-guest-agent)
      windows_verify_via_qga "$CAPE_MACHINE_IP" "$WINDOWS_ISOLATED_MAC" "$WINDOWS_FAKE_IP" "$INETSIM_IP" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT"
      ;;
    winrm)
      windows_verify_via_winrm "$CAPE_MACHINE_IP" "$WINDOWS_ISOLATED_MAC" "$WINDOWS_FAKE_IP" "$INETSIM_IP" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT"
      ;;
    cape-agent-execpy)
      windows_verify_via_cape_agent "$CAPE_MACHINE_IP" "$WINDOWS_ISOLATED_MAC" "$WINDOWS_FAKE_IP" "$INETSIM_IP" "$CAPE_RESULTSERVER_IP" "$CAPE_RESULTSERVER_PORT"
      ;;
    manual-powershell)
      validate_windows_result_file
      ;;
    *)
      fail "Cannot verify Windows safety with backend: ${WINDOWS_BACKEND_USED:-none}"
      return 40
      ;;
  esac
  pass "Windows safety gates passed: fake IP/DNS, no default route, ResultServer reachable, public IP unreachable"
}

windows_poweroff_selected_backend() {
  case "$WINDOWS_BACKEND_USED" in
    qemu-guest-agent) windows_poweroff_via_qga ;;
    winrm) windows_poweroff_via_winrm "$CAPE_MACHINE_IP" ;;
    cape-agent-execpy|manual-powershell) virsh shutdown "$DOMAIN" >/dev/null 2>&1 || true ;;
    *) fail "Unknown Windows poweroff backend: ${WINDOWS_BACKEND_USED:-none}"; return 40 ;;
  esac
  windows_wait_for_domain_state "shut off" 120
}

windows_manual_callback_command() {
  local base_url="$1" token="$2"
  local result_path='C:\Windows\Temp\cape-inetsim-autodeploy-result.json'
  # Single-line command: fetch the exact deployment script from the temporary
  # CAPE-host callback, run it elevated in the already-open Administrator
  # PowerShell, then POST its signed-token result back to the waiting installer.
  printf '%s\n' "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"\$ErrorActionPreference='Stop';\$u='$base_url';\$t='$token';\$p='C:\\Windows\\Temp\\cape-inetsim-autodeploy.ps1';Invoke-WebRequest -UseBasicParsing -Uri (\$u+'/script?token='+\$t) -OutFile \$p;& \$p -ManagementIP '$CAPE_MACHINE_IP' -IsolatedMac '$WINDOWS_ISOLATED_MAC' -FakeIP '$WINDOWS_FAKE_IP' -PrefixLength 24 -DnsIP '$INETSIM_IP' -ResultServerIP '$CAPE_RESULTSERVER_IP' -ResultServerPort $CAPE_RESULTSERVER_PORT -ControlHostIP '$CONTROL_HOST_IP' -ResultPath '$result_path';\$b=Get-Content -Raw '$result_path';Invoke-WebRequest -UseBasicParsing -Uri (\$u+'/result?token='+\$t) -Method Post -ContentType 'application/json' -Body \$b | Out-Null;Remove-Item -Force \$p -ErrorAction SilentlyContinue\""
}

windows_configure_via_manual_callback() {
  local bind_ip="${CONTROL_HOST_IP:-$CAPE_RESULTSERVER_IP}"
  local token ready result server_log port base_url command server_pid rc
  [[ -n "$bind_ip" ]] || { fail "Cannot create Windows fallback callback without a CAPE-host control IP"; return 40; }
  token="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  ready="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-callback.ready"
  result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-verify.json"
  server_log="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-callback.log"
  rm -f "$ready" "$result"

  python3 "$AUTODEPLOY_ROOT/tools/windows_callback.py"     --bind "$bind_ip" --client "$CAPE_MACHINE_IP" --port 0 --token "$token"     --script "$AUTODEPLOY_ROOT/windows/configure-inetsim.ps1"     --result "$result" --ready "$ready" --timeout "${WINDOWS_FALLBACK_TIMEOUT:-900}"     >"$server_log" 2>&1 &
  server_pid=$!

  local i
  for ((i=0;i<50;i++)); do
    [[ -s "$ready" ]] && break
    kill -0 "$server_pid" 2>/dev/null || { fail "Windows fallback callback server failed to start"; wait "$server_pid" || true; return 40; }
    sleep 0.1
  done
  [[ -s "$ready" ]] || { kill "$server_pid" 2>/dev/null || true; fail "Windows fallback callback server did not become ready"; return 40; }

  port="$(tr -d '\r\n' <"$ready")"
  [[ "$port" =~ ^[0-9]+$ ]] || { kill "$server_pid" 2>/dev/null || true; return 40; }
  base_url="http://$bind_ip:$port"
  command="$(windows_manual_callback_command "$base_url" "$token")"
  printf '%s\n' "$command" >"$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-fallback-command.txt"
  chmod 0600 "$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-fallback-command.txt"

  echo
  echo "================================================================"
  echo "ONE WINDOWS COMMAND REQUIRED"
  echo "================================================================"
  echo "No QEMU Guest Agent or approved credentialed WinRM channel was available."
  echo "Run the following ONE command in Administrator PowerShell in the selected"
  echo "Windows analysis VM. The Linux installer is waiting and will continue"
  echo "automatically after the signed validation result returns."
  echo
  echo "$command"
  echo
  echo "Timeout: ${WINDOWS_FALLBACK_TIMEOUT:-900} seconds"
  echo "================================================================"

  set +e
  wait "$server_pid"
  rc=$?
  set -e
  rm -f "$ready"
  [[ "$rc" -eq 0 && -s "$result" ]] || { fail "Windows fallback command did not return a valid result before timeout"; return 40; }

  validate_windows_result_file
  WINDOWS_BACKEND_USED=manual-powershell
  state_record_resource windows-config "$DOMAIN" configured-via-manual-powershell yes "isolated_mac=$WINDOWS_ISOLATED_MAC fake_ip=$WINDOWS_FAKE_IP"
  state_write_atomic
  pass "Windows manual fallback completed and returned its safety result"
}
