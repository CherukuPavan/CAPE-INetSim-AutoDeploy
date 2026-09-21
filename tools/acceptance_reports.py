#!/usr/bin/env python3
import argparse
import gzip
import importlib.util
import json
from pathlib import Path
import sys

p=argparse.ArgumentParser(description="Validate real CAPE route=none reports against the installed Ubuntu-VM INetSim classifier")
p.add_argument("--cape-root",required=True)
p.add_argument("--inetsim-ip",required=True)
p.add_argument("--positive-task")
p.add_argument("--negative-task")
p.add_argument("--output",required=True)
p.add_argument("--scan-limit",type=int,default=200)
a=p.parse_args()

root=Path(a.cape_root)
analyses=root/"storage"/"analyses"
module_path=root/"web"/"analysis"/"inetsim_vm_logic.py"

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
    return {
        "task_id":int(task_id),
        "report_path":str(path),
        "route":route,
        "uses_inetsim":uses,
        "context_enabled":bool(context.get("enabled")),
        "summary":context.get("summary") or {},
        "task_domains":(context.get("attribution_summary") or {}).get("task_domains") or [],
        "capture_path":str(capture) if capture else "",
    }

def numeric_task_ids():
    if not analyses.is_dir():
        return []
    ids=[]
    for x in analyses.iterdir():
        if x.is_dir() and x.name.isdigit():
            ids.append(int(x.name))
    return sorted(ids,reverse=True)[:max(1,a.scan_limit)]

cache={}
def get(task_id):
    tid=int(task_id)
    if tid not in cache:
        cache[tid]=evaluate(tid)
    return cache[tid]

def valid_positive(row):
    return bool(row and row["capture_path"] and row["route"]=="none" and row["uses_inetsim"] and row["context_enabled"])

def valid_negative(row):
    return bool(row and row["capture_path"] and row["route"]=="none" and not row["uses_inetsim"] and not row["context_enabled"])

positive=None
negative=None
errors=[]

if a.positive_task:
    positive=get(a.positive_task)
    if not valid_positive(positive):
        errors.append("explicit positive task is not a route=none INetSim-positive report with a local pcap")
if a.negative_task:
    negative=get(a.negative_task)
    if not valid_negative(negative):
        errors.append("explicit negative task is not a route=none INetSim-negative report with a local pcap")

if positive is None or negative is None:
    for tid in numeric_task_ids():
        row=get(tid)
        if positive is None and valid_positive(row):
            positive=row
        if negative is None and valid_negative(row):
            negative=row
        if positive is not None and negative is not None:
            break

if positive is None:
    errors.append("no completed route=none report with INetSim traffic and a local pcap was found")
if negative is None:
    errors.append("no completed ordinary route=none negative-control report with a local pcap was found")

result={
    "schema":1,
    "status":"pass" if not errors else "incomplete",
    "inetsim_ip":a.inetsim_ip,
    "positive":positive,
    "negative":negative,
    "errors":errors,
}
Path(a.output).parent.mkdir(parents=True,exist_ok=True)
Path(a.output).write_text(json.dumps(result,indent=2)+"\n")

if errors:
    for e in errors:
        print(f"[FAIL] {e}",file=sys.stderr)
    raise SystemExit(20)

print(f"[PASS] positive route=none task {positive['task_id']} classified as Ubuntu-VM INetSim")
print(f"[PASS] negative route=none task {negative['task_id']} remained ordinary")
