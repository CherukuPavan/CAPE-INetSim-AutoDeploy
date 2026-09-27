#!/usr/bin/env bash

WINDOWS_MGMT_FILTER_NAME="${WINDOWS_MGMT_FILTER_NAME:-clean-traffic}"

windows_management_interface_xml() {
  local scope="${1:-inactive}"
  local -a args=(dumpxml "$DOMAIN")
  [[ "$scope" == inactive ]] && args+=(--inactive)
  virsh "${args[@]}" 2>/dev/null | ad_python -c '
import sys,xml.etree.ElementTree as ET
mac=sys.argv[1].lower(); net=sys.argv[2]
try: root=ET.fromstring(sys.stdin.read())
except Exception: raise SystemExit(2)
matches=[]
for i in root.findall("./devices/interface"):
    m=i.find("mac"); s=i.find("source")
    if m is None or s is None: continue
    if (m.get("address") or "").lower()==mac and s.get("network")==net:
        matches.append(i)
if len(matches)!=1: raise SystemExit(3)
print(ET.tostring(matches[0],encoding="unicode"))
' "$WINDOWS_MANAGEMENT_MAC" "$MANAGEMENT_NETWORK_NAME"
}

windows_management_guard_backup_path() {
  local slug
  slug="$(ad_safe_token "${DOMAIN:-unknown}-${WINDOWS_MANAGEMENT_MAC:-unknown}")"
  printf '%s/windows-management-%s.xml\n' "$AD_BACKUP_ROOT/$DEPLOYMENT_ID" "$slug"
}

windows_management_guard_filter_facts() {
  local scope="${1:-inactive}"
  windows_management_interface_xml "$scope" | ad_python -c '
import sys,xml.etree.ElementTree as ET
ip=sys.argv[1]
try: i=ET.fromstring(sys.stdin.read())
except Exception: raise SystemExit(2)
refs=i.findall("filterref")
if not refs:
    print("none|")
    raise SystemExit
if len(refs)!=1:
    print("ambiguous|")
    raise SystemExit
r=refs[0]
name=r.get("filter") or ""
vals=[p.get("value") or "" for p in r.findall("parameter") if (p.get("name") or "").upper()=="IP"]
print(name+"|"+(",".join(vals)))
' "$CAPE_MACHINE_IP"
}

windows_management_guard_exact() {
  local scope="${1:-inactive}"
  [[ "$(windows_management_guard_filter_facts "$scope")" == "$WINDOWS_MGMT_FILTER_NAME|$CAPE_MACHINE_IP" ]]
}

nwfilter_virsh() {
  # On split-daemon libvirt hosts, nwfilter APIs belong to virtnwfilterd and
  # must use the dedicated nwfilter:///system connection. qemu:///system may
  # accept the CLI command yet query a different driver namespace. Probe the
  # driver connection itself, not the requested object's success/failure.
  if virsh -c nwfilter:///system uri >/dev/null 2>&1; then
    virsh -c nwfilter:///system "$@"
  else
    virsh "$@"
  fi
}

windows_management_guard_available_default() {
  # Read-only initial probe before AutoDeploy owns any daemon activation.
  virsh nwfilter-dumpxml "$WINDOWS_MGMT_FILTER_NAME" >/dev/null 2>&1
}

windows_management_guard_available() {
  nwfilter_virsh nwfilter-dumpxml "$WINDOWS_MGMT_FILTER_NAME" >/dev/null 2>&1
}

nwfilter_runtime_definition_closure() {
  local -a roots=()
  mapfile -t roots < <(nwfilter_definition_roots)
  (("${#roots[@]}" > 0)) || { fail "No libvirt nwfilter definition roots are available"; return 1; }
  ad_python - "$WINDOWS_MGMT_FILTER_NAME" "${roots[@]}" <<'PY'
import os,sys,xml.etree.ElementTree as ET
target=sys.argv[1]
roots=sys.argv[2:]
defs={}
refs={}
for root in roots:
    if not os.path.isdir(root):
        continue
    for name in os.listdir(root):
        if not name.endswith(".xml"):
            continue
        p=os.path.join(root,name)
        try:
            r=ET.parse(p).getroot()
        except Exception:
            continue
        if r.tag!="filter" or not r.get("name"):
            continue
        n=r.get("name")
        if n in defs:
            continue
        defs[n]=p
        refs[n]=[x.get("filter") for x in r.findall(".//filterref") if x.get("filter")]
seen=set(); active=set(); order=[]
def visit(n):
    if n in seen: return
    if n in active:
        raise SystemExit(f"nwfilter dependency cycle at {n}")
    if n not in defs:
        raise SystemExit(f"missing packaged nwfilter dependency: {n}")
    active.add(n)
    for d in refs.get(n,[]): visit(d)
    active.remove(n); seen.add(n); order.append((n,defs[n]))
visit(target)
for n,p in order:
    print(n+"|"+p)
PY
}

nwfilter_runtime_load_standard_definitions() {
  local record name path
  while IFS='|' read -r name path; do
    [[ -n "$name" && -n "$path" ]] || continue
    if nwfilter_virsh nwfilter-dumpxml "$name" >/dev/null 2>&1; then
      continue
    fi
    [[ -r "$path" ]] || {
      fail "Standard libvirt nwfilter definition is not readable: $path"
      return 1
    }
    state_record_intent libvirt-nwfilter-definition "$name" loading "source=$path;preexisting-file=yes"
    nwfilter_virsh nwfilter-define "$path" >/dev/null 2>&1 || {
      fail "Could not load standard libvirt nwfilter definition '$name' from $path"
      return 1
    }
    nwfilter_virsh nwfilter-dumpxml "$name" >/dev/null 2>&1 || {
      fail "libvirt accepted '$name' but it is still not resolvable"
      return 1
    }
    # The XML was already an operator/package-owned persistent definition on
    # disk. Loading it into the active libvirt runtime is not an AutoDeploy-owned
    # persistent filter, so rollback must never nwfilter-undefine it.
    state_record_resource libvirt-nwfilter-definition "$name" activated no "source=$path;preexisting-file=yes"
    state_write_atomic
  done < <(nwfilter_runtime_definition_closure) || return 1
}

nwfilter_runtime_prepare() {
  local socket_was_active=no service_was_active=no socket_was_enabled=no
  local socket_loaded=no service_loaded=no
  systemctl is-active --quiet virtnwfilterd.socket && socket_was_active=yes
  systemctl is-active --quiet virtnwfilterd.service && service_was_active=yes
  systemctl is-enabled --quiet virtnwfilterd.socket && socket_was_enabled=yes
  [[ "$(systemctl show -p LoadState --value virtnwfilterd.socket 2>/dev/null || true)" == loaded ]] && socket_loaded=yes
  [[ "$(systemctl show -p LoadState --value virtnwfilterd.service 2>/dev/null || true)" == loaded ]] && service_loaded=yes

  if windows_management_guard_available_default; then
    if [[ "$service_was_active" != yes ]] &&
       systemctl is-active --quiet virtnwfilterd.service &&
       ! state_resource_owned libvirt-service virtnwfilterd.service; then
      state_record_resource libvirt-service virtnwfilterd.service activated yes "preexisting=inactive;probe-activated"
      state_write_atomic
    fi
    MANAGEMENT_NWFILTER_AVAILABLE=yes
    NWFILTER_RUNTIME_MODE=ready
    return 0
  fi

  if [[ "${MANAGEMENT_NWFILTER_AVAILABLE:-no}" != activatable ]]; then
    # Discovery may have run while the modular driver was cold. Re-evaluate
    # from the actual installed units/definitions before failing the deploy.
    DISCOVERY_ERRORS=()
    discover_hypervisor_safety_features
  fi
  [[ "${MANAGEMENT_NWFILTER_AVAILABLE:-no}" == activatable ]] || {
    fail "libvirt nwfilter runtime is unavailable and no standard clean-traffic definition/runtime could be activated"
    return 1
  }

  case "${NWFILTER_RUNTIME_MODE:-unavailable}" in
    modular-socket)
      # Socket activation must survive reboot because deployed management NICs
      # retain their clean-traffic filter references.
      if [[ "$socket_was_enabled" != yes ]]; then
        state_record_intent libvirt-unit-enable virtnwfilterd.socket applying "preexisting=disabled"
        systemctl enable virtnwfilterd.socket >/dev/null
        systemctl is-enabled --quiet virtnwfilterd.socket || {
          fail "Could not enable virtnwfilterd.socket for reboot-safe operation"
          return 1
        }
        state_record_resource libvirt-unit-enable virtnwfilterd.socket applied yes "preexisting=disabled"
        state_write_atomic
      fi

      if [[ "$socket_was_active" != yes ]]; then
        state_record_intent libvirt-service virtnwfilterd.socket activating "preexisting=inactive"
        systemctl start virtnwfilterd.socket
        systemctl is-active --quiet virtnwfilterd.socket || {
          fail "Could not activate virtnwfilterd.socket"
          return 1
        }
        state_record_resource libvirt-service virtnwfilterd.socket activated yes "preexisting=inactive"
        state_write_atomic
      fi

      # Some mixed/transition libvirt installations do not route a normal
      # virsh request through the newly opened socket automatically. Explicitly
      # start the modular service when available so it loads persistent filters.
      if [[ "$service_loaded" == yes && "$service_was_active" != yes ]]; then
        state_record_intent libvirt-service virtnwfilterd.service activating "preexisting=inactive"
        systemctl start virtnwfilterd.service >/dev/null 2>&1 || true
        if systemctl is-active --quiet virtnwfilterd.service; then
          state_record_resource libvirt-service virtnwfilterd.service activated yes "preexisting=inactive;explicit-start"
          state_write_atomic
        fi
      fi
      ;;
    modular-service)
      if [[ "$service_was_active" != yes ]]; then
        state_record_intent libvirt-service virtnwfilterd.service activating "preexisting=inactive"
        systemctl start virtnwfilterd.service
        systemctl is-active --quiet virtnwfilterd.service || {
          fail "Could not activate virtnwfilterd.service"
          return 1
        }
        state_record_resource libvirt-service virtnwfilterd.service activated yes "preexisting=inactive"
        state_write_atomic
      fi
      ;;
    definition-reload)
      ;;
    *)
      fail "Unsupported libvirt nwfilter activation mode: ${NWFILTER_RUNTIME_MODE:-unknown}"
      return 1
      ;;
  esac

  # First see whether service activation loaded the standard filters. If not,
  # load the dependency closure from the already installed /etc/libvirt/nwfilter
  # XML definitions using libvirt's supported nwfilter-define API.
  if ! windows_management_guard_available; then
    nwfilter_runtime_load_standard_definitions || return 1
  fi

  windows_management_guard_available || {
    fail "libvirt still cannot resolve '$WINDOWS_MGMT_FILTER_NAME' after activating/reloading the standard nwfilter runtime"
    return 1
  }

  if [[ "$service_was_active" != yes ]] &&
     systemctl is-active --quiet virtnwfilterd.service &&
     ! state_resource_owned libvirt-service virtnwfilterd.service; then
    state_record_resource libvirt-service virtnwfilterd.service activated yes "preexisting=inactive;runtime-activated"
    state_write_atomic
  fi

  MANAGEMENT_NWFILTER_AVAILABLE=yes
  NWFILTER_RUNTIME_MODE=ready
  pass "libvirt nwfilter runtime ready"
}
nwfilter_runtime_has_bindings() {
  local out
  out="$(nwfilter_virsh nwfilter-binding-list 2>/dev/null)" || return 2
  [[ -n "$(printf '%s\n' "$out" | awk 'NR>2 && NF {print; exit}')" ]]
}

nwfilter_runtime_rollback() {
  local owned_socket=no owned_service=no owned_enable=no
  state_resource_owned libvirt-service virtnwfilterd.socket && owned_socket=yes
  state_resource_owned libvirt-service virtnwfilterd.service && owned_service=yes
  state_resource_owned libvirt-unit-enable virtnwfilterd.socket && owned_enable=yes
  [[ "$owned_socket" == yes || "$owned_service" == yes || "$owned_enable" == yes ]] || return 0

  # Never trade exact daemon-state restoration for possible disruption of a
  # filter binding that appeared while AutoDeploy was active. If bindings are
  # present, or their state cannot be proven, leave the runtime available and
  # boot-enabled.
  local binding_rc=0
  if nwfilter_runtime_has_bindings; then
    warn "libvirt nwfilter bindings remain; leaving AutoDeploy-started nwfilter runtime active"
    [[ "$owned_service" == yes ]] && state_record_resource libvirt-service virtnwfilterd.service released yes "left-active;bindings-present"
    [[ "$owned_socket" == yes ]] && state_record_resource libvirt-service virtnwfilterd.socket released yes "left-active;bindings-present"
    [[ "$owned_enable" == yes ]] && state_record_resource libvirt-unit-enable virtnwfilterd.socket released yes "left-enabled;bindings-present"
    state_write_atomic
    return 0
  else
    binding_rc=$?
  fi
  if ((binding_rc == 2)); then
    warn "Could not prove nwfilter binding state; leaving AutoDeploy-started nwfilter runtime active"
    [[ "$owned_service" == yes ]] && state_record_resource libvirt-service virtnwfilterd.service released yes "left-active;binding-state-unproven"
    [[ "$owned_socket" == yes ]] && state_record_resource libvirt-service virtnwfilterd.socket released yes "left-active;binding-state-unproven"
    [[ "$owned_enable" == yes ]] && state_record_resource libvirt-unit-enable virtnwfilterd.socket released yes "left-enabled;binding-state-unproven"
    state_write_atomic
    return 0
  fi

  if [[ "$owned_service" == yes ]]; then
    systemctl stop virtnwfilterd.service
    state_record_resource libvirt-service virtnwfilterd.service restored yes "restored=inactive"
  fi
  if [[ "$owned_socket" == yes ]]; then
    systemctl stop virtnwfilterd.socket
    state_record_resource libvirt-service virtnwfilterd.socket restored yes "restored=inactive"
  fi
  if [[ "$owned_enable" == yes ]]; then
    systemctl disable virtnwfilterd.socket >/dev/null
    state_record_resource libvirt-unit-enable virtnwfilterd.socket restored yes "restored=disabled"
  fi
  state_write_atomic
}

windows_management_guard_apply() {
  local state
  state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
  case "$state" in
    "shut off"|paused) ;;
    *) fail "Windows management anti-spoof guard must be applied while the analysis VM is shut off or paused"; return 1 ;;
  esac
  [[ -n "${WINDOWS_MANAGEMENT_MAC:-}" && -n "${MANAGEMENT_NETWORK_NAME:-}" && -n "${CAPE_MACHINE_IP:-}" ]] || {
    fail "Windows management NIC identity is incomplete"
    return 1
  }
  windows_management_guard_available || {
    fail "libvirt nwfilter '$WINDOWS_MGMT_FILTER_NAME' is unavailable; refusing a deployment without hypervisor anti-spoofing"
    return 1
  }

  local facts backup original guarded
  local -a update_args=(--config)
  [[ "$state" == paused ]] && update_args+=(--live)
  facts="$(windows_management_guard_filter_facts)" || {
    fail "Could not inspect Windows management NIC filter state"
    return 1
  }

  if [[ "$facts" == "$WINDOWS_MGMT_FILTER_NAME|$CAPE_MACHINE_IP" ]]; then
    if state_resource_owned domain-interface-filter "$DOMAIN:$WINDOWS_MANAGEMENT_MAC"; then
      pass "Windows management anti-spoof guard already applied and owned"
      return 0
    fi
    if state_resource_intended domain-interface-filter "$DOMAIN:$WINDOWS_MANAGEMENT_MAC"; then
      state_record_resource domain-interface-filter "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" recovered-applied yes "filter=$WINDOWS_MGMT_FILTER_NAME ip=$CAPE_MACHINE_IP"
      state_write_atomic
      pass "Recovered deployment-owned Windows management anti-spoof guard"
      return 0
    fi
    # A pre-existing exact clean-traffic/IP policy is protective and remains
    # operator-owned. AutoDeploy may rely on it but will never remove it.
    state_record_resource domain-interface-filter "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" preexisting no "filter=$WINDOWS_MGMT_FILTER_NAME ip=$CAPE_MACHINE_IP"
    pass "Using pre-existing Windows management anti-spoof guard"
    return 0
  fi

  [[ "$facts" == "none|" ]] || {
    fail "Windows management NIC already has an unrecognized libvirt nwfilter ($facts); refusing to overwrite operator policy"
    return 1
  }

  backup="$(windows_management_guard_backup_path)"
  install -d -m 0700 "$(dirname "$backup")"
  original="$(windows_management_interface_xml)" || return 1
  printf '%s\n' "$original" >"$backup"
  chmod 0600 "$backup"

  guarded="$AD_GENERATED_ROOT/${DEPLOYMENT_ID}-windows-management-$(ad_safe_token "$DOMAIN-$WINDOWS_MANAGEMENT_MAC").xml"
  ad_python - "$WINDOWS_MGMT_FILTER_NAME" "$CAPE_MACHINE_IP" "$backup" >"$guarded" <<'PY'
import sys,xml.etree.ElementTree as ET
name,ip,path=sys.argv[1:]
root=ET.parse(path).getroot()
if root.find("filterref") is not None:
    raise SystemExit("refusing to replace existing filterref")
ref=ET.SubElement(root,"filterref",{"filter":name})
ET.SubElement(ref,"parameter",{"name":"IP","value":ip})
print(ET.tostring(root,encoding="unicode"))
PY
  chmod 0600 "$guarded"

  state_record_intent domain-interface-filter "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" applying "filter=$WINDOWS_MGMT_FILTER_NAME ip=$CAPE_MACHINE_IP backup=$backup"
  virsh update-device "$DOMAIN" "$guarded" "${update_args[@]}" >/dev/null
  windows_management_guard_exact inactive || {
    fail "Could not verify persistent Windows management anti-spoof guard after libvirt update"
    return 1
  }
  if [[ "$state" == paused ]] && ! windows_management_guard_exact current; then
    fail "Could not verify live Windows management anti-spoof guard on paused analysis VM"
    return 1
  fi
  state_record_resource domain-interface-filter "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" applied yes "filter=$WINDOWS_MGMT_FILTER_NAME ip=$CAPE_MACHINE_IP backup=$backup"
  state_write_atomic
  pass "Applied hypervisor anti-spoof guard to Windows management NIC"
}

windows_management_guard_verify() {
  windows_management_guard_available || return 1
  windows_management_guard_exact
}

windows_management_guard_restore_if_owned() {
  state_resource_owned domain-interface-filter "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" || return 0

  local facts backup state args=(--config)
  facts="$(windows_management_guard_filter_facts 2>/dev/null || true)"
  if [[ "$facts" == "none|" ]]; then
    state_record_resource domain-interface-filter "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" restored yes "restored-by-snapshot"
    return 0
  fi
  [[ "$facts" == "$WINDOWS_MGMT_FILTER_NAME|$CAPE_MACHINE_IP" ]] || {
    fail "Windows management NIC filter changed externally; refusing to overwrite it during rollback"
    return 1
  }

  backup="$(windows_management_guard_backup_path)"
  [[ -s "$backup" ]] || {
    fail "Windows management NIC backup is missing: $backup"
    return 1
  }
  state="$(virsh domstate "$DOMAIN" 2>/dev/null | xargs || true)"
  [[ "$state" == running || "$state" == paused ]] && args+=(--live)
  virsh update-device "$DOMAIN" "$backup" "${args[@]}" >/dev/null

  facts="$(windows_management_guard_filter_facts 2>/dev/null || true)"
  [[ "$facts" == "none|" ]] || {
    fail "Windows management anti-spoof guard could not be restored to its pre-deployment state"
    return 1
  }
  state_record_resource domain-interface-filter "$DOMAIN:$WINDOWS_MANAGEMENT_MAC" restored yes "backup=$backup"
  state_write_atomic
}
