#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/a.conf" <<'INI'
[one]
a = 1

[target]
# keep me
x = old

[next]
y = 2
INI
python3 "$ROOT/tools/ini_edit.py" "$TMP/a.conf" target x new
python3 "$ROOT/tools/ini_edit.py" "$TMP/a.conf" target added value
grep -q '^x = new$' "$TMP/a.conf"
grep -q '^added = value$' "$TMP/a.conf"
grep -q '^# keep me$' "$TMP/a.conf"
grep -q '^\[next\]$' "$TMP/a.conf"
echo '[PASS] comment-preserving INI editor'
