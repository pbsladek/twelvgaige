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

The workflow then creates or updates the GitHub Release for the tag.
