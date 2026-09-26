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
required=['schema','appliance_version','status','artifact_name','artifact_url','sha256','format','os','inetsim','guest_management','networking','transport']
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
transport=d.get('transport') or {}
if transport.get('compression') not in ('none','gzip'):
    print('unsupported appliance transport compression', file=sys.stderr); raise SystemExit(2)
tname=str(transport.get('artifact_name') or '')
if not tname or tname != tname.split('/')[-1] or tname in ('.','..'):
    print('transport artifact_name must be a safe basename', file=sys.stderr); raise SystemExit(2)
tsha=str(transport.get('sha256') or '').lower()
if not re.fullmatch(r'[0-9a-f]{64}', tsha):
    print('transport sha256 must be 64 hex characters', file=sys.stderr); raise SystemExit(2)
if transport.get('compression')=='gzip' and not tname.endswith('.gz'):
    print('gzip transport artifact must end in .gz', file=sys.stderr); raise SystemExit(2)
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

appliance_verify_transport_file() {
  local file="$1" manifest="${2:-$APPLIANCE_MANIFEST}"
  [[ -f "$file" ]] || { fail "Appliance transport artifact missing: $file"; return 1; }
  local expected actual
  expected="$(appliance_manifest_field transport.sha256 "$manifest")"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    fail "Appliance transport SHA-256 mismatch"
    return 1
  }
}

appliance_download_transport() {
  local url="$1" part="$2"
  local existing=0 rc=0
  local -a args=(
    --fail
    --location
    --proto '=https'
    --tlsv1.2
    --retry 20
    --retry-delay 3
    --retry-all-errors
    --connect-timeout 20
    --speed-time 60
    --speed-limit 1024
  )

  [[ -e "$part" ]] || : >"$part"
  existing="$(stat -c '%s' "$part" 2>/dev/null || echo 0)"

  if ((existing > 0)); then
    info "Resuming appliance download from byte $existing" >&2
    args+=(--continue-at -)
  else
    info "Downloading appliance transport with retry/stall protection" >&2
  fi

  if curl "${args[@]}" --output "$part" "$url"; then
    return 0
  fi
  rc=$?

  # curl 33 means the remote endpoint rejected the requested resume offset.
  # Keep generic network failures resumable, but a server that cannot resume
  # needs one clean restart rather than trapping the installer forever.
  if ((existing > 0 && rc == 33)); then
    warn "Release server rejected ranged resume; restarting this transport download from byte 0" >&2
    : >"$part"
    curl --fail --location --proto '=https' --tlsv1.2 \
      --retry 20 --retry-delay 3 --retry-all-errors \
      --connect-timeout 20 --speed-time 60 --speed-limit 1024 \
      --output "$part" "$url"
    return $?
  fi

  fail "Appliance transport download stopped with curl exit $rc; partial file was preserved for the next retry" >&2
  return "$rc"
}

appliance_fetch() {
  local manifest="${1:-$APPLIANCE_MANIFEST}"
  appliance_manifest_validate "$manifest" >/dev/null

  local name url compression transport_name transport_sha cache raw_part transport transport_part
  name="$(appliance_manifest_field artifact_name "$manifest")"
  url="$(appliance_manifest_field artifact_url "$manifest")"
  compression="$(appliance_manifest_field transport.compression "$manifest")"
  transport_name="$(appliance_manifest_field transport.artifact_name "$manifest")"
  transport_sha="$(appliance_manifest_field transport.sha256 "$manifest")"

  install -d -m 0755 "$APPLIANCE_CACHE_ROOT"
  cache="$APPLIANCE_CACHE_ROOT/$name"
  raw_part="$cache.part"
  transport="$APPLIANCE_CACHE_ROOT/$transport_name"
  transport_part="$transport.$transport_sha.part"

  if [[ -f "$cache" ]] && appliance_verify_file "$cache" "$manifest" >/dev/null 2>&1; then
    pass "Reusing verified cached appliance artifact" >&2
    printf '%s\n' "$cache"
    return 0
  fi

  # A previously completed transport can also be reused if it belongs to this
  # exact manifest. Otherwise retain/resume only the .part download.
  if [[ -f "$transport" ]] && appliance_verify_transport_file "$transport" "$manifest" >/dev/null 2>&1; then
    pass "Reusing verified cached appliance transport" >&2
  else
    rm -f "$transport"
    appliance_download_transport "$url" "$transport_part" || return $?

    if ! appliance_verify_transport_file "$transport_part" "$manifest" >/dev/null 2>&1; then
      # Even an exact-SHA partial can be corrupted locally. Its checksum proves
      # it cannot be completed into this manifest, so restart exactly once.
      warn "Resumed appliance transport did not match this release checksum; retrying once from byte 0" >&2
      : >"$transport_part"
      appliance_download_transport "$url" "$transport_part" || return $?
      appliance_verify_transport_file "$transport_part" "$manifest" >&2 || {
        fail "Appliance transport checksum still mismatches after a clean retry" >&2
        return 1
      }
    else
      pass "Appliance transport SHA-256 verified" >&2
    fi

    chmod 0644 "$transport_part"
    mv -f "$transport_part" "$transport"
  fi

  rm -f "$raw_part"
  case "$compression" in
    none)
      cp --reflink=auto "$transport" "$raw_part"
      ;;
    gzip)
      have gzip || { fail "gzip is required to unpack the appliance release"; return 1; }
      gzip -t "$transport" || { fail "Appliance gzip transport integrity check failed"; return 1; }
      gzip -dc "$transport" >"$raw_part"
      ;;
    *)
      fail "Unsupported appliance transport compression: $compression"
      return 1
      ;;
  esac

  appliance_verify_file "$raw_part" "$manifest" >&2
  chmod 0644 "$raw_part"
  mv -f "$raw_part" "$cache"
  pass "Appliance artifact checksum/integrity verified and cached" >&2
  printf '%s\n' "$cache"
}

