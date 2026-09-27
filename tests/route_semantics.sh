#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

grep -Fq 'Fake Internet — dedicated Ubuntu INetSim appliance' "$ROOT/tools/patch_cape_runtime.py"
grep -Fq 'No network — strictly blocked (analysis egress)' "$ROOT/tools/patch_cape_runtime.py"
grep -Fq 'autodeploy_strict_drop_enable' "$ROOT/tools/patch_cape_runtime.py"
grep -Fq 'autodeploy_internet_enable' "$ROOT/tools/patch_cape_runtime.py"
grep -Fq 'CAPE_INETSIM_AUTODEPLOY_TASK_NETWORK_V1' "$ROOT/tools/patch_cape_runtime.py"

python3 - "$ROOT/tools/task_network_filter.py" <<'PY'
import importlib.util
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("filter_mod", p)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

network = {
    "tcp": [
        {"src":"10.0.0.2","dst":"1.2.3.4","dport":80,"process_id":100},
        {"src":"10.0.0.2","dst":"5.6.7.8","dport":80,"process_id":300},
    ],
    "dns": [
        {"request":"x.test","process_id":100},
        {"request":"noise.test","process_id":300},
    ],
    "http": [
        {"host":"x.test","process_id":100},
        {"host":"noise.test","process_id":300},
    ],
    "hosts": [
        {"ip":"1.2.3.4","process_id":100},
        {"ip":"5.6.7.8","process_id":300},
    ],
}
behavior = {
    "processtree": [
        {"pid":100,"children":[{"pid":200,"children":[]}]},
        {"pid":300,"children":[]},
    ]
}

out = m.filter_network_to_task_process_tree(network, behavior)

assert [x["process_id"] for x in out["tcp"]] == [100]
assert [x["process_id"] for x in out["dns"]] == [100]
assert [x["process_id"] for x in out["http"]] == [100]
assert [x["process_id"] for x in out["hosts"]] == [100]

meta = out["autodeploy_task_network"]
assert meta["root_pid"] == 100
assert meta["tracked_pids"] == 2
assert meta["kept_events"] == 4
assert meta["suppressed_events"] == 4
assert meta["raw_pcap_preserved"] is True

print("RC66 route/network semantics tests passed")
PY
