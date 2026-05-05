# CI And Local Validation

Twelvgaige keeps workflow logic in the Makefile so local checks and GitHub
Actions run the same commands.

## Local Gates

Use these during normal development:

```bash
make check
make test-local
make coverage
make e2e-cli
```

Use these before release work or larger changes:

```bash
make ci
make typecheck
make authoring-check
make e2e
make coverage-export
```

On macOS, package validation can also run locally:

```bash
make e2e-package
make burrito-smoke BURRITO_TARGET=macos_silicon
```

Windows CLI contract testing is handled in GitHub Actions. If PowerShell Core is
installed locally, the same script can be run with:

```bash
make e2e-windows
```

## GitHub Workflows

- `ci.yml`: format, compile, unit tests, persistence tests, authoring checks,
  and the 70% coverage gate.
- `e2e.yml`: offline process-level CLI checks on Linux, macOS, and Windows.
- `build.yml`: package and smoke-test escript, Mix release, and Burrito
  artifacts.
- `release.yml`: build release assets, generate checksums, attest provenance,
  and publish the GitHub release.
- `live-e2e.yml`: opt-in k3d, provider-live, SQLCipher, and keychain checks.

Live workflows never run on ordinary pull requests.

## Live Environments

Credentialed live jobs use GitHub environments so access can be protected with
manual approval in repository settings:

- `live-providers`: hosted LLM keys and live model variables.
- `live-sqlcipher`: optional SQLCipher live key.
- `live-keychain`: macOS keychain live verification.

The scheduled k3d job does not use repository secrets and does not require a
protected environment. Keep provider, SQLCipher, and keychain jobs manual unless
the environment protections and cost controls are intentionally relaxed.

## Required Checks

After the workflows are green on `main`, configure branch protection to require
these checks before merge:

- `test (ubuntu-latest)`
- `test (macos-latest)`
- `authoring checks`
- `coverage`
- `offline cli (ubuntu-latest)`
- `offline cli (macos-14)`
- `windows cli contract`
- `package (linux-x86_64)`
- `package (macos-arm64)`
- `burrito (linux)`
- `burrito (linux_arm64)`
- `burrito (windows)`
- `burrito (macos_silicon)`

Keep live e2e jobs out of required branch protection. They depend on local or
external systems and are manual/scheduled health checks, not ordinary PR gates.

Coverage remains a separate required job instead of being folded into
`make ci`. That keeps the default CI log shorter and preserves an explicit
coverage artifact for review. Coverage summaries are not posted as PR comments
for now; the required check plus uploaded `cover/` and `coverage-summary.txt`
artifacts are enough until review noise proves otherwise.
