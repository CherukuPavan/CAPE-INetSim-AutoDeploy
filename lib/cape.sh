#!/usr/bin/env bash

cape_root_candidates() {
  local unit wd p
  for unit in cape.service cape-web.service cape-processor.service cape-rooter.service; do
    wd="$(systemctl show "$unit" -p WorkingDirectory --value 2>/dev/null || true)"
    [[ -n "$wd" && "$wd" != "/" ]] && printf '%s\n' "$wd"
  done
  printf '%s\n' /opt/CAPEv2 /srv/CAPEv2 /usr/local/CAPEv2
  find /opt /srv /usr/local /home -maxdepth 5 -type f -path '*/conf/kvm.conf' -printf '%h\n' 2>/dev/null | sed 's#/conf$##' || true
}

discover_cape_root() {
  local p
  local -a roots=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    p="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
    [[ -f "$p/conf/kvm.conf" ]] || continue
    if [[ ! " ${roots[*]} " =~ " ${p} " ]]; then roots+=("$p"); fi
  done < <(cape_root_candidates)

  if ((${#roots[@]} == 1)); then
    CAPE_ROOT="${roots[0]}"
    pass "CAPE installation discovered"
  elif ((${#roots[@]} == 0)); then
    CAPE_ROOT=""
    add_error "No CAPE root containing conf/kvm.conf was found"
  else
    CAPE_ROOT=""
    add_error "Multiple CAPE roots found: ${roots[*]}"
  fi
}

discover_cape_git() {
  CAPE_COMMIT="unknown"; CAPE_BRANCH="unknown"; CAPE_DIRTY="unknown"
  [[ -n "${CAPE_ROOT:-}" ]] || return 0
  if git -C "$CAPE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CAPE_COMMIT="$(git -C "$CAPE_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    CAPE_BRANCH="$(git -C "$CAPE_ROOT" branch --show-current 2>/dev/null || true)"
    [[ -n "$CAPE_BRANCH" ]] || CAPE_BRANCH="detached"
    if [[ -n "$(git -C "$CAPE_ROOT" status --porcelain 2>/dev/null || true)" ]]; then CAPE_DIRTY="yes"; else CAPE_DIRTY="no"; fi
  fi
}

discover_cape_services() {
  CAPE_SERVICES=()
  local s
  for s in cape cape-web cape-processor cape-rooter; do
    if systemctl cat "$s" >/dev/null 2>&1; then
      CAPE_SERVICES+=("$s:$(systemctl is-active "$s" 2>/dev/null || true)")
    fi
  done
}

discover_cape_machine_records() {
  CAPE_MACHINE_RECORDS=()
  [[ -n "${CAPE_ROOT:-}" ]] || return 0
  mapfile -t CAPE_MACHINE_RECORDS < <(python3 - "$CAPE_ROOT/conf/kvm.conf" <<'PY'
import configparser,json,sys
p=sys.argv[1]
cfg=configparser.ConfigParser(interpolation=None, strict=False)
cfg.optionxform=str.lower
cfg.read(p)
ignore={'kvm','resultserver','timeouts'}
for sec in cfg.sections():
    if sec.lower() in ignore: continue
    d={k.lower():v.strip() for k,v in cfg.items(sec)}
    if not any(k in d for k in ('ip','label','snapshot','platform','interface')): continue
    if d.get('enabled','yes').lower() in ('no','false','0'): continue
    print(json.dumps({
        'section':sec,
        'label':d.get('label',sec),
        'ip':d.get('ip',''),
        'snapshot':d.get('snapshot',''),
        'interface':d.get('interface',''),
        'platform':d.get('platform','')
    }, separators=(',',':')))
PY
)
  if ((${#CAPE_MACHINE_RECORDS[@]} == 0)); then add_error "No enabled CAPE analysis-machine sections were discovered"; fi
}

record_field(){ python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2"; }

select_machine_by_request() {
  local req="$1" rec section label
  SELECTED_MACHINE_JSON=""
  for rec in "${CAPE_MACHINE_RECORDS[@]}"; do
    section="$(record_field "$rec" section)"; label="$(record_field "$rec" label)"
    if [[ "$req" == "$section" || "$req" == "$label" ]]; then SELECTED_MACHINE_JSON="$rec"; break; fi
  done
  [[ -n "$SELECTED_MACHINE_JSON" ]] || add_error "Requested CAPE machine '$req' was not found"
}

set_selected_machine_fields() {
  [[ -n "${SELECTED_MACHINE_JSON:-}" ]] || return 0
  CAPE_MACHINE_SECTION="$(record_field "$SELECTED_MACHINE_JSON" section)"
  CAPE_MACHINE_LABEL="$(record_field "$SELECTED_MACHINE_JSON" label)"
  CAPE_MACHINE_IP="$(record_field "$SELECTED_MACHINE_JSON" ip)"
  CAPE_MACHINE_SNAPSHOT="$(record_field "$SELECTED_MACHINE_JSON" snapshot)"
  CAPE_MACHINE_INTERFACE="$(record_field "$SELECTED_MACHINE_JSON" interface)"
  CAPE_MACHINE_PLATFORM="$(record_field "$SELECTED_MACHINE_JSON" platform)"
}
