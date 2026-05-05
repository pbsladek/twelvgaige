#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
E2E_REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
export E2E_REPO_ROOT
export E2E_NAME=cli-basic

. "$SCRIPT_DIR/lib/common.sh"

trap e2e_cleanup EXIT INT TERM
e2e_setup

TRAPHOUSE=$(copy_traphouse_fixture)
WORKFLOWS="$TRAPHOUSE/workflows"

run_ok "$E2E_BIN" version
assert_file_contains "$E2E_ARTIFACTS/1.stdout" "."

run_ok "$E2E_BIN" shell validate "$WORKFLOWS/simple.yaml"
run_ok "$E2E_BIN" shell validate "$WORKFLOWS/simple.json"
run_ok "$E2E_BIN" shell validate "$WORKFLOWS/simple.toml"

run_ok "$E2E_BIN" shell normalize "$WORKFLOWS/simple.toml" --format json
cp "$E2E_ARTIFACTS/5.stdout" "$E2E_TMP/normalized.json"
run_ok "$E2E_BIN" shell validate "$E2E_TMP/normalized.json"

run_ok "$E2E_BIN" shell convert "$WORKFLOWS/simple.yaml" --to toml
cp "$E2E_ARTIFACTS/7.stdout" "$E2E_TMP/converted.toml"
run_ok "$E2E_BIN" shell validate "$E2E_TMP/converted.toml"

run_ok "$E2E_BIN" shell convert "$WORKFLOWS/simple.toml" --to yaml
cp "$E2E_ARTIFACTS/9.stdout" "$E2E_TMP/converted.yaml"
run_ok "$E2E_BIN" shell validate "$E2E_TMP/converted.yaml"

run_ok "$E2E_BIN" shell fmt "$E2E_TMP/converted.yaml" --check
run_ok "$E2E_BIN" shell graph "$WORKFLOWS/simple.yaml" --format json
run_ok "$E2E_BIN" shell lint "$WORKFLOWS/simple.yaml" --strict --format json

run_ok "$E2E_BIN" round run "$WORKFLOWS/simple.yaml"
run_ok "$E2E_BIN" round run "$WORKFLOWS/simple.json"
run_ok "$E2E_BIN" round run "$WORKFLOWS/simple.toml"

run_fail 6 "$E2E_BIN" round run "$WORKFLOWS/missing.yaml"
run_fail 4 "$E2E_BIN" round run "$WORKFLOWS/simple.yaml" --input '{'

printf "cli basic e2e passed\n"
