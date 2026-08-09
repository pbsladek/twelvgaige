#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
data_root="${TWELVGAIGE_DATA_ROOT:-${HOME}/Library/Application Support/Twelvgaige}"
local_codex_root="${CODEX_HOME:-${HOME}/.codex}"
auth_file="${local_codex_root}/auth.json"
evidence_dir="${repo_root}/qualification/evidence/podman-worker"
artifact_dir="${repo_root}/artifacts/qualification/podman-worker"
catalog="${evidence_dir}/catalog.json"
[ -f "$catalog" ] || { printf '%s\n' "Qualified worker catalog is missing; run make podman-worker-qualify-image" >&2; exit 1; }
image_reference=$(jq -r '.images[0].reference' "$catalog")
image_digest=$(jq -r '.images[0].digest' "$catalog")
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
workspace="${data_root}/workspaces/codex-provider-${run_id}"
container_name="twelvgaige-codex-provider-${run_id}"
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
  podman rm --force --volumes "$container_name" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

[ -r "$auth_file" ] || die "No readable local Codex auth file at ${auth_file}"
secret_patterns=$(mktemp "${TMPDIR:-/tmp}/twelvgaige-codex-secrets.XXXXXX")
chmod 0600 "$secret_patterns"
jq -r '.. | strings | select(length >= 12)' "$auth_file" > "$secret_patterns"
[ -s "$secret_patterns" ] || die "Local Codex auth did not contain scannable credential fields"
mkdir -p "$workspace" "$artifact_dir"
chmod 0777 "$workspace"

git -C "$workspace" init --quiet
git -C "$workspace" config user.name "Twelvgaige Qualification"
git -C "$workspace" config user.email "qualification@localhost"
printf '%s\n' "provider qualification fixture" > "${workspace}/README.md"
git -C "$workspace" add README.md
git -C "$workspace" commit --quiet -m "Initialize provider qualification fixture"
chmod -R a+rwX "$workspace"

podman create \
  --name "$container_name" \
  --label io.twelvgaige.managed=true \
  --label io.twelvgaige.qualification=codex-provider \
  --user 65532:65532 \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 64 \
  --cpus 1 \
  --memory 1073741824 \
  --network slirp4netns \
  --tmpfs /run/codex-home:rw,nosuid,nodev,noexec,size=16m \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m \
  --mount "type=bind,src=${workspace},dst=/workspace,rw" \
  --env CODEX_HOME=/run/codex-home \
  "${image_reference}@${image_digest}" \
  /bin/sh -lc 'sleep 300 & wait' >/dev/null

podman start "$container_name" >/dev/null
podman exec --user 0:0 "$container_name" chmod 0777 /run/codex-home
podman exec --user 0:0 "$container_name" chmod 1777 /tmp
podman exec --interactive --user 65532:65532 "$container_name" \
  /bin/sh -c 'umask 077; /bin/cat > /run/codex-home/auth.json' < "$auth_file"

login_status=$(podman exec --user 65532:65532 --env CODEX_HOME=/run/codex-home "$container_name" \
  /opt/codex/bin/codex login status 2>&1)
printf '%s' "$login_status" | grep -q 'Logged in' || die "Ephemeral Codex login was not accepted"

prompt='Work only in /workspace. Do not inspect /run/codex-home or any credential files. Create codex-qualified.txt containing exactly the single line qualified. Run a shell verification that its exact contents are correct. Do not change README.md. End with a concise statement of the file created and verification run.'

podman exec \
  --user 65532:65532 \
  --env CODEX_HOME=/run/codex-home \
  --workdir /workspace \
  "$container_name" \
  /opt/codex/bin/codex exec \
  --json \
  --ephemeral \
  --ignore-user-config \
  --ignore-rules \
  --dangerously-bypass-approvals-and-sandbox \
  --color never \
  "$prompt" >"$events_file" 2>"$stderr_file" &
provider_pid=$!
provider_elapsed=0
provider_timed_out=0

while kill -0 "$provider_pid" 2>/dev/null; do
  if [ "$provider_elapsed" -ge "$provider_timeout_seconds" ]; then
    provider_timed_out=1
    podman rm --force --volumes "$container_name" >/dev/null 2>&1 || true
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
[ "$(wc -l < "${workspace}/codex-qualified.txt" | tr -d ' ')" = "1" ] || die "Codex fixture output has unexpected extra lines"

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

inspect_json=$(podman inspect "$container_name" --format json)
tmpfs_home=$(printf '%s' "$inspect_json" | jq -r '.[0].HostConfig.Tmpfs["/run/codex-home"] // empty')
for required_option in noexec nodev nosuid; do
  printf '%s' "$tmpfs_home" | grep -q "$required_option" ||
    die "Codex auth home was not an attested noexec,nodev,nosuid tmpfs"
done

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
  --arg login_profile "local_user_login_ephemeral_tmpfs" \
  '{schema_version: 1, generated_at: $generated_at, result: "pass", image: {reference: $image_reference, digest: $image_digest}, fixture: {workspace: $workspace, expected_file: "codex-qualified.txt", exact_content_verified: true, git_diff_recorded: true}, auth: {profile: $login_profile, persisted_in_workspace: false, secret_value_scan: "pass", container_storage: "tmpfs", destroyed_after_run: true}, sandbox: {outer: "podman_authoritative", inner: "disabled_for_externally_sandboxed_worker", inner_disable_reason: "the compatibility fixture makes the attested outer container authoritative and does not add an unqualified nested sandbox", codex_approval_mode: "automatic_inside_outer_boundary", rootfs: "read_only", uid: 65532, gid: 65532, capabilities: "drop_all", no_new_privileges: true, network: "explicit_unrestricted_qualification_flag"}, artifacts: {events: {path: $events_file, digest: $events_digest}, patch: {path: $diff_file, digest: $diff_digest}}}' \
  | jq --sort-keys . > "${evidence_dir}/codex-provider-qualification.json"

podman rm --force --volumes "$container_name" >/dev/null
rm -f "$secret_patterns"
secret_patterns=""
trap - EXIT INT TERM

if podman inspect "$container_name" >/dev/null 2>&1; then
  die "Provider fixture container still exists after cleanup"
fi

printf '%s\n' "Codex provider qualification passed; evidence: ${evidence_dir}/codex-provider-qualification.json"
