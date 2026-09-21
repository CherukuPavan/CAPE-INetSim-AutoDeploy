#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/cape/web/analysis" "$TMP/cape/storage/analyses/20/reports" "$TMP/cape/storage/analyses/19/reports"
cat >"$TMP/cape/web/analysis/inetsim_vm_logic.py" <<'PY'
def network_uses_inetsim(network, server_ip):
    for row in network.get("tcp") or []:
        if str(row.get("dst","")) == server_ip:
            return True
    for row in network.get("udp") or []:
        if str(row.get("dst","")) == server_ip:
            return True
    for row in network.get("dns") or []:
        for ans in row.get("answers") or []:
            if str(ans.get("data","")) == server_ip:
                return True
    return False

def build_route_none_inetsim_context(network, server_ip):
    enabled=network_uses_inetsim(network,server_ip)
    return {
        "enabled":enabled,
        "summary":{"total":1 if enabled else 0},
        "attribution_summary":{"task_domains":["probe.test"] if enabled else []},
    }
PY

cat >"$TMP/cape/storage/analyses/20/reports/report.json" <<'JSON'
{
  "info":{"id":20,"route":"none"},
  "network":{"tcp":[{"src":"10.77.50.10","dst":"10.77.50.2","dport":443}]}
}
JSON
cat >"$TMP/negative.json" <<'JSON'
{
  "info":{"id":19,"route":"none"},
  "network":{"tcp":[{"src":"10.77.50.10","dst":"203.0.113.9","dport":80}]}
}
JSON
gzip -c "$TMP/negative.json" >"$TMP/cape/storage/analyses/19/reports/report.json.gz"
printf 'pcap-positive-placeholder\n' >"$TMP/cape/storage/analyses/20/dump.pcap"
printf 'pcap-negative-placeholder\n' >"$TMP/cape/storage/analyses/19/dump.pcap"

python3 "$ROOT/tools/acceptance_reports.py" \
  --cape-root "$TMP/cape" --inetsim-ip 10.77.50.2 --output "$TMP/result.json"

python3 - "$TMP/result.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="pass"
assert d["positive"]["task_id"]==20
assert d["positive"]["uses_inetsim"] is True
assert d["positive"]["context_enabled"] is True
assert d["positive"]["capture_path"].endswith("/20/dump.pcap")
assert d["negative"]["task_id"]==19
assert d["negative"]["uses_inetsim"] is False
assert d["negative"]["context_enabled"] is False
assert d["negative"]["capture_path"].endswith("/19/dump.pcap")
PY

if python3 "$ROOT/tools/acceptance_reports.py" \
  --cape-root "$TMP/cape" --inetsim-ip 10.77.50.2 \
  --positive-task 19 --negative-task 20 --output "$TMP/bad.json" >/dev/null 2>&1; then
  echo "acceptance classifier accepted swapped positive/negative controls" >&2
  exit 1
fi

grep -Fq -- '--acceptance) MODE=acceptance' "$ROOT/install"
grep -Fq 'bin/cape-inetsim-acceptance' "$ROOT/install"
grep -Fq 'tcpdump -nn -r "$POS_PCAP"' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'tcpdump -nn -r "$NEG_PCAP"' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'release_validation' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'recovery_assets' "$ROOT/bin/cape-inetsim-acceptance"

echo '[PASS] real-report positive/negative functional acceptance logic'
