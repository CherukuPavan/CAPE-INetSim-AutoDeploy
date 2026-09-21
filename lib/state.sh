#!/usr/bin/env bash

AD_STATE_SCHEMA=1
AD_STATE_ROOT_DEFAULT="/var/lib/cape-inetsim-autodeploy"

state_root() {
  printf '%s\n' "${AD_STATE_ROOT:-$AD_STATE_ROOT_DEFAULT}"
}

state_file() {
  printf '%s/state.json\n' "$(state_root)"
}

resource_file() {
  printf '%s/resources.tsv\n' "$(state_root)"
}

backup_root() {
  printf '%s/backups\n' "$(state_root)"
}

state_prepare_dirs() {
  local root
  root="$(state_root)"
  install -d -m 0750 -o root -g root "$root" "$root/backups" "$root/generated" "$root/logs"
  touch "$root/resources.tsv"
  chmod 0640 "$root/resources.tsv"
}

state_write_initial() {
  state_prepare_dirs
  local file tmp
  file="$(state_file)"
  if [[ -e "$file" ]]; then
    return 0
  fi
  tmp="${file}.tmp.$$"
  python3 - "$tmp" <<PY
import json,os,socket,sys,time
p=sys.argv[1]
data={
 "schema_version": $AD_STATE_SCHEMA,
 "installer_version": "${AD_VERSION}",
 "phase": "planned",
 "hostname": socket.gethostname(),
 "created_at": int(time.time()),
 "updated_at": int(time.time()),
 "cape_root": "${CAPE_ROOT:-}",
 "cape_machine": "${CAPE_MACHINE_SECTION:-}",
 "cape_label": "${CAPE_MACHINE_LABEL:-}",
 "libvirt_domain": "${DOMAIN:-}",
 "original_cape_snapshot": "${CAPE_MACHINE_SNAPSHOT:-}",
 "isolated_subnet": "${ISOLATED_SUBNET:-}",
 "bridge_ip": "${BRIDGE_IP:-}",
 "inetsim_ip": "${INETSIM_IP:-}",
 "windows_fake_ip": "${WINDOWS_FAKE_IP:-}",
 "libvirt_network": "${PLANNED_NETWORK_NAME:-}",
 "bridge_name": "${PLANNED_BRIDGE_NAME:-}"
}
with open(p,"w") as f:
    json.dump(data,f,indent=2,sort_keys=True)
    f.write("\n")
os.chmod(p,0o640)
PY
  mv -f "$tmp" "$file"
}

state_set_phase() {
  local phase="$1" file tmp
  file="$(state_file)"
  [[ -f "$file" ]] || { fail "State file missing: $file"; return 1; }
  tmp="${file}.tmp.$$"
  python3 - "$file" "$tmp" "$phase" <<'PY'
import json,os,sys,time
src,dst,phase=sys.argv[1:4]
with open(src) as f: d=json.load(f)
d["phase"]=phase
d["updated_at"]=int(time.time())
with open(dst,"w") as f:
    json.dump(d,f,indent=2,sort_keys=True); f.write("\n")
os.chmod(dst,0o640)
PY
  mv -f "$tmp" "$file"
}

state_get() {
  local key="$1" file
  file="$(state_file)"
  [[ -f "$file" ]] || return 1
  python3 - "$file" "$key" <<'PY'
import json,sys
with open(sys.argv[1]) as f: d=json.load(f)
v=d.get(sys.argv[2],"")
if isinstance(v,(dict,list)): print(json.dumps(v,separators=(",",":")))
else: print(v)
PY
}
