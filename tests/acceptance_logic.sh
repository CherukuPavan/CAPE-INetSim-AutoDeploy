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
  "info":{"id":20,"route":"none"},
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
  "info":{"id":19,"route":"none"},
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
# accept the controlled marker when the task is route=none and has INetSim
# context; the shell acceptance layer then proves the linkage from a PCAP
# filtered to the INetSim host.
mkdir -p "$TMP/cape/storage/analyses/18/reports"
cat >"$TMP/cape/storage/analyses/18/reports/report.json" <<'JSON'
{
  "info":{"id":18,"route":"none"},
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
printf 'pcap-marker-linkage-is-validated-by-shell-layer\n' >"$TMP/cape/storage/analyses/18/dump.pcap"
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
PY

grep -Fq -- '--marker)' "$ROOT/install"
grep -Fq 'ACCEPT_MARKER' "$ROOT/install"
grep -Fq 'background traffic to INetSim is allowed' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'pcap_has_marker' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'awk -v marker="$MARKER"' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq '"marker_reached_inetsim":bool(inetsim_evidence)' "$ROOT/tools/acceptance_reports.py"
grep -Fq 'packet capture must prove marker-to-INetSim linkage' "$ROOT/tools/acceptance_reports.py"
grep -Fq 'Positive PCAP proved marker-to-INetSim linkage' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'negative_contains_marker' "$ROOT/bin/cape-inetsim-acceptance"
grep -Fq 'background_inetsim_allowed_in_negative' "$ROOT/bin/cape-inetsim-acceptance"

echo '[PASS] marker-based acceptance tolerates CAPE field-shape loss and delegates marker linkage proof to INetSim-filtered PCAP evidence'
