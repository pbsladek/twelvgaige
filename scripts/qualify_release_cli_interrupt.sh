#!/bin/sh
set -eu

release_bin=${TWELVGAIGE_RELEASE_CLI_BIN:-_build/prod/rel/twelvgaige_native/bin/twelvgaige}
evidence=${TWELVGAIGE_RELEASE_CLI_INTERRUPT_EVIDENCE:-qualification/evidence/cli/release-interrupt.json}
session_id=sess_cli_interrupt_qualification
qualification_root=$(mktemp -d "${TMPDIR:-/tmp}/twelvgaige-release-interrupt.XXXXXX")
data_root="$qualification_root/data"
runtime_dir="$qualification_root/runtime"
second_runtime_dir="$qualification_root/runtime-ordinary-interrupt"
private_temp="$qualification_root/tmp"
daemon_log="$qualification_root/daemon.log"
daemon_pid=

cleanup() {
  if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi

  rm -rf -- "$qualification_root"
}

trap cleanup EXIT INT TERM

mkdir -p "$data_root" "$runtime_dir" "$private_temp"
chmod 700 "$qualification_root" "$data_root" "$runtime_dir" "$private_temp"

MIX_ENV=prod mix run scripts/seed_cli_interrupt_session.exs -- "$data_root" "$session_id"

TMPDIR="$private_temp" \
TWELVGAIGE_OPERATIONS_ENABLED=1 \
TWELVGAIGE_DATA_ROOT="$data_root" \
"$release_bin" daemon serve --transport tcp --runtime-dir "$runtime_dir" >"$daemon_log" 2>&1 &
daemon_pid=$!

endpoint="$runtime_dir/breech.endpoint.json"
attempt=0
while [ ! -f "$endpoint" ]; do
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    sed -n '1,120p' "$daemon_log" >&2
    exit 1
  fi

  attempt=$((attempt + 1))
  if [ "$attempt" -ge 200 ]; then
    sed -n '1,120p' "$daemon_log" >&2
    echo "timed out waiting for packaged daemon endpoint" >&2
    exit 1
  fi

  sleep 0.05
done

scripts/qualify_release_cli_interrupt.exp \
  "$release_bin" "$runtime_dir" "$private_temp" "$session_id" "$second_runtime_dir"

session_json=$(TMPDIR="$private_temp" "$release_bin" session show "$session_id" --runtime-dir "$runtime_dir" --format json)
case "$session_json" in
  *'"status":"cancelling"'*) ;;
  *)
    echo "first interrupt did not persist session cancellation" >&2
    echo "$session_json" >&2
    exit 1
    ;;
esac

set +e
TMPDIR="$private_temp" "$release_bin" definitely-not-a-command >"$qualification_root/invalid.stdout" 2>"$qualification_root/invalid.stderr"
invalid_status=$?
set -e
if [ "$invalid_status" -ne 4 ]; then
  echo "invalid packaged command exited with $invalid_status, expected 4" >&2
  exit 1
fi

TMPDIR="$private_temp" "$release_bin" daemon stop --runtime-dir "$runtime_dir" >/dev/null
wait "$daemon_pid"
daemon_pid=

leftover=$(find "$private_temp" -mindepth 1 -maxdepth 1 -type d \( -name 'twelvgaige-cli-*' -o -name 'twelvgaige-release-cli.*' \) -print -quit)
if [ -n "$leftover" ]; then
  echo "packaged CLI left runtime material behind: $leftover" >&2
  exit 1
fi

release_version=$(TMPDIR="$private_temp" "$release_bin" version)
MIX_ENV=prod mix run scripts/record_release_cli_interrupt_evidence.exs -- \
  "$evidence" "${release_bin%/*}/twelvgaige_interrupt" "$release_version"

printf '%s\n' "Packaged CLI interrupt qualification passed: $evidence"
