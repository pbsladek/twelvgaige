#!/bin/sh

set -eu

command_name=${1:-plan}
machine_name=${TWELVGAIGE_PODMAN_MACHINE:-twelvgaige}
data_root=${TWELVGAIGE_DATA_ROOT:-${HOME}/Library/Application Support/Twelvgaige}
podman_cpus=${TWELVGAIGE_PODMAN_CPUS:-4}
podman_memory_mib=${TWELVGAIGE_PODMAN_MEMORY_MIB:-6144}
podman_disk_gib=${TWELVGAIGE_PODMAN_DISK_GIB:-64}

find_podman() {
  if [ -n "${TWELVGAIGE_PODMAN_BIN:-}" ]; then
    printf '%s\n' "$TWELVGAIGE_PODMAN_BIN"
  elif command -v podman >/dev/null 2>&1; then
    command -v podman
  elif [ -x /opt/podman/bin/podman ]; then
    printf '%s\n' /opt/podman/bin/podman
  else
    printf '%s\n' "Podman is not installed or is not on PATH." >&2
    exit 1
  fi
}

require_macos() {
  if [ "$(uname -s)" != Darwin ]; then
    printf '%s\n' "The dedicated Podman machine bootstrap is supported only on macOS." >&2
    exit 1
  fi
}

validate_settings() {
  case "$machine_name" in
    ''|*[!A-Za-z0-9_.-]*)
      printf '%s\n' "Invalid Podman machine name: $machine_name" >&2
      exit 1
      ;;
  esac

  case "$data_root" in
    /*) ;;
    *)
      printf '%s\n' "TWELVGAIGE_DATA_ROOT must be an absolute path." >&2
      exit 1
      ;;
  esac

  case "$data_root" in
    /|/Users|/home|/private|/var|/tmp|"$HOME")
      printf '%s\n' "Refusing to expose a broad host path to the Podman machine: $data_root" >&2
      exit 1
      ;;
  esac

  case "$data_root" in
    *:*)
      printf '%s\n' "TWELVGAIGE_DATA_ROOT cannot contain a colon." >&2
      exit 1
      ;;
  esac

  for numeric_value in "$podman_cpus" "$podman_memory_mib" "$podman_disk_gib"; do
    case "$numeric_value" in
      ''|*[!0-9]*|0)
        printf '%s\n' "Podman CPU, memory, and disk settings must be positive integers." >&2
        exit 1
        ;;
    esac
  done
}

print_plan() {
  printf '%s\n' "Dedicated Podman machine plan"
  printf '  machine:       %s\n' "$machine_name"
  printf '  host data:     %s\n' "$data_root"
  printf '  CPUs:          %s\n' "$podman_cpus"
  printf '  memory MiB:    %s\n' "$podman_memory_mib"
  printf '  disk GiB:      %s\n' "$podman_disk_gib"
  printf '%s\n' "  rootful:       false"
  printf '%s\n' "  host mounts:   one narrow Twelvgaige data root"
  printf '%s\n' ""
  printf '%s\n' "Run 'make podman-machine-create' to create and start it."
}

create_machine() {
  if [ "${TWELVGAIGE_PODMAN_CONFIRM:-0}" != 1 ]; then
    printf '%s\n' "Creation requires TWELVGAIGE_PODMAN_CONFIRM=1." >&2
    printf '%s\n' "Use 'make podman-machine-create' for the confirmed workflow." >&2
    exit 1
  fi

  podman_bin=$(find_podman)

  mkdir -p \
    "$data_root/workspaces" \
    "$data_root/artifacts" \
    "$data_root/databases" \
    "$data_root/integrations" \
    "$data_root/state"
  chmod 700 "$data_root"

  canonical_root=$(CDPATH= cd -- "$data_root" && pwd -P)

  if "$podman_bin" machine inspect "$machine_name" >/dev/null 2>&1; then
    printf 'Podman machine %s already exists; leaving its configuration unchanged.\n' "$machine_name"
  else
    "$podman_bin" machine init \
      --cpus "$podman_cpus" \
      --memory "$podman_memory_mib" \
      --disk-size "$podman_disk_gib" \
      --rootful=false \
      --user-mode-networking=true \
      --volume "$canonical_root:$canonical_root" \
      "$machine_name"
  fi

  machine_state=$(
    "$podman_bin" machine inspect "$machine_name" --format '{{.State}}' 2>/dev/null || true
  )

  if [ "$machine_state" != running ]; then
    "$podman_bin" machine start --no-info "$machine_name"
  fi

  "$podman_bin" system connection default "$machine_name"

  printf '%s\n' "Dedicated Podman machine is running."
  printf '%s\n' "Run 'make podman-machine-health' to verify its mount and security contract."
}

show_status() {
  podman_bin=$(find_podman)
  "$podman_bin" machine inspect "$machine_name"
  "$podman_bin" version --format json
}

require_macos
validate_settings

case "$command_name" in
  plan) print_plan ;;
  create) create_machine ;;
  status) show_status ;;
  *)
    printf 'Usage: %s [plan|create|status]\n' "$0" >&2
    exit 2
    ;;
esac
