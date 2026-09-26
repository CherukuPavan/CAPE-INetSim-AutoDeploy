#!/usr/bin/env bash

# Multi-machine target model.
#
# Default AutoDeploy behavior is to manage every enabled Windows-compatible
# CAPE KVM analysis machine that maps uniquely to a libvirt domain. --machine
# remains an explicit single-machine override for troubleshooting/controlled use.
#
# CAPE_TARGETS_JSON is both the in-memory discovery model and the persisted
# per-target transaction model. The resource ledger remains authoritative for
# ownership; this JSON stores the per-domain values needed to resume/rollback.

CAPE_TARGETS_JSON="${CAPE_TARGETS_JSON:-[]}"
CAPE_TARGETS_COUNT="${CAPE_TARGETS_COUNT:-0}"
TARGET_INDEX="${TARGET_INDEX:-}"

targets_count() {
  python3 - "${CAPE_TARGETS_JSON:-[]}" <<'PY'
import json,sys
try: print(len(json.loads(sys.argv[1])))
except Exception: print(0)
PY
}

targets_get() {
  local index="$1" key="$2"
  python3 - "${CAPE_TARGETS_JSON:-[]}" "$index" "$key" <<'PY'
import json,sys
a=json.loads(sys.argv[1]); i=int(sys.argv[2]); k=sys.argv[3]
v=a[i].get(k,"")
if v is None: v=""
if isinstance(v,(dict,list)): print(json.dumps(v,separators=(",",":")))
else: print(str(v))
PY
}

targets_bind() {
  local index="$1"
  local assignments
  assignments="$(python3 - "${CAPE_TARGETS_JSON:-[]}" "$index" <<'PY'
import json,shlex,sys
a=json.loads(sys.argv[1]); i=int(sys.argv[2]); d=a[i]
mapping={
 "section":"CAPE_MACHINE_SECTION",
 "label":"CAPE_MACHINE_LABEL",
 "ip":"CAPE_MACHINE_IP",
 "original_snapshot":"CAPE_MACHINE_SNAPSHOT",
 "normal_snapshot":"NORMAL_SNAPSHOT",
 "interface":"CAPE_MACHINE_INTERFACE",
 "platform":"CAPE_MACHINE_PLATFORM",
 "domain":"DOMAIN",
 "domain_state":"DOMAIN_STATE",
 "domain_nic_count":"DOMAIN_NIC_COUNT",
 "domain_nic_models":"DOMAIN_NIC_MODELS",
 "snapshot_capable":"WINDOWS_INTERNAL_SNAPSHOT_CAPABLE",
 "analysis_snapshot_status":"CAPE_ANALYSIS_SNAPSHOT_STATUS",
 "analysis_snapshot_state":"CAPE_ANALYSIS_SNAPSHOT_STATE",
 "analysis_snapshot_memory":"CAPE_ANALYSIS_SNAPSHOT_MEMORY",
 "management_network":"MANAGEMENT_NETWORK_NAME",
 "management_bridge":"MANAGEMENT_BRIDGE_NAME",
 "management_mac":"WINDOWS_MANAGEMENT_MAC",
 "resultserver_ip":"CAPE_RESULTSERVER_IP",
 "resultserver_port":"CAPE_RESULTSERVER_PORT",
 "control_host_ip":"CONTROL_HOST_IP",
 "qga_available":"QGA_AVAILABLE",
 "winrm_available":"WINRM_AVAILABLE",
 "cape_agent_reachable":"CAPE_AGENT_REACHABLE",
 "backend_discovered":"WINDOWS_BACKEND",
 "fake_ip":"WINDOWS_FAKE_IP",
 "isolated_nic_model":"WINDOWS_ISOLATED_NIC_MODEL",
 "isolated_mac":"WINDOWS_ISOLATED_MAC",
 "backend_used":"WINDOWS_BACKEND_USED",
 "original_domain_state":"WINDOWS_ORIGINAL_DOMAIN_STATE",
 "safety_snapshot":"SAFETY_SNAPSHOT",
 "working_snapshot":"WORKING_SNAPSHOT",
 "final_snapshot":"FINAL_SNAPSHOT",
 "phase":"TARGET_PHASE",
}
for key,var in mapping.items():
    v=d.get(key,"")
    if key=="normal_snapshot" and not v:
        v=d.get("original_snapshot","")
    if v is None: v=""
    print(f"{var}={shlex.quote(str(v))}")
print(f"TARGET_INDEX={i}")
PY
)"
  eval "$assignments"
}

targets_capture_bound() {
  local index="${1:-${TARGET_INDEX:-}}"
  [[ "$index" =~ ^[0-9]+$ ]] || return 0
  CAPE_TARGETS_JSON="$(python3 - "${CAPE_TARGETS_JSON:-[]}" "$index"     "${WINDOWS_ISOLATED_NIC_MODEL:-}" "${WINDOWS_ISOLATED_MAC:-}"     "${WINDOWS_BACKEND_USED:-}" "${WINDOWS_ORIGINAL_DOMAIN_STATE:-}"     "${SAFETY_SNAPSHOT:-}" "${WORKING_SNAPSHOT:-}" "${FINAL_SNAPSHOT:-}" "${NORMAL_SNAPSHOT:-}"     "${TARGET_PHASE:-discovered}" <<'PY'
import json,sys
a=json.loads(sys.argv[1]); i=int(sys.argv[2])
keys=("isolated_nic_model","isolated_mac","backend_used","original_domain_state",
      "safety_snapshot","working_snapshot","final_snapshot","normal_snapshot","phase")
for k,v in zip(keys,sys.argv[3:]):
    a[i][k]=v
print(json.dumps(a,separators=(",",":")))
PY
)"
  CAPE_TARGETS_COUNT="$(targets_count)"
}

targets_identity_json() {
  python3 - "${CAPE_TARGETS_JSON:-[]}" <<'PY'
import json,sys
a=json.loads(sys.argv[1])
keys=("section","label","ip","platform","domain",
      "management_network","management_bridge","management_mac",
      "resultserver_ip","resultserver_port","control_host_ip")
out=[{k:d.get(k,"") for k in keys} for d in a]
print(json.dumps(out,sort_keys=True,separators=(",",":")))
PY
}

targets_identity_sha256() {
  python3 - "$(targets_identity_json)" <<'PY'
import hashlib,sys
print(hashlib.sha256(sys.argv[1].encode()).hexdigest())
PY
}

targets_append_current() {
  local target_errors_json="${1:-[]}"
  CAPE_TARGETS_JSON="$(python3 - "${CAPE_TARGETS_JSON:-[]}"     "${CAPE_MACHINE_SECTION:-}" "${CAPE_MACHINE_LABEL:-}" "${CAPE_MACHINE_IP:-}"     "${CAPE_MACHINE_SNAPSHOT:-}" "${CAPE_MACHINE_INTERFACE:-}" "${CAPE_MACHINE_PLATFORM:-}"     "${DOMAIN:-}" "${DOMAIN_STATE:-}" "${DOMAIN_NIC_COUNT:-}" "${DOMAIN_NIC_MODELS:-}"     "${WINDOWS_INTERNAL_SNAPSHOT_CAPABLE:-no}"     "${CAPE_ANALYSIS_SNAPSHOT_STATUS:-unproven}" "${CAPE_ANALYSIS_SNAPSHOT_STATE:-}" "${CAPE_ANALYSIS_SNAPSHOT_MEMORY:-}"     "${MANAGEMENT_NETWORK_NAME:-}" "${MANAGEMENT_BRIDGE_NAME:-}" "${WINDOWS_MANAGEMENT_MAC:-}"     "${CAPE_RESULTSERVER_IP:-}" "${CAPE_RESULTSERVER_PORT:-}" "${CONTROL_HOST_IP:-}"     "${QGA_AVAILABLE:-unknown}" "${WINRM_AVAILABLE:-unknown}" "${CAPE_AGENT_REACHABLE:-unknown}" "${WINDOWS_BACKEND:-unknown}"     "$target_errors_json" <<'PY'
import json,sys
a=json.loads(sys.argv[1])
vals=sys.argv[2:]
keys=("section","label","ip","original_snapshot","interface","platform",
      "domain","domain_state","domain_nic_count","domain_nic_models","snapshot_capable",
      "analysis_snapshot_status","analysis_snapshot_state","analysis_snapshot_memory",
      "management_network","management_bridge","management_mac",
      "resultserver_ip","resultserver_port","control_host_ip",
      "qga_available","winrm_available","cape_agent_reachable","backend_discovered")
d=dict(zip(keys,vals[:len(keys)]))
try: d["errors"]=json.loads(vals[len(keys)])
except Exception: d["errors"]=[]
d.update({
 "fake_ip":"","isolated_nic_model":"","isolated_mac":"","backend_used":"",
 "original_domain_state":"","safety_snapshot":"","working_snapshot":"","final_snapshot":"",
 "phase":"discovered"
})
a.append(d)
print(json.dumps(a,separators=(",",":")))
PY
)"
}

targets_assign_fake_ips() {
  [[ -n "${ISOLATED_SUBNET:-}" ]] || return 0
  CAPE_TARGETS_JSON="$(python3 - "${CAPE_TARGETS_JSON:-[]}" "$ISOLATED_SUBNET" <<'PY'
import ipaddress,json,sys
a=json.loads(sys.argv[1]); net=ipaddress.ip_network(sys.argv[2])
if len(a) > 240:
    raise SystemExit("too many CAPE Windows analysis machines for one /24 isolated network")
for i,d in enumerate(a):
    d["fake_ip"]=str(net.network_address + 10 + i)
print(json.dumps(a,separators=(",",":")))
PY
)" || {
    add_error "Too many CAPE Windows analysis machines for the isolated /24 network"
    return 0
  }
}

targets_validate_uniqueness() {
  local report
  report="$(python3 - "${CAPE_TARGETS_JSON:-[]}" <<'PY'
import collections,json,sys
a=json.loads(sys.argv[1])
for key,label in (("section","CAPE section"),("label","CAPE label"),("domain","libvirt domain"),("ip","management IP")):
    c=collections.Counter(str(d.get(key,"")) for d in a if str(d.get(key,"")))
    for value,n in c.items():
        if n>1: print(f"{label} is not unique across enabled analysis machines: {value}")
PY
)"
  if [[ -n "$report" ]]; then
    while IFS= read -r line; do [[ -n "$line" ]] && add_error "$line"; done <<<"$report"
  fi
}

targets_discover_all() {
  CAPE_TARGETS_JSON='[]'
  CAPE_TARGETS_COUNT=0
  TARGET_INDEX=""

  local rec section label
  local -a wanted=()
  if [[ -n "${REQUESTED_MACHINE:-}" ]]; then
    for rec in "${CAPE_MACHINE_RECORDS[@]}"; do
      section="$(record_field "$rec" section)"
      label="$(record_field "$rec" label)"
      if [[ "$REQUESTED_MACHINE" == "$section" || "$REQUESTED_MACHINE" == "$label" ]]; then
        wanted+=("$rec")
      fi
    done
    if ((${#wanted[@]} == 0)); then
      add_error "Requested CAPE machine '$REQUESTED_MACHINE' was not found"
      return 0
    elif ((${#wanted[@]} > 1)); then
      add_error "Requested CAPE machine '$REQUESTED_MACHINE' is ambiguous"
      return 0
    fi
  else
    wanted=("${CAPE_MACHINE_RECORDS[@]}")
  fi

  if ((${#wanted[@]} == 0)); then
    add_error "No enabled Windows-compatible CAPE analysis machines were discovered"
    return 0
  fi

  local -a outer_errors=("${DISCOVERY_ERRORS[@]}")
  DISCOVERY_ERRORS=()
  for rec in "${wanted[@]}"; do
    SELECTED_MACHINE_JSON="$rec"
    set_selected_machine_fields
    [[ -n "${CAPE_MACHINE_PLATFORM:-}" ]] || CAPE_MACHINE_PLATFORM="windows-unspecified"

    DOMAIN=""; DOMAIN_XML=""; DOMAIN_STATE="unknown"
    DOMAIN_NIC_COUNT="unknown"; DOMAIN_NIC_MODELS="unknown"
    WINDOWS_INTERNAL_SNAPSHOT_CAPABLE=no
    MANAGEMENT_NETWORK_NAME=""; MANAGEMENT_BRIDGE_NAME=""; WINDOWS_MANAGEMENT_MAC=""
    CAPE_RESULTSERVER_IP=""; CAPE_RESULTSERVER_PORT=""; CONTROL_HOST_IP=""
    CAPE_ANALYSIS_SNAPSHOT_STATUS="unproven"; CAPE_ANALYSIS_SNAPSHOT_STATE=""; CAPE_ANALYSIS_SNAPSHOT_MEMORY=""
    QGA_AVAILABLE="unknown"; WINRM_AVAILABLE="unknown"; CAPE_AGENT_REACHABLE="unknown"; WINDOWS_BACKEND="deferred-probe"

    DISCOVERY_ERRORS=()
    match_selected_domain
    discover_domain_details
    discover_windows_snapshot_capability
    discover_management_network
    discover_management_network_details
    discover_resultserver
    discover_cape_analysis_snapshot
    discover_windows_backends

    local target_errors_json
    target_errors_json="$(python3 - "${DISCOVERY_ERRORS[@]}" <<'PY'
import json,sys
print(json.dumps(sys.argv[1:],separators=(",",":")))
PY
)"
    targets_append_current "$target_errors_json"

    local err
    for err in "${DISCOVERY_ERRORS[@]}"; do
      outer_errors+=("[${CAPE_MACHINE_SECTION:-unknown}] $err")
    done
  done

  DISCOVERY_ERRORS=("${outer_errors[@]}")
  CAPE_TARGETS_COUNT="$(targets_count)"
  targets_validate_uniqueness
}

targets_prepare_after_network_plan() {
  # The isolated subnet belongs only to the host bridge and INetSim appliance.
  # Windows guests keep their original CAPE management identities.
  CAPE_TARGETS_COUNT="$(targets_count)"
  if ((CAPE_TARGETS_COUNT > 0)); then
    targets_bind 0
  fi
}

targets_for_each_index() {
  local i
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    printf '%s\n' "$i"
  done
}

targets_summary_lines() {
  python3 - "${CAPE_TARGETS_JSON:-[]}" <<'PY'
import json,sys
a=json.loads(sys.argv[1])
for i,d in enumerate(a,1):
    err=d.get("errors") or []
    status="ready" if not err else "blocked"
    snap=d.get("final_snapshot") or d.get("original_snapshot") or "<none>"
    print(f"{i}. {d.get('section','?')} -> {d.get('domain','?')} | mgmt={d.get('ip','?')} | INetSim=per-task-host-route | snapshot={snap} | {status}")
PY
}

target_state_set_phase() {
  TARGET_PHASE="$1"
  targets_capture_bound "${TARGET_INDEX:-0}"
  state_write_atomic
}

targets_all_phase_at_least() {
  local want="$1"
  python3 - "${CAPE_TARGETS_JSON:-[]}" "$want" <<'PY'
import json,sys
order={"discovered":0,"nic-attached":10,"configured":20,"snapshots-ready":30,"cape-configured":40}
a=json.loads(sys.argv[1]); want=sys.argv[2]
w=order.get(want,-1)
if w < 0: raise SystemExit(2)
raise SystemExit(0 if a and all(order.get(d.get("phase","discovered"),-1) >= w for d in a) else 1)
PY
}
