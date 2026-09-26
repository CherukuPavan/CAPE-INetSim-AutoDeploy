#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTODEPLOY_ROOT="$ROOT"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/appliance.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'fake qcow2 bytes for checksum test\n' >"$TMP/a.qcow2"
gzip -c "$TMP/a.qcow2" >"$TMP/a.qcow2.gz"
raw_sha="$(sha256sum "$TMP/a.qcow2" | awk '{print $1}')"
transport_sha="$(sha256sum "$TMP/a.qcow2.gz" | awk '{print $1}')"

cat >"$TMP/manifest.json" <<EOF2
{
  "schema":1,
  "appliance_version":"test",
  "status":"published",
  "artifact_name":"a.qcow2",
  "artifact_url":"https://example.invalid/a.qcow2.gz",
  "sha256":"$raw_sha",
  "format":"qcow2",
  "os":{"distribution":"Ubuntu","release":"24.04 LTS","architecture":"x86_64"},
  "inetsim":{"unprivileged_port_start":53},
  "guest_management":{"qemu_guest_agent":true},
  "networking":{"baked_in_fake_internet_subnet":false},
  "transport":{"compression":"gzip","artifact_name":"a.qcow2.gz","sha256":"$transport_sha"}
}
EOF2

appliance_manifest_validate "$TMP/manifest.json" >/dev/null
have(){ return 1; }
appliance_verify_file "$TMP/a.qcow2" "$TMP/manifest.json" >/dev/null
appliance_verify_transport_file "$TMP/a.qcow2.gz" "$TMP/manifest.json" >/dev/null
gzip -t "$TMP/a.qcow2.gz"
[[ "$(gzip -dc "$TMP/a.qcow2.gz" | sha256sum | awk '{print $1}')" == "$raw_sha" ]]

# Regression: exact-release partial transport downloads resume in place and
# appliance_fetch reuses the completed, checksum-verified transport.
# Keep qemu-img disabled for the synthetic bytes while allowing real gzip.
have(){ [[ "$1" == gzip ]]; }
APPLIANCE_CACHE_ROOT="$TMP/cache"
mkdir -p "$APPLIANCE_CACHE_ROOT"
partial="$APPLIANCE_CACHE_ROOT/a.qcow2.gz.$transport_sha.part"
head -c 7 "$TMP/a.qcow2.gz" >"$partial"
CURL_LOG="$TMP/curl.log"
: >"$CURL_LOG"

curl() {
  local out="" resume="" offset=0
  while (($#)); do
    case "$1" in
      --output) out="$2"; shift 2 ;;
      --continue-at) resume="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf 'resume=%s out=%s\n' "$resume" "$out" >>"$CURL_LOG"
  [[ -n "$out" ]] || return 2
  if [[ "$resume" == "-" ]]; then
    offset="$(stat -c '%s' "$out")"
    dd if="$TMP/a.qcow2.gz" bs=1 skip="$offset" status=none >>"$out"
  else
    cp "$TMP/a.qcow2.gz" "$out"
  fi
}

fetched="$(appliance_fetch "$TMP/manifest.json")"
[[ "$fetched" == "$APPLIANCE_CACHE_ROOT/a.qcow2" ]]
cmp -s "$fetched" "$TMP/a.qcow2"
grep -Fq 'resume=-' "$CURL_LOG"
[[ -f "$APPLIANCE_CACHE_ROOT/a.qcow2.gz" ]]
[[ ! -e "$partial" ]]

# Regression: generic network failure preserves resumable bytes instead of
# deleting them. A later installer invocation can continue from that offset.
failure_part="$TMP/network-failure.part"
printf 'partial-bytes' >"$failure_part"
curl() { printf 'more' >>"$failure_part"; return 56; }
if appliance_download_transport "https://example.invalid/a.qcow2.gz" "$failure_part" >/dev/null 2>&1; then
  echo 'appliance downloader accepted simulated network failure' >&2
  exit 1
fi
grep -Fq 'partial-bytesmore' "$failure_part"

cp "$TMP/a.qcow2.gz" "$TMP/bad.gz"
printf x >>"$TMP/bad.gz"
if appliance_verify_transport_file "$TMP/bad.gz" "$TMP/manifest.json" >/dev/null 2>&1; then
  echo 'transport checksum gate accepted modified package' >&2
  exit 1
fi

if appliance_manifest_validate "$ROOT/appliance/manifest.json" >/dev/null 2>&1; then
  echo 'repository manifest unexpectedly marked published' >&2
  exit 1
else
  rc=$?
  [[ "$rc" -eq 3 ]]
fi

grep -Fq 'full-backing-filename' "$ROOT/lib/appliance.sh"
grep -Fq 'qemu-img check "$file"' "$ROOT/lib/appliance.sh"
grep -Fq 'gzip -dc "$transport"' "$ROOT/lib/appliance.sh"
grep -Fq 'transport.sha256' "$ROOT/lib/appliance.sh"

# The baked guest configurator requires an explicit isolated gateway even when
# the smoke test does not install any client return routes.
grep -Fq 'ISO_GATEWAY=192.168.200.1' "$ROOT/appliance/build/runtime-smoke-test.sh"
grep -Fq -- '--gateway $ISO_GATEWAY' "$ROOT/appliance/build/runtime-smoke-test.sh"

source "$ROOT/lib/validate.sh"
APPLIANCE_MANIFEST="$TMP/manifest.json"
RELEASE_TAG=v1.0.0-rc.9
RELEASE_SOURCE_BUNDLE=CAPE-INetSim-AutoDeploy-1.0.0-rc.9.tar.gz
RELEASE_SOURCE_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
RELEASE_SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567
validate_release_provenance
unset RELEASE_SOURCE_COMMIT
if validate_release_provenance >/dev/null 2>&1; then
  echo 'release provenance accepted an incomplete tuple' >&2
  exit 1
fi

grep -Fq 'source "$ROOT/lib/appliance.sh"' "$ROOT/bin/cape-inetsim-verify"
grep -Fq 'source "$ROOT/lib/extension.sh"' "$ROOT/bin/cape-inetsim-verify"

echo '[PASS] appliance manifest/raw/transport checksum and release-provenance gates'
