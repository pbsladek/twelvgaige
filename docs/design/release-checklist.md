# Twelvgaige Release Checklist

This checklist gates the current local single-node CLI release. It assumes Twelvgaige is a laptop-friendly daemon plus CLI, not a multi-node service.

## Release Target

- Local single-node operation on macOS, Linux, and Windows laptops.
- macOS/Linux default IPC: Unix socket.
- Windows default IPC: authenticated loopback TCP.
- Durable local stores: file store and SQLite store.
- Provider adapters: Anthropic, OpenAI, Gemini, and Ollama with offline fixture coverage.
- Kubernetes support: structured `kubectl` tools with fake-runner tests and opt-in live smoke tests.
- Distribution: source-built escript, native Mix release tarball, and Burrito single-file executable for the target OS/architecture.
- Package targets emit `artifacts/BUILD-METADATA.txt` and `artifacts/SHA256SUMS`; verify both are uploaded with release artifacts before publishing.

Not release blockers for this target:

- Native Windows named-pipe listener I/O. Address parsing, discovery, client injection, and server dispatcher injection are implemented; actual listener I/O still needs Windows verification.
- Multi-node execution, Postgres-backed coordination, and distributed registries.
- Arbitrary `shell_exec`.
- Native installers, code signing, notarization, auto-update, or package-manager distribution beyond the Burrito executable and Mix release tarball.

## Required Test Gates

Run these before tagging a release candidate:

```bash
make ci
```

`make ci` runs dependency fetch, formatter check, warnings-as-errors compile,
normal tests, and persistence tests. GitHub Actions uses the same Make target.
All reusable workflow actions must stay pinned to full commit SHAs.

Run the daemon suite on machines where local IPC tests are supported:

```bash
mix test --include daemon
```

Run live Kubernetes smoke tests only against an explicit local or disposable cluster. The preferred disposable target is k3d:

```bash
k3d cluster create twelvgaige-smoke --servers 1 --agents 0 --wait
kubectl get nodes --context k3d-twelvgaige-smoke
TWELVGAIGE_K8S_LIVE=1 TWELVGAIGE_K8S_CONTEXT=k3d-twelvgaige-smoke mix test --include k8s_live
k3d cluster delete twelvgaige-smoke
```

Provider live smoke tests, when present, must require both an ExUnit tag and environment opt-in so normal tests never call external LLMs.

## Local CLI Smoke

Build and verify the escript:

```bash
make escript-smoke
```

Build and verify the native Mix release bundle. Mix releases are target-specific:
build the macOS artifact on macOS, Linux artifact on Linux, and Windows artifact
on Windows. The tarball includes ERTS and the product CLI wrapper.

```bash
make release-smoke
ls -lh _build/prod/twelvgaige_native-*.tar.gz
```

In the release directory, `bin/twelvgaige` is the product CLI and
`bin/twelvgaige_native` is the Mix-generated lifecycle script for `start`,
`daemon`, `remote`, `rpc`, and `stop`. Windows release artifacts include
`bin\twelvgaige.bat` and `bin\twelvgaige.ps1`; those must be smoke-tested on a
Windows runner before publishing a Windows bundle.

Build and verify the Burrito single-file executable. Burrito v1.5.x requires
Zig `0.15.2` and `xz` in `PATH`; Windows targets also require `7z` or `7zz`.
Burrito supports cross-target builds from macOS and Linux, but not from native
Windows shells. Use WSL for Windows build hosts.

```bash
make burrito-smoke BURRITO_TARGET=macos_silicon
```

If the local OTP patch release is not available from Burrito's ERTS archive
mirror, use a target-specific custom ERTS override for host-target smoke tests:

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
BURRITO_CUSTOM_ERTS_MACOS_SILICON="$(elixir -e 'IO.puts(:code.root_dir())')" \
make package-burrito-smoke BURRITO_TARGET=macos_silicon
```

Supported override variables are `BURRITO_CUSTOM_ERTS_<TARGET>` using uppercase
target names, or the global `BURRITO_CUSTOM_ERTS`. The custom ERTS must match
the target OS and architecture. On macOS with newer SDKs, prefer Homebrew's
patched `zig@0.15` if the upstream Zig binary fails during wrapper linking.

Target names are `macos_silicon`, `linux`, `linux_arm64`, and `windows`.
Burrito outputs `burrito_out/twelvgaige_<target>` or
`burrito_out/twelvgaige_<target>.exe`. Use `make package-burrito-smoke` only
for host-runnable targets; cross-built targets should use `make package-burrito`
and be smoke-tested on native or emulated runners.

Verify daemon discovery and lifecycle in a temporary runtime directory:

```bash
./twelvgaige daemon paths --runtime-dir /tmp/twelvgaige-release
./twelvgaige daemon serve --runtime-dir /tmp/twelvgaige-release
```

In a second terminal:

```bash
export TWELVGAIGE_BREECH_ENDPOINT=/tmp/twelvgaige-release/breech.endpoint.json
./twelvgaige status --format json
./twelvgaige round list --format json
./twelvgaige daemon stop --runtime-dir /tmp/twelvgaige-release
```

Verify SQLite-backed daemon startup and restart with a temporary database:

```bash
TWELVGAIGE_STORE_SQLITE=/tmp/twelvgaige-release.sqlite3 ./twelvgaige daemon serve --runtime-dir /tmp/twelvgaige-sqlite-release
```

Then submit a detached round, stop the daemon, restart it against the same database, and confirm `round list`, `round show`, `round watch`, and `round audit` still work.

## Resource Profile Smoke

Run at least one representative round under each supported local profile:

```bash
TWELVGAIGE_PROFILE=minimal ./twelvgaige round run test/fixtures/shells/simple_workflow.yaml --agent-shell test/fixtures/shells/mock_agent.yaml --input '{}'
TWELVGAIGE_PROFILE=laptop ./twelvgaige round run test/fixtures/shells/simple_workflow.yaml --agent-shell test/fixtures/shells/mock_agent.yaml --input '{}'
TWELVGAIGE_PROFILE=workstation ./twelvgaige round run test/fixtures/shells/simple_workflow.yaml --agent-shell test/fixtures/shells/mock_agent.yaml --input '{}'
```

For release notes, record approximate idle daemon RSS, peak RSS during the smoke workflow, and whether other normal desktop workloads remain responsive.

## Security And Audit Checks

- Confirm logs and audit records redact API keys, bearer tokens, kubeconfig material, authorization headers, and common secret field names.
- Confirm `http_get` and provider transports deny unsafe schemes, userinfo URLs, private destinations by default, redirects where disallowed, and oversized responses.
- Confirm Kubernetes write tools require explicit safety level, `confirm=true`, namespace constraints, and structured argv.
- Confirm `kubectl_exec` remains runtime-disabled unless trusted config opts in.
- Confirm store cleanup does not remove incomplete rounds or unsafe reconciliation records.

## Go/No-Go Criteria

Go only if:

- Required test gates pass.
- The local CLI smoke succeeds.
- File and SQLite durable stores survive restart for at least one terminal round and one awaiting-safety or recovered round.
- Metrics and JSON logs expose useful operational state without high-cardinality labels or raw prompts/tool outputs.
- The release notes clearly state the native Windows named-pipe listener limitation.

No-go if:

- A state transition can fire dependents before the durable store commit succeeds.
- A side-effecting tool can run without prior intent journaling when a store is configured.
- A resource limiter permit can leak after cancellation, timeout, owner crash, or blocked start.
- Normal `mix test` requires network, a live LLM provider, or a live Kubernetes cluster.
