#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
mode="${1:-report}"
summary="${COVERAGE_SUMMARY:-${repo_root}/artifacts/coverage-summary.txt}"

raise_file_limit() {
  current=$(ulimit -n)

  case "$current" in
    unlimited) return ;;
    *[!0-9]*) return ;;
  esac

  if [ "$current" -lt 4096 ]; then
    ulimit -n 4096 2>/dev/null || {
      printf '%s\n' "Coverage requires at least 4096 open files; current soft limit is ${current}." >&2
      exit 1
    }
  fi
}

run_logged() {
  if ! "$@" >> "$summary" 2>&1; then
    cat "$summary"
    exit 1
  fi
}

raise_file_limit
cd "$repo_root"

case "$mode" in
  report)
    exec env MIX_ENV=test mix test --cover
    ;;
  export)
    rm -rf cover
    mkdir -p cover "$(dirname -- "$summary")"
    : > "$summary"
    run_logged env MIX_ENV=test mix test --cover --export-coverage default
    run_logged env MIX_ENV=test mix test --cover --only persistence --export-coverage persistence
    run_logged env MIX_ENV=test mix test --cover --only daemon --export-coverage daemon
    run_logged env MIX_ENV=test mix test.coverage
    coverage_percent=$(awk -F '|' '/Total/ {value=$2} END {gsub(/[ %]/, "", value); print value}' "$summary")

    if [ -z "$coverage_percent" ]; then
      printf '%s\n' "Could not read aggregate coverage from ${summary}." >&2
      exit 1
    fi

    run_logged env MIX_ENV=test TWELVGAIGE_AGGREGATE_COVERAGE="$coverage_percent" \
      mix run scripts/coverage_gate.exs \
      cover/default.coverdata cover/persistence.coverdata cover/daemon.coverdata
    run_logged env MIX_ENV=test mix run scripts/coverage_report.exs
    ;;
  *)
    printf '%s\n' "Usage: $0 report|export" >&2
    exit 64
    ;;
esac
