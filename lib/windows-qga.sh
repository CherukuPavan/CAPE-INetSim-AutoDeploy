#!/usr/bin/env bash

windows_qga_powershell_path='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

windows_configure_via_qga() {
  local guest_ip="$1" isolated_mac="$2" fake_ip="$3" prefix="$4" dns_ip="$5" result_ip="$6" result_port="$7" control_host_ip="$8"
  local ps1="$AUTODEPLOY_ROOT/windows/configure-inetsim.ps1"
  local remote_ps='C:\Windows\Temp\cape-inetsim-autodeploy.ps1'
  local remote_result='C:\Windows\Temp\cape-inetsim-autodeploy-result.json'
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-windows-result.json"

  qga_wait "$DOMAIN" 120 || { fail "Windows QEMU Guest Agent did not answer"; return 1; }
  qga_file_write "$DOMAIN" "$ps1" "$remote_ps"
  qga_exec_wait "$DOMAIN" "$windows_qga_powershell_path"     -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$remote_ps"     -ManagementIP "$guest_ip" -IsolatedMac "$isolated_mac" -FakeIP "$fake_ip"     -PrefixLength "$prefix" -DnsIP "$dns_ip" -ResultServerIP "$result_ip"     -ResultServerPort "$result_port" -ControlHostIP "$control_host_ip" -ResultPath "$remote_result"
  qga_file_read "$DOMAIN" "$remote_result" "$local_result"

  ad_python - "$local_result" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8-sig") as f: d=json.load(f)
if not d.get("ok"):
    print(json.dumps(d,indent=2),file=sys.stderr)
    raise SystemExit(1)
PY
  qga_exec_wait "$DOMAIN" "$windows_qga_powershell_path" -NoProfile -NonInteractive -Command     "Remove-Item -LiteralPath '$remote_ps','$remote_result' -Force -ErrorAction SilentlyContinue" >/dev/null || true
  WINDOWS_BACKEND_USED=qemu-guest-agent
  state_record_resource windows-config "$DOMAIN" configured-via-qga yes "isolated_mac=$isolated_mac fake_ip=$fake_ip"
  state_write_atomic
}

windows_verify_via_qga() {
  local guest_ip="$1" isolated_mac="$2" fake_ip="$3" dns_ip="$4" result_ip="$5" result_port="$6"
  local ps1="$AUTODEPLOY_ROOT/windows/verify-inetsim.ps1"
  local remote_ps='C:\Windows\Temp\cape-inetsim-autodeploy-verify.ps1'
  local remote_result='C:\Windows\Temp\cape-inetsim-autodeploy-verify-result.json'
  local local_result="$AD_LOG_ROOT/${DEPLOYMENT_ID}-windows-verify.json"
  qga_file_write "$DOMAIN" "$ps1" "$remote_ps"
  qga_exec_wait "$DOMAIN" "$windows_qga_powershell_path" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$remote_ps"     -ManagementIP "$guest_ip" -IsolatedMac "$isolated_mac" -FakeIP "$fake_ip" -DnsIP "$dns_ip"     -ResultServerIP "$result_ip" -ResultServerPort "$result_port" -ResultPath "$remote_result"
  qga_file_read "$DOMAIN" "$remote_result" "$local_result"
  ad_python - "$local_result" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8-sig") as f: d=json.load(f)
if not d.get("ok"): raise SystemExit(json.dumps(d))
PY
}

windows_poweroff_via_qga() {
  qga_exec_wait "$DOMAIN" 'C:\Windows\System32\shutdown.exe' /s /t 0 /f >/dev/null 2>&1 || true
}
