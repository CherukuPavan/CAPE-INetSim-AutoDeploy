#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/cape-configure.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/sniffer.py" <<'PY'
import logging
log=logging.getLogger(__name__)
class X:
    def f(self):
        host = self.machine.ip
        # Selects per-machine interface if available.
        interface = self.machine.interface or self.options.get("interface")
PY
patch_sniffer_capture_override "$TMP/sniffer.py"
grep -q 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1' "$TMP/sniffer.py"
grep -q 'capture_host_key = f"capture_host_{self.machine.label}"' "$TMP/sniffer.py"
patch_sniffer_capture_override "$TMP/sniffer.py"
[[ "$(grep -c CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1 "$TMP/sniffer.py")" -eq 1 ]]
echo '[PASS] exact-match CAPE sniffer patch logic'
