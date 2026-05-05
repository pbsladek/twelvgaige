#!/bin/sh
set -eu

: "${E2E_REPO_ROOT:?E2E_REPO_ROOT must point at the repository root}"

E2E_NAME="${E2E_NAME:-e2e}"
E2E_BIN="${TWELVGAIGE_E2E_BIN:-$E2E_REPO_ROOT/twelvgaige}"
E2E_BASE_TMP="${TWELVGAIGE_E2E_TMP:-${TMPDIR:-/tmp}}"
E2E_TMP="${E2E_BASE_TMP%/}/twelvgaige-${E2E_NAME}-$$"
E2E_ARTIFACTS="$E2E_TMP/artifacts"
E2E_TRANSCRIPT="$E2E_ARTIFACTS/transcript.log"
E2E_STEP=0
E2E_DAEMON_PID=""

export TWELVGAIGE_INSTALL_DIR="$E2E_TMP/install"
export TWELVGAIGE_STORE_SQLITE="$E2E_TMP/store.sqlite3"
export TWELVGAIGE_RUNTIME_DIR="$E2E_TMP/run"
export TWELVGAIGE_BREECH_ENDPOINT="$E2E_TMP/run/breech.endpoint.json"
export ERL_CRASH_DUMP="$E2E_TMP/erl_crash.dump"

e2e_setup() {
  rm -rf "$E2E_TMP"
  mkdir -p "$E2E_ARTIFACTS" "$TWELVGAIGE_INSTALL_DIR" "$TWELVGAIGE_RUNTIME_DIR"
  printf "e2e temp: %s\n" "$E2E_TMP"
  printf "bin: %s\n" "$E2E_BIN" > "$E2E_TRANSCRIPT"
  require_bin "$E2E_BIN"
}

e2e_cleanup() {
  status=$?

  stop_daemon_if_running

  if [ "$status" -eq 0 ] && [ "${TWELVGAIGE_E2E_KEEP:-0}" != "1" ]; then
    rm -rf "$E2E_TMP"
  else
    printf "e2e artifacts kept at %s\n" "$E2E_TMP" >&2
  fi

  exit "$status"
}

require_bin() {
  path=$1

  if [ ! -x "$path" ]; then
    printf "missing executable: %s\n" "$path" >&2
    exit 127
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf "missing required command: %s\n" "$1" >&2
    exit 127
  }
}

copy_traphouse_fixture() {
  destination="$E2E_TMP/traphouse"
  rm -rf "$destination"
  mkdir -p "$destination"
  cp -R "$E2E_REPO_ROOT/docs/traphouse/." "$destination/"
  printf "%s\n" "$destination"
}

run_ok() {
  E2E_STEP=$((E2E_STEP + 1))
  stdout="$E2E_ARTIFACTS/$E2E_STEP.stdout"
  stderr="$E2E_ARTIFACTS/$E2E_STEP.stderr"

  {
    printf "\n[%s] ok:" "$E2E_STEP"
    printf " %s" "$@"
    printf "\n"
  } >> "$E2E_TRANSCRIPT"

  if "$@" > "$stdout" 2> "$stderr"; then
    cat "$stdout" >> "$E2E_TRANSCRIPT"
    cat "$stderr" >> "$E2E_TRANSCRIPT"
  else
    status=$?
    printf "command failed with status %s\n" "$status" >&2
    printf "stdout: %s\nstderr: %s\n" "$stdout" "$stderr" >&2
    cat "$stdout" >&2 || true
    cat "$stderr" >&2 || true
    exit "$status"
  fi
}

run_fail() {
  expected=$1
  shift
  E2E_STEP=$((E2E_STEP + 1))
  stdout="$E2E_ARTIFACTS/$E2E_STEP.stdout"
  stderr="$E2E_ARTIFACTS/$E2E_STEP.stderr"

  {
    printf "\n[%s] fail(%s):" "$E2E_STEP" "$expected"
    printf " %s" "$@"
    printf "\n"
  } >> "$E2E_TRANSCRIPT"

  set +e
  "$@" > "$stdout" 2> "$stderr"
  status=$?
  set -e

  cat "$stdout" >> "$E2E_TRANSCRIPT"
  cat "$stderr" >> "$E2E_TRANSCRIPT"

  if [ "$status" -ne "$expected" ]; then
    printf "expected status %s, got %s\n" "$expected" "$status" >&2
    printf "stdout: %s\nstderr: %s\n" "$stdout" "$stderr" >&2
    cat "$stdout" >&2 || true
    cat "$stderr" >&2 || true
    exit 1
  fi
}

assert_file_contains() {
  path=$1
  needle=$2

  if ! grep -F "$needle" "$path" >/dev/null 2>&1; then
    printf "expected %s to contain: %s\n" "$path" "$needle" >&2
    cat "$path" >&2 || true
    exit 1
  fi
}

json_string_field() {
  field=$1
  path=$2

  tr ',' '\n' < "$path" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | sed -n '1p'
}

wait_for_file() {
  path=$1
  attempts=${2:-100}

  while [ "$attempts" -gt 0 ]; do
    if [ -f "$path" ]; then
      return 0
    fi

    attempts=$((attempts - 1))
    sleep 0.1
  done

  printf "timed out waiting for file: %s\n" "$path" >&2
  exit 1
}

wait_command_contains() {
  attempts=$1
  needle=$2
  shift 2

  stdout="$E2E_ARTIFACTS/wait.stdout"
  stderr="$E2E_ARTIFACTS/wait.stderr"

  while [ "$attempts" -gt 0 ]; do
    if "$@" > "$stdout" 2> "$stderr" && grep -F "$needle" "$stdout" >/dev/null 2>&1; then
      return 0
    fi

    attempts=$((attempts - 1))
    sleep 0.1
  done

  printf "timed out waiting for command output to contain: %s\n" "$needle" >&2
  printf "command:" >&2
  printf " %s" "$@" >&2
  printf "\nstdout:\n" >&2
  cat "$stdout" >&2 || true
  printf "\nstderr:\n" >&2
  cat "$stderr" >&2 || true
  exit 1
}

start_daemon() {
  daemon_stdout="$E2E_ARTIFACTS/daemon.stdout"
  daemon_stderr="$E2E_ARTIFACTS/daemon.stderr"

  "$E2E_BIN" daemon serve \
    --transport tcp \
    --runtime-dir "$TWELVGAIGE_RUNTIME_DIR" \
    --endpoint "$TWELVGAIGE_BREECH_ENDPOINT" \
    --format json \
    > "$daemon_stdout" 2> "$daemon_stderr" &

  E2E_DAEMON_PID=$!
  printf "daemon pid: %s\n" "$E2E_DAEMON_PID" >> "$E2E_TRANSCRIPT"
  wait_for_file "$TWELVGAIGE_BREECH_ENDPOINT" 100
  wait_command_contains 100 '"status":"ok"' "$E2E_BIN" status --format json
}

stop_daemon_if_running() {
  if [ -n "${E2E_DAEMON_PID:-}" ] && kill -0 "$E2E_DAEMON_PID" 2>/dev/null; then
    "$E2E_BIN" daemon stop --endpoint "$TWELVGAIGE_BREECH_ENDPOINT" --format json \
      > "$E2E_ARTIFACTS/daemon-stop.stdout" 2> "$E2E_ARTIFACTS/daemon-stop.stderr" || true

    attempts=50
    while [ "$attempts" -gt 0 ] && kill -0 "$E2E_DAEMON_PID" 2>/dev/null; do
      attempts=$((attempts - 1))
      sleep 0.1
    done

    if kill -0 "$E2E_DAEMON_PID" 2>/dev/null; then
      kill "$E2E_DAEMON_PID" 2>/dev/null || true
    fi
  fi

  E2E_DAEMON_PID=""
}
