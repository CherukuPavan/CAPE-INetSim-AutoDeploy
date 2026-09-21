#!/usr/bin/env bash

windows_winrm_password() {
  if [[ -n "${CAPE_INETSIM_WINRM_PASSWORD_FILE:-}" ]]; then
    [[ -f "$CAPE_INETSIM_WINRM_PASSWORD_FILE" && ! -L "$CAPE_INETSIM_WINRM_PASSWORD_FILE" ]] || return 1
    if [[ "$(id -u)" -eq 0 ]]; then
      local uid mode perm
      uid="$(stat -c '%u' "$CAPE_INETSIM_WINRM_PASSWORD_FILE" 2>/dev/null || echo -1)"
      mode="$(stat -c '%a' "$CAPE_INETSIM_WINRM_PASSWORD_FILE" 2>/dev/null || echo 777)"
      [[ "$uid" -eq 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
      perm=$((8#$mode))
      (( (perm & 0077) == 0 )) || return 1
    fi
    cat "$CAPE_INETSIM_WINRM_PASSWORD_FILE"
    return 0
  fi
  [[ -n "${CAPE_INETSIM_WINRM_PASSWORD:-}" ]] || return 1
  printf '%s' "$CAPE_INETSIM_WINRM_PASSWORD"
}

windows_winrm_port() {
  local ip="$1"
  # Prefer WinRM over HTTPS when both listeners are available. Plain HTTP is
  # retained only as a fallback for existing lab guests using NTLM transport.
  if probe_tcp "$ip" 5986; then printf '5986\n'; return 0; fi
  if probe_tcp "$ip" 5985; then printf '5985\n'; return 0; fi
  return 1
}

windows_winrm_client_available() {
  python3 -c 'import winrm' >/dev/null 2>&1
}

windows_winrm_ready() {
  local ip="$1" port password validation="${CAPE_INETSIM_WINRM_CERT_VALIDATION:-validate}"
  [[ -n "${CAPE_INETSIM_WINRM_USERNAME:-}" ]] || return 1
  windows_winrm_client_available || return 1
  port="$(windows_winrm_port "$ip" 2>/dev/null)" || return 1
  password="$(windows_winrm_password)" || return 1
  [[ -n "$password" ]] || return 1

  printf '%s' "$password" | python3 -c '
import sys
try:
    import winrm
except Exception:
    raise SystemExit(1)
host,port,user,validation=sys.argv[1:]
scheme="https" if port=="5986" else "http"
try:
    s=winrm.Session(f"{scheme}://{host}:{port}/wsman",auth=(user,sys.stdin.read()),transport="ntlm",server_cert_validation=validation)
    r=s.run_ps("[bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)")
except Exception:
    raise SystemExit(1)
if r.status_code != 0 or r.std_out.decode(errors="replace").strip().lower() != "true":
    raise SystemExit(1)
' "$ip" "$port" "$CAPE_INETSIM_WINRM_USERNAME" "$validation"
}

windows_winrm_run_script() {
  local ip="$1" script="$2" result_path="$3"
  shift 3
  local port password validation="${CAPE_INETSIM_WINRM_CERT_VALIDATION:-validate}"
  port="$(windows_winrm_port "$ip")" || { fail "WinRM port is no longer reachable"; return 1; }
  password="$(windows_winrm_password)" || { fail "WinRM credentials are unavailable"; return 1; }
  printf '%s' "$password" | python3 "$AUTODEPLOY_ROOT/tools/winrm_exec.py"     --host "$ip" --port "$port" --username "$CAPE_INETSIM_WINRM_USERNAME"     --script "$script" --result-path "$result_path" --cert-validation "$validation" -- "$@"
}

windows_configure_via_winrm() {
  local guest_ip="$1" isolated_mac="$2" fake_ip="$3" prefix="$4" dns_ip="$5" result_ip="$6" result_port="$7" control_host_ip="$8"
  local remote_result='C:\Windows\Temp\cape-inetsim-autodeploy-result.json'
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-result.json"
  windows_winrm_run_script "$guest_ip" "$AUTODEPLOY_ROOT/windows/configure-inetsim.ps1" "$remote_result"     -ManagementIP "$guest_ip" -IsolatedMac "$isolated_mac" -FakeIP "$fake_ip"     -PrefixLength "$prefix" -DnsIP "$dns_ip" -ResultServerIP "$result_ip"     -ResultServerPort "$result_port" -ControlHostIP "$control_host_ip" -ResultPath "$remote_result"     >"$local_result"
  validate_windows_result_path "$local_result"
  WINDOWS_BACKEND_USED=winrm
  state_record_resource windows-config "$DOMAIN" configured-via-winrm yes "isolated_mac=$isolated_mac fake_ip=$fake_ip"
  state_write_atomic
}

windows_verify_via_winrm() {
  local guest_ip="$1" isolated_mac="$2" fake_ip="$3" dns_ip="$4" result_ip="$5" result_port="$6"
  local remote_result='C:\Windows\Temp\cape-inetsim-autodeploy-verify-result.json'
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-$(ad_safe_token "$DOMAIN")-windows-verify.json"
  windows_winrm_run_script "$guest_ip" "$AUTODEPLOY_ROOT/windows/verify-inetsim.ps1" "$remote_result"     -ManagementIP "$guest_ip" -IsolatedMac "$isolated_mac" -FakeIP "$fake_ip"     -DnsIP "$dns_ip" -ResultServerIP "$result_ip" -ResultServerPort "$result_port" -ResultPath "$remote_result"     >"$local_result"
  validate_windows_result_path "$local_result"
}

windows_poweroff_via_winrm() {
  local ip="$1" port password validation="${CAPE_INETSIM_WINRM_CERT_VALIDATION:-validate}"
  port="$(windows_winrm_port "$ip" 2>/dev/null)" || return 0
  password="$(windows_winrm_password)" || return 0
  printf '%s' "$password" | python3 -c '
import sys
try:
    import winrm
    host,port,user,validation=sys.argv[1:]
    scheme="https" if port=="5986" else "http"
    s=winrm.Session(f"{scheme}://{host}:{port}/wsman",auth=(user,sys.stdin.read()),transport="ntlm",server_cert_validation=validation)
    s.run_cmd("shutdown.exe",["/s","/t","0","/f"])
except Exception:
    pass
' "$ip" "$port" "$CAPE_INETSIM_WINRM_USERNAME" "$validation" || true
}
