#!/usr/bin/env bash

APPLIANCE_MANIFEST="${APPLIANCE_MANIFEST:-$AUTODEPLOY_ROOT/appliance/manifest.json}"
APPLIANCE_CACHE_ROOT="${APPLIANCE_CACHE_ROOT:-/var/cache/cape-inetsim-autodeploy}"

appliance_manifest_field() {
  local field="$1" manifest="${2:-$APPLIANCE_MANIFEST}"
  ad_python - "$manifest" "$field" <<'PY'
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
  ad_python - "$manifest" <<'PY'
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
for key in ('sha256','transport_sha256'):
    if key in d and d[key] is not None and not re.fullmatch(r'[0-9a-fA-F]{64}',str(d[key])):
        print(f'{key} must be 64 hex characters', file=sys.stderr); raise SystemExit(2)
if d['format'] != 'qcow2':
    print('only qcow2 appliances are supported', file=sys.stderr); raise SystemExit(2)
compression=str(d.get('transport_compression','none')).lower()
if compression not in ('none','gzip'):
    print('unsupported transport compression', file=sys.stderr); raise SystemExit(2)
if compression=='gzip' and not d.get('transport_sha256'):
    print('gzip transport requires transport_sha256', file=sys.stderr); raise SystemExit(2)
print('OK')
PY
}

appliance_verify_file() {
  local file="$1" manifest="${2:-$APPLIANCE_MANIFEST}"
  [[ -f "$file" ]] || { fail "Appliance artifact missing: $file"; return 1; }
  local expected actual
  expected="$(appliance_manifest_field sha256 "$manifest")"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { fail "Appliance SHA-256 mismatch"; return 1; }
  if have qemu-img; then
    local fmt
    fmt="$(qemu-img info --output=json "$file" 2>/dev/null | ad_python -c 'import json,sys; print(json.load(sys.stdin).get("format",""))' 2>/dev/null || true)"
    [[ "$fmt" == qcow2 ]] || { fail "Appliance is not qcow2 (detected: ${fmt:-unknown})"; return 1; }
  fi
  pass "Appliance QCOW2 checksum/format verified"
}

appliance_fetch() {
  local manifest="${1:-$APPLIANCE_MANIFEST}"
  appliance_manifest_validate "$manifest" >/dev/null
  local name url cache compression transport_sha transport part actual
  name="$(appliance_manifest_field artifact_name "$manifest")"
  url="$(appliance_manifest_field artifact_url "$manifest")"
  compression="$(appliance_manifest_field transport_compression "$manifest" 2>/dev/null || echo none)"
  transport_sha="$(appliance_manifest_field transport_sha256 "$manifest" 2>/dev/null || true)"
  install -d -m 0755 "$APPLIANCE_CACHE_ROOT"
  cache="$APPLIANCE_CACHE_ROOT/$name"

  if [[ -f "$cache" ]] && appliance_verify_file "$cache" "$manifest" >/dev/null 2>&1; then
    printf '%s\n' "$cache"
    return 0
  fi

  transport="$cache.download"
  [[ "$compression" == gzip ]] && transport="$transport.gz"
  part="$transport.part"
  rm -f "$part" "$transport" "$cache.part"

  curl --fail --location --proto '=https' --tlsv1.2 --retry 5 --retry-all-errors --continue-at - --output "$part" "$url"
  mv -f "$part" "$transport"

  if [[ -n "$transport_sha" ]]; then
    actual="$(sha256sum "$transport" | awk '{print $1}')"
    [[ "$actual" == "$transport_sha" ]] || { rm -f "$transport"; fail "Appliance transport SHA-256 mismatch"; return 1; }
  fi

  case "$compression" in
    gzip)
      gzip -t "$transport"
      gzip -dc "$transport" >"$cache.part"
      ;;
    none)
      cp -f "$transport" "$cache.part"
      ;;
  esac

  appliance_verify_file "$cache.part" "$manifest" >&2
  chmod 0644 "$cache.part"
  mv -f "$cache.part" "$cache"
  rm -f "$transport"
  printf '%s\n' "$cache"
}
