#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  ./manage_logs.sh LOG_DIR [THRESHOLD_PERCENT] [CAPACITY_MIB] [BACKUP_DIR]

Arguments:
  LOG_DIR            Directory whose files should be checked
  THRESHOLD_PERCENT  Usage threshold from 0 to 100 (default: 70)
  CAPACITY_MIB       Logical capacity of LOG_DIR in MiB (default: 1024)
  BACKUP_DIR         Archive directory (default: $HOME/backup)

Example:
  ./manage_logs.sh ./logs 70 1000 ./backup
USAGE
}

if (( $# < 1 || $# > 4 )); then
    usage
    exit 2
fi

LOG_DIR_INPUT=$1
THRESHOLD=${2:-70}
CAPACITY_MIB=${3:-1024}
BACKUP_DIR_INPUT=${4:-"$HOME/backup"}

if [[ ! -d "$LOG_DIR_INPUT" ]]; then
    printf 'Error: log directory does not exist: %s\n' "$LOG_DIR_INPUT" >&2
    exit 1
fi

if [[ ! "$THRESHOLD" =~ ^[0-9]+$ ]] || (( THRESHOLD > 100 )); then
    printf 'Error: threshold must be an integer from 0 to 100.\n' >&2
    exit 2
fi

if [[ ! "$CAPACITY_MIB" =~ ^[0-9]+$ ]] || (( CAPACITY_MIB < 1 )); then
    printf 'Error: capacity must be a positive integer in MiB.\n' >&2
    exit 2
fi

LOG_DIR=$(cd -- "$LOG_DIR_INPUT" && pwd -P)
mkdir -p -- "$BACKUP_DIR_INPUT"
BACKUP_DIR=$(cd -- "$BACKUP_DIR_INPUT" && pwd -P)

case "$BACKUP_DIR/" in
    "$LOG_DIR/"*)
        printf 'Error: backup directory must not be inside the log directory.\n' >&2
        exit 2
        ;;
esac

CAPACITY_BYTES=$((CAPACITY_MIB * 1024 * 1024))
TARGET_BYTES=$((CAPACITY_BYTES * THRESHOLD / 100))

get_used_bytes() {
    local total=0
    local size

    while IFS= read -r size; do
        [[ "$size" =~ ^[0-9]+$ ]] || continue
        total=$((total + size))
    done < <(find "$LOG_DIR" -type f -printf '%s\n')

    printf '%s\n' "$total"
}

format_mib() {
    awk -v bytes="$1" 'BEGIN { printf "%.1f", bytes / 1048576 }'
}

USED_BYTES=$(get_used_bytes)
USED_PERCENT=$(awk -v used="$USED_BYTES" -v cap="$CAPACITY_BYTES" 'BEGIN { printf "%.1f", used * 100 / cap }')

printf 'Log directory: %s\n' "$LOG_DIR"
printf 'Usage: %s MiB of %s MiB (%s%%); threshold: %s%%.\n' \
    "$(format_mib "$USED_BYTES")" "$CAPACITY_MIB" "$USED_PERCENT" "$THRESHOLD"

if (( USED_BYTES * 100 <= CAPACITY_BYTES * THRESHOLD )); then
    printf 'Threshold not exceeded. Nothing to archive.\n'
    exit 0
fi

# GNU find + sort provide modification-time ordering. NUL separators keep names with
# spaces, tabs, and newlines safe while processing the list.
declare -a SELECTED_FILES=()
SELECTED_BYTES=0

while IFS=' ' read -r -d '' mtime size relative_path; do
    [[ -n "$relative_path" ]] || continue
    SELECTED_FILES+=("$relative_path")
    SELECTED_BYTES=$((SELECTED_BYTES + size))

    if (( USED_BYTES - SELECTED_BYTES <= TARGET_BYTES )); then
        break
    fi
done < <(cd -- "$LOG_DIR" && find . -type f -printf '%T@ %s %p\0' | sort -z -n)

if (( ${#SELECTED_FILES[@]} == 0 )); then
    printf 'Error: usage is above the threshold, but no files could be selected.\n' >&2
    exit 1
fi

LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/lab1-files.XXXXXX")
trap 'rm -f -- "$LIST_FILE"' EXIT
printf '%s\0' "${SELECTED_FILES[@]}" > "$LIST_FILE"

if [[ "${LAB1_MAX_COMPRESSION:-0}" == "1" ]]; then
    ARCHIVE_PATH="$BACKUP_DIR/logs_$(date '+%Y%m%d_%H%M%S')_$$.tar.lzma"
    TAR_CREATE_ARGS=(--lzma -cf)
    COMPRESSION_NAME="LZMA"
else
    ARCHIVE_PATH="$BACKUP_DIR/logs_$(date '+%Y%m%d_%H%M%S')_$$.tar.gz"
    TAR_CREATE_ARGS=(-czf)
    COMPRESSION_NAME="gzip"
fi

printf 'Archiving %s oldest file(s), total %s MiB using %s...\n' \
    "${#SELECTED_FILES[@]}" "$(format_mib "$SELECTED_BYTES")" "$COMPRESSION_NAME"

if (cd -- "$LOG_DIR" && tar --null "${TAR_CREATE_ARGS[@]}" "$ARCHIVE_PATH" -T "$LIST_FILE") && tar -tf "$ARCHIVE_PATH" >/dev/null; then
    :
else
    rm -f -- "$ARCHIVE_PATH"
    printf 'Error: archive creation or validation failed. Source files were not deleted.\n' >&2
    exit 1
fi

for relative_path in "${SELECTED_FILES[@]}"; do
    absolute_path="$LOG_DIR/${relative_path#./}"
    if [[ -f "$absolute_path" ]]; then
        if ! rm -- "$absolute_path"; then
            printf 'Error: archive was created, but could not delete: %s\n' "$absolute_path" >&2
            exit 1
        fi
    fi
done

NEW_USED_BYTES=$(get_used_bytes)
NEW_USED_PERCENT=$(awk -v used="$NEW_USED_BYTES" -v cap="$CAPACITY_BYTES" 'BEGIN { printf "%.1f", used * 100 / cap }')
printf 'Archive saved: %s\n' "$ARCHIVE_PATH"
printf 'After cleanup: %s MiB (%s%%).\n' "$(format_mib "$NEW_USED_BYTES")" "$NEW_USED_PERCENT"
