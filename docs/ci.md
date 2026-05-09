# CI And Local Validation

Twelvgaige keeps workflow logic in the Makefile so local checks and GitHub
Actions run the same commands.

## Local Gates

Use the repo-pinned tool versions when possible:

```bash
mise install
make doctor
```

`.mise.toml` pins Erlang/OTP, Elixir, Zig, `kubectl`, and `k3d`. `make doctor`
does not install tools; it reports whether the current shell can run the normal
offline suite and optional package/live checks.

Use these during normal development:

```bash
make check
make test-local
make coverage
make e2e-cli
```

When a local e2e failure needs to be shared, preserve artifacts under the repo
ignored `artifacts/e2e` directory:

```bash
make e2e-artifacts
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

## Local Live Suites

Live suites stay opt-in. `make e2e-live-local` runs only the suites explicitly
enabled by environment variables:

```bash
make e2e-live-local K3D_LIVE=1
make e2e-live-local PROVIDER_LIVE=1 PROVIDER_LIVE_PROVIDERS=openai
make e2e-live-local SQLCIPHER_LIVE=1 SQLCIPHER_PREFIX=/usr
make e2e-live-local KEYCHAIN_LIVE=1
```

Use `make doctor-live` first when setting up a machine for live tests. Live
artifacts are written under `artifacts/live/<platform>` locally unless
`LIVE_ARTIFACT_DIR` is overridden.

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
See [Live E2E implementation plan](design/live-e2e-implementation-plan.md) for
the suite design and promotion criteria.

## Live Environments

Credentialed live jobs use GitHub environments so access can be protected with
manual approval in repository settings:

- `live-providers`: hosted LLM keys and live model variables.
- `live-sqlcipher`: optional SQLCipher live key.
- `live-keychain`: macOS keychain live verification.

The scheduled k3d job does not use repository secrets and does not require a
protected environment. Keep provider, SQLCipher, and keychain jobs manual unless
the environment protections and cost controls are intentionally relaxed.

Every live job uploads a small artifact bundle. k3d artifacts include a summary,
generated fixture workflows, deterministic mock response scripts, CLI round
outputs/stores, and cluster diagnostics on failure. The k3d suite covers
read-only Kubernetes tools, runtime policy denial, RBAC denial, live
`http_get`/`http_post` through a port-forwarded in-cluster fixture, a GitOps
commit/apply/verify round, Git destructive-safety denial, guarded scale
remediation, daemon restart/resume across a safety gate, and a fanout/fan-in
inspection round. Generated least-privilege kubeconfigs are temp-only and are
not uploaded. Provider, SQLCipher, and keychain artifacts include the live test
log captured by the Make target.

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
