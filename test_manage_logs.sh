#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BASE_SCRIPT="$SCRIPT_DIR/manage_logs.sh"

if [[ ! -f "$BASE_SCRIPT" ]]; then
    printf 'Error: base script not found: %s\n' "$BASE_SCRIPT" >&2
    exit 1
fi

if ! command -v tar >/dev/null 2>&1 || ! command -v dd >/dev/null 2>&1; then
    printf 'Error: this test requires tar and dd.\n' >&2
    exit 1
fi
if ! tar --help 2>&1 | grep -q -- '--lzma'; then
    printf 'Error: this tar build does not support --lzma. Install GNU tar with LZMA support.\n' >&2
    exit 1
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lab1-tests.XXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

create_file_mib() {
    local file_path=$1
    local size_mib=$2
    dd if=/dev/zero of="$file_path" bs=1M count="$size_mib" 2>/dev/null || fail "could not create test file: $file_path"
}

assert_log_at_least_500_mib() {
    local log_dir=$1
    local actual_mib
    actual_mib=$(du -sm -- "$log_dir" | awk '{print $1}')
    (( actual_mib >= 500 )) || fail "test setup error: $log_dir is only ${actual_mib} MiB; need at least 500 MiB"
}

archive_count() {
    find "$1" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tar.lzma' \) -print | wc -l | tr -d '[:space:]'
}

get_one_archive() {
    find "$1" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tar.lzma' \) -print -quit
}

run_base_script() {
    local log_dir=$1
    local threshold=$2
    local capacity_mib=$3
    local backup_dir=$4
    local compression_mode=${5:-0}
    local output

    if [[ "$compression_mode" == "1" ]]; then
        if output=$(LAB1_MAX_COMPRESSION=1 "$BASE_SCRIPT" "$log_dir" "$threshold" "$capacity_mib" "$backup_dir" 2>&1); then
            printf '%s' "$output"
        else
            fail "base script failed with LZMA enabled: $output"
        fi
    else
        if output=$("$BASE_SCRIPT" "$log_dir" "$threshold" "$capacity_mib" "$backup_dir" 2>&1); then
            printf '%s' "$output"
        else
            fail "base script failed: $output"
        fi
    fi
}

# Test 1: 600 MiB is below the 70% threshold of a 1000 MiB capacity.
TEST_DIR="$WORK_DIR/test1"
mkdir -p "$TEST_DIR/log"
create_file_mib "$TEST_DIR/log/recent.log" 600
touch -d '2025-01-01 00:00:00' "$TEST_DIR/log/recent.log"
assert_log_at_least_500_mib "$TEST_DIR/log"
run_base_script "$TEST_DIR/log" 70 1000 "$TEST_DIR/backup" >/dev/null
[[ -f "$TEST_DIR/log/recent.log" ]] || fail 'test 1: source file should remain'
[[ $(archive_count "$TEST_DIR/backup") -eq 0 ]] || fail 'test 1: no archive should be created'
printf 'PASS 1/5: below threshold, no archive created.\n'
rm -rf -- "$TEST_DIR"

# Test 2: 900 MiB total; the oldest 300 MiB file should be archived and deleted.
TEST_DIR="$WORK_DIR/test2"
mkdir -p "$TEST_DIR/log"
create_file_mib "$TEST_DIR/log/old.log" 300
create_file_mib "$TEST_DIR/log/middle.log" 300
create_file_mib "$TEST_DIR/log/new.log" 300
touch -d '2020-01-01 00:00:00' "$TEST_DIR/log/old.log"
touch -d '2021-01-01 00:00:00' "$TEST_DIR/log/middle.log"
touch -d '2022-01-01 00:00:00' "$TEST_DIR/log/new.log"
assert_log_at_least_500_mib "$TEST_DIR/log"
run_base_script "$TEST_DIR/log" 70 1000 "$TEST_DIR/backup" >/dev/null
[[ ! -e "$TEST_DIR/log/old.log" ]] || fail 'test 2: oldest file should be deleted from log'
[[ -f "$TEST_DIR/log/middle.log" && -f "$TEST_DIR/log/new.log" ]] || fail 'test 2: newer files should remain'
[[ $(archive_count "$TEST_DIR/backup") -eq 1 ]] || fail 'test 2: exactly one archive should be created'
ARCHIVE=$(get_one_archive "$TEST_DIR/backup")
tar -tzf "$ARCHIVE" | grep -Fxq './old.log' || fail 'test 2: archive must contain old.log'
if tar -tzf "$ARCHIVE" | grep -Fxq './middle.log'; then
    fail 'test 2: middle.log should not be in the archive'
fi
printf 'PASS 2/5: usage over threshold, oldest file archived and removed.\n'
rm -rf -- "$TEST_DIR"

# Test 3: custom 50% threshold; archive the oldest 200 MiB file from a 650 MiB log.
TEST_DIR="$WORK_DIR/test3"
mkdir -p "$TEST_DIR/log"
create_file_mib "$TEST_DIR/log/old.log" 200
create_file_mib "$TEST_DIR/log/middle.log" 200
create_file_mib "$TEST_DIR/log/new.log" 250
touch -d '2020-01-01 00:00:00' "$TEST_DIR/log/old.log"
touch -d '2021-01-01 00:00:00' "$TEST_DIR/log/middle.log"
touch -d '2022-01-01 00:00:00' "$TEST_DIR/log/new.log"
assert_log_at_least_500_mib "$TEST_DIR/log"
run_base_script "$TEST_DIR/log" 50 1000 "$TEST_DIR/backup" >/dev/null
[[ ! -e "$TEST_DIR/log/old.log" ]] || fail 'test 3: oldest file should be deleted from log'
[[ -f "$TEST_DIR/log/middle.log" && -f "$TEST_DIR/log/new.log" ]] || fail 'test 3: newer files should remain'
[[ $(archive_count "$TEST_DIR/backup") -eq 1 ]] || fail 'test 3: exactly one archive should be created'
ARCHIVE=$(get_one_archive "$TEST_DIR/backup")
tar -tzf "$ARCHIVE" | grep -Fxq './old.log' || fail 'test 3: archive must contain old.log'
printf 'PASS 3/5: custom threshold of 50%% is respected.\n'
rm -rf -- "$TEST_DIR"

# Test 4: exactly 700 MiB is exactly 70% of a 1000 MiB capacity; > is false at equality.
TEST_DIR="$WORK_DIR/test4"
mkdir -p "$TEST_DIR/log"
create_file_mib "$TEST_DIR/log/exact-limit.log" 700
touch -d '2024-01-01 00:00:00' "$TEST_DIR/log/exact-limit.log"
assert_log_at_least_500_mib "$TEST_DIR/log"
run_base_script "$TEST_DIR/log" 70 1000 "$TEST_DIR/backup" >/dev/null
[[ -f "$TEST_DIR/log/exact-limit.log" ]] || fail 'test 4: file should remain at exact threshold'
[[ $(archive_count "$TEST_DIR/backup") -eq 0 ]] || fail 'test 4: no archive should be created at exact threshold'
printf 'PASS 4/5: exact threshold does not trigger archiving.\n'
rm -rf -- "$TEST_DIR"

# Test 5: LAB1_MAX_COMPRESSION=1 must create a readable LZMA archive.
TEST_DIR="$WORK_DIR/test5"
mkdir -p "$TEST_DIR/log"
create_file_mib "$TEST_DIR/log/old.log" 300
create_file_mib "$TEST_DIR/log/middle.log" 300
create_file_mib "$TEST_DIR/log/new.log" 300
touch -d '2020-01-01 00:00:00' "$TEST_DIR/log/old.log"
touch -d '2021-01-01 00:00:00' "$TEST_DIR/log/middle.log"
touch -d '2022-01-01 00:00:00' "$TEST_DIR/log/new.log"
assert_log_at_least_500_mib "$TEST_DIR/log"
run_base_script "$TEST_DIR/log" 70 1000 "$TEST_DIR/backup" 1 >/dev/null
[[ ! -e "$TEST_DIR/log/old.log" ]] || fail 'test 5: oldest file should be deleted from log'
[[ -f "$TEST_DIR/log/middle.log" && -f "$TEST_DIR/log/new.log" ]] || fail 'test 5: newer files should remain'
[[ $(find "$TEST_DIR/backup" -maxdepth 1 -type f -name '*.tar.lzma' | wc -l | tr -d '[:space:]') -eq 1 ]] || fail 'test 5: exactly one .tar.lzma archive should be created'
ARCHIVE=$(find "$TEST_DIR/backup" -maxdepth 1 -type f -name '*.tar.lzma' -print -quit)
tar -tf "$ARCHIVE" | grep -Fxq './old.log' || fail 'test 5: LZMA archive must contain old.log'
if tar -tf "$ARCHIVE" | grep -Fxq './middle.log'; then
    fail 'test 5: middle.log should not be in the archive'
fi
printf 'PASS 5/5: LAB1_MAX_COMPRESSION=1 creates a valid LZMA archive.\n'

printf 'All 5 tests passed.\n' 
