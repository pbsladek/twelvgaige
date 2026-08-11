#!/bin/sh
set -eu

evidence_path="${TWELVGAIGE_FAULT_EVIDENCE:-qualification/evidence/lifecycle/fault-matrix.json}"
temporary_root="${TMPDIR:-/tmp}"
events_dir="$(mktemp -d "${temporary_root%/}/twelvgaige-fault-events.XXXXXX")"

cleanup() {
  rm -rf "$events_dir"
}

trap cleanup EXIT HUP INT TERM

TWELVGAIGE_FAULT_EVIDENCE_EVENTS="$events_dir" \
  MIX_ENV=test \
  mix test \
    test/twelvgaige/workspace/manager_test.exs \
    test/twelvgaige/sandbox/manager_test.exs \
    --only fault_matrix \
    --seed 0

TWELVGAIGE_FAULT_EVIDENCE_EVENTS="$events_dir" \
  TWELVGAIGE_FAULT_EVIDENCE="$evidence_path" \
  MIX_ENV=test \
  mix run scripts/qualify_fault_matrix.exs
