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

windows_mac_in_use() {
  local want="${1,,}" d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    virsh dumpxml "$d" 2>/dev/null | grep -Eiq "<mac[[:space:]]+address=['\"]$want['\"]" && return 0
  done < <(virsh list --all --name 2>/dev/null)
  return 1
}

windows_choose_isolated_mac() {
  [[ -n "${WINDOWS_ISOLATED_MAC:-}" ]] && return 0
  local i candidate
  for i in $(seq 0 255); do
    candidate="$(python3 - "$DEPLOYMENT_ID" "$DOMAIN" "$i" <<'PY'
import hashlib,sys
h=hashlib.sha256(("|".join(sys.argv[1:])).encode()).digest()
print("52:54:00:%02x:%02x:%02x"%(h[0],h[1],h[2]))
PY
)"
    if ! windows_mac_in_use "$candidate"; then
      WINDOWS_ISOLATED_MAC="$candidate"
      state_write_atomic
      return 0
    fi
  done
  fail "Could not allocate an unused deterministic MAC for the Windows isolated NIC"
  return 1
}

windows_attach_isolated_nic() {
  [[ "$(virsh domstate "$DOMAIN" | xargs)" == "shut off" ]] || { fail "Windows domain must be shut off before persistent NIC attachment"; return 1; }
  isolated_network_defaults
  windows_choose_nic_model
  windows_choose_isolated_mac

  local -a macs=()
  mapfile -t macs < <(windows_find_isolated_mac | sed '/^$/d')
  if ((${#macs[@]} > 0)); then
    if ((${#macs[@]} == 1)) && [[ "${macs[0],,}" == "${WINDOWS_ISOLATED_MAC,,}" ]]; then
      if state_resource_owned domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC"; then
        pass "Windows isolated NIC already attached and owned"
        return 0
      fi
      if state_resource_intended domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC"; then
        state_record_resource domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC" recovered-attached yes "network=$ISOLATED_NETWORK_NAME model=$WINDOWS_ISOLATED_NIC_MODEL"
        state_write_atomic
        pass "Recovered deployment-owned Windows NIC after interrupted attach"
        return 0
      fi
    fi
    fail "Domain already has an unowned/untracked interface on $ISOLATED_NETWORK_NAME"
    return 1
  fi

  state_record_intent domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC" attaching "network=$ISOLATED_NETWORK_NAME model=$WINDOWS_ISOLATED_NIC_MODEL"
  if ! virsh attach-interface --domain "$DOMAIN" --type network --source "$ISOLATED_NETWORK_NAME" --model "$WINDOWS_ISOLATED_NIC_MODEL" --mac "$WINDOWS_ISOLATED_MAC" --config >/dev/null; then
    return 1
  fi

  mapfile -t macs < <(windows_find_isolated_mac | sed '/^$/d')
  ((${#macs[@]} == 1)) && [[ "${macs[0],,}" == "${WINDOWS_ISOLATED_MAC,,}" ]] || {
    fail "Could not verify newly attached isolated NIC"
    return 1
  }
  state_record_resource domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC" attached yes "network=$ISOLATED_NETWORK_NAME model=$WINDOWS_ISOLATED_NIC_MODEL"
  state_write_atomic
  pass "Attached isolated NIC $WINDOWS_ISOLATED_MAC using model $WINDOWS_ISOLATED_NIC_MODEL"
}

windows_detach_isolated_nic() {
  [[ -n "${WINDOWS_ISOLATED_MAC:-}" ]] || return 0
  if ! state_resource_owned domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC"; then
    if state_resource_intended domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC" &&
       windows_find_isolated_mac | grep -Fqi "$WINDOWS_ISOLATED_MAC"; then
      state_record_resource domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC" recovered-attached yes "rollback-adoption"
    else
      fail "Refusing to detach unowned Windows NIC $WINDOWS_ISOLATED_MAC"
      return 1
    fi
  fi
  if windows_find_isolated_mac | grep -Fqi "$WINDOWS_ISOLATED_MAC"; then
    [[ "$(virsh domstate "$DOMAIN" | xargs)" == "shut off" ]] || { fail "Windows domain must be shut off before NIC rollback"; return 1; }
    virsh detach-interface --domain "$DOMAIN" --type network --mac "$WINDOWS_ISOLATED_MAC" --config >/dev/null
  fi
  state_record_resource domain-interface "$DOMAIN:$WINDOWS_ISOLATED_MAC" removed-by-rollback yes ""
}

windows_snapshot_exists() { virsh snapshot-info "$DOMAIN" "$1" >/dev/null 2>&1; }

windows_snapshot_description() {
  virsh snapshot-dumpxml "$DOMAIN" "$1" 2>/dev/null | python3 -c '
import sys,xml.etree.ElementTree as ET
try: r=ET.fromstring(sys.stdin.read())
except Exception: raise SystemExit
print(r.findtext("description") or "")
'
}

windows_snapshot_adopt_if_intended() {
  local snap="$1" expected_description="$2" expected_facts="$3"
  state_resource_intended snapshot "$DOMAIN:$snap" || return 1
  [[ "$(windows_snapshot_description "$snap")" == "$expected_description" ]] || return 1
  [[ "$(snapshot_state_memory "$snap")" == "$expected_facts" ]] || return 1
  state_record_resource snapshot "$DOMAIN:$snap" recovered-created yes "facts=$expected_facts"
  state_write_atomic
  return 0
}

windows_create_safety_snapshot() {
  [[ "$(virsh domstate "$DOMAIN" | xargs)" == "shut off" ]] || { fail "Safety snapshot requires shut-off domain"; return 1; }
  if [[ -z "${SAFETY_SNAPSHOT:-}" ]]; then
    SAFETY_SNAPSHOT="cape-inetsim-pre-${DEPLOYMENT_ID:0:24}"
    state_write_atomic
  fi
  local desc="CAPE-INetSim AutoDeploy pre-change snapshot $DEPLOYMENT_ID"
  if windows_snapshot_exists "$SAFETY_SNAPSHOT"; then
    if state_resource_owned snapshot "$DOMAIN:$SAFETY_SNAPSHOT"; then
      [[ "$(windows_snapshot_description "$SAFETY_SNAPSHOT")" == "$desc" ]] || { fail "Owned safety snapshot description mismatch"; return 1; }
      [[ "$(snapshot_state_memory "$SAFETY_SNAPSHOT")" == "shutoff|no" ]] || { fail "Owned safety snapshot state mismatch"; return 1; }
      return 0
    fi
    windows_snapshot_adopt_if_intended "$SAFETY_SNAPSHOT" "$desc" "shutoff|no" || {
      fail "Safety snapshot name already exists but is not safely attributable to this deployment"
      return 1
    }
    return 0
  fi
  state_record_intent snapshot "$DOMAIN:$SAFETY_SNAPSHOT" creating "state=shutoff purpose=safety"
  virsh snapshot-create-as "$DOMAIN" "$SAFETY_SNAPSHOT" --description "$desc" --atomic >/dev/null
  [[ "$(snapshot_state_memory "$SAFETY_SNAPSHOT")" == "shutoff|no" ]] || { fail "Safety snapshot state mismatch after create"; return 1; }
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

windows_create_working_snapshot() {
  [[ "$(virsh domstate "$DOMAIN" | xargs)" == "shut off" ]] || { fail "Configured rollback snapshot requires shut-off Windows domain"; return 1; }
  if [[ -z "${WORKING_SNAPSHOT:-}" ]]; then
    WORKING_SNAPSHOT="cape-inetsim-working-${DEPLOYMENT_ID:0:20}"
    state_write_atomic
  fi
  local desc="CAPE-INetSim AutoDeploy configured rollback snapshot $DEPLOYMENT_ID"
  if windows_snapshot_exists "$WORKING_SNAPSHOT"; then
    if ! state_resource_owned snapshot "$DOMAIN:$WORKING_SNAPSHOT"; then
      windows_snapshot_adopt_if_intended "$WORKING_SNAPSHOT" "$desc" "shutoff|no" || {
        fail "Working snapshot name exists but is not safely attributable to this deployment"
        return 1
      }
    fi
  else
    state_record_intent snapshot "$DOMAIN:$WORKING_SNAPSHOT" creating "state=shutoff purpose=configured-rollback"
    virsh snapshot-create-as "$DOMAIN" "$WORKING_SNAPSHOT" --description "$desc" --atomic >/dev/null
    state_record_resource snapshot "$DOMAIN:$WORKING_SNAPSHOT" created yes "state=shutoff purpose=configured-rollback"
  fi
  local facts
  facts="$(snapshot_state_memory "$WORKING_SNAPSHOT")"
  [[ "$facts" == "shutoff|no" ]] || { fail "Working snapshot did not capture shutoff/no-memory state: $facts"; return 1; }
  [[ "$(windows_snapshot_description "$WORKING_SNAPSHOT")" == "$desc" ]] || { fail "Working snapshot description mismatch"; return 1; }
  state_write_atomic
  pass "Created configured shutoff rollback snapshot $WORKING_SNAPSHOT"
}

windows_create_running_snapshot() {
  [[ "$(virsh domstate "$DOMAIN" | xargs)" == "running" ]] || { fail "Final CAPE snapshot must be created while Windows is running"; return 1; }
  if [[ -z "${FINAL_SNAPSHOT:-}" ]]; then
    FINAL_SNAPSHOT="cape-inetsim-ready-${DEPLOYMENT_ID:0:22}"
    state_write_atomic
  fi
  local desc="CAPE-INetSim AutoDeploy running analysis snapshot $DEPLOYMENT_ID"
  if windows_snapshot_exists "$FINAL_SNAPSHOT"; then
    if ! state_resource_owned snapshot "$DOMAIN:$FINAL_SNAPSHOT"; then
      windows_snapshot_adopt_if_intended "$FINAL_SNAPSHOT" "$desc" "running|internal" || {
        fail "Final snapshot name exists but is not safely attributable to this deployment"
        return 1
      }
    fi
  else
    state_record_intent snapshot "$DOMAIN:$FINAL_SNAPSHOT" creating "state=running purpose=cape-analysis"
    virsh snapshot-create-as "$DOMAIN" "$FINAL_SNAPSHOT" --description "$desc" --atomic >/dev/null
    state_record_resource snapshot "$DOMAIN:$FINAL_SNAPSHOT" created yes "state=running purpose=cape-analysis"
  fi
  local facts
  facts="$(snapshot_state_memory "$FINAL_SNAPSHOT")"
  [[ "$facts" == "running|internal" ]] || { fail "Final snapshot is not running-state with internal memory: $facts"; return 1; }
  [[ "$(windows_snapshot_description "$FINAL_SNAPSHOT")" == "$desc" ]] || { fail "Final snapshot description mismatch"; return 1; }
  state_write_atomic
  pass "Created CAPE-ready running snapshot $FINAL_SNAPSHOT"
}


windows_stop_for_cutover() {
  local state
  state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
  WINDOWS_ORIGINAL_DOMAIN_STATE="${WINDOWS_ORIGINAL_DOMAIN_STATE:-$state}"
  state_write_atomic
  case "$state" in
    "shut off") return 0 ;;
    running)
      virsh shutdown "$DOMAIN" >/dev/null 2>&1 || true
      local i
      for ((i=0;i<60;i+=2)); do
        [[ "$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)" == "shut off" ]] && return 0
        sleep 2
      done
      fail "Windows domain is running but did not shut down cleanly; refusing forced cutover"
      return 1
      ;;
    *)
      fail "Windows domain state is not safe for cutover: ${state:-unknown}"
      return 1
      ;;
  esac
}

windows_snapshot_has_child() {
  local candidate="$1" snap parent
  while IFS= read -r snap; do
    [[ -n "$snap" && "$snap" != "$candidate" ]] || continue
    parent="$(virsh snapshot-dumpxml "$DOMAIN" "$snap" 2>/dev/null | python3 -c '
import sys,xml.etree.ElementTree as ET
try: r=ET.fromstring(sys.stdin.read())
except Exception: raise SystemExit
print(r.findtext("./parent/name") or "")
' || true)"
    [[ "$parent" == "$candidate" ]] && return 0
  done < <(virsh snapshot-list "$DOMAIN" --name 2>/dev/null)
  return 1
}

windows_delete_owned_snapshots_leaf_first() {
  local -a owned=()
  local snap progress remaining i
  for snap in "${FINAL_SNAPSHOT:-}" "${WORKING_SNAPSHOT:-}" "${SAFETY_SNAPSHOT:-}"; do
    [[ -n "$snap" ]] || continue
    state_resource_owned snapshot "$DOMAIN:$snap" && owned+=("$snap")
  done

  for ((i=0;i<10;i++)); do
    progress=no
    remaining=0
    for snap in "${owned[@]}"; do
      state_resource_owned snapshot "$DOMAIN:$snap" || continue
      if ! windows_snapshot_exists "$snap"; then
        state_record_resource snapshot "$DOMAIN:$snap" deleted-by-rollback yes "already-absent"
        progress=yes
        continue
      fi
      remaining=$((remaining+1))
      if ! windows_snapshot_has_child "$snap"; then
        virsh snapshot-delete "$DOMAIN" "$snap" >/dev/null
        state_record_resource snapshot "$DOMAIN:$snap" deleted-by-rollback yes ""
        progress=yes
      fi
    done
    [[ "$remaining" -eq 0 ]] && return 0
    [[ "$progress" == yes ]] || break
  done

  for snap in "${owned[@]}"; do
    if state_resource_owned snapshot "$DOMAIN:$snap" && windows_snapshot_exists "$snap"; then
      fail "Refusing to delete owned snapshot '$snap' because it still has a child snapshot (possibly operator-created)"
      return 1
    fi
  done
}

windows_rollback_to_safety() {
  local state

  # Recover ownership of any exactly matching snapshot that was created after
  # its intent was journaled but before the success ledger row was flushed.
  if [[ -n "${SAFETY_SNAPSHOT:-}" ]] && windows_snapshot_exists "$SAFETY_SNAPSHOT" &&
     ! state_resource_owned snapshot "$DOMAIN:$SAFETY_SNAPSHOT"; then
    windows_snapshot_adopt_if_intended "$SAFETY_SNAPSHOT" "CAPE-INetSim AutoDeploy pre-change snapshot $DEPLOYMENT_ID" "shutoff|no" || {
      fail "Safety snapshot exists but cannot be attributed to this deployment"
      return 1
    }
  fi
  if [[ -n "${WORKING_SNAPSHOT:-}" ]] && windows_snapshot_exists "$WORKING_SNAPSHOT" &&
     ! state_resource_owned snapshot "$DOMAIN:$WORKING_SNAPSHOT"; then
    windows_snapshot_adopt_if_intended "$WORKING_SNAPSHOT" "CAPE-INetSim AutoDeploy configured rollback snapshot $DEPLOYMENT_ID" "shutoff|no" || {
      fail "Working snapshot exists but cannot be attributed to this deployment"
      return 1
    }
  fi
  if [[ -n "${FINAL_SNAPSHOT:-}" ]] && windows_snapshot_exists "$FINAL_SNAPSHOT" &&
     ! state_resource_owned snapshot "$DOMAIN:$FINAL_SNAPSHOT"; then
    windows_snapshot_adopt_if_intended "$FINAL_SNAPSHOT" "CAPE-INetSim AutoDeploy running analysis snapshot $DEPLOYMENT_ID" "running|internal" || {
      fail "Final snapshot exists but cannot be attributed to this deployment"
      return 1
    }
  fi

  state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
  if [[ "$state" == running ]]; then
    virsh shutdown "$DOMAIN" >/dev/null 2>&1 || true
    local i
    for ((i=0;i<30;i+=2)); do
      [[ "$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)" == "shut off" ]] && break
      sleep 2
    done
    if [[ "$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)" != "shut off" ]]; then
      warn "Windows did not shut down during rollback; forcing power-off after CAPE maintenance lock"
      virsh destroy "$DOMAIN" >/dev/null
    fi
  fi

  if [[ -n "${SAFETY_SNAPSHOT:-}" ]] && state_resource_owned snapshot "$DOMAIN:$SAFETY_SNAPSHOT" && windows_snapshot_exists "$SAFETY_SNAPSHOT"; then
    virsh snapshot-revert "$DOMAIN" "$SAFETY_SNAPSHOT" --force >/dev/null
    [[ "$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)" == "shut off" ]] || virsh destroy "$DOMAIN" >/dev/null 2>&1 || true
  fi

  # Reverting the pre-change snapshot normally restores the pre-NIC domain XML.
  # Detach explicitly only if the deployment-owned interface still remains.
  if [[ -n "${WINDOWS_ISOLATED_MAC:-}" ]] && windows_find_isolated_mac | grep -Fqi "$WINDOWS_ISOLATED_MAC"; then
    windows_detach_isolated_nic
  fi

  windows_delete_owned_snapshots_leaf_first

  if [[ "${WINDOWS_ORIGINAL_DOMAIN_STATE:-}" == running ]]; then
    virsh start "$DOMAIN" >/dev/null
  fi
}
