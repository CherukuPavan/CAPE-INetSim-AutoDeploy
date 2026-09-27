#!/usr/bin/env bash

AD_INVENTORY_FILE=""

inventory_write() {
  state_init_paths
  AD_INVENTORY_FILE="$AD_STATE_ROOT/autodeploy-inventory.json"
  local py="${AD_HOST_PYTHON:-}"
  [[ -x "$py" ]] || { fail "Cannot generate inventory without host Python"; return 1; }

  CAPE_ROOT="${CAPE_ROOT:-}"   CAPE_PYTHON="${CAPE_PYTHON:-}"   CAPE_SCHEDULER_SERVICE="${CAPE_SCHEDULER_SERVICE:-}"   CAPE_PROCESSOR_SERVICE="${CAPE_PROCESSOR_SERVICE:-}"   CAPE_WEB_SERVICE="${CAPE_WEB_SERVICE:-}"   CAPE_ROOTER_SERVICE="${CAPE_ROOTER_SERVICE:-}"   CAPE_ROOTER_SOCKET="${CAPE_ROOTER_SOCKET:-}"   LIBVIRT_URI="${LIBVIRT_URI:-}"   CAPE_MACHINE_SECTION="${CAPE_MACHINE_SECTION:-}"   DOMAIN="${DOMAIN:-}"   "$py" - "$AD_INVENTORY_FILE" <<'PY'
import json, os, platform, shutil, subprocess, sys
from pathlib import Path

out=Path(sys.argv[1])

def run(cmd):
    try:
        p=subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        return {"rc":p.returncode,"output":p.stdout.strip()}
    except Exception as e:
        return {"rc":-1,"output":str(e)}

def one(cmd):
    r=run(cmd)
    return r["output"]

services={}
for role,var in [
    ("scheduler","CAPE_SCHEDULER_SERVICE"),("processor","CAPE_PROCESSOR_SERVICE"),
    ("web","CAPE_WEB_SERVICE"),("rooter","CAPE_ROOTER_SERVICE")]:
    name=os.environ.get(var,"")
    services[role]={"name":name}
    if name:
        services[role]["active"]=one(["systemctl","is-active",name])
        services[role]["enabled"]=one(["systemctl","is-enabled",name])
        services[role]["exec_start"]=one(["systemctl","show",name,"-p","ExecStart","--value"])
        services[role]["working_directory"]=one(["systemctl","show",name,"-p","WorkingDirectory","--value"])

cape_root=os.environ.get("CAPE_ROOT","")
cape={}
if cape_root:
    cape["root"]=cape_root
    cape["git_commit"]=one(["git","-C",cape_root,"rev-parse","HEAD"])
    cape["git_branch"]=one(["git","-C",cape_root,"branch","--show-current"])
    cape["version_files"]={}
    for rel in ("VERSION","version.txt","pyproject.toml"):
        p=Path(cape_root,rel)
        if p.exists():
            cape["version_files"][rel]=str(p)
cape["python"]=os.environ.get("CAPE_PYTHON","")
cape["selected_machine"]=os.environ.get("CAPE_MACHINE_SECTION","")
cape["selected_domain"]=os.environ.get("DOMAIN","")
cape["services"]=services
cape["rooter_socket"]=os.environ.get("CAPE_ROOTER_SOCKET","")

data={
 "schema":1,
 "generated_at":one(["date","-Is"]),
 "host":{
   "hostname":platform.node(),
   "os_release":Path("/etc/os-release").read_text(errors="replace") if Path("/etc/os-release").exists() else "",
   "architecture":platform.machine(),
   "kernel":platform.release(),
   "cpu":one(["sh","-c","lscpu 2>/dev/null || cat /proc/cpuinfo"]),
   "memory":one(["sh","-c","free -h 2>/dev/null || cat /proc/meminfo"]),
   "disk":one(["df","-hT"]),
   "kvm_device":os.path.exists("/dev/kvm"),
   "kvm_ok":run(["sh","-c","test -r /dev/kvm -a -w /dev/kvm"]),
 },
 "software":{
   "libvirt_version":one(["virsh","--version"]) if shutil.which("virsh") else "",
   "qemu_img_version":one(["qemu-img","--version"]) if shutil.which("qemu-img") else "",
   "python_commands":{x:shutil.which(x) for x in ("python","python3","poetry","pip","pip3")},
 },
 "libvirt":{
   "uri":os.environ.get("LIBVIRT_URI",""),
   "domains":run(["virsh","list","--all"]) if shutil.which("virsh") else {},
   "domain_interfaces":{},
   "networks":run(["virsh","net-list","--all"]) if shutil.which("virsh") else {},
   "bridges":run(["ip","-br","link"]) if shutil.which("ip") else {},
   "addresses":run(["ip","-br","addr"]) if shutil.which("ip") else {},
   "routes":run(["ip","route","show","table","all"]) if shutil.which("ip") else {},
 },
 "firewall":{
   "nft":run(["nft","list","ruleset"]) if shutil.which("nft") else {},
   "iptables_save":run(["iptables-save"]) if shutil.which("iptables-save") else {},
 },
 "cape":cape,
 "autodeploy":{
   "state_root":str(out.parent),
   "state_file_exists":Path(out.parent,"state.env").exists(),
   "resource_ledger_exists":Path(out.parent,"resources.tsv").exists(),
   "existing_files":[p.name for p in out.parent.iterdir()] if out.parent.exists() else [],
 }
}
if shutil.which("virsh"):
    names=one(["virsh","list","--all","--name"]).splitlines()
    for name in filter(None,map(str.strip,names)):
        data["libvirt"]["domain_interfaces"][name]=run(["virsh","domiflist",name])
out.write_text(json.dumps(data,indent=2,sort_keys=True)+"\n")
PY
  chmod 0600 "$AD_INVENTORY_FILE"
  pass "Inventory written: $AD_INVENTORY_FILE"
}
