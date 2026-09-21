#!/usr/bin/env bash

FIREWALL_TABLE="cape_inetsim_autodeploy"
FIREWALL_DIR="/etc/cape-inetsim-autodeploy"
FIREWALL_RULES="$FIREWALL_DIR/firewall.nft"
FIREWALL_UNIT="/etc/systemd/system/cape-inetsim-autodeploy-firewall.service"

firewall_render_rules() {
  local bridge="$1"
  cat <<EOF
# CAPE-INetSim-AutoDeploy managed rules. Do not edit while deployment is active.
table inet $FIREWALL_TABLE {
  chain input_guard {
    type filter hook input priority -50; policy accept;
    iifname "$bridge" ct state established,related accept
    iifname "$bridge" drop
  }

  chain forward_guard {
    type filter hook forward priority -50; policy accept;
    iifname "$bridge" drop
    oifname "$bridge" drop
  }
}
EOF
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
ExecStart=/usr/sbin/nft -f $FIREWALL_RULES
ExecStop=-/usr/sbin/nft delete table inet $FIREWALL_TABLE

[Install]
WantedBy=multi-user.target
EOF
}

firewall_table_exists() {
  nft list table inet "$FIREWALL_TABLE" >/dev/null 2>&1
}

firewall_table_matches_plan() {
  local text
  text="$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null)" || return 1
  grep -Fq "iifname \"$ISOLATED_BRIDGE_NAME\"" <<<"$text" || return 1
  grep -Fq "oifname \"$ISOLATED_BRIDGE_NAME\"" <<<"$text" || return 1
}

firewall_file_matches_plan() {
  [[ -f "$FIREWALL_RULES" ]] || return 1
  grep -Fq 'CAPE-INetSim-AutoDeploy managed rules' "$FIREWALL_RULES" &&
    grep -Fq "iifname \"$ISOLATED_BRIDGE_NAME\"" "$FIREWALL_RULES" &&
    grep -Fq "oifname \"$ISOLATED_BRIDGE_NAME\"" "$FIREWALL_RULES"
}

firewall_unit_matches_project() {
  [[ -f "$FIREWALL_UNIT" ]] &&
    grep -Fq 'CAPE-INetSim-AutoDeploy managed unit' "$FIREWALL_UNIT" &&
    grep -Fq "$FIREWALL_RULES" "$FIREWALL_UNIT"
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

  firewall_file_matches_plan || { fail "Installed firewall rules do not match deployment plan"; return 1; }
  firewall_unit_matches_project || { fail "Installed firewall service does not match project"; return 1; }
  firewall_table_matches_plan || { fail "Active nftables egress guard does not match isolated bridge"; return 1; }
  systemctl is-active --quiet cape-inetsim-autodeploy-firewall.service

  state_record_resource firewall-file "$FIREWALL_RULES" created yes "bridge=$ISOLATED_BRIDGE_NAME"
  state_record_resource firewall-unit "$FIREWALL_UNIT" created yes ""
  state_record_resource firewall-table "$FIREWALL_TABLE" created yes "bridge=$ISOLATED_BRIDGE_NAME"
  state_write_atomic
  pass "Installed host forwarding/input guard for isolated bridge $ISOLATED_BRIDGE_NAME"
}

firewall_verify() {
  firewall_file_matches_plan || return 1
  firewall_unit_matches_project || return 1
  firewall_table_matches_plan || return 1
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
    if { ! firewall_table_exists || firewall_table_matches_plan; } &&
       { [[ ! -e "$FIREWALL_RULES" ]] || firewall_file_matches_plan; } &&
       { [[ ! -e "$FIREWALL_UNIT" ]] || firewall_unit_matches_project; }; then
      can_remove=yes
    fi
  fi

  [[ "$can_remove" == yes ]] || {
    if firewall_table_exists || [[ -e "$FIREWALL_RULES" || -e "$FIREWALL_UNIT" ]]; then
      fail "Refusing to remove firewall resources that cannot be attributed to this deployment"
      return 1
    fi
    return 0
  }

  systemctl disable --now cape-inetsim-autodeploy-firewall.service >/dev/null 2>&1 || true
  nft delete table inet "$FIREWALL_TABLE" >/dev/null 2>&1 || true
  rm -f "$FIREWALL_UNIT" "$FIREWALL_RULES"
  rmdir "$FIREWALL_DIR" >/dev/null 2>&1 || true
  systemctl daemon-reload

  state_record_resource firewall-table "$FIREWALL_TABLE" removed-by-rollback yes ""
  state_record_resource firewall-unit "$FIREWALL_UNIT" removed-by-rollback yes ""
  state_record_resource firewall-file "$FIREWALL_RULES" removed-by-rollback yes ""
  pass "Removed AutoDeploy host firewall guard"
}
