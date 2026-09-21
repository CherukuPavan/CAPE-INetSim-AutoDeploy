#!/usr/bin/env bash

FIREWALL_TABLE="cape_inetsim_autodeploy"
FIREWALL_BRIDGE_TABLE="cape_inetsim_autodeploy_l2"
FIREWALL_DIR="/etc/cape-inetsim-autodeploy"
FIREWALL_RULES="$FIREWALL_DIR/firewall.nft"
FIREWALL_UNIT="/etc/systemd/system/cape-inetsim-autodeploy-firewall.service"

firewall_management_records() {
  python3 - "${CAPE_TARGETS_JSON:-[]}" <<'PY'
import json,sys
order={"discovered":0,"nic-attached":10,"configured":20,"snapshots-ready":30,"cape-configured":40}
try: a=json.loads(sys.argv[1])
except Exception: a=[]
for d in a:
    if order.get(d.get("phase","discovered"),0) < order["nic-attached"]:
        continue
    vals=[str(d.get(k,"")) for k in ("management_bridge","management_mac","ip","domain")]
    if all(vals):
        print("|".join(vals))
PY
}

firewall_render_rules() {
  local isolated_bridge="$1" include_management="${2:-no}"
  local records=""
  [[ "$include_management" == yes ]] && records="$(firewall_management_records)"

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
  if [[ -n "$records" ]]; then
    echo "    # Block routed/lateral egress from every protected CAPE analysis management NIC."
    local bridge mac ip domain
    while IFS='|' read -r bridge mac ip domain; do
      [[ -n "$bridge" && -n "$mac" && -n "$ip" ]] || continue
      printf '    iifname "%s" ether saddr %s drop\n' "$bridge" "$mac"
      printf '    iifname "%s" ip saddr %s drop\n' "$bridge" "$ip"
    done <<<"$records"
  fi
  cat <<'EOF'
  }
}
EOF

  if [[ -n "$records" ]]; then
    cat <<EOF

table bridge $FIREWALL_BRIDGE_TABLE {
  chain forward_guard {
    type filter hook forward priority -50; policy accept;
EOF
    local bridge mac ip domain
    while IFS='|' read -r bridge mac ip domain; do
      [[ -n "$mac" ]] || continue
      printf '    ether saddr %s drop\n' "$mac"
    done <<<"$records"
    cat <<'EOF'
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

firewall_validate_management_antispof_all() {
  local saved="${TARGET_INDEX:-}" i phase
  CAPE_TARGETS_COUNT="$(targets_count)"
  for ((i=0;i<CAPE_TARGETS_COUNT;i++)); do
    phase="$(targets_get "$i" phase)"
    case "$phase" in
      nic-attached|configured|snapshots-ready|cape-configured)
        targets_bind "$i"
        windows_management_guard_verify || {
          [[ "$saved" =~ ^[0-9]+$ ]] && targets_bind "$saved"
          return 1
        }
        ;;
    esac
  done
  if [[ "$saved" =~ ^[0-9]+$ ]]; then targets_bind "$saved"; fi
  return 0
}

firewall_management_guards_match_all() {
  local records inet_text bridge_text bridge mac ip domain
  records="$(firewall_management_records)"
  [[ -n "$records" ]] || return 1
  inet_text="$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null)" || return 1
  bridge_text="$(nft list table bridge "$FIREWALL_BRIDGE_TABLE" 2>/dev/null)" || return 1
  while IFS='|' read -r bridge mac ip domain; do
    grep -Fq "iifname \"$bridge\" ether saddr $mac drop" <<<"$inet_text" || return 1
    grep -Fq "iifname \"$bridge\" ip saddr $ip drop" <<<"$inet_text" || return 1
    grep -Fq "ether saddr $mac drop" <<<"$bridge_text" || return 1
  done <<<"$records"
}

firewall_file_has_management_guards_all() {
  [[ -f "$FIREWALL_RULES" ]] || return 1
  local records bridge mac ip domain
  records="$(firewall_management_records)"
  [[ -n "$records" ]] || return 1
  grep -Fq "table bridge $FIREWALL_BRIDGE_TABLE" "$FIREWALL_RULES" || return 1
  while IFS='|' read -r bridge mac ip domain; do
    grep -Fq "iifname \"$bridge\" ether saddr $mac drop" "$FIREWALL_RULES" || return 1
    grep -Fq "iifname \"$bridge\" ip saddr $ip drop" "$FIREWALL_RULES" || return 1
    grep -Fq "ether saddr $mac drop" "$FIREWALL_RULES" || return 1
  done <<<"$records"
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

  local want_management=no
  if [[ -n "$(firewall_management_records)" ]]; then
    want_management=yes
    firewall_validate_management_antispof_all || {
      fail "One or more CAPE analysis management NIC anti-spoof guards are not active"
      return 1
    }
  fi

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
    if [[ "$want_management" == no ]] || { firewall_file_has_management_guards_all && firewall_management_guards_match_all; }; then
      pass "Host network safety firewall guard already active"
      return 0
    fi
  fi

  install -d -m 0755 "$FIREWALL_DIR"
  local tmp_rules="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-firewall.nft"
  local tmp_unit="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-firewall.service"
  firewall_render_rules "$ISOLATED_BRIDGE_NAME" "$want_management" >"$tmp_rules"
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
  if [[ "$want_management" == yes ]]; then
    firewall_file_has_management_guards_all && firewall_management_guards_match_all || {
      fail "Restored firewall is missing one or more Windows management egress guards"
      return 1
    }
    local bridge mac ip domain
    while IFS='|' read -r bridge mac ip domain; do
      state_record_resource firewall-management-guard "$domain:$mac" active yes "bridge=$bridge ip=$ip"
    done < <(firewall_management_records)
  fi

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

  state_record_intent firewall-management-guard "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" applying "bridge=$MANAGEMENT_BRIDGE_NAME ip=$CAPE_MACHINE_IP"
  firewall_apply
  firewall_file_has_management_guards_all && firewall_management_guards_match_all || {
    fail "Windows management forwarding guard did not become active for the complete protected target set"
    return 1
  }
  state_write_atomic
  pass "Blocked routed/lateral egress from protected CAPE analysis management NICs"
}

firewall_verify() {
  firewall_file_matches_base || return 1
  firewall_unit_matches_project || return 1
  firewall_table_matches_base || return 1
  firewall_validate_management_antispof_all || return 1
  firewall_file_has_management_guards_all || return 1
  firewall_management_guards_match_all || return 1
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

  local bridge mac ip domain
  while IFS='|' read -r bridge mac ip domain; do
    state_record_resource firewall-management-guard "$domain:$mac" removed-by-rollback yes ""
  done < <(firewall_management_records)
  state_record_resource firewall-table "$FIREWALL_TABLE" removed-by-rollback yes ""
  state_record_resource firewall-unit "$FIREWALL_UNIT" removed-by-rollback yes ""
  state_record_resource firewall-file "$FIREWALL_RULES" removed-by-rollback yes ""
  pass "Removed AutoDeploy host firewall guard"
}
