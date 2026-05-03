# Supply Chain Provenance Sweep

This drill reviews a release candidate from source to artifact. It checks build
metadata, dependency changes, checksums, package notes, and release readiness,
then produces an auditable go/no-go packet.

## Why It Shows The Power

Supply-chain review crosses many evidence types. Twelvgaige can keep those
checks split into bounded shots, let agents specialize, and preserve a durable
audit trail of what was inspected before a release decision.

## Workflow Shape

```yaml
kind: workflow
id: supply_chain_provenance_sweep
version: 1.0.0
shots:
  - id: read_release_manifest
    kind: slug
    agent: release_reader
    tools: [shell_read]
    prompt: |
      Read the release manifest, changelog, checksums, and build metadata files
      named in round input. Extract artifact names, versions, commit SHA, and
      declared build environment.

  - id: dependency_delta
    kind: slug
    agent: dependency_reviewer
    tools: [shell_read, http_get]
    prompt: |
      Read dependency diff and approved advisory URLs. Identify new direct
      dependencies, major upgrades, yanked packages, and known advisories.

  - id: package_surface
    kind: slug
    agent: package_reviewer
    tools: [shell_read]
    prompt: |
      Inspect approved packaging files. Identify included binaries, generated
      wrappers, license files, runtime config, and files that should not ship.

  - id: provenance_decision
    kind: slug
    agent: release_security_lead
    depends_on:
      - read_release_manifest
      - dependency_delta
      - package_surface
    prompt: |
      Produce a release provenance decision: pass, conditional pass, or block.
      Include missing evidence, risky artifacts, and exact follow-up commands.

  - id: release_gate
    kind: safety
    depends_on: [provenance_decision]
    description: "Release owner approval before publishing artifacts"
```

## Example Input

```json
{
  "release_manifest": "dist/release-manifest.json",
  "checksum_file": "dist/checksums.txt",
  "dependency_diff": "artifacts/deps-diff.txt",
  "packaging_files": [
    "mix.exs",
    ".github/workflows/release.yml",
    "docs/design/release-checklist.md"
  ],
  "approved_advisory_urls": [
    "https://security.example.com/advisories/runtime"
  ]
}
```

## CLI Flow

```bash
twelvgaige round run workflows/supply_chain_provenance_sweep.yaml \
  --input release-input.json \
  --format json
```

Detached release gate:

```bash
twelvgaige round run workflows/supply_chain_provenance_sweep.yaml \
  --input release-input.json \
  --detach

twelvgaige round audit <round-id> --format ndjson > release-audit.ndjson
twelvgaige round approve <round-id> --shot release_gate --reason "release owner approved"
```

## Chokes

- Keep the sweep read-only. Publishing should be a separate guarded round.
- `http_get` should be allowlisted to advisory or registry metadata hosts.
- Generated binaries should not be committed just because a model found them.
- Preserve audit output with the release notes for later incident review.
