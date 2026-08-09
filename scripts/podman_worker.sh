#!/bin/sh
set -eu

command_name="${1:-build}"
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
data_root="${TWELVGAIGE_DATA_ROOT:-${HOME}/Library/Application Support/Twelvgaige}"
machine_name="${TWELVGAIGE_PODMAN_MACHINE:-twelvgaige}"
codex_version="${TWELVGAIGE_CODEX_VERSION:-0.146.0}"
image_reference="${TWELVGAIGE_WORKER_IMAGE:-localhost/twelvgaige/worker:codex-${codex_version}}"
evidence_dir="${TWELVGAIGE_QUALIFICATION_EVIDENCE:-${repo_root}/qualification/evidence/podman-worker}"
artifact_dir="${TWELVGAIGE_QUALIFICATION_ARTIFACTS:-${repo_root}/artifacts/qualification/podman-worker}"
cache_dir="${data_root}/cache/worker"
state_dir="${data_root}/state"
tool_dir="${data_root}/tools/qualification"
codex_archive="${cache_dir}/codex-${codex_version}-linux-arm64.tgz"
codex_url="https://registry.npmjs.org/@openai/codex/-/codex-${codex_version}-linux-arm64.tgz"
codex_sha512="aa2603c649041675c6ee3a1a7495ba43e5dc8320d70a919da5af6793f73e8b4804a26babd63edb1efc75d8d7d658217fcbc4eaae2e9acbe14bb82d8c8dd7a1b4"
syft_version="1.44.0"
syft_sha256="24e4d34078ae81da7c82539616f0ccac3e226cf4f74a38ce6fb3463619e50a55"
grype_version="0.112.0"
grype_sha256="58c3c372e334c27e5bd5031cfb5ae85dbe5e782478d52fb5515ea413b6d47da4"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

sha512_file() {
  shasum -a 512 "$1" | awk '{print $1}'
}

download_checked() {
  url=$1
  destination=$2
  expected=$3
  algorithm=$4

  if [ -f "$destination" ]; then
    if [ "$algorithm" = "sha512" ]; then
      observed=$(sha512_file "$destination")
    else
      observed=$(sha256_file "$destination")
    fi
    [ "$observed" = "$expected" ] && return 0
    die "Checksum mismatch for cached file: $destination"
  fi

  mkdir -p "$(dirname -- "$destination")"
  curl --fail --location --silent --show-error "$url" --output "${destination}.partial"
  if [ "$algorithm" = "sha512" ]; then
    observed=$(sha512_file "${destination}.partial")
  else
    observed=$(sha256_file "${destination}.partial")
  fi
  [ "$observed" = "$expected" ] || die "Checksum mismatch for download: $url"
  mv "${destination}.partial" "$destination"
}

install_tool() {
  tool=$1
  version=$2
  expected=$3
  binary="${tool_dir}/${tool}-${version}"
  [ -x "$binary" ] && return 0

  archive="${cache_dir}/${tool}-${version}-darwin-arm64.tar.gz"
  url="https://github.com/anchore/${tool}/releases/download/v${version}/${tool}_${version}_darwin_arm64.tar.gz"
  download_checked "$url" "$archive" "$expected" sha256

  staging=$(mktemp -d "${TMPDIR:-/tmp}/twelvgaige-${tool}.XXXXXX")
  trap 'rm -rf "$staging"' EXIT INT TERM
  tar -xzf "$archive" -C "$staging" "$tool"
  mkdir -p "$tool_dir"
  install -m 0755 "${staging}/${tool}" "$binary"
  rm -rf "$staging"
  trap - EXIT INT TERM
}

image_digest() {
  podman image inspect "$image_reference" --format '{{.Digest}}'
}

build_image() {
  require podman
  require curl
  require shasum
  require jq

  podman machine inspect "$machine_name" >/dev/null
  download_checked "$codex_url" "$codex_archive" "$codex_sha512" sha512

  build_context=$(mktemp -d "${TMPDIR:-/tmp}/twelvgaige-worker.XXXXXX")
  trap 'rm -rf "$build_context"' EXIT INT TERM
  cp "${repo_root}/qualification/podman/worker/Containerfile" "${build_context}/Containerfile"
  cp "$codex_archive" "${build_context}/codex-linux-arm64.tgz"

  podman build \
    --pull=never \
    --format oci \
    --label "org.opencontainers.image.revision=$(git -C "$repo_root" rev-parse HEAD)" \
    --tag "$image_reference" \
    "$build_context"

  digest=$(image_digest)
  podman run --rm --network none "$image_reference@$digest" /opt/codex/bin/codex --version
  printf '%s\n' "Built ${image_reference}@${digest}"

  rm -rf "$build_context"
  trap - EXIT INT TERM
}

record_supply_chain() {
  require podman
  require jq
  require openssl
  require shasum

  digest=$(image_digest)
  [ -n "$digest" ] || die "Worker image is not built"
  mkdir -p "$evidence_dir" "$artifact_dir" "$state_dir"

  install_tool syft "$syft_version" "$syft_sha256"
  install_tool grype "$grype_version" "$grype_sha256"

  oci_archive="${artifact_dir}/worker.oci.tar"
  sbom_file="${evidence_dir}/sbom.spdx.json"
  vulnerability_file="${evidence_dir}/vulnerabilities.json"
  image_inspect_file="${evidence_dir}/image-inspect.json"

  podman save --format oci-archive --output "$oci_archive" "$image_reference@$digest"
  podman image inspect "$image_reference@$digest" --format json > "$image_inspect_file"
  "${tool_dir}/syft-${syft_version}" "oci-archive:${oci_archive}" --output "spdx-json=${sbom_file}"

  grype_status=0
  "${tool_dir}/grype-${grype_version}" "sbom:${sbom_file}" --output json > "$vulnerability_file" || grype_status=$?
  [ "$grype_status" -eq 0 ] || die "Grype failed with status ${grype_status}"

  critical_count=$(jq '[.matches[] | select(.vulnerability.severity == "Critical")] | length' "$vulnerability_file")
  high_count=$(jq '[.matches[] | select(.vulnerability.severity == "High")] | length' "$vulnerability_file")
  unreviewed_high_count=$(jq '[.matches[] | select(.vulnerability.severity == "High") | select(.vulnerability.id != "CVE-2026-32631" or .artifact.name != "git")] | length' "$vulnerability_file")
  medium_count=$(jq '[.matches[] | select(.vulnerability.severity == "Medium")] | length' "$vulnerability_file")
  vulnerability_result=pass
  [ "$critical_count" -eq 0 ] || vulnerability_result=fail
  [ "$unreviewed_high_count" -eq 0 ] || vulnerability_result=fail

  jq -n \
    --arg reviewed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson critical "$critical_count" \
    --argjson high "$high_count" \
    --argjson unreviewed_high "$unreviewed_high_count" \
    '{schema_version: 1, reviewed_at: $reviewed_at, policy: {maximum_critical: 0, maximum_unreviewed_high: 0}, counts: {critical: $critical, high: $high, unreviewed_high: $unreviewed_high}, exceptions: [{id: "CVE-2026-32631", package: "git", disposition: "not_applicable", rationale: "The advisory affects Git for Windows NTLM authentication; this worker is Linux/ARM64 and contains no Windows Git binary or NTLM credential flow."}]}' \
    | jq --sort-keys . > "${evidence_dir}/security-review.json"

  signing_key="${state_dir}/qualification-signing-key.pem"
  public_key="${evidence_dir}/qualification-signing-public-key.pem"
  [ -f "$signing_key" ] || openssl genpkey -algorithm ED25519 -out "$signing_key"
  chmod 0600 "$signing_key"
  openssl pkey -in "$signing_key" -pubout -out "$public_key"

  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  sbom_digest=$(sha256_file "$sbom_file")
  vulnerability_digest=$(sha256_file "$vulnerability_file")
  security_review_digest=$(sha256_file "${evidence_dir}/security-review.json")
  inspect_digest=$(sha256_file "$image_inspect_file")
  oci_digest=$(sha256_file "$oci_archive")
  containerfile_digest=$(sha256_file "${repo_root}/qualification/podman/worker/Containerfile")
  git_revision=$(git -C "$repo_root" rev-parse HEAD)
  git_dirty=false
  [ -z "$(git -C "$repo_root" status --porcelain)" ] || git_dirty=true

  jq -n \
    --arg schema_version "1" \
    --arg generated_at "$generated_at" \
    --arg reference "$image_reference" \
    --arg digest "$digest" \
    --arg base_digest "sha256:d858bb5442632a31bd4bca6c5e601dbe6b536fd7942092ea6a08a0a95805693c" \
    --arg codex_version "$codex_version" \
    --arg codex_sha512 "$codex_sha512" \
    --arg git_revision "$git_revision" \
    --argjson git_dirty "$git_dirty" \
    --arg sbom_digest "sha256:${sbom_digest}" \
    --arg vulnerability_digest "sha256:${vulnerability_digest}" \
    --arg security_review_digest "sha256:${security_review_digest}" \
    --arg inspect_digest "sha256:${inspect_digest}" \
    --arg oci_digest "sha256:${oci_digest}" \
    --arg containerfile_digest "sha256:${containerfile_digest}" \
    --arg vulnerability_result "$vulnerability_result" \
    --argjson critical "$critical_count" \
    --argjson high "$high_count" \
    --argjson unreviewed_high "$unreviewed_high_count" \
    --argjson medium "$medium_count" \
    --arg syft_version "$syft_version" \
    --arg grype_version "$grype_version" \
    '{schema_version: ($schema_version | tonumber), generated_at: $generated_at, image: {reference: $reference, digest: $digest, base_digest: $base_digest, architecture: "linux/arm64"}, runtime: {name: "codex", version: $codex_version, artifact_sha512: $codex_sha512}, provenance: {repository_revision: $git_revision, repository_dirty: $git_dirty, containerfile_digest: $containerfile_digest, builder: "podman", network_during_build: true}, evidence: {sbom_digest: $sbom_digest, vulnerability_digest: $vulnerability_digest, security_review_digest: $security_review_digest, image_inspect_digest: $inspect_digest, oci_archive_digest: $oci_digest}, vulnerability_gate: {result: $vulnerability_result, policy: "zero known critical and zero unreviewed high findings", counts: {critical: $critical, high: $high, unreviewed_high: $unreviewed_high, medium: $medium}}, tools: {syft: $syft_version, grype: $grype_version}}' \
    | jq --sort-keys . > "${evidence_dir}/image-record.json"

  openssl pkeyutl -sign -inkey "$signing_key" -rawin \
    -in "${evidence_dir}/image-record.json" -out "${evidence_dir}/image-record.sig"
  openssl pkeyutl -verify -pubin -inkey "$public_key" -rawin \
    -in "${evidence_dir}/image-record.json" -sigfile "${evidence_dir}/image-record.sig"

  jq -n \
    --arg reference "$image_reference" \
    --arg digest "$digest" \
    --arg sbom_digest "sha256:${sbom_digest}" \
    --arg vulnerability_result "$vulnerability_result" \
    '{schema_version: 1, catalog_revision: "qualification-2026-08-02", images: [{reference: $reference, digest: $digest, provenance: "image-record.json", sbom_digest: $sbom_digest, vulnerability_result: $vulnerability_result, signature_verified: true, support_status: "supported"}]}' \
    | jq --sort-keys . > "${evidence_dir}/catalog.json"

  [ "$vulnerability_result" = pass ] || die "Worker image failed the zero-critical vulnerability gate"
  printf '%s\n' "Recorded and verified worker evidence in ${evidence_dir}"
}

show_status() {
  digest=$(image_digest 2>/dev/null || true)
  [ -n "$digest" ] || die "Worker image is not built"
  printf '%s\n' "${image_reference}@${digest}"
  if [ -f "${evidence_dir}/image-record.json" ]; then
    jq '{image, vulnerability_gate, evidence, tools}' "${evidence_dir}/image-record.json"
  fi
}

case "$command_name" in
  build)
    build_image
    ;;
  supply-chain)
    record_supply_chain
    ;;
  qualify-image)
    build_image
    record_supply_chain
    ;;
  status)
    show_status
    ;;
  *)
    die "Usage: $0 build|supply-chain|qualify-image|status"
    ;;
esac
