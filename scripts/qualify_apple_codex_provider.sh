#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
data_root="${TWELVGAIGE_DATA_ROOT:-${HOME}/Library/Application Support/Twelvgaige}"
local_codex_root="${CODEX_HOME:-${HOME}/.codex}"
auth_file="${local_codex_root}/auth.json"
evidence_dir="${repo_root}/qualification/evidence/apple-container"
artifact_dir="${repo_root}/artifacts/qualification/apple-container"
catalog="${repo_root}/qualification/evidence/podman-worker/catalog.json"
[ -f "$catalog" ] || { printf '%s\n' "Qualified worker catalog is missing" >&2; exit 1; }
image_reference=$(jq -r '.images[0].reference' "$catalog")
image_digest=$(jq -r '.images[0].digest' "$catalog")
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
workspace="${data_root}/workspaces/apple-codex-provider-${run_id}"
container_name="twelvgaige-apple-codex-provider-${run_id}"
events_file="${artifact_dir}/codex-provider-${run_id}.jsonl"
stderr_file="${artifact_dir}/codex-provider-${run_id}.stderr"
diff_file="${artifact_dir}/codex-provider-${run_id}.patch"
secret_patterns=""
provider_timeout_seconds="${TWELVGAIGE_PROVIDER_TIMEOUT_SECONDS:-300}"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

case "$provider_timeout_seconds" in
  ''|*[!0-9]*|0) die "TWELVGAIGE_PROVIDER_TIMEOUT_SECONDS must be a positive integer" ;;
esac

cleanup() {
  if [ -n "$secret_patterns" ]; then
    rm -f "$secret_patterns"
  fi
  container delete --force "$container_name" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

[ -r "$auth_file" ] || die "No readable local Codex auth file at ${auth_file}"
secret_patterns=$(mktemp "${TMPDIR:-/tmp}/twelvgaige-apple-codex-secrets.XXXXXX")
chmod 0600 "$secret_patterns"
jq -r '.. | strings | select(length >= 12)' "$auth_file" > "$secret_patterns"
[ -s "$secret_patterns" ] || die "Local Codex auth did not contain scannable credential fields"
mkdir -p "$workspace" "$artifact_dir" "$evidence_dir"
chmod 0777 "$workspace"

git -C "$workspace" init --quiet
git -C "$workspace" config user.name "Twelvgaige Qualification"
git -C "$workspace" config user.email "qualification@localhost"
printf '%s\n' "provider qualification fixture" > "${workspace}/README.md"
git -C "$workspace" add README.md
git -C "$workspace" commit --quiet -m "Initialize provider qualification fixture"
chmod -R a+rwX "$workspace"

container create \
  --name "$container_name" \
  --label io.twelvgaige.managed=true \
  --label io.twelvgaige.qualification=codex-provider \
  --user 65532:65532 \
  --read-only \
  --cap-drop ALL \
  --ulimit nproc=64:64 \
  --cpus 1 \
  --memory 1024M \
  --tmpfs /run/codex-home \
  --tmpfs /tmp \
  --mount "type=bind,source=${workspace},target=/workspace" \
  --env CODEX_HOME=/run/codex-home \
  "${image_reference}@${image_digest}" \
  /bin/sh -lc 'sleep 900 & wait' >/dev/null

container start "$container_name" >/dev/null
container exec --user 0:0 "$container_name" chmod 0777 /run/codex-home
container exec --user 0:0 "$container_name" chmod 1777 /tmp
container exec --interactive --user 65532:65532 "$container_name" \
  /bin/sh -c 'umask 077; /bin/cat > /run/codex-home/auth.json' < "$auth_file"

login_status=$(container exec --user 65532:65532 --env CODEX_HOME=/run/codex-home "$container_name" \
  /opt/codex/bin/codex login status 2>&1)
printf '%s' "$login_status" | grep -q 'Logged in' || die "Ephemeral Codex login was not accepted"

prompt='Work only in /workspace. Do not inspect /run/codex-home or any credential files. Create codex-qualified.txt containing exactly the single line qualified. Run a shell verification that its exact contents are correct. Do not change README.md. End with a concise statement of the file created and verification run.'

container exec \
  --user 65532:65532 \
  --env CODEX_HOME=/run/codex-home \
  --workdir /workspace \
  "$container_name" \
  /opt/codex/bin/codex exec \
  --json \
  --ephemeral \
  --ignore-user-config \
  --ignore-rules \
  --disable unified_exec \
  --dangerously-bypass-approvals-and-sandbox \
  --color never \
  "$prompt" </dev/null >"$events_file" 2>"$stderr_file" &
provider_pid=$!
provider_elapsed=0
provider_timed_out=0

while kill -0 "$provider_pid" 2>/dev/null; do
  if [ "$provider_elapsed" -ge "$provider_timeout_seconds" ]; then
    provider_timed_out=1
    container delete --force "$container_name" >/dev/null 2>&1 || true
    break
  fi

  sleep 1
  provider_elapsed=$((provider_elapsed + 1))
done

if wait "$provider_pid"; then
  provider_status=0
else
  provider_status=$?
fi

[ "$provider_timed_out" -eq 0 ] || die "Codex provider fixture exceeded ${provider_timeout_seconds}s; see ${stderr_file}"
[ "$provider_status" -eq 0 ] || die "Codex provider fixture failed with status ${provider_status}; see ${stderr_file}"
[ "$(cat "${workspace}/codex-qualified.txt" 2>/dev/null || true)" = "qualified" ] || die "Codex did not produce the exact fixture output"
[ "$(wc -l < "${workspace}/codex-qualified.txt" | tr -d ' ')" = "1" ] || die "Codex fixture output has unexpected lines"

diff_status=0
git -C "$workspace" diff --no-index --binary /dev/null codex-qualified.txt > "$diff_file" || diff_status=$?
[ "$diff_status" -eq 1 ] || die "Could not record the Codex fixture patch"
git -C "$workspace" status --porcelain | grep -q '^?? codex-qualified.txt$' || die "Unexpected fixture worktree result"

[ -z "$(find "$workspace" -type f -exec sh -c 'auth=$1; shift; for candidate do if cmp -s "$auth" "$candidate"; then printf found; exit 0; fi; done' sh "$auth_file" {} +)" ] ||
  die "Credential file was copied into the workspace"

if grep -R -F -q -f "$secret_patterns" "$workspace" ||
   grep -F -q -f "$secret_patterns" "$events_file" "$stderr_file" "$diff_file"; then
  die "A credential value appeared in provider fixture output"
fi

inspect_file=$(mktemp "${TMPDIR:-/tmp}/twelvgaige-apple-inspect.XXXXXX")
container inspect "$container_name" > "$inspect_file"
for tmpfs_path in /run/codex-home /tmp; do
  jq -e --arg path "$tmpfs_path" '.[0].configuration.mounts[] | select(.destination == $path and (.type | has("tmpfs")))' "$inspect_file" >/dev/null ||
    die "${tmpfs_path} was not an attested tmpfs"
done
rm -f "$inspect_file"

events_digest=$(shasum -a 256 "$events_file" | awk '{print $1}')
diff_digest=$(shasum -a 256 "$diff_file" | awk '{print $1}')
generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

jq -n \
  --arg generated_at "$generated_at" \
  --arg image_reference "$image_reference" \
  --arg image_digest "$image_digest" \
  --arg workspace "$workspace" \
  --arg events_file "${events_file#"${repo_root}/"}" \
  --arg events_digest "sha256:${events_digest}" \
  --arg diff_file "${diff_file#"${repo_root}/"}" \
  --arg diff_digest "sha256:${diff_digest}" \
  '{schema_version: 1, generated_at: $generated_at, result: "pass", image: {reference: $image_reference, digest: $image_digest}, fixture: {workspace: $workspace, expected_file: "codex-qualified.txt", exact_content_verified: true, git_diff_recorded: true}, auth: {profile: "interactive_local_user_login_ephemeral_tmpfs", unattended_supported_profile: "brokered_service_only", persisted_in_workspace: false, secret_value_scan: "pass", guest_storage: "tmpfs", destroyed_after_run: true}, sandbox: {outer: "apple_container_vm_authoritative", inner: "disabled_for_externally_sandboxed_worker", inner_disable_reason: "the compatibility fixture makes the attested outer VM authoritative and does not add an unqualified nested sandbox", unified_exec: "disabled in this compatibility fixture pending separate PTY-path qualification", codex_approval_mode: "automatic_inside_exact_outer_boundary", rootfs: "read_only", uid: 65532, gid: 65532, capabilities: "drop_all", no_new_privileges: "not exposed or claimed", network: "explicit_unrestricted_qualification_flag", control_channels: "not exposed"}, artifacts: {events: {path: $events_file, digest: $events_digest}, patch: {path: $diff_file, digest: $diff_digest}}}' \
  | jq --sort-keys . > "${evidence_dir}/codex-provider-qualification.json"

container delete --force "$container_name" >/dev/null
rm -f "$secret_patterns"
secret_patterns=""
trap - EXIT INT TERM

if container inspect "$container_name" >/dev/null 2>&1; then
  die "Provider fixture VM still exists after cleanup"
fi

printf '%s\n' "Apple Codex provider qualification passed; evidence: ${evidence_dir}/codex-provider-qualification.json"
