#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT/tools/task_network_filter.py" <<'PY'
import importlib.util, pathlib, sys
p=pathlib.Path(sys.argv[1])
spec=importlib.util.spec_from_file_location("task_filter", p)
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

network={"tcp":[{"process_id":300,"dst":"8.8.8.8"}],"dns":[{"process_id":300,"request":"background.invalid"}]}
out=m.filter_network_to_task_process_tree(network, {}, "internet")
meta=out["autodeploy_task_network"]
assert meta["mode"] == "primary-process-tree-no-root"
assert meta["source_event_count"] == 2
assert meta["source_event_counts"]["tcp"] == 1
assert meta["source_event_counts"]["dns"] == 1
assert meta["suppressed_events"] == 2
assert meta["kept_events"] == 0
assert meta["attribution_status"] == "no-process-tree"
assert meta["raw_pcap_preserved"] is True

network={"tcp":[{"process_id":100,"dst":"192.168.200.2"}],"dns":[],"dead_hosts":[["192.168.200.2",80]]}
behavior={"processtree":[{"pid":100,"children":[]}]}
out=m.filter_network_to_task_process_tree(network, behavior, "inetsim")
meta=out["autodeploy_task_network"]
assert meta["source_event_count"] == 1
assert meta["kept_events"] == 1
assert meta["suppressed_events"] == 0
assert meta["attribution_status"] == "process-attributed"
assert out["dead_hosts"] == []
print("Network Analysis evidence metadata regression passed")
PY

grep -Fq 'CAPE_INETSIM_AUTODEPLOY_NETWORK_UI_V1' "$ROOT/tools/patch_cape_runtime.py"
grep -Fq 'web/templates/analysis/network/index.html' "$ROOT/tools/patch_cape_runtime.py"
grep -Fq 'source_event_count' "$ROOT/tools/task_network_filter.py"
echo 'Network Analysis observability source checks passed'
