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
make quality
make test-local
make coverage
make e2e-cli
```

`make check` enforces formatting, warnings-as-errors compilation, the strict
Credo baseline, the high-confidence Sobelow gate, unit tests, and the existing
performance/doc checks. `make quality` adds locked Hex advisory audits.
The Sobelow scan records all confidence levels in `artifacts/sobelow.sarif`, but
only reviewed high-confidence findings fail the build. Reviewed syntax-only
false positives are documented next to the protected code.

`make authoring-check` builds a test-environment escript so its provider-assisted
review step uses the test-only deterministic adapter. It does not require an
Ollama service or hosted credentials; production builds still expose only
OpenAI and Ollama.

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

The OpenAI live suite qualifies Responses and Chat Completions independently.
Both run by default and each must pass plain-text, strict structured-output,
forced function-call, and tool-result continuation contracts. Set
`OPENAI_LIVE_APIS=responses` or `OPENAI_LIVE_APIS=chat_completions` to run one
surface. Each surface writes a separate redacted test log.

## GitHub Workflows

- `ci.yml`: format, compile, Credo, Sobelow, dependency advisories, unit and
  persistence tests, authoring checks, and aggregate plus critical-boundary
  coverage gates, including a dedicated provider-adapter floor.
- `e2e.yml`: offline process-level CLI checks on Linux and macOS.
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
generated fixture workflows, test-only deterministic response scripts, CLI
round outputs/stores, and cluster diagnostics on failure. The k3d suite covers
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
- `package (ubuntu-latest)`
- `package (macos-14)`
- `burrito (linux)`
- `burrito (linux_arm64)`
- `burrito (macos_silicon)`

Keep live e2e jobs out of required branch protection. They depend on local or
external systems and are manual/scheduled health checks, not ordinary PR gates.

Coverage remains a separate required job instead of being folded into
`make ci`. That keeps the default CI log shorter and preserves an explicit
coverage artifact for review. It publishes LCOV, Cobertura XML, and ExCoveralls
JSON for Elixir. Codecov enforces 76% project coverage and 90% changed-line
coverage. The local qualification gate also enforces 85% for critical
authorization, schema, manager-dispatch, durable-store, and sandbox-reconciliation
modules; 55% for the two subprocess/protocol boundary modules; and 65% for the
OpenAI provider and shared provider-transport boundary. These repository gates
run before any external upload and remain authoritative.
