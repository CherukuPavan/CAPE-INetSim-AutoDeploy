#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

grep -Fq 'Fake Internet — dedicated Ubuntu INetSim appliance' "$ROOT/tools/patch_cape_runtime.py"
grep -Fq 'No network — strictly blocked (analysis egress)' "$ROOT/tools/patch_cape_runtime.py"
grep -Fq 'autodeploy_route_policy_set' "$ROOT/tools/patch_cape_runtime.py"
grep -Fq 'CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V2' "$ROOT/tools/patch_cape_runtime.py"

# Build a minimal CAPEv2-compatible fixture from the exact patch anchors and
# exercise the same patcher twice. The second pass proves marker/idempotency
# protection without modifying a real CAPE tree.
mkdir -p "$TMP/cape/lib/cuckoo/core" "$TMP/cape/utils" "$TMP/cape/modules/processing" "$TMP/cape/web/templates/submission"
cat >"$TMP/cape/utils/rooter.py" <<'PY'
class ServicePaths:
    iptables = "/sbin/iptables"

def drop_enable(ipaddr, resultserver_port):
    pass

def drop_disable(ipaddr, resultserver_port):
    pass

handlers = {
}
PY

cat >"$TMP/cape/lib/cuckoo/core/analysis_manager.py" <<'PY'
    def route_network(self):
        routing = Config("routing")
        self.route = routing.routing.route

        if self.task.route:
            self.route = self.task.route

        if self.route in ("none", "None", "drop", "false"):
            self.interface = None
            self.rt_table = None
        elif self.route == "inetsim":
            self.interface = routing.inetsim.interface

        if self.route == "inetsim":
            self.rooter_response = rooter(
                "inetsim_enable",
                self.machine.ip,
                str(routing.inetsim.server),
                str(routing.inetsim.dnsport),
                str(self.machine.resultserver_port),
                str(routing.inetsim.ports),
            )

        elif self.route == "tor":
            self.rooter_response = rooter("tor")

        elif str(self.route).lower() in ("none", "drop", "false"):
            self.rooter_response = rooter("drop_enable", self.machine.ip, str(self.machine.resultserver_port))

        self._rooter_response_check()

        # nexthop bind (self.interface is None for a gateway route, so the generic
        self._dispatch_nexthop()

    def unroute_network(self):
        routing = Config("routing")
        if self.interface:
            pass

        if self.no_local_routing:
            rooter("delete_dev_from_vrf", self.machine.interface)
        elif self.rt_table:
            self.rooter_response = rooter("srcroute_disable", self.rt_table, self.machine.ip)
            self._rooter_response_check()

        if self.route == "inetsim":
            pass
PY

cat >"$TMP/cape/modules/processing/network.py" <<'PY'
from lib.cuckoo.common.path_utils import path_delete, path_exists, path_mkdir, path_read_file, path_write_file

class NetworkAnalysis:
    def run(self):
        if proc_cfg.network.process_map:
            self._process_map(results)
            if proc_cfg.network.merge_behavior_map:
                self._merge_behavior_network(results)

        return results
PY

cat >"$TMP/cape/web/templates/submission/index.html" <<'EOF'
                                        {% if inetsim %}
                                        <option value="inetsim">inetsim/fakenet-ng</option>
                                        {% endif %}
                                        <option value="none" {% if route == "none" %} selected{% endif %}>Drop all VM
                                            traffic</option>
                                </div>
                                <div class="mb-3">
                                    <label for="form_timeout" class="text-white-50">Timeout (seconds)</label>
EOF

python3 "$ROOT/tools/patch_cape_runtime.py"   --root "$TMP/cape"   --helper-source "$ROOT/tools/task_network_filter.py"

python3 "$ROOT/tools/patch_cape_runtime.py"   --root "$TMP/cape"   --helper-source "$ROOT/tools/task_network_filter.py"

python3 - "$TMP/cape" <<'PY'
from pathlib import Path
root=Path(__import__("sys").argv[1])
checks={
    "utils/rooter.py":"CAPE_INETSIM_AUTODEPLOY_ROUTE_V4",
    "lib/cuckoo/core/analysis_manager.py":"CAPE_INETSIM_AUTODEPLOY_ROUTE_V4",
    "modules/processing/network.py":"CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V2",
    "web/templates/submission/index.html":"CAPE_INETSIM_AUTODEPLOY_ROUTE_UI_V2",
}
for rel,marker in checks.items():
    text=(root/rel).read_text()
    assert text.count(marker)==1, (rel,text.count(marker))
rooter=(root/"utils/rooter.py").read_text()
assert "CAPEAD_" in rooter
assert "autodeploy_route_policy_set" in rooter
assert '"autodeploy_route_policy_set": autodeploy_route_policy_set' in rooter
print("RC66 patcher idempotency/marker checks passed")
PY

# Verify route-policy semantics against a small fake CAPE Rooter environment.
python3 - "$TMP/cape/utils/rooter.py" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1])
mod={}
calls=[]

def run(*args):
    calls.append(("run",args))
    if len(args) >= 3 and args[-2:] == ("-F", args[-1]):
        return "", ""
    if "-N" in args or "-X" in args:
        return "", ""
    return "", "not found"

def run_iptables(*args, **kwargs):
    calls.append(("iptables",args))
    if args[:2] == ("-D","CAPE_REJECTED_SEGMENTS"):
        return "", "rule absent"
    return "", ""

mod["run"]=run
mod["run_iptables"]=run_iptables
exec(p.read_text(),mod)

mod["ServicePaths"].iptables="/sbin/iptables"
mod["autodeploy_route_policy_set"]("192.168.122.204","virbr0","ens33","192.168.122.1","2040")
rules=[" ".join(a) for kind,a in calls if kind=="iptables"]
assert any("-i virbr0" in r and "-o ens33" in r and "-j ACCEPT" in r for r in rules), rules
assert any("-i virbr0" in r and "--destination 192.168.122.1" in r and "--dport 2040" in r and "-j ACCEPT" in r for r in rules), rules
assert any("-i virbr0" in r and "-j DROP" in r and "-o" not in r for r in rules), rules

calls.clear()
mod["autodeploy_route_policy_set"]("192.168.122.204","virbr0","","192.168.122.1","2040")
rules=[" ".join(a) for kind,a in calls if kind=="iptables"]
assert not any("-o ens33" in r for r in rules)
assert any("-j DROP" in r for r in rules)
print("RC66 route-policy allowlist/drop semantics passed")
PY

echo "RC66 routing/network semantics test suite passed"

# Route=drop/none must suppress all analyst-facing Network Analysis events.
python3 - "$ROOT/tools/task_network_filter.py" <<'PY'
import importlib.util
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("task_filter", p)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

network = {
    "tcp": [{"process_id": 100, "dst": "8.8.8.8"}],
    "udp": [{"process_id": 100, "dst": "1.1.1.1"}],
    "icmp": [{"process_id": 100, "dst": "9.9.9.9"}],
    "dns": [{"process_id": 100, "request": "example.invalid"}],
    "http": [{"process_id": 300, "host": "background.invalid"}],
    "hosts": [{"ip":"8.8.8.8"},{"ip":"6.6.6.6"}],
    "domains": ["example.invalid","background.invalid","leak.invalid"],
    "dead_hosts": [("6.6.6.6",80)],
    "sorted": {"tcp":[{"process_id":300,"dst":"5.5.5.5"}]},
}
behavior = {"processtree": [{"pid": 100, "children": []}]}
out = m.filter_network_to_task_process_tree(network, behavior, "drop")
assert out["tcp"] == []
assert out["udp"] == []
assert out["icmp"] == []
assert out["dns"] == []
assert out["http"] == []
assert out["hosts"] == []
assert out["domains"] == []
assert out["dead_hosts"] == []
assert out["sorted"] == {}
meta = out["autodeploy_task_network"]
assert meta["mode"] == "strict-no-network"
assert meta["kept_events"] == 0
assert meta["suppressed_events"] == 7
assert meta["raw_pcap_preserved"] is True
print("RC66 strict no-network Network Analysis filter passed")
PY
