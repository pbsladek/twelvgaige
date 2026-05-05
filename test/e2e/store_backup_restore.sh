#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
E2E_REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
export E2E_REPO_ROOT
export E2E_NAME=store-backup-restore

. "$SCRIPT_DIR/lib/common.sh"

trap e2e_cleanup EXIT INT TERM
e2e_setup

TRAPHOUSE=$(copy_traphouse_fixture)
WORKFLOW="$TRAPHOUSE/workflows/simple.yaml"
BACKUP_PATH="$E2E_TMP/store-backup.sqlite3"
RESTORED_PATH="$E2E_TMP/store-restored.sqlite3"

start_daemon

run_ok "$E2E_BIN" round run "$WORKFLOW" --detach --format json
ROUND_ID=$(json_string_field id "$E2E_ARTIFACTS/1.stdout")

if [ -z "$ROUND_ID" ]; then
  printf "failed to extract round id\n" >&2
  cat "$E2E_ARTIFACTS/1.stdout" >&2
  exit 1
fi

wait_command_contains 100 '"status":"complete"' "$E2E_BIN" round show "$ROUND_ID" --format json
stop_daemon_if_running

run_fail 7 "$E2E_BIN" store backup "$E2E_TMP/denied-backup.sqlite3" --format json

run_ok "$E2E_BIN" store backup "$BACKUP_PATH" --allow-plaintext-export --format json
assert_file_contains "$E2E_ARTIFACTS/3.stdout" "$BACKUP_PATH"

run_ok "$E2E_BIN" store restore "$BACKUP_PATH" "$RESTORED_PATH" --format json
assert_file_contains "$E2E_ARTIFACTS/4.stdout" "$RESTORED_PATH"

run_ok env TWELVGAIGE_STORE_SQLITE="$RESTORED_PATH" "$E2E_BIN" round list --format json
assert_file_contains "$E2E_ARTIFACTS/5.stdout" "$ROUND_ID"

run_ok env TWELVGAIGE_STORE_SQLITE="$RESTORED_PATH" "$E2E_BIN" round show "$ROUND_ID" --format json
assert_file_contains "$E2E_ARTIFACTS/6.stdout" '"status":"complete"'

printf "store backup restore e2e passed\n"
