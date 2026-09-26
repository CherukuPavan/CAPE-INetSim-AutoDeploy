#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME=(
  "$ROOT/install"
  "$ROOT/release/bootstrap-template.sh"
  "$ROOT/lib"
  "$ROOT/bin"
  "$ROOT/tools"
  "$ROOT/windows"
  "$ROOT/appliance/guest-configure.sh"
)

fail_if(){
  local pattern="$1" label="$2"
  if grep -RInE --binary-files=without-match "$pattern" "${RUNTIME[@]}" 2>/dev/null; then
    echo "[FAIL] production runtime contains forbidden machine-specific assumption: $label" >&2
    exit 1
  fi
}

fail_if '/opt/CAPEv2([/"[:space:]]|$)' 'fixed CAPE path /opt/CAPEv2'
fail_if '/home/cape([/"[:space:]]|$)' 'fixed CAPE home /home/cape'
fail_if '(^|[^[:alnum:]_])virbr0([^[:alnum:]_]|$)' 'fixed management bridge virbr0'
fail_if '(^|[^[:alnum:]_])capeisim0([^[:alnum:]_]|$)' 'fixed isolated bridge capeisim0'
fail_if '(^|[^0-9])192\.168\.200\.2([^0-9]|$)' 'fixed INetSim IP'
fail_if '(^|[^[:alnum:]_])win10([^[:alnum:]_]|$)' 'fixed analysis VM name'
fail_if '/usr/bin/python3|/usr/local/bin/python3' 'fixed host Python path'
fail_if 'systemctl[[:space:]].*cape(-rooter|-processor|-web)?\.service' 'fixed CAPE systemd unit in operational path'

grep -Fq 'ad_select_host_python' "$ROOT/lib/common.sh"
grep -Fq 'cape_all_systemd_units' "$ROOT/lib/cape.sh"
grep -Fq 'CAPE_SCHEDULER_SERVICE' "$ROOT/lib/services.sh"
grep -Fq 'CAPE_ROOTER_SERVICE' "$ROOT/lib/services.sh"
grep -Fq 'services_rooter_socket_probe' "$ROOT/lib/services.sh"

echo "[PASS] production runtime contains no forbidden host/path/VM/network/service assumptions"
