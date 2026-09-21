#!/usr/bin/env bash

resolve_cape_root_from_path() {
  local p="$1" i
  [[ -n "$p" && "$p" != "/" ]] || return 1
  p="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
  [[ -f "$p" ]] && p="$(dirname "$p")"
  for i in 1 2 3 4 5 6; do
    if [[ -f "$p/conf/kvm.conf" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
    [[ "$p" == "/" ]] && break
    p="$(dirname "$p")"
  done
  return 1
}

cape_service_roots() {
  local unit wd root
  for unit in cape.service cape-web.service cape-processor.service cape-rooter.service; do
    systemctl cat "$unit" >/dev/null 2>&1 || continue
    wd="$(systemctl show "$unit" -p WorkingDirectory --value 2>/dev/null || true)"
    root="$(resolve_cape_root_from_path "$wd" 2>/dev/null || true)"
    [[ -n "$root" ]] && printf '%s\n' "$root"
  done | sort -u
}

cape_fallback_roots() {
  local p
  if [[ -n "${CAPE_ROOT:-}" ]]; then
    resolve_cape_root_from_path "$CAPE_ROOT" 2>/dev/null || true
  fi
  for p in /opt/CAPEv2 /srv/CAPEv2 /usr/local/CAPEv2; do
    resolve_cape_root_from_path "$p" 2>/dev/null || true
  done
  find /opt /srv /usr/local /home -maxdepth 5 -type f -path '*/conf/kvm.conf' -printf '%h\n' 2>/dev/null |
    sed 's#/conf$##' || true
}

discover_cape_root() {
  local -a service_roots=() fallback_roots=()
  mapfile -t service_roots < <(cape_service_roots)

  # The CAPE instance referenced by CAPE systemd units is authoritative.
  # This avoids mistaking backup/source copies (for example CAPEv2-backup)
  # for the live sandbox installation.
  if ((${#service_roots[@]} == 1)); then
    CAPE_ROOT="${service_roots[0]}"
    CAPE_ROOT_SOURCE="systemd"
    pass "Live CAPE installation discovered from systemd"
    return 0
  elif ((${#service_roots[@]} > 1)); then
    CAPE_ROOT=""
    CAPE_ROOT_SOURCE="ambiguous-systemd"
    add_error "CAPE services resolve to multiple roots: ${service_roots[*]}"
    return 0
  fi

  mapfile -t fallback_roots < <(cape_fallback_roots | sed '/^$/d' | sort -u)
  if ((${#fallback_roots[@]} == 1)); then
    CAPE_ROOT="${fallback_roots[0]}"
    CAPE_ROOT_SOURCE="filesystem-fallback"
    pass "CAPE installation discovered by filesystem fallback"
  elif ((${#fallback_roots[@]} == 0)); then
    CAPE_ROOT=""
    CAPE_ROOT_SOURCE="not-found"
    add_error "No CAPE root containing conf/kvm.conf was found"
  else
    CAPE_ROOT=""
    CAPE_ROOT_SOURCE="ambiguous-filesystem"
    add_error "No authoritative CAPE service root; multiple filesystem CAPE roots found: ${fallback_roots[*]}"
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

discover_cape_database_backend() {
  CAPE_DB_BACKEND="unknown"
  [[ -n "${CAPE_ROOT:-}" && -f "$CAPE_ROOT/conf/cuckoo.conf" ]] || return 0
  CAPE_DB_BACKEND="$(python3 - "$CAPE_ROOT/conf/cuckoo.conf" <<'PY'
import configparser,sys,urllib.parse
c=configparser.ConfigParser(interpolation=None,strict=False)
c.read(sys.argv[1])
value=c.get("database","connection",fallback="").strip()
if not value:
    print("sqlite")
else:
    scheme=urllib.parse.urlsplit(value).scheme.lower()
    base=scheme.split("+",1)[0]
    print(base or "unknown")
PY
)"
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

# CAPE's [kvm] machines= list is the authoritative set of guests actually
# available to the KVM machinery. Example/template/stale sections may coexist
# in the same file and must not be auto-deployed merely because they look like
# valid machine sections.
configured=[]
if cfg.has_section('kvm'):
    raw=cfg.get('kvm','machines',fallback='').strip()
    configured=[x.strip() for x in raw.replace('\n',',').split(',') if x.strip()]
configured_set=set(configured)

sections=configured if configured else [s for s in cfg.sections() if s.lower() not in ignore]
for sec in sections:
    if sec.lower() in ignore or not cfg.has_section(sec):
        continue
    d={k.lower():v.strip() for k,v in cfg.items(sec)}
    if not any(k in d for k in ('ip','label','snapshot','platform','interface')): continue
    if d.get('enabled','yes').lower() in ('no','false','0'): continue
    platform=d.get('platform','').strip().lower()
    if platform and not platform.startswith('windows'):
        continue
    print(json.dumps({
        'section':sec,
        'label':d.get('label',sec),
        'ip':d.get('ip',''),
        'snapshot':d.get('snapshot',''),
        'interface':d.get('interface',''),
        'platform':d.get('platform',''),
        'resultserver_ip':d.get('resultserver_ip',''),
        'resultserver_port':d.get('resultserver_port','')
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
  CAPE_MACHINE_RESULTSERVER_IP="$(record_field "$SELECTED_MACHINE_JSON" resultserver_ip)"
  CAPE_MACHINE_RESULTSERVER_PORT="$(record_field "$SELECTED_MACHINE_JSON" resultserver_port)"
}

discover_resultserver() {
  CAPE_RESULTSERVER_IP=""
  CAPE_RESULTSERVER_PORT=""
  CONTROL_HOST_IP=""
  [[ -n "${CAPE_ROOT:-}" && -n "${CAPE_MACHINE_IP:-}" ]] || return 0

  local global_ip global_port route_line
  read -r global_ip global_port < <(python3 - "$CAPE_ROOT/conf/cuckoo.conf" <<'PY'
import configparser,sys
c=configparser.ConfigParser(interpolation=None,strict=False)
c.read(sys.argv[1])
print(c.get('resultserver','ip',fallback=''), c.get('resultserver','port',fallback='2042'))
PY
)
  route_line="$(ip -4 route get "$CAPE_MACHINE_IP" 2>/dev/null | head -1 || true)"
  CONTROL_HOST_IP="$(awk '{for(i=1;i<=NF;i++) if($i=="src" && i<NF){print $(i+1);exit}}' <<<"$route_line")"

  CAPE_RESULTSERVER_IP="${CAPE_MACHINE_RESULTSERVER_IP:-}"
  if [[ -z "$CAPE_RESULTSERVER_IP" || "$CAPE_RESULTSERVER_IP" == "0.0.0.0" ]]; then
    if [[ -n "$global_ip" && "$global_ip" != "0.0.0.0" ]] &&
       python3 - "$global_ip" <<'PY' >/dev/null 2>&1
import ipaddress,sys
ip=ipaddress.ip_address(sys.argv[1])
raise SystemExit(0 if ip.version==4 and not ip.is_loopback and not ip.is_unspecified else 1)
PY
    then
      CAPE_RESULTSERVER_IP="$global_ip"
    else
      CAPE_RESULTSERVER_IP="$CONTROL_HOST_IP"
    fi
  fi
  CAPE_RESULTSERVER_PORT="${CAPE_MACHINE_RESULTSERVER_PORT:-$global_port}"
  [[ -n "$CAPE_RESULTSERVER_PORT" ]] || CAPE_RESULTSERVER_PORT=2042

  [[ -n "$CAPE_RESULTSERVER_IP" ]] || add_error "Could not derive a guest-reachable CAPE ResultServer IP"
  [[ "$CAPE_RESULTSERVER_PORT" =~ ^[0-9]+$ ]] || add_error "Invalid ResultServer port: $CAPE_RESULTSERVER_PORT"

  if [[ -n "$CAPE_RESULTSERVER_IP" ]]; then
    local resultserver_local=no addr
    while IFS= read -r addr; do
      [[ "$addr" == "$CAPE_RESULTSERVER_IP" ]] && { resultserver_local=yes; break; }
    done < <(ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')
    if [[ "$resultserver_local" != yes ]]; then
      add_error "CAPE ResultServer IP $CAPE_RESULTSERVER_IP is not host-local; v1 refuses a routed ResultServer path that could weaken the Windows egress guard"
    fi
  fi
}
