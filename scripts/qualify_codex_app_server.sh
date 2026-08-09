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
workspace="${data_root}/workspaces/codex-app-server-${run_id}"
container_name="twelvgaige-codex-app-server-${run_id}"
protocol_report="${artifact_dir}/codex-app-server-${run_id}.json"
evidence_file="${evidence_dir}/codex-app-server-provider-qualification.json"
secret_patterns=""

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$secret_patterns" ]; then
    rm -f "$secret_patterns"
  fi
  podman rm --force --volumes "$container_name" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

[ -r "$auth_file" ] || die "No readable local Codex auth file at ${auth_file}"
secret_patterns=$(mktemp "${TMPDIR:-/tmp}/twelvgaige-codex-app-secrets.XXXXXX")
chmod 0600 "$secret_patterns"
jq -r '.. | strings | select(length >= 12)' "$auth_file" > "$secret_patterns"
[ -s "$secret_patterns" ] || die "Local Codex auth did not contain scannable credential fields"

mkdir -p "$workspace" "$artifact_dir"
chmod 0777 "$workspace"
git -C "$workspace" init --quiet
git -C "$workspace" config user.name "Twelvgaige Qualification"
git -C "$workspace" config user.email "qualification@localhost"
printf '%s\n' "App Server qualification fixture" > "${workspace}/README.md"
git -C "$workspace" add README.md
git -C "$workspace" commit --quiet -m "Initialize App Server qualification fixture"
chmod -R a+rwX "$workspace"

podman create \
  --name "$container_name" \
  --label io.twelvgaige.managed=true \
  --label io.twelvgaige.qualification=codex-app-server \
  --user 65532:65532 \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 64 \
  --cpus 1 \
  --memory 1073741824 \
  --network slirp4netns \
  --tmpfs /run/codex-home:rw,nosuid,nodev,noexec,size=32m \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m \
  --mount "type=bind,src=${workspace},dst=/workspace,rw" \
  --env CODEX_HOME=/run/codex-home \
  "${image_reference}@${image_digest}" \
  /bin/sh -lc 'sleep 600 & wait' >/dev/null

podman start "$container_name" >/dev/null
podman exec --user 0:0 "$container_name" chmod 0777 /run/codex-home
podman exec --user 0:0 "$container_name" chmod 1777 /tmp
podman exec --interactive --user 65532:65532 "$container_name" \
  /bin/sh -c 'umask 077; /bin/cat > /run/codex-home/auth.json' < "$auth_file"

login_status=$(podman exec --user 65532:65532 --env CODEX_HOME=/run/codex-home "$container_name" \
  /opt/codex/bin/codex login status 2>&1)
printf '%s' "$login_status" | grep -q 'Logged in' || die "Ephemeral Codex login was not accepted"

TWELVGAIGE_CODEX_APP_CONTAINER="$container_name" \
TWELVGAIGE_CODEX_APP_REPORT="$protocol_report" \
MIX_ENV=dev mix run "${repo_root}/scripts/qualify_codex_app_server.exs"

[ "$(jq -r '.result' "$protocol_report")" = "pass" ] || die "App Server protocol report did not pass"
[ "$(jq -r '.protocol.exact_resume_verified' "$protocol_report")" = "true" ] || die "Exact App Server resume was not verified"
[ "$(jq -r '.protocol.digest_bound_receipts' "$protocol_report")" = "true" ] || die "Digest-bound approval receipt was not verified"
[ "$(jq -r '.protocol.approval_count' "$protocol_report")" -ge 1 ] || die "No native App Server approval was exercised"
[ "$(cat "${workspace}/app-server-qualified.txt" 2>/dev/null || true)" = "qualified" ] || die "App Server fixture output was not exact"
[ "$(wc -l < "${workspace}/app-server-qualified.txt" | tr -d ' ')" = "1" ] || die "App Server fixture output has extra lines"
git -C "$workspace" status --porcelain | grep -q '^?? app-server-qualified.txt$' || die "Unexpected App Server worktree result"

if grep -R -F -q -f "$secret_patterns" "$workspace" || grep -F -q -f "$secret_patterns" "$protocol_report"; then
  die "A credential value appeared in App Server qualification output"
fi

inspect_json=$(podman inspect "$container_name" --format json)
tmpfs_home=$(printf '%s' "$inspect_json" | jq -r '.[0].HostConfig.Tmpfs["/run/codex-home"] // empty')
for required_option in noexec nodev nosuid; do
  printf '%s' "$tmpfs_home" | grep -q "$required_option" || die "Codex auth home lacks ${required_option}"
done

protocol_digest=$(shasum -a 256 "$protocol_report" | awk '{print $1}')
generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

jq -n \
  --arg generated_at "$generated_at" \
  --arg image_reference "$image_reference" \
  --arg image_digest "$image_digest" \
  --arg report_path "${protocol_report#"${repo_root}/"}" \
  --arg report_digest "sha256:${protocol_digest}" \
  --slurpfile protocol "$protocol_report" \
  '{schema_version: 1, generated_at: $generated_at, result: "pass", image: {reference: $image_reference, digest: $image_digest}, protocol: $protocol[0].protocol, initialized: $protocol[0].initialized, fixture: {expected_file: "app-server-qualified.txt", exact_content_verified: true}, auth: {profile: "local_user_login_ephemeral_tmpfs", persisted_in_workspace: false, secret_value_scan: "pass", container_storage: "tmpfs", destroyed_after_run: true}, sandbox: {outer: "podman_authoritative", inner: "codex_external_sandbox_mode", rootfs: "read_only", uid: 65532, gid: 65532, capabilities: "drop_all", no_new_privileges: true, network: "explicit_unrestricted_qualification_flag"}, artifacts: {protocol_report: {path: $report_path, digest: $report_digest}}}' \
  | jq --sort-keys . > "$evidence_file"

podman rm --force --volumes "$container_name" >/dev/null
rm -f "$secret_patterns"
secret_patterns=""
trap - EXIT INT TERM

if podman inspect "$container_name" >/dev/null 2>&1; then
  die "App Server qualification container still exists after cleanup"
fi

printf '%s\n' "Codex App Server qualification passed; evidence: ${evidence_file}"
