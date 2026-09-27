#!/usr/bin/env bash

discover_libvirt() {
  LIBVIRT_URI=""; LIBVIRT_DOMAINS=(); LIBVIRT_NETWORKS=()
  if ! have virsh; then add_error "virsh is not installed"; return 0; fi
  LIBVIRT_URI="$(virsh uri 2>/dev/null || true)"
  [[ -n "$LIBVIRT_URI" ]] || add_error "libvirt connection is unavailable"
  mapfile -t LIBVIRT_DOMAINS < <(virsh list --all --name 2>/dev/null | sed '/^$/d')
  mapfile -t LIBVIRT_NETWORKS < <(virsh net-list --all --name 2>/dev/null | sed '/^$/d')
  ((${#LIBVIRT_DOMAINS[@]} > 0)) || add_error "No libvirt domains were found"
}

record_matches_domain() {
  local rec="$1" d section label ip
  section="$(record_field "$rec" section)"; label="$(record_field "$rec" label)"; ip="$(record_field "$rec" ip)"
  for d in "${LIBVIRT_DOMAINS[@]}"; do
    if [[ "$d" == "$section" || "$d" == "$label" ]]; then printf '%s\n' "$d"; return 0; fi
  done
  if [[ -n "$ip" ]]; then
    local -a ip_matches=()
    for d in "${LIBVIRT_DOMAINS[@]}"; do
      if virsh domifaddr "$d" --source agent 2>/dev/null | awk -v ip="$ip" '{split($4,a,"/"); if(a[1]==ip) found=1} END{exit !found}' ||
         virsh domifaddr "$d" --source lease 2>/dev/null | awk -v ip="$ip" '{split($4,a,"/"); if(a[1]==ip) found=1} END{exit !found}'; then
        ip_matches+=("$d")
      fi
    done
    if ((${#ip_matches[@]} == 1)); then
      printf '%s\n' "${ip_matches[0]}"
      return 0
    fi
    # Zero or multiple IP matches are deliberately non-matches. The caller
    # safe-stops rather than selecting the first domain with a reused address.
  fi
  return 1
}

auto_select_cape_machine() {
  [[ -n "${REQUESTED_MACHINE:-}" ]] && { select_machine_by_request "$REQUESTED_MACHINE"; set_selected_machine_fields; return 0; }
  local rec d
  local -a matched_records=()
  for rec in "${CAPE_MACHINE_RECORDS[@]}"; do
    d="$(record_matches_domain "$rec" 2>/dev/null || true)"
    [[ -n "$d" ]] && matched_records+=("$rec")
  done
  if ((${#matched_records[@]} == 1)); then
    SELECTED_MACHINE_JSON="${matched_records[0]}"
  elif ((${#CAPE_MACHINE_RECORDS[@]} == 1)); then
    SELECTED_MACHINE_JSON="${CAPE_MACHINE_RECORDS[0]}"
  else
    local choices=()
    for rec in "${CAPE_MACHINE_RECORDS[@]}"; do choices+=("$(record_field "$rec" section)"); done
    add_error "Could not uniquely auto-select a CAPE analysis machine; candidates: ${choices[*]}"
  fi
  set_selected_machine_fields
}

match_selected_domain() {
  DOMAIN=""
  [[ -n "${SELECTED_MACHINE_JSON:-}" ]] || return 0
  DOMAIN="$(record_matches_domain "$SELECTED_MACHINE_JSON" 2>/dev/null || true)"
  [[ -n "$DOMAIN" ]] || add_error "Could not map selected CAPE machine to a libvirt domain"
}

discover_domain_details() {
  DOMAIN_STATE="unknown"; DOMAIN_NIC_COUNT="unknown"; DOMAIN_NIC_MODELS="unknown"; DOMAIN_XML=""
  [[ -n "${DOMAIN:-}" ]] || return 0
  DOMAIN_STATE="$(virsh domstate "$DOMAIN" 2>/dev/null | head -1 | xargs || true)"
  DOMAIN_XML="$(virsh dumpxml "$DOMAIN" 2>/dev/null || true)"
  read -r DOMAIN_NIC_COUNT DOMAIN_NIC_MODELS < <(ad_python -c '
import sys,xml.etree.ElementTree as ET
xml=sys.stdin.read()
try: root=ET.fromstring(xml)
except Exception:
    print("unknown unknown")
    raise SystemExit
ifs=root.findall("./devices/interface")
models=[]
for i in ifs:
    m=i.find("model")
    if m is not None and m.get("type"): models.append(m.get("type"))
print(len(ifs), ",".join(sorted(set(models))) or "unknown")
' <<<"$DOMAIN_XML")
}


qemu_img_detect_format_readonly() {
  local path="$1" info=""

  # qemu-img normally refuses to inspect an image that a running QEMU process
  # holds with an exclusive write lock. First use the ordinary read-only path;
  # if that is blocked for a live guest, retry with QEMU's explicit shared
  # read-only inspection mode. Never run qemu-img check/convert against a live
  # Windows analysis disk here.
  info="$(qemu-img info --output=json "$path" 2>/dev/null || true)"
  if [[ -z "$info" && "${DOMAIN_STATE:-unknown}" != "shut off" ]]; then
    info="$(qemu-img info --force-share --output=json "$path" 2>/dev/null || true)"
  fi

  ad_python -c '
import json,sys
try:
    print(json.load(sys.stdin).get("format",""))
except Exception:
    pass
' <<<"$info"
}

discover_windows_snapshot_capability() {
  WINDOWS_INTERNAL_SNAPSHOT_CAPABLE=no
  [[ -n "${DOMAIN_XML:-}" && -n "${DOMAIN:-}" ]] || return 0

  local disk_records
  disk_records="$(ad_python -c '
import sys,xml.etree.ElementTree as ET
try: root=ET.fromstring(sys.stdin.read())
except Exception: raise SystemExit
for d in root.findall("./devices/disk"):
    if d.get("device")!="disk":
        continue
    src=d.find("source"); drv=d.find("driver")
    if src is None:
        continue
    path=src.get("file") or ""
    typ=(drv.get("type") if drv is not None else "") or ""
    snap=d.get("snapshot") or "default"
    readonly=d.find("readonly") is not None
    if not readonly:
        print(path+"|"+typ+"|"+snap)
' <<<"$DOMAIN_XML")"

  local -a records=()
  mapfile -t records < <(printf '%s\n' "$disk_records" | sed '/^$/d')
  if ((${#records[@]} == 0)); then
    add_error "Selected Windows domain has no writable file-backed disk eligible for the required internal snapshots"
    return 0
  fi

  local rec path declared snap detected
  for rec in "${records[@]}"; do
    IFS='|' read -r path declared snap <<<"$rec"
    if [[ "$snap" == no ]]; then
      add_error "Windows writable disk is excluded from snapshots; refusing an incomplete analysis/safety snapshot: ${path:-unknown}"
      return 0
    fi
    if [[ -z "$path" || ! -f "$path" ]]; then
      add_error "Windows snapshot preflight requires writable file-backed disks; unsupported disk source detected"
      return 0
    fi
    if ! have qemu-img; then
      add_error "qemu-img is required to prove Windows internal-snapshot capability"
      return 0
    fi
    if [[ "$declared" != qcow2 ]]; then
      add_error "Windows disk driver is not declared qcow2; required shutoff/running internal snapshots are not safely supported: $path"
      return 0
    fi
    detected="$(qemu_img_detect_format_readonly "$path")"
    if [[ -z "$detected" ]]; then
      add_error "Could not safely inspect Windows disk format while proving internal-snapshot capability: $path"
      return 0
    fi
    if [[ "$detected" != qcow2 ]]; then
      add_error "Windows disk is not qcow2; required shutoff/running internal snapshots are not safely supported: $path"
      return 0
    fi
  done

  WINDOWS_INTERNAL_SNAPSHOT_CAPABLE=yes
}

discover_cape_analysis_snapshot() {
  CAPE_ANALYSIS_SNAPSHOT_STATUS="unproven"
  CAPE_ANALYSIS_SNAPSHOT_STATE=""
  CAPE_ANALYSIS_SNAPSHOT_MEMORY=""
  [[ -n "${DOMAIN:-}" ]] || return 0

  # A CAPE machine is allowed to have no preconfigured snapshot. AutoDeploy
  # acquires CAPE-wide maintenance ownership, powers the guest off safely,
  # captures its own pre-change safety snapshot, configures the isolated NIC,
  # and finally creates a new running-state CAPE analysis snapshot. Requiring an
  # old snapshot here would make fresh/legacy CAPE machines impossible to adopt.
  if [[ -z "${CAPE_MACHINE_SNAPSHOT:-}" ]]; then
    CAPE_ANALYSIS_SNAPSHOT_STATUS="not-configured"
    return 0
  fi

  [[ -n "${MANAGEMENT_NETWORK_NAME:-}" && -n "${WINDOWS_MANAGEMENT_MAC:-}" ]] || return 0

  local xml facts
  xml="$(virsh snapshot-dumpxml "$DOMAIN" "$CAPE_MACHINE_SNAPSHOT" 2>/dev/null || true)"
  [[ -n "$xml" ]] || {
    add_error "Configured CAPE analysis snapshot '$CAPE_MACHINE_SNAPSHOT' does not exist for domain '$DOMAIN'"
    return 0
  }

  facts="$(ad_python -c '
import sys,xml.etree.ElementTree as ET
domain,net,mac=sys.argv[1:]
try:
    r=ET.fromstring(sys.stdin.read())
except Exception:
    raise SystemExit(2)
state=(r.findtext("state") or "").strip()
m=r.find("memory")
memory=(m.get("snapshot") if m is not None else "") or ""
d=r.find("domain")
dname=(d.findtext("name") or "").strip() if d is not None else ""
matches=0
if d is not None:
    for i in d.findall("./devices/interface"):
        src=i.find("source"); ma=i.find("mac")
        if src is not None and ma is not None and src.get("network")==net and (ma.get("address") or "").lower()==mac.lower():
            matches += 1
print(state, memory, dname, matches, sep="|")
' "$DOMAIN" "$MANAGEMENT_NETWORK_NAME" "$WINDOWS_MANAGEMENT_MAC" <<<"$xml" 2>/dev/null || true)"

  local snap_state snap_memory snap_domain mgmt_matches
  IFS='|' read -r snap_state snap_memory snap_domain mgmt_matches <<<"$facts"
  CAPE_ANALYSIS_SNAPSHOT_STATE="$snap_state"
  CAPE_ANALYSIS_SNAPSHOT_MEMORY="$snap_memory"

  [[ "$snap_domain" == "$DOMAIN" ]] || {
    add_error "Configured CAPE snapshot '$CAPE_MACHINE_SNAPSHOT' does not embed the selected domain identity"
    return 0
  }
  [[ "$snap_state" == running && ( "$snap_memory" == internal || "$snap_memory" == external ) ]] || {
    add_error "Configured CAPE snapshot '$CAPE_MACHINE_SNAPSHOT' is not a running-state analysis baseline with internal/external saved memory (found state=${snap_state:-unknown} memory=${snap_memory:-unknown})"
    return 0
  }
  [[ "$mgmt_matches" == 1 ]] || {
    add_error "Configured CAPE snapshot '$CAPE_MACHINE_SNAPSHOT' does not contain the proven management NIC identity ($MANAGEMENT_NETWORK_NAME / $WINDOWS_MANAGEMENT_MAC)"
    return 0
  }

  CAPE_ANALYSIS_SNAPSHOT_STATUS="proven"
}

discover_management_network() {
  MANAGEMENT_NETWORK_NAME=""
  [[ -n "${DOMAIN_XML:-}" && -n "${CAPE_MACHINE_IP:-}" && -n "${DOMAIN:-}" ]] || return 0

  # First preference: map the management IP reported by libvirt to the exact
  # interface MAC, then map that MAC back to its source network in domain XML.
  local addr_text mgmt_mac
  addr_text="$(
    { virsh domifaddr "$DOMAIN" --source agent 2>/dev/null || true
      virsh domifaddr "$DOMAIN" --source lease 2>/dev/null || true; } |
    awk -v ip="$CAPE_MACHINE_IP" '{split($4,a,"/"); if(a[1]==ip) print tolower($2)}' | sed '/^$/d' | sort -u
  )"
  mapfile -t _mgmt_macs < <(printf '%s\n' "$addr_text" | sed '/^$/d')
  if ((${#_mgmt_macs[@]} == 1)); then
    mgmt_mac="${_mgmt_macs[0]}"
    MANAGEMENT_NETWORK_NAME="$(ad_python -c '
import sys,xml.etree.ElementTree as ET
mac=sys.argv[1].lower()
try: root=ET.fromstring(sys.stdin.read())
except Exception: raise SystemExit
nets=[]
for i in root.findall("./devices/interface"):
    m=i.find("mac"); s=i.find("source")
    if m is not None and s is not None and (m.get("address") or "").lower()==mac and s.get("network"):
        nets.append(s.get("network"))
if len(set(nets))==1: print(nets[0])
' "$mgmt_mac" <<<"$DOMAIN_XML")"
    [[ -n "$MANAGEMENT_NETWORK_NAME" ]] && return 0
  elif ((${#_mgmt_macs[@]} > 1)); then
    add_error "Multiple libvirt interfaces report CAPE management IP $CAPE_MACHINE_IP"
    return 0
  fi

  # Fallback for guests without QGA/lease visibility: require exactly one
  # attached libvirt network whose declared subnet contains the CAPE IP.
  local candidates
  candidates="$(ad_python -c '
import sys,xml.etree.ElementTree as ET
root=ET.fromstring(sys.stdin.read())
for i in root.findall("./devices/interface"):
    src=i.find("source")
    if src is not None and src.get("network"): print(src.get("network"))
' <<<"$DOMAIN_XML")"
  mapfile -t _mgmt_candidates < <(printf '%s\n' "$candidates" | sed '/^$/d' | sort -u)

  local n netxml match
  local -a subnet_matches=()
  for n in "${_mgmt_candidates[@]}"; do
    netxml="$(virsh net-dumpxml "$n" 2>/dev/null || true)"
    match="$(ad_python -c '
import ipaddress,sys,xml.etree.ElementTree as ET
target=ipaddress.ip_address(sys.argv[1])
try: root=ET.fromstring(sys.stdin.read())
except Exception: raise SystemExit
for x in root.findall("ip"):
    a=x.get("address"); m=x.get("netmask"); p=x.get("prefix")
    if not a: continue
    try: net=ipaddress.ip_network(f"{a}/{p or m}",strict=False)
    except Exception: continue
    if target in net:
        print("yes")
        break
' "$CAPE_MACHINE_IP" <<<"$netxml")"
    [[ "$match" == yes ]] && subnet_matches+=("$n")
  done

  if ((${#subnet_matches[@]} == 1)); then
    MANAGEMENT_NETWORK_NAME="${subnet_matches[0]}"
  elif ((${#subnet_matches[@]} > 1)); then
    add_error "Multiple attached libvirt networks contain CAPE management IP $CAPE_MACHINE_IP"
  else
    add_error "Could not prove the libvirt management network for $CAPE_MACHINE_IP"
  fi
}
discover_management_network_details() {
  MANAGEMENT_BRIDGE_NAME=""
  WINDOWS_MANAGEMENT_MAC=""
  [[ -n "${MANAGEMENT_NETWORK_NAME:-}" && -n "${DOMAIN_XML:-}" ]] || return 0

  local netxml
  netxml="$(virsh net-dumpxml "$MANAGEMENT_NETWORK_NAME" 2>/dev/null || true)"
  MANAGEMENT_BRIDGE_NAME="$(ad_python -c '
import sys,xml.etree.ElementTree as ET
try: r=ET.fromstring(sys.stdin.read())
except Exception: raise SystemExit
b=r.find("bridge")
print((b.get("name") or "") if b is not None else "")
' <<<"$netxml")"

  WINDOWS_MANAGEMENT_MAC="$(ad_python -c '
import sys,xml.etree.ElementTree as ET
net=sys.argv[1]
try: r=ET.fromstring(sys.stdin.read())
except Exception: raise SystemExit
macs=[]
for i in r.findall("./devices/interface"):
    src=i.find("source"); mac=i.find("mac")
    if src is not None and src.get("network")==net and mac is not None and mac.get("address"):
        macs.append(mac.get("address").lower())
if len(macs)==1: print(macs[0])
' "$MANAGEMENT_NETWORK_NAME" <<<"$DOMAIN_XML")"

  [[ -n "$MANAGEMENT_BRIDGE_NAME" ]] || add_error "Could not derive bridge name for management libvirt network $MANAGEMENT_NETWORK_NAME"
  [[ -n "$WINDOWS_MANAGEMENT_MAC" ]] || add_error "Could not uniquely derive Windows management NIC MAC on $MANAGEMENT_NETWORK_NAME"
}

NWFILTER_DEFINITION_ROOT="${NWFILTER_DEFINITION_ROOT:-}"

nwfilter_clean_traffic_definition_present() {
  nwfilter_find_definition clean-traffic >/dev/null
}

discover_hypervisor_safety_features() {
  MANAGEMENT_NWFILTER_AVAILABLE=no
  NWFILTER_RUNTIME_MODE=unavailable

  if virsh nwfilter-dumpxml clean-traffic >/dev/null 2>&1; then
    MANAGEMENT_NWFILTER_AVAILABLE=yes
    NWFILTER_RUNTIME_MODE=ready
    return 0
  fi

  # Modern libvirt can run nwfilter as a modular daemon. A standard
  # clean-traffic XML already installed on disk is a valid source of truth even
  # when the daemon has not loaded it yet. Deployment may transactionally start
  # the modular runtime and, if necessary, ask libvirt to define the packaged
  # dependency closure before any Windows/CAPE cutover.
  if nwfilter_clean_traffic_definition_present; then
    if [[ "$(systemctl show -p LoadState --value virtnwfilterd.socket 2>/dev/null || true)" == loaded ]]; then
      MANAGEMENT_NWFILTER_AVAILABLE=activatable
      NWFILTER_RUNTIME_MODE=modular-socket
      return 0
    fi
    if [[ "$(systemctl show -p LoadState --value virtnwfilterd.service 2>/dev/null || true)" == loaded ]]; then
      MANAGEMENT_NWFILTER_AVAILABLE=activatable
      NWFILTER_RUNTIME_MODE=modular-service
      return 0
    fi
    if virsh help nwfilter-define >/dev/null 2>&1; then
      MANAGEMENT_NWFILTER_AVAILABLE=activatable
      NWFILTER_RUNTIME_MODE=definition-reload
      return 0
    fi
  fi

  add_error "libvirt nwfilter 'clean-traffic' is unavailable and no safely activatable standard definition/runtime was proven; hypervisor anti-spoofing cannot be guaranteed"
}
