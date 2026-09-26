#!/usr/bin/env bash

discover_busy_state() {
  CAPE_BUSY="unknown"
  BUSY_REASON="read-only planning cannot prove CAPE database idleness; deploy cutover uses the atomic task-aware maintenance guard"

  # CAPE's local sniffer command line carries the per-analysis dump path. This
  # is a read-only strong busy signal and catches work on any analysis VM, not
  # merely the currently selected libvirt domain.
  local active_capture
  active_capture="$(ps -eo args= 2>/dev/null | awk '
    /[t]cpdump/ && /storage\/analyses\/[0-9]+\/(dump|dump_sorted)\.pcap/ {print; exit}
  ' || true)"
  if [[ -n "$active_capture" ]]; then
    CAPE_BUSY="yes"
    BUSY_REASON="active CAPE analysis packet capture process detected"
    return 0
  fi

  CAPE_BUSY="unknown"
  BUSY_REASON="per-VM power state does not prove CAPE idleness; cutover locks the complete CAPE machine set atomically"
}

check_cape_layout() {
  COMPAT_STATUS="blocked"; COMPAT_NOTES=()
  [[ -n "${CAPE_ROOT:-}" ]] || return 0
  local f missing=()
  for f in conf/kvm.conf conf/auxiliary.conf conf/processing.conf conf/routing.conf modules/auxiliary/sniffer.py modules/machinery/kvm.py lib/cuckoo/common/abstracts.py lib/cuckoo/core/machinery_manager.py lib/cuckoo/core/analysis_manager.py web/analysis/views.py; do [[ -e "$CAPE_ROOT/$f" ]] || missing+=("$f"); done
  if ((${#missing[@]})); then add_note "missing:${missing[*]}"; return 0; fi

  local config_layout
  config_layout="$(python3 - "$CAPE_ROOT" "${CAPE_TARGETS_JSON:-[]}" <<'PY'
import configparser,json,sys
root,targets_json=sys.argv[1:]
checks=[
    ("auxiliary","sniffer"),
    ("processing","network"),
    ("routing","routing"),
    ("routing","inetsim"),
]
problems=[]
for name,section in checks:
    p=f"{root}/conf/{name}.conf"
    cfg=configparser.ConfigParser(interpolation=None,strict=False)
    cfg.read(p)
    if not cfg.has_section(section):
        problems.append(f"{name}.conf:[{section}]")
k=configparser.ConfigParser(interpolation=None,strict=False)
k.read(f"{root}/conf/kvm.conf")
try:
    targets=json.loads(targets_json)
except Exception:
    targets=[]
if not targets:
    problems.append("kvm.conf:[no-managed-machines]")
for d in targets:
    machine=str(d.get("section") or "")
    if not machine or not k.has_section(machine):
        problems.append(f"kvm.conf:[{machine or 'managed-machine-missing'}]")
print("OK" if not problems else "missing-sections:"+",".join(problems))
PY
)"
  if [[ "$config_layout" != OK ]]; then
    COMPAT_STATUS="plan-only-unknown-cape-layout"
    add_note "config-layout:$config_layout"
    return 0
  fi

  local maintenance_layout
  maintenance_layout="$(python3 - "$CAPE_ROOT" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1])
required={
  "lib/cuckoo/core/data/machines.py":[
    "class Machine(", "locked:", "locked_changed_on:", "with_for_update(of=Machine)",
  ],
  "lib/cuckoo/core/data/task.py":[
    'TASK_RUNNING = "running"', 'TASK_DISTRIBUTED = "distributed"',
    'TASK_COMPLETED = "completed"', 'TASK_DISTRIBUTED_COMPLETED = "distributed_completed"',
  ],
  "lib/cuckoo/core/data/db_common.py":["def _utcnow_naive("],
  "lib/cuckoo/core/database.py":["class _Database(", "class Database:", "def init_database("],
}
missing=[]
for rel,tokens in required.items():
    p=root/rel
    if not p.is_file():
        missing.append(rel+":missing")
        continue
    text=p.read_text(encoding="utf-8",errors="replace")
    for token in tokens:
        if token not in text:
            missing.append(rel+":"+token)
print("OK" if not missing else "unsupported:"+",".join(missing))
PY
)"
  if [[ "$maintenance_layout" != OK ]]; then
    COMPAT_STATUS="plan-only-unknown-cape-layout"
    add_note "maintenance-api:$maintenance_layout"
    return 0
  fi
  add_note "maintenance-api:known-layout"

  local route_layout
  route_layout="$(python3 - "$CAPE_ROOT" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1])
checks={
  "modules/auxiliary/sniffer.py":(
    "CAPE_INETSIM_ROUTE_AWARE_CAPTURE_V2",
    "CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1",
    '        host = self.machine.ip\n        # Selects per-machine interface if available.\n        interface = self.machine.interface or self.options.get("interface")\n',
  ),
  "lib/cuckoo/common/abstracts.py":(
    "CAPE_INETSIM_ROUTE_SNAPSHOT_OVERRIDE_V1","",
    '    def start(self, label=None):\n        """Starts a virtual machine.\n',
  ),
  "lib/cuckoo/core/machinery_manager.py":(
    "CAPE_INETSIM_MACHINERY_ROUTE_START_V1","",
    '    def start_machine(self, machine: Machine) -> None:\n',
  ),
  "lib/cuckoo/core/analysis_manager.py":(
    "CAPE_INETSIM_ANALYSIS_ROUTE_START_V1","",
    '                self.machinery_manager.start_machine(self.machine)\n',
  ),
  "modules/machinery/kvm.py":(
    "CAPE_INETSIM_KVM_ROUTE_SNAPSHOT_V1","",
    '    def start(self, label):\n        super(KVM, self).start(label)\n',
  ),
}
bad=[]; states=[]
for rel,(marker,legacy,anchor) in checks.items():
    p=root/rel
    if not p.is_file():
        bad.append(rel+":missing"); continue
    t=p.read_text(encoding="utf-8",errors="replace")
    if t.count(marker)==1:
        states.append(rel+":patched"); continue
    if t.count(marker)>1:
        bad.append(rel+":ambiguous-marker"); continue
    if legacy and t.count(legacy)==1:
        states.append(rel+":legacy"); continue
    if t.count(anchor)==1:
        states.append(rel+":clean")
    elif t.count(anchor)>1:
        bad.append(rel+":ambiguous-anchor")
    else:
        bad.append(rel+":unknown-layout")
print(("OK\t"+";".join(states)) if not bad else ("BAD\t"+";".join(bad)))
PY
)"
  case "$route_layout" in
    OK$'\t'*)
      COMPAT_STATUS="plan-compatible"
      add_note "route-aware-source:\${route_layout#*$'\t'}"
      ;;
    *)
      COMPAT_STATUS="plan-only-unknown-cape-layout"
      add_note "route-aware-source:\${route_layout#*$'\t'}"
      ;;
  esac
  if grep -Rqs 'CAPE_INETSIM_VM_ROUTE_AWARE_V1' "$CAPE_ROOT/web" 2>/dev/null; then
    add_note "extension:route-aware"
  elif grep -Rqs 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$CAPE_ROOT/web" 2>/dev/null; then
    add_note "extension:legacy-present"
  else
    add_note "extension:not-present"
  fi
}

discover_resources() {
  HOST_MEM_KIB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  HOST_MEM_AVAILABLE_KIB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  LIBVIRT_FREE_KIB=0
  LIBVIRT_STORAGE_POOL=""
  LIBVIRT_STORAGE_PATH=""

  local p state xml typ path avail
  local -a ordered=()
  virsh pool-info default >/dev/null 2>&1 && ordered+=(default)
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != default ]] && ordered+=("$p")
  done < <(virsh pool-list --all --name 2>/dev/null)

  for p in "${ordered[@]}"; do
    state="$(virsh pool-info "$p" 2>/dev/null | awk -F: '/^State:/ {gsub(/^[ \t]+/,"",$2);print $2}')"
    [[ "$state" == running ]] || continue
    xml="$(virsh pool-dumpxml "$p" 2>/dev/null || true)"
    typ="$(python3 -c 'import sys,xml.etree.ElementTree as E
try: r=E.fromstring(sys.stdin.read())
except Exception: raise SystemExit
print(r.get("type",""))' <<<"$xml" 2>/dev/null || true)"
    [[ "$typ" == dir ]] || continue
    path="$(python3 -c 'import sys,xml.etree.ElementTree as E
try: r=E.fromstring(sys.stdin.read())
except Exception: raise SystemExit
x=r.find("./target/path")
print(x.text if x is not None else "")' <<<"$xml" 2>/dev/null || true)"
    [[ -n "$path" && -d "$path" ]] || continue
    avail="$(df -Pk "$path" 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$avail" =~ ^[0-9]+$ ]] || continue
    if ((avail > LIBVIRT_FREE_KIB)); then
      LIBVIRT_FREE_KIB="$avail"
      LIBVIRT_STORAGE_POOL="$p"
      LIBVIRT_STORAGE_PATH="$path"
    fi
  done

  if [[ -z "$LIBVIRT_STORAGE_POOL" || "$LIBVIRT_FREE_KIB" -lt 20971520 ]]; then
    add_error "No active directory libvirt storage pool with at least 20 GiB free was found"
  fi
}
