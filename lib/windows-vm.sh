#!/usr/bin/env bash

windows_existing_network_interfaces() {
  local dom="$1"
  virsh dumpxml "$dom" | python3 -c '
import sys,xml.etree.ElementTree as ET
root=ET.fromstring(sys.stdin.read())
for i in root.findall("./devices/interface"):
    src=i.find("source"); mac=i.find("mac"); model=i.find("model")
    if src is None: continue
    network=src.get("network","")
    bridge=src.get("bridge","")
    print("|".join([network,bridge,mac.get("address","") if mac is not None else "",model.get("type","") if model is not None else ""]))
'
}

windows_choose_nic_model() {
  local records model
  records="$(windows_existing_network_interfaces "$DOMAIN")"
  model="$(awk -F '|' 'NF>=4 && $4!="" {print $4; exit}' <<<"$records")"
  [[ -n "$model" ]] || { fail "Could not determine Windows NIC model from existing domain"; return 1; }
  WINDOWS_ISOLATED_NIC_MODEL="$model"
}

windows_find_isolated_mac() {
  windows_existing_network_interfaces "$DOMAIN" | awk -F '|' -v n="$ISOLATED_NETWORK_NAME" '$1==n {print $3}'
}

windows_attach_isolated_nic() {
  [[ "$(virsh domstate "$DOMAIN" | xargs)" == "shut off" ]] || { fail "Windows domain must be shut off before persistent NIC attachment"; return 1; }
  isolated_network_defaults
  windows_choose_nic_model

  local -a macs=()
  mapfile -t macs < <(windows_find_isolated_mac | sed '/^$/d')
  if ((${#macs[@]} == 1)); then
    if [[ -n "${WINDOWS_ISOLATED_MAC:-}" && "${WINDOWS_ISOLATED_MAC,,}" == "${macs[0],,}" ]] && state_resource_owned domain-interface "$DOMAIN:${macs[0]}"; then
      pass "Windows isolated NIC already attached and owned"
      return 0
    fi
    fail "Domain already has an unowned/untracked interface on $ISOLATED_NETWORK_NAME"
    return 1
  elif ((${#macs[@]} > 1)); then
    fail "Domain has multiple interfaces on $ISOLATED_NETWORK_NAME"
    return 1
  fi

  virsh attach-interface --domain "$DOMAIN" --type network --source "$ISOLATED_NETWORK_NAME" --model "$WINDOWS_ISOLATED_NIC_MODEL" --config >/dev/null
  mapfile -t macs < <(windows_find_isolated_mac | sed '/^$/d')
  ((${#macs[@]} == 1)) || { fail "Could not identify newly attached isolated NIC"; return 1; }
  WINDOWS_ISOLATED_MAC="${macs[0],,}"
  state_record_resource domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC" attached yes "network=$ISOLATED_NETWORK_NAME model=$WINDOWS_ISOLATED_NIC_MODEL"
  state_write_atomic
  pass "Attached isolated NIC $WINDOWS_ISOLATED_MAC using model $WINDOWS_ISOLATED_NIC_MODEL"
}

windows_detach_isolated_nic() {
  [[ -n "${WINDOWS_ISOLATED_MAC:-}" ]] || return 0
  if ! state_resource_owned domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC"; then
    fail "Refusing to detach unowned Windows NIC $WINDOWS_ISOLATED_MAC"
    return 1
  fi
  if windows_find_isolated_mac | grep -Fqi "$WINDOWS_ISOLATED_MAC"; then
    [[ "$(virsh domstate "$DOMAIN" | xargs)" == "shut off" ]] || { fail "Windows domain must be shut off before NIC rollback"; return 1; }
    virsh detach-interface --domain "$DOMAIN" --type network --mac "$WINDOWS_ISOLATED_MAC" --config >/dev/null
  fi
  state_record_resource domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC" removed-by-rollback yes ""
}

windows_snapshot_exists() { virsh snapshot-info "$DOMAIN" "$1" >/dev/null 2>&1; }

windows_create_safety_snapshot() {
  [[ "$(virsh domstate "$DOMAIN" | xargs)" == "shut off" ]] || { fail "Safety snapshot requires shut-off domain"; return 1; }
  if [[ -z "${SAFETY_SNAPSHOT:-}" ]]; then
    SAFETY_SNAPSHOT="cape-inetsim-pre-${DEPLOYMENT_ID:0:24}"
  fi
  if windows_snapshot_exists "$SAFETY_SNAPSHOT"; then
    state_resource_owned snapshot "$DOMAIN:$SAFETY_SNAPSHOT" || { fail "Safety snapshot name already exists but is not owned"; return 1; }
    return 0
  fi
  virsh snapshot-create-as "$DOMAIN" "$SAFETY_SNAPSHOT" --description "CAPE-INetSim AutoDeploy pre-change snapshot $DEPLOYMENT_ID" >/dev/null
  state_record_resource snapshot "$DOMAIN:$SAFETY_SNAPSHOT" created yes "state=shutoff purpose=safety"
  state_write_atomic
}

snapshot_state_memory() {
  local snap="$1"
  virsh snapshot-dumpxml "$DOMAIN" "$snap" | python3 -c '
import sys,xml.etree.ElementTree as ET
r=ET.fromstring(sys.stdin.read())
state=r.findtext("state") or ""
m=r.find("memory")
print(state+"|"+(m.get("snapshot","") if m is not None else ""))
'
}

windows_create_running_snapshot() {
  [[ "$(virsh domstate "$DOMAIN" | xargs)" == "running" ]] || { fail "Final CAPE snapshot must be created while Windows is running"; return 1; }
  if [[ -z "${FINAL_SNAPSHOT:-}" ]]; then FINAL_SNAPSHOT="cape-inetsim-ready-${DEPLOYMENT_ID:0:22}"; fi
  if windows_snapshot_exists "$FINAL_SNAPSHOT"; then
    state_resource_owned snapshot "$DOMAIN:$FINAL_SNAPSHOT" || { fail "Final snapshot name already exists but is not owned"; return 1; }
  else
    virsh snapshot-create-as "$DOMAIN" "$FINAL_SNAPSHOT" --description "CAPE-INetSim AutoDeploy running analysis snapshot $DEPLOYMENT_ID" >/dev/null
    state_record_resource snapshot "$DOMAIN:$FINAL_SNAPSHOT" created yes "state=running purpose=cape-analysis"
  fi
  local facts
  facts="$(snapshot_state_memory "$FINAL_SNAPSHOT")"
  [[ "$facts" == "running|internal" ]] || { fail "Final snapshot is not running-state with internal memory: $facts"; return 1; }
  state_write_atomic
  pass "Created CAPE-ready running snapshot $FINAL_SNAPSHOT"
}
