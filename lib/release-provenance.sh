#!/usr/bin/env bash
set -Eeuo pipefail

# Release provenance discovery for direct in-place repair.
# A public source bundle contains release/source-provenance.json. If the exact
# sibling tarball is present, calculate its bytes locally so repair can commit
# the same checksum-pinned provenance as the release installer.
cape_autodiscover_release_provenance() {
  local root="${1:?AUTODEPLOY_ROOT required}"
  local manifest="$root/release/source-provenance.json"
  local parent bundle_path bundle_name bundle_sha
  local auto_tag auto_commit auto_bundle

  [[ -f "$manifest" ]] || return 0

  read -r auto_tag auto_commit auto_bundle < <(
    python3 - "$manifest" <<'PY'
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
print(str(d.get("release_tag","")).strip(),
      str(d.get("source_commit","")).strip(),
      str(d.get("source_bundle","")).strip())
PY
  )

  [[ -n "${CAPE_INETSIM_RELEASE_TAG:-}" ]] || CAPE_INETSIM_RELEASE_TAG="$auto_tag"
  [[ -n "${CAPE_INETSIM_RELEASE_SOURCE_COMMIT:-}" ]] || CAPE_INETSIM_RELEASE_SOURCE_COMMIT="$auto_commit"
  [[ -n "${CAPE_INETSIM_RELEASE_SOURCE_BUNDLE:-}" ]] || CAPE_INETSIM_RELEASE_SOURCE_BUNDLE="$auto_bundle"
  export CAPE_INETSIM_RELEASE_TAG CAPE_INETSIM_RELEASE_SOURCE_COMMIT CAPE_INETSIM_RELEASE_SOURCE_BUNDLE

  if [[ -z "${CAPE_INETSIM_RELEASE_SOURCE_SHA256:-}" && -n "${CAPE_INETSIM_RELEASE_SOURCE_BUNDLE:-}" ]]; then
    parent="$(dirname "$root")"
    bundle_path="$parent/${CAPE_INETSIM_RELEASE_SOURCE_BUNDLE}"
    if [[ -f "$bundle_path" ]]; then
      bundle_name="$(basename "$bundle_path")"
      bundle_sha="$(sha256sum "$bundle_path" | awk '{print $1}')"
      CAPE_INETSIM_RELEASE_SOURCE_SHA256="$bundle_sha"
      export CAPE_INETSIM_RELEASE_SOURCE_SHA256
      if declare -F info >/dev/null 2>&1; then
        info "Auto-discovered release provenance from $bundle_name"
      fi
    fi
  fi
}
