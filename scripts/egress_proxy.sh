#!/bin/sh
set -eu

command_name="${1:-build}"
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
data_root="${TWELVGAIGE_DATA_ROOT:-${HOME}/Library/Application Support/Twelvgaige}"
image_reference="${TWELVGAIGE_EGRESS_IMAGE:-localhost/twelvgaige/egress-proxy:1}"
artifact_dir="${TWELVGAIGE_EGRESS_ARTIFACTS:-${repo_root}/artifacts/qualification/egress-proxy}"
evidence_dir="${TWELVGAIGE_EGRESS_EVIDENCE:-${repo_root}/qualification/evidence/egress-proxy}"
state_dir="${data_root}/state"
oci_archive="${artifact_dir}/egress-proxy.oci.tar"

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

image_digest() {
  podman image inspect "$image_reference" --format '{{.Digest}}'
}

build_image() {
  require go
  require podman
  require container
  require shasum

  mkdir -p "$artifact_dir" "$evidence_dir"
  build_context=$(mktemp -d "${TMPDIR:-/tmp}/twelvgaige-egress-proxy.XXXXXX")
  trap 'rm -rf "$build_context"' EXIT INT TERM

  (
    cd "${repo_root}/native/egress_proxy"
    go test ./...
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
      -trimpath -buildvcs=true -ldflags='-s -w' \
      -o "${build_context}/egress-proxy" .
  )
  chmod 0755 "${build_context}/egress-proxy"
  cp "${repo_root}/qualification/egress-proxy/Containerfile" "${build_context}/Containerfile"

  podman build \
    --network none \
    --pull=never \
    --format oci \
    --label "org.opencontainers.image.revision=$(git -C "$repo_root" rev-parse HEAD)" \
    --tag "$image_reference" \
    "$build_context"

  digest=$(image_digest)
  podman save --format oci-archive --output "$oci_archive" "$image_reference@$digest"
  container image load --input "$oci_archive"

  podman run --rm --network none "$image_reference@$digest" --config /missing >/dev/null 2>&1 &&
    die "Egress proxy unexpectedly accepted a missing configuration"

  printf '%s\n' "Built and loaded ${image_reference}@${digest}"
  rm -rf "$build_context"
  trap - EXIT INT TERM
}

record_evidence() {
  require jq
  require openssl
  require podman
  require shasum

  digest=$(image_digest)
  [ -n "$digest" ] || die "Egress proxy image is not built"
  [ -f "$oci_archive" ] || die "Egress proxy OCI archive is missing"
  mkdir -p "$artifact_dir" "$evidence_dir" "$state_dir"

  syft="${data_root}/tools/qualification/syft-1.44.0"
  grype="${data_root}/tools/qualification/grype-0.112.0"
  [ -x "$syft" ] || die "Qualified syft binary is missing: $syft"
  [ -x "$grype" ] || die "Qualified grype binary is missing: $grype"

  sbom="${evidence_dir}/sbom.spdx.json"
  vulnerabilities="${evidence_dir}/vulnerabilities.json"
  inspect_file="${evidence_dir}/image-inspect.json"

  "$syft" "oci-archive:${oci_archive}" --output "spdx-json=${sbom}"
  "$grype" "sbom:${sbom}" --output json > "$vulnerabilities"
  podman image inspect "$image_reference@$digest" --format json > "$inspect_file"

  critical=$(jq '[.matches[] | select(.vulnerability.severity == "Critical")] | length' "$vulnerabilities")
  high=$(jq '[.matches[] | select(.vulnerability.severity == "High")] | length' "$vulnerabilities")
  [ "$critical" -eq 0 ] || die "Egress proxy has critical findings"
  [ "$high" -eq 0 ] || die "Egress proxy has high findings"

  signing_key="${state_dir}/qualification-signing-key.pem"
  public_key="${evidence_dir}/qualification-signing-public-key.pem"
  [ -f "$signing_key" ] || openssl genpkey -algorithm ED25519 -out "$signing_key"
  chmod 0600 "$signing_key"
  openssl pkey -in "$signing_key" -pubout -out "$public_key"

  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  git_revision=$(git -C "$repo_root" rev-parse HEAD)
  git_dirty=false
  [ -z "$(git -C "$repo_root" status --porcelain)" ] || git_dirty=true
  source_digest=$(
    shasum -a 256 \
      "${repo_root}/native/egress_proxy/go.mod" \
      "${repo_root}/native/egress_proxy/"*.go \
      | shasum -a 256 \
      | awk '{print $1}'
  )

  jq -n \
    --arg generated_at "$generated_at" \
    --arg reference "$image_reference" \
    --arg digest "$digest" \
    --arg git_revision "$git_revision" \
    --argjson git_dirty "$git_dirty" \
    --arg source_digest "sha256:${source_digest}" \
    --arg containerfile_digest "sha256:$(sha256_file "${repo_root}/qualification/egress-proxy/Containerfile")" \
    --arg sbom_digest "sha256:$(sha256_file "$sbom")" \
    --arg vulnerability_digest "sha256:$(sha256_file "$vulnerabilities")" \
    --arg inspect_digest "sha256:$(sha256_file "$inspect_file")" \
    --arg oci_digest "sha256:$(sha256_file "$oci_archive")" \
    --argjson critical "$critical" \
    --argjson high "$high" \
    '{schema_version: 1, generated_at: $generated_at, image: {reference: $reference, digest: $digest, architecture: "linux/arm64"}, provenance: {repository_revision: $git_revision, repository_dirty: $git_dirty, source_digest: $source_digest, containerfile_digest: $containerfile_digest, builder: "podman", build_network: "none"}, security: {runs_as: "65532:65532", rootfs: "read_only_at_runtime", capabilities: "drop_all", network_role: "dual_homed_policy_gateway", findings: {critical: $critical, high: $high}}, evidence: {sbom_digest: $sbom_digest, vulnerability_digest: $vulnerability_digest, image_inspect_digest: $inspect_digest, oci_archive_digest: $oci_digest}}' \
    | jq --sort-keys . > "${evidence_dir}/image-record.json"

  openssl pkeyutl -sign -inkey "$signing_key" -rawin \
    -in "${evidence_dir}/image-record.json" -out "${evidence_dir}/image-record.sig"
  openssl pkeyutl -verify -pubin -inkey "$public_key" -rawin \
    -in "${evidence_dir}/image-record.json" -sigfile "${evidence_dir}/image-record.sig"

  printf '%s\n' "Recorded egress proxy evidence in ${evidence_dir}"
}

case "$command_name" in
  build)
    build_image
    ;;
  qualify-image)
    build_image
    record_evidence
    ;;
  evidence)
    record_evidence
    ;;
  status)
    digest=$(image_digest 2>/dev/null || true)
    [ -n "$digest" ] || die "Egress proxy image is not built"
    printf '%s\n' "${image_reference}@${digest}"
    ;;
  *)
    die "Usage: $0 build|qualify-image|evidence|status"
    ;;
esac
