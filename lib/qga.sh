#!/usr/bin/env bash

qga_wait() {
  local dom="$1" timeout="${2:-180}" i
  for ((i=0;i<timeout;i+=2)); do
    virsh qemu-agent-command "$dom" '{"execute":"guest-ping"}' >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

qga_exec_wait() {
  local dom="$1" path="$2"
  shift 2
  local json pid status exited i args_json
  args_json="$(python3 - "$@" <<'PY'
import json,sys
print(json.dumps(sys.argv[1:]))
PY
)"
  json="$(python3 - "$path" "$args_json" <<'PY'
import json,sys
print(json.dumps({"execute":"guest-exec","arguments":{"path":sys.argv[1],"arg":json.loads(sys.argv[2]),"capture-output":True}}))
PY
)"
  pid="$(virsh qemu-agent-command "$dom" "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])')"

  for ((i=0;i<180;i++)); do
    status="$(virsh qemu-agent-command "$dom" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}")"
    exited="$(python3 -c 'import json,sys; print(str(json.load(sys.stdin)["return"].get("exited",False)).lower())' <<<"$status")"
    if [[ "$exited" == true ]]; then
      python3 -c 'import base64,json,sys
r=json.load(sys.stdin)["return"]
if r.get("out-data"): sys.stdout.write(base64.b64decode(r["out-data"]).decode(errors="replace"))
if r.get("err-data"): sys.stderr.write(base64.b64decode(r["err-data"]).decode(errors="replace"))
raise SystemExit(r.get("exitcode",1))' <<<"$status"
      return $?
    fi
    sleep 1
  done
  return 124
}

qga_file_write() {
  local dom="$1" local_file="$2" remote_path="$3"
  [[ -f "$local_file" ]] || return 1
  local open_json handle data chunk write_json
  open_json="$(python3 - "$remote_path" <<'PY'
import json,sys
print(json.dumps({"execute":"guest-file-open","arguments":{"path":sys.argv[1],"mode":"w"}}))
PY
)"
  handle="$(virsh qemu-agent-command "$dom" "$open_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"])')"
  data="$(base64 -w0 "$local_file")"
  while [[ -n "$data" ]]; do
    chunk="${data:0:32768}"
    data="${data:32768}"
    write_json="$(python3 - "$handle" "$chunk" <<'PY'
import json,sys
print(json.dumps({"execute":"guest-file-write","arguments":{"handle":int(sys.argv[1]),"buf-b64":sys.argv[2]}}))
PY
)"
    virsh qemu-agent-command "$dom" "$write_json" >/dev/null
  done
  virsh qemu-agent-command "$dom" "{\"execute\":\"guest-file-flush\",\"arguments\":{\"handle\":$handle}}" >/dev/null
  virsh qemu-agent-command "$dom" "{\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":$handle}}" >/dev/null
}

qga_file_read() {
  local dom="$1" remote_path="$2" local_file="$3"
  local open_json handle resp eof
  open_json="$(python3 - "$remote_path" <<'PY'
import json,sys
print(json.dumps({"execute":"guest-file-open","arguments":{"path":sys.argv[1],"mode":"r"}}))
PY
)"
  handle="$(virsh qemu-agent-command "$dom" "$open_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"])')"
  : >"$local_file"
  while :; do
    resp="$(virsh qemu-agent-command "$dom" "{\"execute\":\"guest-file-read\",\"arguments\":{\"handle\":$handle,\"count\":32768}}")"
    python3 - "$local_file" <<'PY' <<<"$resp"
import base64,json,sys
p=sys.argv[1]
r=json.load(sys.stdin)["return"]
b=r.get("buf-b64")
if b:
    with open(p,"ab") as f: f.write(base64.b64decode(b))
PY
    eof="$(python3 -c 'import json,sys; print(str(json.load(sys.stdin)["return"].get("eof",False)).lower())' <<<"$resp")"
    [[ "$eof" == true ]] && break
  done
  virsh qemu-agent-command "$dom" "{\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":$handle}}" >/dev/null
}
