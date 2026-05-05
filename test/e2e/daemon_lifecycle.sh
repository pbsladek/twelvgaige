#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
E2E_REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
export E2E_REPO_ROOT
export E2E_NAME=daemon-lifecycle

. "$SCRIPT_DIR/lib/common.sh"

trap e2e_cleanup EXIT INT TERM
e2e_setup

TRAPHOUSE=$(copy_traphouse_fixture)
WORKFLOWS="$TRAPHOUSE/workflows"

start_daemon

run_ok "$E2E_BIN" daemon paths \
  --transport tcp \
  --runtime-dir "$TWELVGAIGE_RUNTIME_DIR" \
  --endpoint "$TWELVGAIGE_BREECH_ENDPOINT" \
  --format json
assert_file_contains "$E2E_ARTIFACTS/1.stdout" "$TWELVGAIGE_BREECH_ENDPOINT"

run_ok "$E2E_BIN" status --format json
assert_file_contains "$E2E_ARTIFACTS/2.stdout" '"status":"ok"'

run_ok "$E2E_BIN" round run "$WORKFLOWS/simple.yaml" --detach --format json
ROUND_ID=$(json_string_field id "$E2E_ARTIFACTS/3.stdout")

if [ -z "$ROUND_ID" ]; then
  printf "failed to extract round id\n" >&2
  cat "$E2E_ARTIFACTS/3.stdout" >&2
  exit 1
fi

wait_command_contains 100 '"status":"complete"' "$E2E_BIN" round show "$ROUND_ID" --format json

run_ok "$E2E_BIN" round list --format json
assert_file_contains "$E2E_ARTIFACTS/4.stdout" "$ROUND_ID"

run_ok "$E2E_BIN" round show "$ROUND_ID" --format json
assert_file_contains "$E2E_ARTIFACTS/5.stdout" '"status":"complete"'

run_ok "$E2E_BIN" round watch "$ROUND_ID" --format ndjson --until-terminal --timeout-ms 1000
assert_file_contains "$E2E_ARTIFACTS/6.stdout" '"event_type":"round_completed"'

run_ok "$E2E_BIN" round audit "$ROUND_ID" --format checkpoint
cp "$E2E_ARTIFACTS/7.stdout" "$E2E_TMP/checkpoint.json"

run_ok "$E2E_BIN" audit verify "$E2E_TMP/checkpoint.json" --format json
assert_file_contains "$E2E_ARTIFACTS/8.stdout" '"valid":true'

stop_daemon_if_running

if [ -e "$TWELVGAIGE_BREECH_ENDPOINT" ]; then
  printf "endpoint was not removed after daemon stop: %s\n" "$TWELVGAIGE_BREECH_ENDPOINT" >&2
  exit 1
fi

start_daemon
run_ok "$E2E_BIN" status --format json
assert_file_contains "$E2E_ARTIFACTS/9.stdout" '"status":"ok"'

printf "daemon lifecycle e2e passed\n"
