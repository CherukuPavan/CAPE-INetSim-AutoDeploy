#!/usr/bin/env bash

validate_windows_result_file() {
  local f="$AD_LOG_ROOT/${DEPLOYMENT_ID}-windows-verify.json"
  [[ -f "$f" ]] || { fail "Windows verification record missing: $f"; return 1; }
  python3 - "$f" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8-sig") as h: d=json.load(h)
assert d.get("ok") is True
assert int(d.get("default_routes",-1)) == 0
assert d.get("resultserver_reachable") is True
assert d.get("public_ip_reachable") is False
PY
}

validate_final_snapshot_hardware() {
  local xml
  xml="$(virsh snapshot-dumpxml "$DOMAIN" "$FINAL_SNAPSHOT")" || return 1
  python3 -c '
import sys,xml.etree.ElementTree as ET
net,mac=sys.argv[1],sys.argv[2].lower()
r=ET.fromstring(sys.stdin.read())
if (r.findtext("state") or "")!="running": raise SystemExit("snapshot state is not running")
mem=r.find("memory")
if mem is None or mem.get("snapshot")!="internal": raise SystemExit("snapshot has no internal memory state")
dom=r.find("domain")
if dom is None: raise SystemExit("snapshot has no embedded domain XML")
found=False
for i in dom.findall("./devices/interface"):
    s=i.find("source"); m=i.find("mac")
    if s is not None and s.get("network")==net and m is not None and (m.get("address") or "").lower()==mac:
        found=True
if not found: raise SystemExit("snapshot does not contain the isolated NIC")
' "$ISOLATED_NETWORK_NAME" "$WINDOWS_ISOLATED_MAC" <<<"$xml"
}

validate_cape_configuration() {
  python3 - "$CAPE_ROOT" "$CAPE_MACHINE_SECTION" "$CAPE_MACHINE_LABEL" "$FINAL_SNAPSHOT" "$ISOLATED_BRIDGE_NAME" "$WINDOWS_FAKE_IP" <<'PY'
import configparser,sys
root,section,label,snapshot,iface,fake=sys.argv[1:]
def load(name):
    c=configparser.ConfigParser(interpolation=None,strict=False)
    c.optionxform=str.lower
    c.read(f"{root}/conf/{name}.conf")
    return c
k=load("kvm")
a=load("auxiliary")
p=load("processing")
r=load("routing")
if not k.has_section(section): raise SystemExit("CAPE machine section missing")
if k.get(section,"snapshot",fallback="") != snapshot: raise SystemExit("CAPE snapshot mismatch")
if k.get(section,"interface",fallback="") != iface: raise SystemExit("CAPE interface mismatch")
if a.get("sniffer",f"capture_host_{label}",fallback="") != fake: raise SystemExit("capture host mismatch")
if p.get("network","dnswhitelist",fallback="").lower() != "no": raise SystemExit("dnswhitelist not disabled")
if p.get("network","ipwhitelist",fallback="").lower() != "no": raise SystemExit("ipwhitelist not disabled")
if r.get("routing","route",fallback="").lower() != "none": raise SystemExit("CAPE default route is not none")
PY
  grep -q 'CAPE_INETSIM_AUTODEPLOY_CAPTURE_V1' "$CAPE_ROOT/modules/auxiliary/sniffer.py"
}

validate_resultserver_host() {
  [[ "${CAPE_SERVICE_WAS_ACTIVE:-yes}" == yes ]] || return 0
  timeout 3 bash -c "</dev/tcp/$CAPE_RESULTSERVER_IP/$CAPE_RESULTSERVER_PORT" >/dev/null 2>&1 || {
    fail "CAPE ResultServer is not reachable at $CAPE_RESULTSERVER_IP:$CAPE_RESULTSERVER_PORT"
    return 1
  }
}

validate_deployment_structural() {
  verify_isolated_network_definition "$ISOLATED_NETWORK_NAME" "$ISOLATED_BRIDGE_NAME" "$ISOLATED_SUBNET" "$BRIDGE_IP"
  inetsim_verify_host
  validate_windows_result_file
  validate_final_snapshot_hardware
  validate_cape_configuration
  grep -Rqs 'CAPE_INETSIM_VM_ROUTE_NONE_V1' "$CAPE_ROOT/web"
  pass "Structural deployment gates passed"
}

validate_deployment_services() {
  services_validate_restored_state
  validate_resultserver_host
  pass "CAPE service and ResultServer health gates passed"
}
