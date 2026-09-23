#!/usr/bin/env bash

# ============================================================
# CAPE Ubuntu-VM INetSim Extension
# Production-safe backup utility
# ============================================================

set -u

SCRIPT_DIR="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
    pwd
)"

EXT_ROOT="$(
    cd -- "$SCRIPT_DIR/.." &&
    pwd
)"

CONFIG_FILE="$EXT_ROOT/src/inetsim-vm.conf"

MODE="${1:-backup}"


if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "[FAIL] Configuration file not found:"
    echo "       $CONFIG_FILE"
    exit 1
fi


# shellcheck disable=SC1090
source "$CONFIG_FILE"


if [[ ! -d "${CAPE_ROOT:-}" ]]; then
    echo "[FAIL] CAPE_ROOT does not exist:"
    echo "       ${CAPE_ROOT:-<empty>}"
    exit 1
fi


TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

BACKUP_ROOT="$EXT_ROOT/backups"

BACKUP_DIR="$BACKUP_ROOT/cape-inetsim-before-install-$TIMESTAMP"


# Only production paths that this installer actually adds or changes.
#
# Keeping this list narrowly scoped prevents rollback from overwriting
# unrelated CAPE configuration or source changes made after installation.
FILES=(
    "web/templates/analysis/network/index.html"
    "web/analysis/inetsim_vm_logic.py"
    "web/analysis/templatetags/inetsim_vm_tags.py"
    "web/templates/analysis/network/_inetsim_vm_visual.html"
)


echo
echo "============================================================"
echo " CAPE INETSIM VM EXTENSION - BACKUP PROTECTION"
echo "============================================================"

echo
echo "CAPE installation:"
echo "  $CAPE_ROOT"

echo
echo "Proposed backup:"
echo "  $BACKUP_DIR"


if [[ "$MODE" == "--dry-run" ]]; then

    echo
    echo "Mode: DRY RUN"
    echo "No backup directory will be created."

else

    echo
    echo "Mode: CREATE BACKUP"

fi


echo
echo "Protected production paths:"


existing=0
missing=0


for relative in "${FILES[@]}"; do

    source_file="$CAPE_ROOT/$relative"

    if [[ -f "$source_file" ]]; then

        printf '  [EXISTED] %s\n' "$relative"
        existing=$((existing + 1))

    else

        printf '  [MISSING] %s\n' "$relative"
        missing=$((missing + 1))

    fi

done


echo
echo "Existing files to preserve: $existing"
echo "Originally missing paths:   $missing"


if [[ "$MODE" == "--dry-run" ]]; then

    echo
    echo "STATUS: PRODUCTION BACKUP DRY-RUN PASSED"
    echo "No production CAPE file was modified."
    echo "No backup directory was created."

    exit 0

fi


if [[ "$MODE" != "backup" ]]; then

    echo
    echo "[FAIL] Unknown backup mode:"
    echo "       $MODE"

    echo
    echo "Valid commands:"
    echo "  $0"
    echo "  $0 --dry-run"

    exit 1

fi


mkdir -p "$BACKUP_DIR"


# ------------------------------------------------------------
# Record ORIGINAL state before copying anything.
# ------------------------------------------------------------

STATE_FILE="$BACKUP_DIR/FILE-STATE.tsv"

printf 'STATE\tFILE\n' > "$STATE_FILE"


for relative in "${FILES[@]}"; do

    source_file="$CAPE_ROOT/$relative"

    if [[ -f "$source_file" ]]; then

        printf 'EXISTED\t%s\n' "$relative" \
            >> "$STATE_FILE"

    else

        printf 'MISSING\t%s\n' "$relative" \
            >> "$STATE_FILE"

    fi

done


# ------------------------------------------------------------
# Copy only files that originally existed.
# ------------------------------------------------------------

for relative in "${FILES[@]}"; do

    source_file="$CAPE_ROOT/$relative"

    if [[ ! -f "$source_file" ]]; then
        continue
    fi

    destination="$BACKUP_DIR/$relative"

    mkdir -p "$(dirname "$destination")"

    cp -a \
        "$source_file" \
        "$destination"

done


# ------------------------------------------------------------
# Backup metadata.
# ------------------------------------------------------------

cat > "$BACKUP_DIR/BACKUP-INFO.txt" <<INFO
CAPE Ubuntu-VM INetSim Extension Backup

Created:
$(date --iso-8601=seconds)

Source CAPE directory:
$CAPE_ROOT

Backup directory:
$BACKUP_DIR

Purpose:
Automatic rollback point created immediately before CAPEv2
is modified by the Ubuntu-VM INetSim extension.

FILE-STATE.tsv meanings:

EXISTED
    File existed before installation.
    Rollback restores the backed-up copy.

MISSING
    File did not exist before installation.
    Rollback removes the extension-created file if present.
INFO


# ------------------------------------------------------------
# Generate checksums for original CAPE file copies and the
# rollback state manifest that controls restore/remove actions.
# ------------------------------------------------------------

(
    cd "$BACKUP_DIR" || exit 1

    find . -type f \
        ! -name 'SHA256SUMS' \
        ! -name 'BACKUP-INFO.txt' \
        -print0 |
    sort -z |
    xargs -0 sha256sum \
        > SHA256SUMS
)


# ------------------------------------------------------------
# Verify expected number of actual copies.
# ------------------------------------------------------------

backup_count="$(
    find "$BACKUP_DIR" -type f \
        ! -name 'SHA256SUMS' \
        ! -name 'BACKUP-INFO.txt' \
        ! -name 'FILE-STATE.tsv' |
    wc -l
)"


if [[ "$backup_count" -ne "$existing" ]]; then

    echo
    echo "[FAIL] Backup file count mismatch."
    echo "Expected: $existing"
    echo "Created:  $backup_count"

    exit 1

fi


echo
echo "[PASS] Backup file count verified: $backup_count"


# ------------------------------------------------------------
# Verify checksum file immediately.
# ------------------------------------------------------------

if (
    cd "$BACKUP_DIR" &&
    sha256sum -c SHA256SUMS >/dev/null 2>&1
); then

    echo "[PASS] Backup checksums verified"

else

    echo "[FAIL] Backup checksum validation failed"
    exit 1

fi


echo
echo "[PASS] Original file-state manifest created"

echo
echo "STATUS: PRODUCTION BACKUP CREATED SUCCESSFULLY"
echo "Original CAPE files remain unchanged."


printf '%s\n' "$BACKUP_DIR" \
    > "$EXT_ROOT/.last_backup"

exit 0
