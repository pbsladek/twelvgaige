# Release Flow

Twelvgaige releases are tag driven. A local Make target bumps the version,
creates a release commit, creates an annotated `vX.Y.Z` tag, and pushes the tag
to GitHub. The GitHub `release.yml` workflow publishes artifacts from that tag.

## Local Commands

Preview the next version without changing files:

```bash
make release-plan
make release-plan BUMP=minor
make release-plan RELEASE_VERSION=1.0.0
```

Create the local version commit and annotated tag:

```bash
make release-tag BUMP=patch
```

Run checks, create the release commit and tag, then push to GitHub:

```bash
make release-github BUMP=patch
```

`BUMP` accepts `patch`, `minor`, or `major`. `RELEASE_VERSION=X.Y.Z` can be used
instead when the exact version is known.

## What Gets Updated

The release helper updates the application version in `mix.exs`. It does not
rewrite workflow shell versions in `docs/traphouse`; those are example workflow
definition versions, not the Twelvgaige binary version.

## Safety Rules

The release helper requires a clean git worktree before changing files. This
prevents a release tag from pointing at a commit that accidentally omits local
work.

The release helper refuses to create a version that is not greater than the
current `mix.exs` version and refuses to reuse an existing tag.

## GitHub Release

Pushing a `v*` tag starts `.github/workflows/release.yml`. That workflow builds:

- Native Mix release artifacts.
- Burrito single-binary artifacts for supported targets.
- Build metadata.
- SHA-256 checksums.
- GitHub artifact attestations for staged release assets.

The workflow then creates or updates the GitHub Release for the tag.

Release assets are staged into a flat `release-assets/` directory before
upload. GitHub Release assets share one filename namespace, so per-job metadata
files such as `BUILD-METADATA.txt` and `SHA256SUMS` are renamed with their
artifact prefix. The publish job also emits one top-level `RELEASE-SHA256SUMS`
for the staged assets.

## Verify A Release

Download assets from a release:

```bash
gh release download v0.0.1 --repo pbsladek/twelvgaige --dir twelvgaige-v0.0.1
cd twelvgaige-v0.0.1
```

Verify checksums first:

```bash
shasum -a 256 -c RELEASE-SHA256SUMS
```

Then verify the GitHub artifact attestation for the checksum manifest and any
binary you plan to run:

```bash
gh attestation verify RELEASE-SHA256SUMS --repo pbsladek/twelvgaige
gh attestation verify twelvgaige-burrito-0.0.1-macos_silicon --repo pbsladek/twelvgaige
```

The attestation proves GitHub signed provenance for an artifact produced by this
repository's release workflow. It does not prove bit-for-bit reproducibility on
another machine, and it is not a separate project-managed GPG key. Treat it as
the MVP user-verifiable signing path until explicit release signing keys are
introduced.
