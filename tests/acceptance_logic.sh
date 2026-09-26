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
        "attribution_summary":{"task_domains":["background.test"] if enabled else []},
    }
PY

cat >"$TMP/cape/storage/analyses/20/reports/report.json" <<'JSON'
{
  "info":{"id":20,"route":"inetsim"},
  "network":{
    "tcp":[{"src":"10.77.50.10","dst":"10.77.50.2","dport":80}],
    "dns":[
      {"request":"background.test","answers":[{"data":"10.77.50.2"}]},
      {"request":"cape-inetsim-accept-123.invalid","answers":[{"data":"10.77.50.2"}]}
    ],
    "http":[{"dst":"10.77.50.2","host":"cape-inetsim-accept-123.invalid","uri":"http://cape-inetsim-accept-123.invalid/"}]
  }
}
JSON

cat >"$TMP/negative.json" <<'JSON'
{
  "info":{"id":19,"route":"inetsim"},
  "network":{
    "tcp":[{"src":"10.77.50.10","dst":"10.77.50.2","dport":443}],
    "dns":[{"request":"background.test","answers":[{"data":"10.77.50.2"}]}]
  }
}
JSON
gzip -c "$TMP/negative.json" >"$TMP/cape/storage/analyses/19/reports/report.json.gz"
printf 'pcap-positive-placeholder\n' >"$TMP/cape/storage/analyses/20/dump.pcap"
printf 'pcap-negative-placeholder\n' >"$TMP/cape/storage/analyses/19/dump.pcap"

python3 "$ROOT/tools/acceptance_reports.py"   --cape-root "$TMP/cape"   --inetsim-ip 10.77.50.2   --positive-task 20   --negative-task 19   --marker cape-inetsim-accept-123.invalid   --output "$TMP/result.json"

python3 - "$TMP/result.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["schema"]==2
assert d["status"]=="pass"
assert d["mode"]=="marker-pair"
assert d["positive"]["task_id"]==20
assert d["positive"]["uses_inetsim"] is True
assert d["positive"]["marker_present"] is True
assert d["positive"]["marker_reached_inetsim"] is True
assert d["positive"]["marker_inetsim_evidence"]
assert d["negative"]["task_id"]==19
assert d["negative"]["uses_inetsim"] is True
assert d["negative"]["context_enabled"] is True
assert d["negative"]["marker_present"] is False
assert d["background_inetsim_allowed_in_negative"] is True
PY

if python3 "$ROOT/tools/acceptance_reports.py"   --cape-root "$TMP/cape" --inetsim-ip 10.77.50.2   --positive-task 19 --negative-task 20   --marker cape-inetsim-accept-123.invalid   --output "$TMP/bad.json" >/dev/null 2>&1; then
  echo "marker acceptance accepted swapped positive/negative controls" >&2
  exit 1
fi

# Regression: CAPE reports do not always preserve enough destination/answer
# fields to prove marker-to-INetSim linkage. The report layer should still
# accept the controlled marker when the task is route=inetsim and has INetSim
# context; the shell acceptance layer then proves the linkage from a PCAP
# filtered to the INetSim host.
mkdir -p "$TMP/cape/storage/analyses/18/reports"
cat >"$TMP/cape/storage/analyses/18/reports/report.json" <<'JSON'
{
  "info":{"id":18,"route":"inetsim"},
  "network":{
    "tcp":[{"src":"10.77.50.10","dst":"10.77.50.2","dport":443}],
    "dns":[
      {"request":"background.test","answers":[{"data":"10.77.50.2"}]},
      {"request":"cape-inetsim-accept-123.invalid","answers":[]}
    ],
    "http":[
      {"host":"cape-inetsim-accept-123.invalid","uri":"http://cape-inetsim-accept-123.invalid/"}
    ]
  }
}
JSON
: >"$TMP/cape/storage/analyses/18/dump.pcap"
printf 'pcap-marker-linkage-is-validated-by-shell-layer\n' >"$TMP/cape/storage/analyses/18/dump_sorted.pcap"
python3 "$ROOT/tools/acceptance_reports.py" \
  --cape-root "$TMP/cape" --inetsim-ip 10.77.50.2 \
  --positive-task 18 --negative-task 19 \
  --marker cape-inetsim-accept-123.invalid \
  --output "$TMP/field-shape.json"

python3 - "$TMP/field-shape.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="pass"
assert d["positive"]["marker_present"] is True
assert d["positive"]["uses_inetsim"] is True
assert d["positive"]["marker_reached_inetsim"] is False
assert d["positive"]["capture_path"].endswith("/dump_sorted.pcap")
PY

grep -Fq -- '--marker)' "$ROOT/install"
grep -Fq 'ACCEPT_MARKER' "$ROOT/install"
grep -Fq 'background traffic to INetSim is allowed' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'pcap_has_marker' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'acceptance_capture_path()' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq '[[ -s "$POS_PCAP" ]]' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq '[[ -s "$NEG_PCAP" ]]' "$ROOT/bin/cape-inetsim-acceptance"
if grep -Fq 'local task="$1" base=' "$ROOT/bin/cape-inetsim-acceptance"; then
  echo "acceptance helper reintroduced nounset-unsafe dependent local assignment" >&2
  exit 1
fi
grep -Fq 'awk -v marker="$MARKER"' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq '"marker_reached_inetsim":bool(inetsim_evidence)' "$ROOT/tools/acceptance_reports.py"
grep -Fq 'packet capture must prove marker-to-INetSim linkage' "$ROOT/tools/acceptance_reports.py"
grep -Fq 'Positive PCAP proved marker-to-INetSim linkage' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'negative_contains_marker' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'background_inetsim_allowed_in_negative' "$ROOT/bin/cape-inetsim-acceptance"

# Execute the real shell acceptance helper with a fully controlled stub
# runtime. This catches set -u / shell-integration regressions that static
# report tests cannot detect.
RUNTIME="$TMP/runtime"
mkdir -p "$RUNTIME"/{bin,lib,tools} "$TMP/fakebin" "$TMP/logs"
cp "$ROOT/bin/cape-inetsim-acceptance" "$RUNTIME/bin/"
cp "$ROOT/tools/acceptance_reports.py" "$RUNTIME/tools/"

cat >"$RUNTIME/lib/common.sh" <<'SH'
require_root(){ :; }
fail(){ printf '[FAIL] %s\n' "$*" >&2; }
pass(){ printf '[PASS] %s\n' "$*"; }
kv(){ printf '%s %s\n' "$1" "$2"; }
have(){ command -v "$1" >/dev/null 2>&1; }
SH
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
while (($#)); do
  if [[ "$1" == "-r" ]]; then
    pcap="$2"
    shift 2
    continue
  fi
  shift
done
[[ -n "$pcap" && -s "$pcap" ]] || exit 1
cat "$pcap"
SH
chmod +x "$TMP/fakebin/tcpdump"

printf '\n# CAPE_INETSIM_VM_ROUTE_NONE_V1\n' >>"$TMP/cape/web/analysis/inetsim_vm_logic.py"
printf 'cape-inetsim-accept-123.invalid\n' >"$TMP/cape/storage/analyses/20/dump.pcap"
printf 'background-only\n' >"$TMP/cape/storage/analyses/19/dump.pcap"

PATH="$TMP/fakebin:$PATH" AUTODEPLOY_ROOT="$RUNTIME" \
  bash "$RUNTIME/bin/cape-inetsim-acceptance" \
    --positive-task 20 \
    --negative-task 19 \
    --marker cape-inetsim-accept-123.invalid \
    --output "$TMP/shell-acceptance.json"

python3 - "$TMP/shell-acceptance.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["status"]=="pass"
assert d["pcap_validation"]["positive_contains_marker"] is True
assert d["pcap_validation"]["negative_contains_marker"] is False
assert d["pcap_validation"]["positive_contains_inetsim_ip"] is True
PY

echo '[PASS] marker-based acceptance tolerates CAPE field-shape loss and delegates marker linkage proof to INetSim-filtered PCAP evidence'
