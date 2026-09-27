#!/usr/bin/env bash

FIREWALL_TABLE="cape_inetsim_autodeploy"
FIREWALL_BRIDGE_TABLE="cape_inetsim_autodeploy_l2"
FIREWALL_DIR="/etc/cape-inetsim-autodeploy"
FIREWALL_RULES="$FIREWALL_DIR/firewall.nft"
FIREWALL_UNIT="/etc/systemd/system/cape-inetsim-autodeploy-firewall.service"

firewall_management_records() {
  ad_python - "${CAPE_TARGETS_JSON:-[]}" <<'PY'
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

firewall_inetsim_client_records() {
  ad_python - "${CAPE_TARGETS_JSON:-[]}" <<'PY'
import json,sys
try: a=json.loads(sys.argv[1])
except Exception: a=[]
for d in a:
    bridge=str(d.get("management_bridge") or "")
    ip=str(d.get("ip") or "")
    domain=str(d.get("domain") or "")
    if bridge and ip:
        print("|".join((bridge,ip,domain)))
PY
}

firewall_isolated_resultserver_records() {
  ad_python - "${CAPE_TARGETS_JSON:-[]}" <<'PY'
import json,sys
try: a=json.loads(sys.argv[1])
except Exception: a=[]
for d in a:
    fake=str(d.get("fake_ip") or "")
    rip=str(d.get("resultserver_ip") or "")
    port=str(d.get("resultserver_port") or "")
    if fake and rip and port.isdigit():
        print("|".join((fake,rip,port,str(d.get("domain") or ""))))
PY
}

firewall_render_rules() {
  local isolated_bridge="$1"
  local clients
  clients="$(firewall_inetsim_client_records)"

  cat <<EOF
# CAPE-INetSim-AutoDeploy managed rules. Do not edit while deployment is active.
# Per-task route separation: only CAPE's host routing may reach the isolated
# INetSim endpoint. Normal Internet tasks are not redirected to this bridge.
table inet $FIREWALL_TABLE {
  chain input_guard {
    type filter hook input priority -50; policy accept;
    iifname "$isolated_bridge" ct state established,related accept
    iifname "$isolated_bridge" drop
  }

  chain forward_guard {
    type filter hook forward priority -50; policy accept;
EOF

  if [[ -n "$clients" ]]; then
    local bridge ip domain
    while IFS='|' read -r bridge ip domain; do
      [[ -n "$bridge" && -n "$ip" ]] || continue
      printf '    iifname "%s" ip saddr %s oifname "%s" ip daddr %s accept\n' \
        "$bridge" "$ip" "$isolated_bridge" "$INETSIM_IP"
      printf '    iifname "%s" ip saddr %s oifname "%s" ip daddr %s ct state established,related accept\n' \
        "$isolated_bridge" "$INETSIM_IP" "$bridge" "$ip"
    done <<<"$clients"
  fi

  cat <<EOF
    iifname "$isolated_bridge" drop
    oifname "$isolated_bridge" drop
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

firewall_render_runtime_batch() {
  local rules_file="$1"

  # nft -c validates against the current ruleset. During Windows cutover the
  # deployment-owned base inet table is already active, so checking a file that
  # creates the same table again fails before any mutation. Build one nft
  # transaction that removes only the currently present AutoDeploy tables and
  # recreates the desired ruleset. The same batch is used for validation and
  # for the live update, keeping the guard replacement atomic.
  if firewall_table_exists; then
    printf 'delete table inet %s\n' "$FIREWALL_TABLE"
  fi
  if firewall_bridge_table_exists; then
    printf 'delete table bridge %s\n' "$FIREWALL_BRIDGE_TABLE"
  fi
  cat "$rules_file"
}

firewall_activate_rules() {
  local runtime_batch="$1"

  if systemctl is-active --quiet cape-inetsim-autodeploy-firewall.service; then
    # RemainAfterExit oneshot units are not re-run by "enable --now" when they
    # are already active. Apply the checked nft transaction directly, then keep
    # the unit enabled so the just-installed persistent rules return on reboot.
    nft -f "$runtime_batch"
    systemctl enable cape-inetsim-autodeploy-firewall.service >/dev/null
  else
    systemctl enable --now cape-inetsim-autodeploy-firewall.service
  fi
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
    grep -Fq 'Per-task route separation' "$FIREWALL_RULES" &&
    grep -Fq "iifname \"$ISOLATED_BRIDGE_NAME\"" "$FIREWALL_RULES" &&
    grep -Fq "oifname \"$ISOLATED_BRIDGE_NAME\"" "$FIREWALL_RULES"
}

firewall_resultserver_exceptions_match_all() {
  local records text fake_ip result_ip result_port domain
  records="$(firewall_isolated_resultserver_records)"
  [[ -n "$records" ]] || return 0
  text="$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null)" || return 1
  while IFS='|' read -r fake_ip result_ip result_port domain; do
    grep -Fq "iifname \"$ISOLATED_BRIDGE_NAME\" ip saddr $fake_ip ip daddr $result_ip tcp dport $result_port accept" <<<"$text" || return 1
  done <<<"$records"
}

firewall_file_has_resultserver_exceptions_all() {
  local records fake_ip result_ip result_port domain
  records="$(firewall_isolated_resultserver_records)"
  [[ -n "$records" ]] || return 0
  [[ -f "$FIREWALL_RULES" ]] || return 1
  while IFS='|' read -r fake_ip result_ip result_port domain; do
    grep -Fq "iifname \"$ISOLATED_BRIDGE_NAME\" ip saddr $fake_ip ip daddr $result_ip tcp dport $result_port accept" "$FIREWALL_RULES" || return 1
  done <<<"$records"
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
firewall_inetsim_route_exceptions_match_all() {
  local clients text bridge ip domain
  clients="$(firewall_inetsim_client_records)"
  [[ -n "$clients" ]] || return 1
  text="$(nft list table inet "$FIREWALL_TABLE" 2>/dev/null)" || return 1
  while IFS='|' read -r bridge ip domain; do
    grep -Fq "iifname \"$bridge\" ip saddr $ip oifname \"$ISOLATED_BRIDGE_NAME\" ip daddr $INETSIM_IP accept" <<<"$text" || return 1
  done <<<"$clients"
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
     firewall_inetsim_route_exceptions_match_all &&
     ! firewall_bridge_table_exists &&
     systemctl is-active --quiet cape-inetsim-autodeploy-firewall.service; then
    pass "Host INetSim isolation firewall guard already active"
    return 0
  fi

  install -d -m 0755 "$FIREWALL_DIR"
  local tmp_rules="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-firewall.nft"
  local tmp_unit="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-firewall.service"
  local tmp_runtime_batch="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-firewall-runtime.nft"
  firewall_render_rules "$ISOLATED_BRIDGE_NAME" >"$tmp_rules"
  firewall_render_unit >"$tmp_unit"
  firewall_render_runtime_batch "$tmp_rules" >"$tmp_runtime_batch"
  chmod 0600 "$tmp_rules" "$tmp_unit" "$tmp_runtime_batch"

  nft -c -f "$tmp_runtime_batch"

  state_record_intent firewall-file "$FIREWALL_RULES" creating "bridge=$ISOLATED_BRIDGE_NAME"
  state_record_intent firewall-unit "$FIREWALL_UNIT" creating ""
  state_record_intent firewall-table "$FIREWALL_TABLE" creating "bridge=$ISOLATED_BRIDGE_NAME"

  install -m 0644 "$tmp_rules" "$FIREWALL_RULES"
  install -m 0644 "$tmp_unit" "$FIREWALL_UNIT"
  systemctl daemon-reload
  firewall_activate_rules "$tmp_runtime_batch"

  firewall_file_matches_base || { fail "Installed firewall rules do not match deployment plan"; return 1; }
  firewall_unit_matches_project || { fail "Installed firewall service does not match project"; return 1; }
  firewall_table_matches_base || { fail "Active nftables egress guard does not match isolated bridge"; return 1; }
  firewall_inetsim_route_exceptions_match_all || {
    fail "Installed firewall is missing one or more CAPE-to-INetSim route exceptions"
    return 1
  }
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
  firewall_inetsim_route_exceptions_match_all || return 1
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
