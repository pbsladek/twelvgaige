# Testing, Coverage, And E2E Plan

This plan raises test confidence around Twelvgaige's CLI, daemon, authoring,
storage, packaging, and integration surfaces. The first coverage target is 70%
line coverage, enforced in CI after a measured baseline and targeted gap
closure. E2E coverage should exercise the real CLI locally and on GitHub-hosted
runners without requiring hosted LLM credentials by default. Local development
and manual e2e iteration should optimize for macOS first because the primary
developer machine is a Mac.

## Current State Review

What is strong today:

- Broad unit and component coverage already exists across rounds, shots,
  resource limiting, stores, Breech daemon IPC, shell parsing, authoring,
  Kubernetes tool wrappers, provider adapters, audit checkpoints, and CLI
  command dispatch.
- Tests are tagged for expensive or environment-dependent paths:
  `:daemon`, `:persistence`, `:k8s_live`, `:provider_live`,
  `:keychain_live`, `:sqlcipher_live`, `:slow`, and `:integration`.
- `make ci` runs formatter, warnings-as-errors compile, normal tests, and
  persistence tests.
- `make authoring-check`, `make smoke`, `make burrito-smoke`, and k3d live
  Kubernetes smoke checks already prove important CLI paths outside pure unit
  tests.
- GitHub Actions already has separate CI, build, release, and authoring jobs,
  with pinned actions.

Gaps to close:

- Coverage is not measured or gated in `mix.exs`, Makefile, or GitHub Actions.
- No baseline coverage artifact is generated for review on pull requests.
- CLI e2e coverage is spread across smoke targets and ExUnit command tests, but
  there is no explicit `e2e` suite that models user workflows end to end.
- Remote GitHub e2e should prove the CLI on clean runners, including Linux,
  macOS, and eventually Windows behavior.
- Unit tests need a more explicit gap-closure track so coverage increases come
  from meaningful branch and contract tests, not shallow assertions.
- Daemon lifecycle e2e should cover a real background process, endpoint
  discovery, status/list/show/watch/audit, and graceful shutdown.
- Safety-gate e2e should cover a round that waits for approval and then resumes
  via the CLI.
- Authoring e2e should cover scaffold, lint, read-only author review, patch
  verify, dry-run apply, and guarded write inside a temporary traphouse.
- Release/package e2e should cover installed artifacts, not only source tree
  commands.

## Goals

- Enforce 70% line coverage as the first project-wide threshold.
- Keep normal PR coverage deterministic and offline.
- Make macOS the first-class local test path for developer iteration.
- Add explicit local e2e commands that developers can run before release.
- Add GitHub-hosted e2e workflows that run on PRs, pushes, scheduled jobs, and
  manual dispatch as appropriate.
- Keep live cloud/provider/Kubernetes checks opt-in and isolated.
- Make failures actionable with logs, CLI outputs, temporary runtime dirs, and
  uploaded artifacts.
- Keep the default local loop fast enough for normal laptop development.
- Treat process-level e2e as a user-contract suite, not as a replacement for
  focused ExUnit branch coverage.
- Improve unit and component tests around pure logic, error classification,
  policy boundaries, serialization, and failure branches.

## Non-Goals

- Do not require live Anthropic, OpenAI, Gemini, Ollama, Kubernetes, Keychain, or
  SQLCipher for normal PR checks.
- Do not target 90%+ coverage before stabilizing the 70% gate and e2e suite.
- Do not test every CLI flag through shell e2e; use ExUnit for detailed matrix
  coverage and e2e for user-critical flows.
- Do not introduce browser/UI tooling. Twelvgaige is CLI-first.
- Do not count live provider, live Kubernetes, SQLCipher, or OS keychain tests
  in the first 70% coverage gate. Those are health checks for integration
  boundaries and should remain opt-in.

## Test Taxonomy

Use a clear hierarchy so new tests land in the right place:

| Layer | Location | Purpose | Default PR? |
| --- | --- | --- | --- |
| Unit | `test/twelvgaige/**` async where possible | Pure functions, parsers, policies, serializers, retry/error classification | Yes |
| Component | `test/twelvgaige/**` mostly ExUnit processes | GenServers, stores, IPC protocol, provider fakes, tool execution with injected runners | Yes |
| Persistence | `@tag :persistence` | SQLite and durable recovery paths that need serial state | Yes, separate Make target |
| Process E2E | `test/e2e/*.sh` | Real CLI binary, real OS process boundaries, temp runtime dirs | Yes after stable |
| Package E2E | `test/e2e/package_artifact.sh` | Escript, Mix release wrapper, host-runnable Burrito artifact | Push/main and release first |
| Live E2E | tagged ExUnit or e2e wrappers | k3d, hosted LLMs, Keychain, SQLCipher, provider credentials | Manual/scheduled only |

Default PR checks should favor deterministic fake providers and local stores.
Slow or live checks need explicit tags plus explicit environment variables.

## Local Platform Priority

Local testing centers on macOS:

- `make check`, `make coverage`, `make e2e`, `make e2e-package`, and
  `make burrito-smoke BURRITO_TARGET=macos_silicon` are the primary local
  commands.
- Local e2e scripts must work with the default macOS shell tools available on a
  normal developer laptop. If a script needs GNU-specific behavior, add a small
  compatibility helper instead of requiring Homebrew coreutils.
- macOS local daemon tests should use isolated runtime dirs under `/tmp` and the
  supported local transport path for the current implementation.
- macOS-specific live checks, such as Keychain and Apple Silicon Burrito smoke,
  should be easy to run manually but remain opt-in.
- Linux remains the main CI baseline because GitHub Linux runners are fast and
  cheap; macOS CI should cover the user-facing CLI contract and package smoke.
- Linux and Windows validation should run in GitHub workflow jobs, not as a
  normal local developer requirement.
- Windows remains a compatibility contract in CI, with source-level CLI tests,
  PowerShell e2e, and package/build checks before daemon transport is promoted.

## Coverage Denominator

The initial 70% gate should measure the normal offline ExUnit suite only:

- include normal tests;
- exclude `:integration`, `:daemon`, `:provider_live`, `:k8s_live`,
  `:keychain_live`, `:sqlcipher_live`, and `:slow`;
- run persistence coverage as a separate report only after the normal gate is
  stable;
- do not include process e2e in the first coverage number, because a separate
  CLI executable will not naturally contribute to the BEAM coverage data.

This makes the gate stable and understandable. E2E proves the shipped command
surface; coverage proves internal branch exercise.

## Coverage Strategy

Use Elixir's built-in coverage first:

```elixir
test_coverage: [
  summary: [threshold: 70],
  ignore_modules: [
    ~r/^Twelvgaige\.CLI\.Release$/,
    ~r/^Twelvgaige\.TestSupport\./
  ]
]
```

Initial Make targets:

```make
coverage:
	MIX_ENV=test mix test --cover

coverage-export:
	rm -rf cover
	MIX_ENV=test mix test --cover --export-coverage default
	mix test.coverage

coverage-persistence:
	rm -rf cover/persistence
	MIX_ENV=test mix test --cover --include persistence --export-coverage persistence
	mix test.coverage
```

Coverage should start with the normal offline test set. Persistence, daemon, and
e2e coverage can be reported separately later because they are slower and may
require serial execution.

Coverage reporting rules:

- PRs should show the total percentage in logs.
- The HTML/text coverage output should be uploaded as a GitHub artifact.
- Coverage artifacts should include `cover/`, the raw exported coverage files,
  and a short `coverage-summary.txt` generated by the Make target.
- The gate should fail below 70%.
- Coverage failures should be treated as signal, but the initial phase may use
  `continue-on-error` for one or two PRs while the baseline is measured.
- Exclusions must be small. Prefer testing CLI/release wrapper modules through
  unit or process e2e instead of excluding them because they are awkward.

Likely coverage gap areas to inspect after the first report:

- CLI branches for error formatting and rarely used options.
- Native release/Burrito wrapper code.
- Windows-specific path and named-pipe branches.
- Failure branches in daemon IPC and HTTP API.
- Store backup/restore/migration error paths.
- Authoring patch partial-failure branches.
- Provider transport edge cases and retry classification.

Coverage measured on macOS after Phase T6 targeted unit updates:

- Export command: `make coverage-export`
- Result: 840 tests, 0 failures, 40 excluded.
- Exported total coverage: 75.06%.
- Report path: `cover/`
- Summary artifact: `artifacts/coverage-summary.txt`

Lowest default-suite coverage areas from the first baseline:

- 0%: `Twelvgaige.Crypto.Key`, SQLite schema modules,
  `Twelvgaige.Store.SQLiteEncrypted`.
- 18.45%: `Twelvgaige.Store.SQLite.Migration`.
- 30.00%: `Twelvgaige.CLI.Burrito`.
- 30.30%: `Twelvgaige.Crypto.SQLCipherSpike`.
- 50% range: key material, provider config, security, SQLite repo, IPC client,
  loadout, shot run, and SQLite store branches.

The initial 70% gate is already passing, so the next useful work is targeted
unit/component coverage for meaningful failure paths rather than exclusions.

## Unit Testing Improvements

Coverage should improve through better tests at the lowest useful layer. E2E
tests prove the product works from the outside, but most regression prevention
should stay in fast ExUnit tests.

### Priorities

- Keep pure-function modules heavily unit-tested: shell parsing, DAG/condition
  evaluation, admission policy, retry policy, output parsing, provider config,
  redaction, audit checkpointing, resource limiter accounting, and path/root
  validation.
- Add table-driven tests for CLI parsing and deterministic exit-code mapping
  instead of one-off happy-path assertions.
- Add contract tests for behaviours with multiple implementations:
  `Store`, `LLM.Provider`, tool execution, key managers, audit exporters, and
  command runners.
- Add failure-branch tests for policy-denied actions, malformed inputs,
  unsupported formats, stale patch digests, daemon auth/version mismatches,
  provider timeouts, retryable vs non-retryable errors, and store migration
  failures.
- Add boundary tests for macOS-local paths and CI-platform paths: spaces in
  paths, long Unix socket paths, temp runtime dirs, Windows-style paths, and
  endpoint URI parsing.
- Add regression tests for resource cleanup: blocked starts, canceled rounds,
  failed tool calls, daemon stop, stale endpoint cleanup, and scheduler-owned
  recovered rounds.

### Test Shape

- Prefer small fixtures built in the test or from `test/fixtures/**`.
- Prefer fake providers, fake command runners, and injected clocks over sleeps
  and live processes.
- Use property tests sparingly for logic where invariants matter, such as graph
  validation, condition evaluation, redaction idempotence, and retry delay caps.
  Do not add property tests where simple table tests are clearer.
- Use `async: true` for pure and isolated tests. Keep tests that mutate
  application config, process environment, global registries, stores, or daemon
  state as `async: false`.
- Avoid asserting on full human output when a stable JSON surface exists. Human
  output tests should check the important lines only.
- For bugs found by e2e or live tests, add a lower-level unit/component
  regression test before closing the issue.

### Suggested Unit Test Gap List

Start with these areas after the first coverage report:

- `Twelvgaige.CLI.Main`: option parsing errors, JSON output errors, invalid
  format values, missing path handling, and command-specific exit code mapping.
- `Twelvgaige.Breech.IPC.Endpoint`: stale cleanup edge cases, owner lock
  mismatch, endpoint redaction, path-length failures, and version mismatch
  messages.
- `Twelvgaige.Store.SQLite`: backup/restore policy failures, migration
  rollback behavior, corrupted store handling, and private file mode checks.
- `Twelvgaige.Authoring.Patch`: partial write failure, validation command
  failure, digest mismatch, approval mismatch, and path traversal rejection.
- `Twelvgaige.LLM`: provider error normalization, timeout classification,
  base URL policy, retry hints, and fake transport contracts.
- `Twelvgaige.Tool.CommandRunner`: environment scrubbing, cwd handling, output
  caps, stderr caps, timeout cleanup, and shell-free argument handling on macOS.
- `Twelvgaige.ResourceLimiter`: queued work ordering, blocked-start cleanup,
  cancellation accounting, and profile clamping.
- `Twelvgaige.Scheduler` and recovery modules: scheduler-owned recovered rounds
  route through the intended recovery path and do not double-start shots.

### Unit Test Acceptance

- New unit/component tests run in the default `mix test` suite unless they need
  durable stores or live dependencies.
- Coverage increases are tied to meaningful branch or contract coverage.
- New tests should not require network, provider keys, k3d, Keychain, or
  SQLCipher.
- Modules with known failure modes should have at least one negative-path test,
  not only happy-path coverage.

## E2E Test Model

Use shell scripts under `test/e2e/` for true process-level CLI tests. Keep them
portable POSIX shell where possible and write Windows-specific PowerShell tests
separately when needed.

Recommended structure:

```text
test/e2e/
  lib/common.sh
  cli_basic.sh
  daemon_lifecycle.sh
  safety_gate.sh
  authoring_patch.sh
  store_backup_restore.sh
  package_artifact.sh
  windows_cli.ps1
```

Each script should:

- Create its own temp directory.
- Set `TWELVGAIGE_INSTALL_DIR`, `TWELVGAIGE_STORE_SQLITE`,
  `TWELVGAIGE_RUNTIME_DIR`, `TWELVGAIGE_BREECH_ENDPOINT`, and daemon runtime
  paths under that temp directory.
- Use the built binary passed as `TWELVGAIGE_E2E_BIN`, defaulting to
  `./twelvgaige`.
- Save command outputs and daemon logs under the temp directory.
- Clean up daemons and temporary clusters on exit.
- Print the temp directory on failure.
- Capture every command in a transcript with command, exit status, stdout file,
  stderr file, and elapsed time.
- Never read or write the developer's default traphouse, store, runtime dir, or
  provider credentials unless a live test explicitly opts in.

`test/e2e/lib/common.sh` should provide:

- `e2e_tmpdir` and `e2e_cleanup` helpers.
- `run_ok` and `run_fail` helpers that preserve stdout/stderr.
- `wait_json_field` for polling daemon status and round state.
- `start_daemon` and `stop_daemon` helpers that always use isolated endpoint
  and runtime paths.
- `copy_traphouse_fixture` so workflows are tested from a temp tree.
- `require_bin` and `require_command` checks with clear skip/fail messages.

Do not add retries around failed commands. Use bounded polling for asynchronous
state and let real failures fail quickly with artifacts.

Because macOS is the primary local target, POSIX e2e scripts should be tested on
macOS before being promoted to CI. Avoid Linux-only assumptions such as
`readlink -f`, GNU `date`, GNU `sed -r`, or `/proc`.

## E2E Runtime Budgets

Keep runtime predictable:

| Suite | Target local runtime | CI timeout |
| --- | ---: | ---: |
| `e2e-cli` | under 30 seconds | 5 minutes |
| `e2e-daemon` | under 60 seconds | 8 minutes |
| `e2e-safety` | under 60 seconds | 8 minutes |
| `e2e-authoring` | under 60 seconds | 8 minutes |
| `e2e-store` | under 30 seconds | 5 minutes |
| `e2e-package` | under 3 minutes after artifact build | 10 minutes |
| `e2e-k3d` | under 8 minutes | 15 minutes |

If a suite consistently exceeds its budget, split it rather than making the
default e2e target slower.

## Core Local E2E Flows

### CLI Basic

Purpose: prove the built CLI can run core shell and round commands.

Commands:

- `version`
- `shell validate` for YAML, JSON, and TOML
- `shell normalize`
- `shell convert`
- `shell fmt --check`
- `shell graph --format json`
- `shell lint --strict`
- `round run` for YAML, JSON, and TOML
- Missing shell file returns deterministic exit code 6.
- Invalid JSON input returns deterministic exit code 4.

### Daemon Lifecycle

Purpose: prove a real daemon process is usable from another CLI process.

Flow:

1. Start `daemon serve` in the background with a temp runtime dir.
2. Wait for endpoint discovery.
3. Run `status --format json`.
4. Run detached `round run --detach`.
5. Run `round list`, `round show`, `round watch --until-terminal`.
6. Run `round audit --format checkpoint`.
7. Verify checkpoint with `audit verify`.
8. Stop daemon and assert endpoint cleanup.
9. Start daemon again with the same runtime dir to prove stale cleanup does not
   block the next launch.

### Safety Gate

Purpose: prove human-in-the-loop behavior through the CLI.

Flow:

1. Start a safety workflow detached.
2. Wait until `awaiting_approval`.
3. Run `round approve --shot <id> --reason <text>`.
4. Watch to completion.
5. Repeat with `round reject` and verify halted status.
6. Repeat with `round cancel` and verify canceled status.

### Authoring Patch

Purpose: prove safe agent-assisted authoring workflow without live providers.

Flow:

1. Copy `docs/traphouse` to a temp traphouse.
2. Run `shell scaffold verify`.
3. Run `shot library verify`.
4. Run `shell author review` with mock provider.
5. Generate a patch fixture.
6. Run `shell patch inspect`.
7. Run `shell patch verify --approval`.
8. Run `shell patch apply` dry-run.
9. Run `shell patch apply --write --approval`.
10. Run post-write `shell validate` and `shell lint --strict`.
11. Verify JSON apply report contains audit checkpoint.

### Store Backup Restore

Purpose: prove SQLite store backup/restore at the CLI boundary.

Flow:

1. Run a round with `TWELVGAIGE_STORE_SQLITE`.
2. Run `store backup --allow-plaintext-export`.
3. Run `store restore`.
4. Reopen restored store and confirm `round list` sees data.
5. Verify plaintext export without explicit allowance fails with a policy error.

### Package Artifact

Purpose: prove release artifacts work outside the source command path.

Flow:

- Escript: run `make escript`, then e2e basic against `./twelvgaige`.
- Mix release: run `make release`, then e2e basic against
  `_build/prod/rel/twelvgaige_native/bin/twelvgaige`.
- Burrito: run `make burrito-smoke-only` for host-runnable targets.

## Remote GitHub E2E Workflows

Add `.github/workflows/e2e.yml`.

Recommended jobs:

- `cli-e2e-linux`
  - Runs on `ubuntu-latest`.
  - Builds escript.
  - Runs `make e2e-cli`.
  - Uploads e2e logs/artifacts.
  - Covers the Linux CLI contract in GitHub workflows rather than requiring
    local Linux testing.

- `cli-e2e-macos`
  - Runs on `macos-14`.
  - Builds escript.
  - Runs `make e2e-cli`.
  - Acts as the remote check that local macOS assumptions still work on a clean
    Apple Silicon runner.

- `daemon-e2e-linux`
  - Runs on `ubuntu-latest`.
  - Runs `make e2e-daemon`.
  - Uploads daemon logs and endpoint files on failure.

- `authoring-e2e-linux`
  - Runs on `ubuntu-latest`.
  - Runs `make e2e-authoring`.

- `package-e2e`
  - Runs on `ubuntu-latest` and `macos-14`.
  - Builds package artifacts and runs e2e against the built artifact.
  - This can initially run on pushes to `main` and manual dispatch, then move to
    PRs if runtime is acceptable.
  - macOS package e2e should include the Apple Silicon Burrito host-runnable
    target when runtime permits.

- `windows-cli-contract`
  - Runs on `windows-latest`.
  - Starts with source-level CLI contract tests through `mix test` and a
    PowerShell e2e script for `version`, `shell validate`, `shell normalize`,
    and `round run`.
  - Defers daemon/native named-pipe e2e until Windows daemon transport is
    verified. Windows default loopback TCP discovery should still be covered by
    unit/component tests.
  - Covers Windows compatibility in GitHub workflows rather than requiring a
    local Windows machine.

- `k3d-e2e`
  - Runs on `ubuntu-latest`.
  - Manual dispatch and nightly schedule only at first.
  - Creates a disposable k3d cluster.
  - Runs `TWELVGAIGE_K8S_LIVE=1 mix test --include k8s_live`.
  - Always deletes the cluster.

- `provider-live-e2e`
  - Manual dispatch only.
  - Requires repository/environment secrets.
  - Runs one minimal prompt per hosted provider.
  - Must never run on pull requests from forks.

Artifacts to upload:

- `e2e-artifacts/**`
- daemon logs
- coverage reports
- release smoke outputs
- failed command transcript
- endpoint files with bearer tokens redacted
- store backup metadata, not raw stores, unless the artifact is explicitly a
  disposable test store with no secrets
- k3d cluster diagnostic output on live Kubernetes failures

Artifact rules:

- Upload full artifacts on failure.
- Upload compact summaries on success.
- Redact provider keys, daemon bearer tokens, Authorization headers, and
  configured secret env names that contain values.
- Retain normal PR artifacts for 7 days and release/live artifacts for 14 days.

## Makefile Targets

Add these targets:

```make
coverage
coverage-export
coverage-persistence
unit-focus
e2e
e2e-cli
e2e-daemon
e2e-safety
e2e-authoring
e2e-store
e2e-package
e2e-k3d
```

Suggested grouping:

- `make unit-focus`: optional fast target for focused unit/component files
  identified by the coverage gap list.
- `make e2e`: offline local process-level suite.
- `make e2e-package`: slower artifact suite.
- `make e2e-k3d`: live local Kubernetes suite.
- `make e2e-local-mac`: optional convenience alias for the macOS-focused local
  loop once the scripts exist.
- `make ci`: keep as current deterministic gate.
- `make release-github`: depend on `ci authoring-check typecheck e2e`; keep
  `e2e-package` in build/release workflows until its runtime is consistently
  acceptable locally.

## Phased Implementation

Implementation status:

- Phase T0 is started and the initial coverage gate is wired.
- Phase T1 is complete with the shared shell harness, CLI, daemon, safety,
  authoring, and store E2E scripts.
- Phase T2 is started with a Linux coverage GitHub Actions job.
- Phase T3 is implemented with Linux/macOS offline E2E workflow jobs, a Windows
  source-built CLI contract job, deterministic runner-temp artifact paths, and a
  branch-protection checklist; remote confirmation remains pending.
- Phase T1A is complete for the current unit-gap checklist: persisted error-map
  regression coverage, crypto key tests, deeper resource limiter cleanup
  coverage, scheduler-owned Breech recovery coverage, and provider DNS policy
  negative-path coverage are in place.
- Phase T4 is implemented locally and wired into build/release workflows; remote
  workflow confirmation remains pending.
- Phase T5 is implemented as opt-in live workflow/Make targets; remote live
  execution confirmation remains pending.
- Phase T6 is in progress with focused coverage tests for security equality,
  provider config normalization, redaction, SQLCipher spike reporting, CLI JSON
  errors, store failure reporting, and patch apply post-write validation
  failures, daemon endpoint cleanup, and IPC address parsing.

### Phase T0 - Baseline And Coverage Gate Design

Goal: measure current coverage without changing runtime behavior.

Tasks:

- Add `test_coverage` config to `mix.exs` with `summary: [threshold: 70]`.
- Add `make coverage` and `make coverage-export`.
- Run baseline coverage locally.
- Record the baseline and largest uncovered modules in this plan.
- Add ignore rules only for generated/test-support/release-wrapper modules with
  explicit justification.
- Confirm the first gate excludes live/slow tags and document the exact command
  used for the denominator.
- Add a short coverage summary artifact target that CI can upload.
- Use the first report to produce a concrete unit-test gap checklist before
  adding broad e2e workflows.

Acceptance:

- `[x]` `make coverage` runs locally.
- `[x]` Coverage report is generated under `cover/`.
- `[x]` Threshold is passing at the first baseline.
- `[x]` No live credentials, k3d cluster, SQLCipher library, or OS keychain is
  needed.

### Phase T1 - Local CLI E2E Harness

Goal: make process-level CLI flows repeatable.

Tasks:

- Add `test/e2e/lib/common.sh`.
- Add `test/e2e/cli_basic.sh`.
- Add `test/e2e/daemon_lifecycle.sh`.
- Add `test/e2e/safety_gate.sh`.
- Add `test/e2e/authoring_patch.sh`.
- Add `test/e2e/store_backup_restore.sh`.
- Add Make targets for each script.
- Add transcript and artifact helpers before adding the individual suites.
- Ensure all scripts force temp `TWELVGAIGE_INSTALL_DIR`,
  `TWELVGAIGE_STORE_SQLITE`, `TWELVGAIGE_RUNTIME_DIR`, and
  `TWELVGAIGE_BREECH_ENDPOINT`.
- Validate the first implementation on macOS before adding Linux/macOS remote
  workflow jobs.

Acceptance:

- `[x]` `make e2e-cli` passes on a macOS developer laptop without network,
  hosted LLMs, k3d, or SQLCipher.
- `[x]` Failed e2e runs leave command transcripts and stdout/stderr artifacts.
- `[x]` Full `make e2e` includes CLI, daemon, safety, authoring, and store
  flows.
- `[x]` A failed daemon run should not leave a live daemon or stale endpoint that
  breaks the next run.

### Phase T1A - Unit Test Gap Closure

Goal: raise confidence and coverage through targeted unit/component tests before
leaning too heavily on process e2e.

Tasks:

- Add focused tests for the highest uncovered modules from the baseline report.
- Prioritize negative paths and edge cases listed in the unit test gap list.
- Convert any easy, isolated tests to `async: true` where safe.
- Add contract-style tests for behaviours with multiple implementations.
- Add regression tests for known recent risk areas: blocked-start resource
  cleanup, scheduler-owned recovery, daemon endpoint cleanup, provider transport
  policy, and patch approval/digest handling.

Acceptance:

- Default `mix test` remains deterministic and offline.
- Coverage moves toward or past the 70% gate through real branch coverage.
- No new test depends on host-specific state unless explicitly tagged.

Progress:

- `[x]` Persisted string-key error maps serialize safely in round snapshots.
- `[x]` Crypto key metadata serializes without raw key material.
- `[x]` Key material validation and inspect redaction have focused tests.
- `[x]` Resource limiter owner-down cleanup releases held permits, drops stale
  waiters, and notifies the next eligible owner.
- `[x]` Scheduler-owned recovered rounds are routed through Breech recovery and
  complete via `Round.Server.recover_sync/3`.
- `[x]` Provider transport policy denies endpoint overrides when DNS returns no
  addresses, invalid resolver responses, or resolver exceptions.

### Phase T2 - Coverage CI

Goal: publish and enforce the 70% coverage gate.

Tasks:

- Add a `coverage` job to `.github/workflows/ci.yml`.
- Run `make coverage-export`.
- Upload `cover/**`.
- Keep the threshold at 70%.
- Add a badge or docs note after the workflow is stable.
- Use one Linux coverage job first. macOS coverage can be added later if it
  catches platform-specific gaps worth the runtime.

Acceptance:

- `[x]` Linux coverage job runs `make coverage-export`.
- `[x]` Coverage artifacts upload `cover/**` and
  `artifacts/coverage-summary.txt`.
- `[ ]` Pull requests show coverage as a required branch-protection check.
- `[x]` Coverage below 70% fails the job.

Progress:

- `[x]` Added `docs/ci.md` with the required coverage check name for branch
  protection.
- `[x]` Coverage remains a separate required job rather than being folded into
  `make ci`; this keeps CI logs clearer and preserves coverage artifacts.
- `[x]` Coverage PR comments are deferred; required check status plus uploaded
  artifacts are enough for now.

### Phase T3 - Remote Offline E2E CI

Goal: run real CLI e2e on clean GitHub runners.

Tasks:

- Add `.github/workflows/e2e.yml`.
- Run Linux and macOS e2e CLI flows on PRs and pushes, with macOS treated as
  the local-developer parity check.
- Run daemon and authoring e2e on Linux.
- Add the initial Windows CLI contract job after POSIX e2e is stable.
- Keep Linux and Windows coverage in GitHub workflows so local development can
  stay centered on macOS.
- Upload e2e artifacts on failure.

Acceptance:

- `[x]` Linux and macOS e2e jobs are defined without secrets.
- `[ ]` Linux and macOS e2e jobs pass remotely.
- `[ ]` Windows CLI contract job passes without secrets.
- `[x]` E2E jobs are pinned to exact action SHAs.
- `[x]` Forked PRs do not require secrets.

Progress:

- `[x]` Added `test/e2e/windows_cli.ps1` for source-built CLI checks on
  `windows-latest`.
- `[x]` Added the `windows-cli-contract` job to `.github/workflows/e2e.yml`.
- `[x]` Added `make e2e-windows` as a local/CI convenience wrapper for
  PowerShell-capable environments.
- `[x]` E2E artifact paths are rooted under `${{ runner.temp }}` on GitHub
  runners for Linux, macOS, and Windows.
- `[x]` Added `docs/ci.md` with required e2e/package check names for branch
  protection.
- `[x]` Added job-level timeouts to e2e jobs so stuck daemon or package commands
  fail with bounded runtime.

### Phase T4 - Package E2E

Goal: prove built artifacts behave like the source CLI.

Tasks:

- `[x]` Run e2e basic against the escript.
- `[x]` Run e2e basic against Mix release CLI wrappers.
- `[x]` Run host-runnable Burrito e2e on Linux and macOS.
- `[x]` Keep cross-built Windows and ARM artifacts to build-only until native runners
  or emulation are available.

Acceptance:

- `[ ]` Package e2e passes on pushes to `main`.
- `[x]` Release workflow can reuse the same Make targets.
- `[x]` Package e2e uses the same `test/e2e` scripts by changing only
  `TWELVGAIGE_E2E_BIN`.

Progress:

- `[x]` Added `make e2e-package`, `make e2e-package-escript`,
  `make e2e-package-release`, `make e2e-package-burrito`, and
  `make e2e-package-burrito-only`.
- `[x]` `make package` now runs package E2E for escript and native Mix release
  artifacts before copying release assets.
- `[x]` Build and release workflows run package E2E for host-runnable Burrito
  targets and keep cross-built Linux ARM64/Windows Burrito artifacts build-only.
- `[x]` Local macOS validation passed for escript, native release, Burrito, and
  the combined `make package ARTIFACT_SUFFIX=local-package-e2e` path.
- `[x]` Added job-level timeouts to build and release package jobs.

### Phase T5 - Live Remote E2E

Goal: add opt-in live environment checks.

Tasks:

- `[x]` Add manual/scheduled k3d job.
- `[x]` Add manual provider-live job for Anthropic/OpenAI/Gemini/Ollama where
  practical.
- `[x]` Add SQLCipher and Keychain live jobs as manual platform-specific workflows.
- `[x]` Require both tags and explicit env opt-ins, for example
  `TWELVGAIGE_K8S_LIVE=1` or `TWELVGAIGE_PROVIDER_LIVE=1`.

Acceptance:

- `[x]` Live jobs never run on ordinary PRs.
- `[x]` Live jobs clean up external/local resources.
- `[x]` Failures upload logs and command transcripts.

Progress:

- `[x]` Added `make e2e-k3d`, `make e2e-provider-live`, and
  `make e2e-sqlcipher-live`.
- `[x]` Added `test/e2e/k3d_live.sh`, which creates a disposable k3d cluster,
  runs the existing `:k8s_live` tests, captures Kubernetes diagnostics on
  failure, and deletes the cluster on exit.
- `[x]` Added `test/twelvgaige/llm/provider_live_test.exs`, which only runs
  behind `:provider_live` and requires `TWELVGAIGE_PROVIDER_LIVE=1` plus explicit
  model/credential environment.
- `[x]` Added `.github/workflows/live-e2e.yml` with manual suite selection,
  weekly scheduled k3d coverage, pinned actions, 14-day artifact retention, and
  no PR trigger.
- `[x]` Added job-level timeouts to live e2e jobs.
- `[x]` Provider, SQLCipher, and Keychain live jobs use GitHub environments
  (`live-providers`, `live-sqlcipher`, `live-keychain`) so repository settings
  can require manual approval before secrets are exposed.
- `[ ]` Remote live k3d/provider/SQLCipher/Keychain jobs have been manually
  confirmed in GitHub Actions.

### Phase T6 - Coverage Improvement To 70% And Beyond

Goal: use the baseline to add targeted tests, not broad shallow assertions.

Current target:

- Keep the required gate at 70% until the remote coverage job is stable.
- The 75% local milestone is met on macOS. Raise the enforced gate only after
  offline Linux/macOS CI and package E2E have been green for at least a week.

Priority areas:

- `[x]` CLI error and JSON formatting paths.
- `[x]` Daemon endpoint failure and recovery branches.
- `[x]` Store backup/restore/migration failure paths.
- `[x]` Patch apply partial-failure and invalid validation paths.
- `[x]` Provider transport error classification.
- `[x]` Windows path/address parsing.
- `[x]` Resource limiter queue cleanup and blocked-start accounting.
- `[x]` Scheduler-owned recovered rounds.
- `[x]` Security equality, provider config normalization, redaction, and
  SQLCipher spike reporting edge cases.

Acceptance:

- `[x]` Project coverage is at or above 70%.
- `[x]` New critical CLI features include unit tests and at least one e2e path.
- `[x]` The next target is documented after 70% is stable.
- `[x]` Unit-test gap list is either completed or reduced to documented low-value
  branches.

Progress:

- `[x]` Corrupt or invalid daemon endpoint discovery files are removed only
  after singleton lock verification, allowing daemon startup/recovery to clear
  stale local state without deleting a live endpoint.
- `[x]` TCP IPC endpoint strings round-trip IPv4 and bracketed IPv6 addresses.
- `[x]` Windows named pipe endpoint strings round-trip encoded path segments and
  reject malformed pipe addresses.

## Proposed GitHub Workflow Triggers

`ci.yml`:

- PR and push to `main`.
- Unit, persistence, authoring, coverage.

`e2e.yml`:

- PR and push to `main` for offline Linux/macOS e2e.
- `workflow_dispatch` for all e2e jobs.

`live-e2e.yml`:

- Nightly schedule for k3d e2e.
- Provider-live jobs only on `workflow_dispatch` with protected environment
  secrets.
- SQLCipher and Keychain live jobs only on `workflow_dispatch`.

`build.yml`:

- Keep package build/smoke.
- Optionally call `make e2e-package` after package artifacts are built.

`release.yml`:

- Reuse package e2e before publish where runtime is acceptable.

## Coverage Policy

- Initial gate: 70%.
- Files excluded from coverage must be justified in `mix.exs` comments or this
  plan.
- Lowering the threshold requires updating this plan with a reason.
- Raising the threshold should happen in 5% increments after a stable week of
  green CI.
- New user-visible CLI commands should include unit/component tests plus either
  an existing e2e path or a documented reason why process e2e is unnecessary.
- New live integrations must include fake/offline tests first, then opt-in live
  tests.
- A coverage increase from e2e alone is not enough for complex logic; add
  lower-level tests around the decision points.

## Flake Policy

- A flaky e2e must be fixed or quarantined behind a non-required manual target;
  do not add blind retries.
- Polling loops must have explicit timeouts and print the last observed state.
- E2E scripts must clean up child processes on `EXIT`, `INT`, and `TERM`.
- All tests that mutate process environment or application config should remain
  `async: false` unless they use isolated helper APIs.
- CI failures should preserve enough artifacts to reproduce locally with the
  same Make target.

## Definition Of Done For This Testing Track

- `make coverage` enforces 70% offline coverage.
- `make e2e` runs the core CLI contract locally without network credentials.
- `.github/workflows/e2e.yml` runs offline e2e on clean runners.
- Package e2e reuses the same scripts against built artifacts.
- Live k3d/provider checks are opt-in and cannot block ordinary forked PRs.
- README and usage docs mention the main local validation commands.
