#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/cape/web/analysis" "$TMP/cape/storage/analyses/20/reports" "$TMP/cape/storage/analyses/19/reports"
cat >"$TMP/cape/web/analysis/inetsim_vm_logic.py" <<'PY'
def network_uses_inetsim(network, server_ip):
    for proto in ("tcp","udp"):
        for row in network.get(proto) or []:
            if str(row.get("dst","")) == server_ip:
                return True
    for row in network.get("dns") or []:
        for ans in row.get("answers") or []:
            if str(ans.get("data","")) == server_ip:
                return True
    return False

def build_inetsim_route_context(network, server_ip):
    enabled=network_uses_inetsim(network,server_ip)
    return {
        "enabled":enabled,
        "summary":{"total":1 if enabled else 0},
        "attribution_summary":{"task_domains":["marker.test"] if enabled else []},
    }
# CAPE_INETSIM_VM_ROUTE_GATED_V2
PY

cat >"$TMP/cape/storage/analyses/20/reports/report.json" <<'JSON'
{
  "info":{"id":20,"route":"inetsim"},
  "network":{
    "tcp":[{"src":"192.168.122.100","dst":"10.77.50.2","dport":80}],
    "dns":[{"request":"cape-inetsim-accept-123.invalid","answers":[{"data":"10.77.50.2"}]}],
    "http":[{"dst":"10.77.50.2","host":"cape-inetsim-accept-123.invalid","uri":"http://cape-inetsim-accept-123.invalid/"}]
  }
}
JSON

cat >"$TMP/cape/storage/analyses/19/reports/report.json" <<'JSON'
{
  "info":{"id":19,"route":"internet"},
  "network":{
    "tcp":[{"src":"192.168.122.100","dst":"8.8.8.8","dport":443}],
    "dns":[{"request":"example.com","answers":[{"data":"93.184.216.34"}]}]
  }
}
JSON

printf '10.77.50.2 cape-inetsim-accept-123.invalid\n' >"$TMP/cape/storage/analyses/20/dump.pcap"
printf '8.8.8.8 internet-only\n' >"$TMP/cape/storage/analyses/19/dump.pcap"

python3 "$ROOT/tools/acceptance_reports.py" \
  --cape-root "$TMP/cape" --inetsim-ip 10.77.50.2 \
  --positive-task 20 --negative-task 19 \
  --marker cape-inetsim-accept-123.invalid --output "$TMP/result.json"

python3 - "$TMP/result.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="pass"
assert d["mode"]=="route-separation-marker-pair"
assert d["positive"]["route"]=="inetsim"
assert d["positive"]["uses_inetsim"] is True
assert d["positive"]["marker_present"] is True
assert d["negative"]["route"]=="internet"
assert d["negative"]["uses_inetsim"] is False
assert d["negative"]["context_enabled"] is False
assert d["negative"]["marker_present"] is False
assert d["background_inetsim_allowed_in_negative"] is False
PY

if python3 "$ROOT/tools/acceptance_reports.py" \
  --cape-root "$TMP/cape" --inetsim-ip 10.77.50.2 \
  --positive-task 19 --negative-task 20 \
  --marker cape-inetsim-accept-123.invalid --output "$TMP/bad.json" >/dev/null 2>&1; then
  echo "route-separation acceptance accepted swapped controls" >&2
  exit 1
fi

RUNTIME="$TMP/runtime"
mkdir -p "$RUNTIME"/{bin,lib,tools} "$TMP/fakebin" "$TMP/logs"
cp "$ROOT/bin/cape-inetsim-acceptance" "$RUNTIME/bin/"
cp "$ROOT/tools/acceptance_reports.py" "$RUNTIME/tools/"
cp "$ROOT/lib/common.sh" "$RUNTIME/lib/common.sh"
: >"$RUNTIME/lib/targets.sh"

cat >"$RUNTIME/lib/state.sh" <<SH
state_load(){
  DEPLOYMENT_PHASE=committed
  CAPE_ROOT="$TMP/cape"
  INETSIM_IP="10.77.50.2"
  AD_LOG_ROOT="$TMP/logs"
  DEPLOYMENT_ID="acceptance-shell-test"
  RELEASE_TAG=""
  RELEASE_SOURCE_COMMIT=""
  RELEASE_SOURCE_SHA256=""
  return 0
}
SH

cat >"$RUNTIME/bin/cape-inetsim-verify" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '[PASS] stub deployment verification passed\n'
SH
chmod +x "$RUNTIME/bin/cape-inetsim-verify" "$RUNTIME/bin/cape-inetsim-acceptance"

cat >"$TMP/fakebin/tcpdump" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
pcap=""
filter=""
while (($#)); do
  if [[ "$1" == "-r" ]]; then pcap="$2"; shift 2; continue; fi
  filter+=" $1"
  shift
done
[[ -n "$pcap" && -s "$pcap" ]] || exit 1
if [[ "$filter" == *"host 10.77.50.2"* ]]; then
  grep -F '10.77.50.2' "$pcap"
else
  cat "$pcap"
fi
SH
chmod +x "$TMP/fakebin/tcpdump"

sudo env PATH="$TMP/fakebin:$PATH" AUTODEPLOY_ROOT="$RUNTIME" \
  bash "$RUNTIME/bin/cape-inetsim-acceptance" \
    --positive-task 20 --negative-task 19 \
    --marker cape-inetsim-accept-123.invalid \
    --output "$TMP/shell-acceptance.json"

python3 - "$TMP/shell-acceptance.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="pass"
assert d["pcap_validation"]["positive_contains_marker"] is True
assert d["pcap_validation"]["negative_contains_marker"] is False
assert d["pcap_validation"]["positive_contains_inetsim_ip"] is True
assert d["pcap_validation"]["negative_contains_inetsim_ip"] is False
PY

echo '[PASS] acceptance proves route=inetsim marker traffic and clean route=internet separation'
