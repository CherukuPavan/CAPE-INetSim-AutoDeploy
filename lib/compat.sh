#!/usr/bin/env bash

discover_busy_state() {
  CAPE_BUSY="unknown"; BUSY_REASON="unable to determine safely"
  case "${DOMAIN_STATE:-unknown}" in
    running|paused|blocked|pmsuspended) CAPE_BUSY="yes"; BUSY_REASON="analysis domain state is '${DOMAIN_STATE}'; treat as busy until a CAPE task-aware idle check is implemented" ;;
    "shut off"|shutoff|crashed) CAPE_BUSY="no"; BUSY_REASON="analysis domain state is '${DOMAIN_STATE}'" ;;
  esac
}

check_cape_layout() {
  COMPAT_STATUS="blocked"; COMPAT_NOTES=()
  [[ -n "${CAPE_ROOT:-}" ]] || return 0
  local f missing=()
  for f in conf/kvm.conf conf/auxiliary.conf conf/processing.conf modules/auxiliary/sniffer.py web/analysis/views.py; do [[ -e "$CAPE_ROOT/$f" ]] || missing+=("$f"); done
  if ((${#missing[@]})); then add_note "missing:${missing[*]}"; return 0; fi

  local config_layout
  config_layout="$(python3 - "$CAPE_ROOT" "${CAPE_MACHINE_SECTION:-}" <<'PY'
import configparser,sys
root,machine=sys.argv[1:]
checks=[
    ("auxiliary","sniffer"),
    ("processing","network"),
    ("routing","routing"),
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
if not machine or not k.has_section(machine):
    problems.append(f"kvm.conf:[{machine or 'selected-machine-missing'}]")
print("OK" if not problems else "missing-sections:"+",".join(problems))
PY
)"
  if [[ "$config_layout" != OK ]]; then
    COMPAT_STATUS="plan-only-unknown-cape-layout"
    add_note "config-layout:$config_layout"
    return 0
  fi

  local sniffer="$CAPE_ROOT/modules/auxiliary/sniffer.py" layout
  layout="$(python3 - "$sniffer" <<'PY'
import sys
p=sys.argv[1]
s=open(p,encoding="utf-8").read()
marker="CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1"
old="        host = self.machine.ip\n        # Selects per-machine interface if available.\n"
if s.count(marker)==1:
    print("already-present")
elif s.count(marker)>1:
    print("ambiguous-marker")
elif s.count(old)==1:
    print("known-clean-pattern")
elif s.count(old)>1:
    print("ambiguous-clean-pattern")
else:
    print("unknown")
PY
)"
  case "$layout" in
    already-present)
      COMPAT_STATUS="plan-compatible"; add_note "capture-override:already-present" ;;
    known-clean-pattern)
      if git -C "$CAPE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
         [[ -n "$(git -C "$CAPE_ROOT" status --porcelain -- modules/auxiliary/sniffer.py 2>/dev/null || true)" ]]; then
        COMPAT_STATUS="plan-only-unknown-cape-layout"
        add_note "capture-override:preexisting-source-modification"
      else
        COMPAT_STATUS="plan-compatible"; add_note "capture-override:known-clean-pattern"
      fi
      ;;
    *)
      COMPAT_STATUS="plan-only-unknown-cape-layout"; add_note "capture-override:$layout" ;;
  esac
  if grep -Rqs 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$CAPE_ROOT/web" 2>/dev/null; then add_note "extension:already-present"; else add_note "extension:not-present"; fi
}

discover_resources() {
  HOST_MEM_KIB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  LIBVIRT_FREE_KIB="$(df -Pk /var/lib/libvirt/images 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
}
