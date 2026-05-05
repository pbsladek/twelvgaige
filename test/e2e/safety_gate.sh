#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
E2E_REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
export E2E_REPO_ROOT
export E2E_NAME=safety-gate

. "$SCRIPT_DIR/lib/common.sh"

trap e2e_cleanup EXIT INT TERM
e2e_setup

TRAPHOUSE=$(copy_traphouse_fixture)
WORKFLOW="$TRAPHOUSE/workflows/safety.yaml"

start_daemon

run_ok "$E2E_BIN" round run "$WORKFLOW" --detach --format json
APPROVE_ROUND_ID=$(json_string_field id "$E2E_ARTIFACTS/1.stdout")
wait_command_contains 100 '"status":"awaiting_safety"' \
  "$E2E_BIN" round show "$APPROVE_ROUND_ID" --format json

run_ok "$E2E_BIN" round approve "$APPROVE_ROUND_ID" \
  --shot approval \
  --reason "e2e reviewed" \
  --format json
assert_file_contains "$E2E_ARTIFACTS/2.stdout" '"decision":"approve"'

wait_command_contains 100 '"status":"complete"' \
  "$E2E_BIN" round show "$APPROVE_ROUND_ID" --format json

run_ok "$E2E_BIN" round watch "$APPROVE_ROUND_ID" --format ndjson --until-terminal --timeout-ms 1000
assert_file_contains "$E2E_ARTIFACTS/3.stdout" '"event_type":"round_completed"'

run_ok "$E2E_BIN" round run "$WORKFLOW" --detach --format json
REJECT_ROUND_ID=$(json_string_field id "$E2E_ARTIFACTS/4.stdout")
wait_command_contains 100 '"status":"awaiting_safety"' \
  "$E2E_BIN" round show "$REJECT_ROUND_ID" --format json

run_ok "$E2E_BIN" round reject "$REJECT_ROUND_ID" \
  --shot approval \
  --reason "e2e rejected" \
  --format json
assert_file_contains "$E2E_ARTIFACTS/5.stdout" '"decision":"reject"'

wait_command_contains 100 '"status":"halted"' \
  "$E2E_BIN" round show "$REJECT_ROUND_ID" --format json

run_ok "$E2E_BIN" round run "$WORKFLOW" --detach --format json
CANCEL_ROUND_ID=$(json_string_field id "$E2E_ARTIFACTS/6.stdout")
wait_command_contains 100 '"status":"awaiting_safety"' \
  "$E2E_BIN" round show "$CANCEL_ROUND_ID" --format json

run_ok "$E2E_BIN" round cancel "$CANCEL_ROUND_ID" \
  --reason "e2e cancel" \
  --format json
assert_file_contains "$E2E_ARTIFACTS/7.stdout" '"decision":"cancel"'

wait_command_contains 100 '"status":"cancelled"' \
  "$E2E_BIN" round show "$CANCEL_ROUND_ID" --format json

printf "safety gate e2e passed\n"
