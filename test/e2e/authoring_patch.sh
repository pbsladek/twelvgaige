#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
E2E_REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
export E2E_REPO_ROOT
export E2E_NAME=authoring-patch

. "$SCRIPT_DIR/lib/common.sh"

trap e2e_cleanup EXIT INT TERM
e2e_setup

FIXTURE_DIR="$E2E_TMP/authoring-fixture"
MIX_ENV=test mix run "$E2E_REPO_ROOT/scripts/authoring_fixture.exs" "$FIXTURE_DIR" \
  > "$E2E_ARTIFACTS/fixture.stdout" 2> "$E2E_ARTIFACTS/fixture.stderr"

TRAPHOUSE="$FIXTURE_DIR/traphouse"
WORKFLOW="$TRAPHOUSE/workflows/simple.yaml"
PATCH="$FIXTURE_DIR/patch.json"
APPROVAL="$FIXTURE_DIR/approval.json"

run_ok "$E2E_BIN" shell scaffold verify --root "$TRAPHOUSE" --format json
assert_file_contains "$E2E_ARTIFACTS/1.stdout" '"status": "ok"'

run_ok "$E2E_BIN" shot library verify --root "$TRAPHOUSE" --format json
assert_file_contains "$E2E_ARTIFACTS/2.stdout" '"status": "ok"'

run_ok "$E2E_BIN" shell author review "$WORKFLOW" --root "$TRAPHOUSE" --format json
assert_file_contains "$E2E_ARTIFACTS/3.stdout" '"writes_files": false'
assert_file_contains "$E2E_ARTIFACTS/3.stdout" '"plan_digest": "sha256:'

run_ok "$E2E_BIN" shell patch inspect "$PATCH" --root "$TRAPHOUSE" --format json
assert_file_contains "$E2E_ARTIFACTS/4.stdout" '"kind": "twelvgaige.patch.inspect"'

run_ok "$E2E_BIN" shell patch verify "$PATCH" --root "$TRAPHOUSE" --approval "$APPROVAL" --format json
assert_file_contains "$E2E_ARTIFACTS/5.stdout" '"status": "ok"'

run_ok "$E2E_BIN" shell patch apply "$PATCH" --root "$TRAPHOUSE" --approval "$APPROVAL" --format json
assert_file_contains "$E2E_ARTIFACTS/6.stdout" '"mode": "dry_run"'
assert_file_contains "$E2E_ARTIFACTS/6.stdout" '"changed": false'

if grep -F "first prompt reviewed" "$WORKFLOW" >/dev/null 2>&1; then
  printf "dry-run patch unexpectedly changed workflow\n" >&2
  exit 1
fi

run_ok "$E2E_BIN" shell patch apply "$PATCH" --root "$TRAPHOUSE" --approval "$APPROVAL" --write --format json
assert_file_contains "$E2E_ARTIFACTS/7.stdout" '"mode": "write"'
assert_file_contains "$E2E_ARTIFACTS/7.stdout" '"changed": true'

if ! grep -F "first prompt reviewed" "$WORKFLOW" >/dev/null 2>&1; then
  printf "write patch did not update workflow\n" >&2
  exit 1
fi

run_ok "$E2E_BIN" shell validate "$WORKFLOW" --format json
assert_file_contains "$E2E_ARTIFACTS/8.stdout" '"kind":"workflow"'
assert_file_contains "$E2E_ARTIFACTS/8.stdout" '"id":"simple"'

run_ok "$E2E_BIN" shell lint "$WORKFLOW" --root "$TRAPHOUSE" --strict --format json
assert_file_contains "$E2E_ARTIFACTS/9.stdout" '"status":"ok"'

printf "authoring patch e2e passed\n"
