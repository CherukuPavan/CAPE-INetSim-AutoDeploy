#!/usr/bin/env bash

stage_isolated_network() {
  txn_lock
  state_write_initial

  local root xml
  root="$(state_root)"
  xml="$root/generated/isolated-network.xml"
  render_isolated_network_xml "$xml"
  validate_isolated_network_xml "$xml" >/dev/null

  if virsh net-info "$PLANNED_NETWORK_NAME" >/dev/null 2>&1; then
    fail "Refusing to adopt pre-existing libvirt network '$PLANNED_NETWORK_NAME' without ownership state"
    return 1
  fi

  virsh net-define "$xml" >/dev/null
  txn_record_resource "libvirt-network" "$PLANNED_NETWORK_NAME" "$PLANNED_BRIDGE_NAME"
  virsh net-autostart "$PLANNED_NETWORK_NAME" >/dev/null
  virsh net-start "$PLANNED_NETWORK_NAME" >/dev/null

  local live
  live="$root/generated/isolated-network.live.xml"
  virsh net-dumpxml "$PLANNED_NETWORK_NAME" >"$live"
  validate_isolated_network_xml "$live" >/dev/null

  ip -4 addr show dev "$PLANNED_BRIDGE_NAME" | grep -Fq "$BRIDGE_IP/24" || {
    fail "Bridge '$PLANNED_BRIDGE_NAME' did not receive planned address $BRIDGE_IP/24"
    return 1
  }

  state_set_phase "network_staged"
  pass "Isolated libvirt network staged: $PLANNED_NETWORK_NAME ($PLANNED_BRIDGE_NAME)"
}

rollback_isolated_network() {
  local net
  net="${PLANNED_NETWORK_NAME:-$(state_get libvirt_network 2>/dev/null || true)}"
  [[ -n "$net" ]] || return 0
  if txn_has_resource "libvirt-network" "$net"; then
    virsh net-destroy "$net" >/dev/null 2>&1 || true
    virsh net-undefine "$net" >/dev/null 2>&1 || true
    pass "Removed deployment-owned libvirt network: $net"
  else
    warn "Network '$net' is not in the AutoDeploy resource ledger; leaving it untouched"
  fi
}
