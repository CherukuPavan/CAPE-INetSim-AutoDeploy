#!/usr/bin/env python3
import argparse
import gzip
import importlib.util
import json
from pathlib import Path
import sys
from urllib.parse import urlsplit

p=argparse.ArgumentParser(description="Validate controlled real CAPE route=none reports against Ubuntu-VM INetSim")
p.add_argument("--cape-root",required=True)
p.add_argument("--inetsim-ip",required=True)
p.add_argument("--positive-task",required=True)
p.add_argument("--negative-task",required=True)
p.add_argument("--marker",required=True,help="Unique hostname marker intentionally generated only by the positive control")
p.add_argument("--output",required=True)
a=p.parse_args()

root=Path(a.cape_root)
analyses=root/"storage"/"analyses"
module_path=root/"web"/"analysis"/"inetsim_vm_logic.py"
marker=str(a.marker or "").strip().lower().rstrip(".")

if not marker or any(c.isspace() for c in marker):
    raise SystemExit("acceptance marker must be a non-empty hostname-like token without whitespace")
if not module_path.is_file():
    raise SystemExit(f"installed extension logic missing: {module_path}")

spec=importlib.util.spec_from_file_location("cape_inetsim_acceptance_logic",module_path)
logic=importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(logic)

def load_report(task_id):
    base=analyses/str(task_id)/"reports"
    candidates=[
        base/"report.json",
        base/"report.json.gz",
        analyses/str(task_id)/"report.json",
        analyses/str(task_id)/"report.json.gz",
    ]
    for path in candidates:
        if not path.is_file():
            continue
        if path.suffix==".gz":
            with gzip.open(path,"rt",encoding="utf-8",errors="replace") as f:
                return json.load(f),path
        with path.open(encoding="utf-8",errors="replace") as f:
            return json.load(f),path
    return None,None

def capture_path(task_id):
    base=analyses/str(task_id)
    for path in (base/"dump.pcap",base/"dump_sorted.pcap"):
        if path.is_file() and path.stat().st_size > 0:
            return path
    return None

def norm_host(value):
    return str(value or "").strip().lower().rstrip(".")

def marker_evidence(network):
    hits=[]
    if not isinstance(network,dict):
        return hits
    for event in network.get("dns") or []:
        if not isinstance(event,dict):
            continue
        request=norm_host(event.get("request"))
        if request==marker:
            hits.append({"kind":"dns","value":request})
    for event in network.get("http") or []:
        if not isinstance(event,dict):
            continue
        host=norm_host(event.get("host") or event.get("hostname"))
        if host==marker:
            hits.append({"kind":"http-host","value":host})
        raw_url=str(event.get("url") or event.get("uri") or "").strip()
        if raw_url:
            try:
                parsed=norm_host(urlsplit(raw_url).hostname)
            except Exception:
                parsed=""
            if parsed==marker:
                hits.append({"kind":"http-url","value":raw_url})
    return hits

def evaluate(task_id):
    report,path=load_report(task_id)
    if not isinstance(report,dict):
        return None
    capture=capture_path(task_id)
    info=report.get("info") or {}
    route=str(info.get("route") or "").strip().lower()
    network=report.get("network") or {}
    if not isinstance(network,dict):
        network={}
    uses=bool(logic.network_uses_inetsim(network,a.inetsim_ip))
    context=logic.build_route_none_inetsim_context(network,a.inetsim_ip)
    evidence=marker_evidence(network)
    return {
        "task_id":int(task_id),
        "report_path":str(path),
        "route":route,
        "uses_inetsim":uses,
        "context_enabled":bool(context.get("enabled")),
        "summary":context.get("summary") or {},
        "task_domains":(context.get("attribution_summary") or {}).get("task_domains") or [],
        "capture_path":str(capture) if capture else "",
        "marker_present":bool(evidence),
        "marker_evidence":evidence,
    }

positive=evaluate(a.positive_task)
negative=evaluate(a.negative_task)
errors=[]

positive_ok=bool(
    positive
    and positive["capture_path"]
    and positive["route"]=="none"
    and positive["uses_inetsim"]
    and positive["context_enabled"]
    and positive["marker_present"]
)
negative_ok=bool(
    negative
    and negative["capture_path"]
    and negative["route"]=="none"
    and not negative["marker_present"]
)

if not positive_ok:
    errors.append("explicit positive task is not a route=none INetSim report containing the required marker with a local pcap")
if not negative_ok:
    errors.append("explicit negative task is not a route=none report without the required marker and a local pcap")

result={
    "schema":2,
    "status":"pass" if not errors else "incomplete",
    "mode":"marker-pair",
    "inetsim_ip":a.inetsim_ip,
    "marker":marker,
    "positive":positive,
    "negative":negative,
    "background_inetsim_allowed_in_negative":True,
    "errors":errors,
}
Path(a.output).parent.mkdir(parents=True,exist_ok=True)
Path(a.output).write_text(json.dumps(result,indent=2)+"\n")

if errors:
    for e in errors:
        print(f"[FAIL] {e}",file=sys.stderr)
    raise SystemExit(20)

print(f"[PASS] positive route=none task {positive['task_id']} contains marker {marker} and reached Ubuntu-VM INetSim")
if negative["uses_inetsim"]:
    print(f"[PASS] negative route=none task {negative['task_id']} lacks marker {marker}; background INetSim traffic is allowed")
else:
    print(f"[PASS] negative route=none task {negative['task_id']} lacks marker {marker} and has no INetSim traffic")
