#!/usr/bin/env bash

FIREWALL_TABLE="cape_inetsim_autodeploy"
FIREWALL_BRIDGE_TABLE="cape_inetsim_autodeploy_l2"
FIREWALL_DIR="/etc/cape-inetsim-autodeploy"
FIREWALL_RULES="$FIREWALL_DIR/firewall.nft"
FIREWALL_UNIT="/etc/systemd/system/cape-inetsim-autodeploy-firewall.service"

firewall_render_rules() {
  local isolated_bridge="$1"
  local management_bridge="${2:-}" management_mac="${3:-}" management_ip="${4:-}"

  cat <<EOF
# CAPE-INetSim-AutoDeploy managed rules. Do not edit while deployment is active.
table inet $FIREWALL_TABLE {
  chain input_guard {
    type filter hook input priority -50; policy accept;
    iifname "$isolated_bridge" ct state established,related accept
    iifname "$isolated_bridge" drop
  }

  chain forward_guard {
    type filter hook forward priority -50; policy accept;
    iifname "$isolated_bridge" drop
    oifname "$isolated_bridge" drop
EOF
  if [[ -n "$management_bridge" && -n "$management_mac" && -n "$management_ip" ]]; then
    cat <<EOF
    # The Windows management NIC may live on a NAT-capable libvirt network.
    # ResultServer traffic is host-local and does not traverse this forward
    # hook. Any routed traffic from the protected source identity is dropped.
    iifname "$management_bridge" ether saddr $management_mac drop
    iifname "$management_bridge" ip saddr $management_ip drop
EOF
  fi
  cat <<'EOF'
  }
}
EOF

  if [[ -n "$management_bridge" && -n "$management_mac" && -n "$management_ip" ]]; then
    cat <<EOF

table bridge $FIREWALL_BRIDGE_TABLE {
  chain forward_guard {
    type filter hook forward priority -50; policy accept;
    # Prevent the protected analysis NIC from talking laterally to another
    # bridge port. Host-local CAPE management traffic remains available.
    ether saddr $management_mac drop
  }
}
EOF
  fi
}

firewall_render_unit() {
  cat <<EOF
# CAPE-INetSim-AutoDeploy managed unit.
[Unit]
Description=CAPE INetSim isolated-network firewall guard
After=network-pre.target
Before=libvirtd.service virtqemud.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table inet $FIREWALL_TABLE
ExecStartPre=-/usr/sbin/nft delete table bridge $FIREWALL_BRIDGE_TABLE
ExecStart=/usr/sbin/nft -f $FIREWALL_RULES
ExecStop=-/usr/sbin/nft delete table bridge $FIREWALL_BRIDGE_TABLE
ExecStop=-/usr/sbin/nft delete table inet $FIREWALL_TABLE

[Install]
WantedBy=multi-user.target
EOF
}

firewall_table_exists() {
  nft list table inet "$FIREWALL_TABLE" >/dev/null 2>&1
}

firewall_bridge_table_exists() {
  nft list table bridge "$FIREWALL_BRIDGE_TABLE" >/dev/null 2>&1
}

firewall_table_matches_base() {
  local text
  text="$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null)" || return 1
  grep -Fq "iifname \"$ISOLATED_BRIDGE_NAME\"" <<<"$text" || return 1
  grep -Fq "oifname \"$ISOLATED_BRIDGE_NAME\"" <<<"$text" || return 1
}

firewall_file_matches_base() {
  [[ -f "$FIREWALL_RULES" ]] || return 1
  grep -Fq 'CAPE-INetSim-AutoDeploy managed rules' "$FIREWALL_RULES" &&
    grep -Fq "iifname \"$ISOLATED_BRIDGE_NAME\"" "$FIREWALL_RULES" &&
    grep -Fq "oifname \"$ISOLATED_BRIDGE_NAME\"" "$FIREWALL_RULES"
}

firewall_management_guard_matches() {
  [[ -n "${MANAGEMENT_BRIDGE_NAME:-}" && -n "${WINDOWS_MANAGEMENT_MAC:-}" && -n "${CAPE_MACHINE_IP:-}" ]] || return 1
  local inet_text bridge_text
  inet_text="$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null)" || return 1
  bridge_text="$(nft list table bridge "$FIREWALL_BRIDGE_TABLE" 2>/dev/null)" || return 1
  grep -Fq "iifname \"$MANAGEMENT_BRIDGE_NAME\" ether saddr $WINDOWS_MANAGEMENT_MAC drop" <<<"$inet_text" || return 1
  grep -Fq "iifname \"$MANAGEMENT_BRIDGE_NAME\" ip saddr $CAPE_MACHINE_IP drop" <<<"$inet_text" || return 1
  grep -Fq "ether saddr $WINDOWS_MANAGEMENT_MAC drop" <<<"$bridge_text" || return 1
}

firewall_file_has_management_guard() {
  [[ -f "$FIREWALL_RULES" ]] || return 1
  grep -Fq "iifname \"$MANAGEMENT_BRIDGE_NAME\" ether saddr $WINDOWS_MANAGEMENT_MAC drop" "$FIREWALL_RULES" &&
    grep -Fq "iifname \"$MANAGEMENT_BRIDGE_NAME\" ip saddr $CAPE_MACHINE_IP drop" "$FIREWALL_RULES" &&
    grep -Fq "table bridge $FIREWALL_BRIDGE_TABLE" "$FIREWALL_RULES" &&
    grep -Fq "ether saddr $WINDOWS_MANAGEMENT_MAC drop" "$FIREWALL_RULES"
}

firewall_unit_matches_project() {
  [[ -f "$FIREWALL_UNIT" ]] &&
    grep -Fq 'CAPE-INetSim-AutoDeploy managed unit' "$FIREWALL_UNIT" &&
    grep -Fq "$FIREWALL_RULES" "$FIREWALL_UNIT" &&
    grep -Fq "delete table bridge $FIREWALL_BRIDGE_TABLE" "$FIREWALL_UNIT"
}

firewall_apply() {
  have nft || { fail "nftables command 'nft' is required for fake-Internet egress guard"; return 1; }
  [[ -n "${ISOLATED_BRIDGE_NAME:-}" ]] || { fail "Isolated bridge is unknown"; return 1; }

  if [[ -e "$FIREWALL_RULES" ]] &&
     ! state_resource_owned firewall-file "$FIREWALL_RULES" &&
     ! state_resource_intended firewall-file "$FIREWALL_RULES"; then
    fail "Firewall rules path already exists but is not AutoDeploy-owned: $FIREWALL_RULES"
    return 1
  fi
  if [[ -e "$FIREWALL_UNIT" ]] &&
     ! state_resource_owned firewall-unit "$FIREWALL_UNIT" &&
     ! state_resource_intended firewall-unit "$FIREWALL_UNIT"; then
    fail "Firewall unit already exists but is not AutoDeploy-owned: $FIREWALL_UNIT"
    return 1
  fi
  if firewall_table_exists &&
     ! state_resource_owned firewall-table "$FIREWALL_TABLE" &&
     ! state_resource_intended firewall-table "$FIREWALL_TABLE"; then
    fail "nftables table already exists but is not AutoDeploy-owned: $FIREWALL_TABLE"
    return 1
  fi

  # Do not overwrite an already-owned full rule set during resume; in
  # particular, preserve the management-forwarding guard once cutover begins.
  if state_resource_owned firewall-file "$FIREWALL_RULES" &&
     state_resource_owned firewall-unit "$FIREWALL_UNIT" &&
     state_resource_owned firewall-table "$FIREWALL_TABLE" &&
     firewall_file_matches_base && firewall_unit_matches_project &&
     firewall_table_matches_base &&
     systemctl is-active --quiet cape-inetsim-autodeploy-firewall.service; then
    pass "Host isolated-network firewall guard already active"
    return 0
  fi

  install -d -m 0755 "$FIREWALL_DIR"
  local tmp_rules="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-firewall.nft"
  local tmp_unit="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-firewall.service"
  firewall_render_rules "$ISOLATED_BRIDGE_NAME" >"$tmp_rules"
  firewall_render_unit >"$tmp_unit"
  chmod 0600 "$tmp_rules" "$tmp_unit"

  nft -c -f "$tmp_rules"

  state_record_intent firewall-file "$FIREWALL_RULES" creating "bridge=$ISOLATED_BRIDGE_NAME"
  state_record_intent firewall-unit "$FIREWALL_UNIT" creating ""
  state_record_intent firewall-table "$FIREWALL_TABLE" creating "bridge=$ISOLATED_BRIDGE_NAME"

  install -m 0644 "$tmp_rules" "$FIREWALL_RULES"
  install -m 0644 "$tmp_unit" "$FIREWALL_UNIT"
  systemctl daemon-reload
  systemctl enable --now cape-inetsim-autodeploy-firewall.service

  firewall_file_matches_base || { fail "Installed firewall rules do not match deployment plan"; return 1; }
  firewall_unit_matches_project || { fail "Installed firewall service does not match project"; return 1; }
  firewall_table_matches_base || { fail "Active nftables egress guard does not match isolated bridge"; return 1; }
  systemctl is-active --quiet cape-inetsim-autodeploy-firewall.service

  state_record_resource firewall-file "$FIREWALL_RULES" created yes "bridge=$ISOLATED_BRIDGE_NAME"
  state_record_resource firewall-unit "$FIREWALL_UNIT" created yes ""
  state_record_resource firewall-table "$FIREWALL_TABLE" created yes "bridge=$ISOLATED_BRIDGE_NAME"
  state_write_atomic
  pass "Installed host forwarding/input guard for isolated bridge $ISOLATED_BRIDGE_NAME"
}

firewall_enable_windows_management_guard() {
  [[ -n "${MANAGEMENT_BRIDGE_NAME:-}" && -n "${WINDOWS_MANAGEMENT_MAC:-}" && -n "${CAPE_MACHINE_IP:-}" ]] || {
    fail "Management bridge/MAC/IP are required before enabling the Windows egress guard"
    return 1
  }
  windows_management_guard_verify || {
    fail "Hypervisor management anti-spoof guard must be active before host management egress blocking is enabled"
    return 1
  }

  if firewall_file_has_management_guard && firewall_management_guard_matches; then
    state_record_resource firewall-management-guard "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" active yes "bridge=$MANAGEMENT_BRIDGE_NAME ip=$CAPE_MACHINE_IP"
    pass "Windows management forwarding guard already active"
    return 0
  fi

  local tmp="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-firewall-full.nft"
  firewall_render_rules "$ISOLATED_BRIDGE_NAME" "$MANAGEMENT_BRIDGE_NAME" "$WINDOWS_MANAGEMENT_MAC" "$CAPE_MACHINE_IP" >"$tmp"
  chmod 0600 "$tmp"
  nft -c -f "$tmp"

  state_record_intent firewall-management-guard "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" applying "bridge=$MANAGEMENT_BRIDGE_NAME ip=$CAPE_MACHINE_IP"
  install -m 0644 "$tmp" "$FIREWALL_RULES"
  systemctl restart cape-inetsim-autodeploy-firewall.service
  firewall_file_has_management_guard && firewall_management_guard_matches || {
    fail "Windows management forwarding guard did not become active"
    return 1
  }
  state_record_resource firewall-management-guard "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" active yes "bridge=$MANAGEMENT_BRIDGE_NAME ip=$CAPE_MACHINE_IP"
  state_write_atomic
  pass "Blocked routed/lateral egress from Windows management NIC while preserving host-local CAPE traffic"
}

firewall_verify() {
  firewall_file_matches_base || return 1
  firewall_unit_matches_project || return 1
  firewall_table_matches_base || return 1
  firewall_file_has_management_guard || return 1
  firewall_management_guard_matches || return 1
  systemctl is-active --quiet cape-inetsim-autodeploy-firewall.service
}

firewall_rollback() {
  local can_remove=no

  if state_resource_owned firewall-table "$FIREWALL_TABLE" ||
     state_resource_owned firewall-file "$FIREWALL_RULES" ||
     state_resource_owned firewall-unit "$FIREWALL_UNIT"; then
    can_remove=yes
  elif state_resource_intended firewall-table "$FIREWALL_TABLE" ||
       state_resource_intended firewall-file "$FIREWALL_RULES" ||
       state_resource_intended firewall-unit "$FIREWALL_UNIT"; then
    if { ! firewall_table_exists || firewall_table_matches_base; } &&
       { [[ ! -e "$FIREWALL_RULES" ]] || firewall_file_matches_base; } &&
       { [[ ! -e "$FIREWALL_UNIT" ]] || firewall_unit_matches_project; }; then
      can_remove=yes
    fi
  fi

  [[ "$can_remove" == yes ]] || {
    if firewall_table_exists || firewall_bridge_table_exists || [[ -e "$FIREWALL_RULES" || -e "$FIREWALL_UNIT" ]]; then
      fail "Refusing to remove firewall resources that cannot be attributed to this deployment"
      return 1
    fi
    return 0
  }

  systemctl disable --now cape-inetsim-autodeploy-firewall.service >/dev/null 2>&1 || true
  nft delete table bridge "$FIREWALL_BRIDGE_TABLE" >/dev/null 2>&1 || true
  nft delete table inet "$FIREWALL_TABLE" >/dev/null 2>&1 || true
  rm -f "$FIREWALL_UNIT" "$FIREWALL_RULES"
  rmdir "$FIREWALL_DIR" >/dev/null 2>&1 || true
  systemctl daemon-reload

  state_record_resource firewall-management-guard "$DOMAIN:${WINDOWS_MANAGEMENT_MAC:-unknown}" removed-by-rollback yes ""
  state_record_resource firewall-table "$FIREWALL_TABLE" removed-by-rollback yes ""
  state_record_resource firewall-unit "$FIREWALL_UNIT" removed-by-rollback yes ""
  state_record_resource firewall-file "$FIREWALL_RULES" removed-by-rollback yes ""
  pass "Removed AutoDeploy host firewall guard"
}
