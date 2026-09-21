#!/usr/bin/env bash

APPLIANCE_MANIFEST="${APPLIANCE_MANIFEST:-$AUTODEPLOY_ROOT/appliance/manifest.json}"
APPLIANCE_CACHE_ROOT="${APPLIANCE_CACHE_ROOT:-/var/cache/cape-inetsim-autodeploy}"

appliance_manifest_field() {
  local field="$1" manifest="${2:-$APPLIANCE_MANIFEST}"
  python3 - "$manifest" "$field" <<'PY'
import json,sys
p,key=sys.argv[1:]
with open(p) as f: d=json.load(f)
v=d
for part in key.split('.'):
    if not isinstance(v,dict) or part not in v: raise SystemExit(2)
    v=v[part]
if v is None: print('')
elif isinstance(v,bool): print('true' if v else 'false')
else: print(v)
PY
}

appliance_manifest_validate() {
  local manifest="${1:-$APPLIANCE_MANIFEST}"
  python3 - "$manifest" <<'PY'
import json,re,sys,urllib.parse
p=sys.argv[1]
try:
    with open(p) as f: d=json.load(f)
except Exception as e:
    print(f"invalid JSON: {e}", file=sys.stderr); raise SystemExit(2)
required=['schema','appliance_version','status','artifact_name','artifact_url','sha256','format','os','inetsim','guest_management','networking']
missing=[k for k in required if k not in d]
if missing:
    print('missing fields: '+','.join(missing), file=sys.stderr); raise SystemExit(2)
if d['schema'] != 1:
    print('unsupported manifest schema', file=sys.stderr); raise SystemExit(2)
if d['status'] != 'published':
    print('appliance artifact is not published yet', file=sys.stderr); raise SystemExit(3)
url=str(d['artifact_url'] or '')
if urllib.parse.urlparse(url).scheme != 'https':
    print('artifact_url must use https', file=sys.stderr); raise SystemExit(2)
sha=str(d['sha256'] or '').lower()
if not re.fullmatch(r'[0-9a-f]{64}', sha):
    print('sha256 must be 64 hex characters', file=sys.stderr); raise SystemExit(2)
if d['format'] != 'qcow2':
    print('only qcow2 appliances are supported', file=sys.stderr); raise SystemExit(2)
name=str(d.get('artifact_name') or '')
if not name or name != name.split('/')[-1] or name in ('.','..'):
    print('artifact_name must be a safe basename', file=sys.stderr); raise SystemExit(2)
osinfo=d.get('os') or {}
if osinfo.get('distribution') != 'Ubuntu' or osinfo.get('release') != '24.04 LTS' or osinfo.get('architecture') != 'x86_64':
    print('unsupported appliance OS identity', file=sys.stderr); raise SystemExit(2)
if (d.get('guest_management') or {}).get('qemu_guest_agent') is not True:
    print('appliance must require QEMU Guest Agent management', file=sys.stderr); raise SystemExit(2)
if (d.get('networking') or {}).get('baked_in_fake_internet_subnet') is not False:
    print('appliance must not contain a baked-in fake-Internet subnet', file=sys.stderr); raise SystemExit(2)
if (d.get('inetsim') or {}).get('unprivileged_port_start') != 53:
    print('appliance low-port safety setting is unexpected', file=sys.stderr); raise SystemExit(2)
print('OK')
PY
}

appliance_verify_file() {
  local file="$1" manifest="${2:-$APPLIANCE_MANIFEST}"
  [[ -f "$file" ]] || { fail "Appliance artifact missing: $file"; return 1; }
  local expected actual
  expected="$(appliance_manifest_field sha256 "$manifest")"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    fail "Appliance SHA-256 mismatch"
    return 1
  }
  if have qemu-img; then
    local info_check
    info_check="$(qemu-img info --output=json "$file" 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit(2)
if d.get("format")!="qcow2": print("format="+str(d.get("format","unknown"))); raise SystemExit(3)
for key in ("backing-filename","full-backing-filename","data-file","full-data-filename"):
    if d.get(key): print("external="+key); raise SystemExit(4)
print("OK")
' 2>/dev/null || true)"
    [[ "$info_check" == OK ]] || { fail "Appliance qcow2 has an unsupported format/backing dependency"; return 1; }
    qemu-img check "$file" >/dev/null || { fail "Appliance qcow2 integrity check failed"; return 1; }
  fi
  pass "Appliance artifact checksum verified"
}

appliance_fetch() {
  local manifest="${1:-$APPLIANCE_MANIFEST}"
  appliance_manifest_validate "$manifest" >/dev/null
  local name url cache part
  name="$(appliance_manifest_field artifact_name "$manifest")"
  url="$(appliance_manifest_field artifact_url "$manifest")"
  install -d -m 0755 "$APPLIANCE_CACHE_ROOT"
  cache="$APPLIANCE_CACHE_ROOT/$name"
  part="$cache.part"

  if [[ -f "$cache" ]] && appliance_verify_file "$cache" "$manifest" >/dev/null 2>&1; then
    printf '%s\n' "$cache"
    return 0
  fi

  rm -f "$part"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$part" "$url"
  appliance_verify_file "$part" "$manifest" >&2
  chmod 0644 "$part"
  mv -f "$part" "$cache"
  printf '%s\n' "$cache"
}
