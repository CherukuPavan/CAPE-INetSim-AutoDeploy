#!/usr/bin/env bash

# ============================================================
# CAPE INetSim VM Extension
# Safe rollback utility
# ============================================================
#
# --check
#     Read-only validation. Makes no CAPE changes.
#
# --restore
#     Restores the installation-specific backup by default.
#
# An explicit backup directory may be supplied as the second
# argument for validation or recovery of a specific backup.
#
# The restore mode is intentionally NOT executed automatically.
#

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$EXT_ROOT/src/inetsim-vm.conf"
LAST_BACKUP_FILE="$EXT_ROOT/.last_backup"
INSTALLED_BACKUP_FILE="$EXT_ROOT/.installed_backup"

MODE="${1:---check}"
REQUESTED_BACKUP="${2:-}"


pass() {
    printf '  [PASS] %s\n' "$1"
}


info() {
    printf '  [INFO] %s\n' "$1"
}


fail() {
    printf '  [FAIL] %s\n' "$1"
}

validate_state_manifest() {

    local state_file="$1"
    local cape_root="$2"
    local backup_dir="$3"

    local state=""
    local relative=""
    local canonical_root=""
    local canonical_backup_root=""
    local canonical_target=""
    local canonical_source=""

    declare -A seen=()

    # Require exactly:
    #
    #   STATE<TAB>FILE
    #   EXISTED<TAB>relative/path
    #   MISSING<TAB>relative/path
    #
    if ! awk -F '\t' '
        NR == 1 {
            if ($0 != "STATE\tFILE")
                exit 1
            next
        }

        NF != 2 {
            exit 1
        }

        $1 != "EXISTED" && $1 != "MISSING" {
            exit 1
        }

        $2 == "" {
            exit 1
        }

        END {
            if (NR < 2)
                exit 1
        }
    ' "$state_file"; then

        fail "Rollback state manifest structure is invalid"
        return 1

    fi


    canonical_root="$(
        python3 -c \
        'import os,sys; print(os.path.realpath(sys.argv[1]))' \
        "$cape_root"
    )" || {
        fail "Could not canonicalize CAPE_ROOT"
        return 1
    }


    canonical_backup_root="$(
        python3 -c \
        'import os,sys; print(os.path.realpath(sys.argv[1]))' \
        "$backup_dir"
    )" || {
        fail "Could not canonicalize backup directory"
        return 1
    }


    if [[ "$canonical_root" == "/" ]]; then

        fail "Unsafe CAPE_ROOT detected: /"
        return 1

    fi


    while IFS=$'\t' read -r state relative; do

        [[ "$state" == "STATE" ]] && continue


        # CAPE source paths used by this extension are ordinary
        # relative POSIX paths. Reject unexpected characters.
        if [[ ! "$relative" =~ ^[A-Za-z0-9._/-]+$ ]]; then

            fail "Unsafe rollback path characters: $relative"
            return 1

        fi


        # Reject absolute paths, empty components, leading ./,
        # trailing slash, and explicit . or .. path components.
        if [[ "$relative" == /* \
           || "$relative" == ./* \
           || "$relative" == */ \
           || "$relative" == *//* \
           || "$relative" =~ (^|/)\.\.?(/|$) ]]; then

            fail "Unsafe rollback relative path: $relative"
            return 1

        fi


        if [[ -n "${seen[$relative]+x}" ]]; then

            fail "Duplicate rollback path: $relative"
            return 1

        fi

        seen["$relative"]=1


        canonical_target="$(
            python3 -c \
            'import os,sys; print(os.path.realpath(sys.argv[1]))' \
            "$cape_root/$relative"
        )" || {
            fail "Could not canonicalize CAPE target: $relative"
            return 1
        }


        case "$canonical_target" in

            "$canonical_root"/*)
                ;;

            *)
                fail "Rollback target escapes CAPE_ROOT: $relative"
                return 1
                ;;

        esac


        if [[ "$state" == "EXISTED" ]]; then

            canonical_source="$(
                python3 -c \
                'import os,sys; print(os.path.realpath(sys.argv[1]))' \
                "$backup_dir/$relative"
            )" || {
                fail "Could not canonicalize backup source: $relative"
                return 1
            }


            case "$canonical_source" in

                "$canonical_backup_root"/*)
                    ;;

                *)
                    fail "Backup source escapes backup directory: $relative"
                    return 1
                    ;;

            esac

        fi

    done < "$state_file"


    if [[ "${#seen[@]}" -eq 0 ]]; then

        fail "Rollback state manifest contains no managed paths"
        return 1

    fi


    pass "Rollback state manifest structure and paths are safe"
    return 0
}


if [[ ! -r "$CONFIG_FILE" ]]; then
    fail "Extension configuration is missing:"
    echo "       $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"


if [[ -n "$REQUESTED_BACKUP" ]]; then

    BACKUP_DIR="$REQUESTED_BACKUP"
    BACKUP_SELECTION="explicit backup argument"

elif [[ -s "$INSTALLED_BACKUP_FILE" ]]; then

    BACKUP_DIR="$(cat "$INSTALLED_BACKUP_FILE")"
    BACKUP_SELECTION=".installed_backup installation recovery point"

elif [[ -s "$LAST_BACKUP_FILE" ]]; then

    BACKUP_DIR="$(cat "$LAST_BACKUP_FILE")"
    BACKUP_SELECTION=".last_backup fallback"

else

    fail "No usable backup reference was found."

    echo "       Checked:"
    echo "       $INSTALLED_BACKUP_FILE"
    echo "       $LAST_BACKUP_FILE"

    exit 1
fi


if [[ -z "$BACKUP_DIR" ]]; then

    fail "Selected backup directory is empty"
    exit 1

fi


STATE_FILE="$BACKUP_DIR/FILE-STATE.tsv"
CHECKSUM_FILE="$BACKUP_DIR/SHA256SUMS"


echo
echo "============================================================"
echo " CAPE INETSIM VM EXTENSION - ROLLBACK PROTECTION"
echo "============================================================"
echo

echo "CAPE installation:"
echo "  $CAPE_ROOT"

echo
echo "Backup selection:"
echo "  $BACKUP_SELECTION"

echo
echo "Backup source:"
echo "  $BACKUP_DIR"

echo
echo "Requested mode:"
echo "  $MODE"


# ------------------------------------------------------------
# Verify backup structure
# ------------------------------------------------------------

echo
echo "1. Backup structure"

if [[ -d "$BACKUP_DIR" ]]; then
    pass "Backup directory exists"
else
    fail "Backup directory does not exist"
    exit 1
fi


if [[ -s "$STATE_FILE" ]]; then
    pass "FILE-STATE.tsv exists"
else
    fail "FILE-STATE.tsv is missing"
    exit 1
fi


if [[ -s "$CHECKSUM_FILE" ]]; then
    pass "SHA256SUMS exists"
else
    fail "SHA256SUMS is missing"
    exit 1
fi


# ------------------------------------------------------------
# Verify backup checksums
# ------------------------------------------------------------

echo
echo "2. Backup integrity"

if (
    cd "$BACKUP_DIR" &&
    sha256sum -c SHA256SUMS >/dev/null 2>&1
); then
    pass "All protected backup checksums are valid"
else
    fail "One or more backup checksums failed"
    echo
    echo "ROLLBACK ABORTED."
    exit 1
fi


# ------------------------------------------------------------
# Validate rollback state manifest
# ------------------------------------------------------------

echo
echo "3. Rollback state manifest safety"

if ! validate_state_manifest     "$STATE_FILE"     "$CAPE_ROOT"     "$BACKUP_DIR"; then

    echo
    echo "ROLLBACK ABORTED."
    exit 1

fi


# ------------------------------------------------------------
# Display rollback plan
# ------------------------------------------------------------

echo
echo "4. Rollback plan"

restore_count=0
remove_count=0

while IFS=$'\t' read -r state relative; do

    [[ "$state" == "STATE" ]] && continue
    [[ -z "${relative:-}" ]] && continue

    case "$state" in

        EXISTED)

            if [[ -f "$BACKUP_DIR/$relative" ]]; then
                printf '  [RESTORE] %s\n' "$relative"
                restore_count=$((restore_count + 1))
            else
                fail "Backup copy missing for $relative"
                exit 1
            fi

            ;;

        MISSING)

            printf '  [REMOVE ] %s if created by extension\n' "$relative"
            remove_count=$((remove_count + 1))

            ;;

        *)

            fail "Unknown state '$state' for $relative"
            exit 1

            ;;

    esac

done < "$STATE_FILE"


echo
echo "Files to restore: $restore_count"
echo "Files to remove if extension-created: $remove_count"


# ------------------------------------------------------------
# Read-only check mode
# ------------------------------------------------------------

if [[ "$MODE" == "--check" ]]; then

    echo
    echo "STATUS: ROLLBACK PROTECTION READY"
    echo "Backup integrity has been verified."
    echo "Rollback actions have been calculated."
    echo
    echo "READ-ONLY CHECK COMPLETE."
    echo "No production CAPE files were modified."

    exit 0
fi


# ------------------------------------------------------------
# Restore mode safety
# ------------------------------------------------------------

if [[ "$MODE" != "--restore" ]]; then

    echo
    fail "Unknown mode: $MODE"

    echo
    echo "Usage:"
    echo "  $0 --check [BACKUP_DIR]"
    echo "  sudo $0 --restore [BACKUP_DIR]"

    exit 1
fi


if [[ "$EUID" -ne 0 ]]; then

    fail "Restore mode requires root privileges."

    echo
    echo "Run:"
    echo "  sudo $0 --restore"

    exit 1
fi


echo
echo "============================================================"
echo " WARNING: RESTORE MODE"
echo "============================================================"
echo
echo "This will change files inside:"
echo "  $CAPE_ROOT"
echo
echo "Type exactly:"
echo
echo "  RESTORE"
echo
read -r -p "Confirmation: " confirmation


if [[ "$confirmation" != "RESTORE" ]]; then

    echo
    echo "Rollback cancelled."
    echo "No CAPE files were changed."

    exit 1
fi


# ------------------------------------------------------------
# Perform rollback
# ------------------------------------------------------------

echo
echo "Restoring CAPE files..."


while IFS=$'\t' read -r state relative; do

    [[ "$state" == "STATE" ]] && continue
    [[ -z "${relative:-}" ]] && continue

    target="$CAPE_ROOT/$relative"

    case "$state" in

        EXISTED)

            mkdir -p "$(dirname "$target")"

            cp -a \
                "$BACKUP_DIR/$relative" \
                "$target"

            echo "  [RESTORED] $relative"

            ;;

        MISSING)

            if [[ -e "$target" ]]; then

                rm -f "$target"

                echo "  [REMOVED] $relative"

            else

                echo "  [ABSENT] $relative"

            fi

            ;;

    esac

done < "$STATE_FILE"


echo
echo "STATUS: ROLLBACK FILE RESTORATION COMPLETED"
echo
echo "Restart CAPE services and run verify.sh before reuse."

exit 0
