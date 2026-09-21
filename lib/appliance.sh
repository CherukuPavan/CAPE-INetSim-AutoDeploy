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
required=['schema','appliance_version','status','artifact_name','artifact_url','sha256','format','os','inetsim']
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
    local fmt
    fmt="$(qemu-img info --output=json "$file" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format",""))' 2>/dev/null || true)"
    [[ "$fmt" == qcow2 ]] || { fail "Appliance is not qcow2 (detected: ${fmt:-unknown})"; return 1; }
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
