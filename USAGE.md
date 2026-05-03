# Twelvgaige Usage

Twelvgaige runs deterministic agent workflows from the CLI. Elixir/OTP owns the control flow, retries, resource limits, safety gates, and persistence; LLMs only produce bounded shot outputs.

For broader documentation, start at [`README.md`](README.md). For scenario
drills, see the traphouse rack at
[`traphouse/drills/README.md`](traphouse/drills/README.md).
Provider credentials and endpoint policy are covered in
[`docs/secrets-and-providers.md`](docs/secrets-and-providers.md).

## Core Terms

- **Shell**: a workflow or agent definition file. YAML, JSON, and TOML are
  implemented authoring formats.
- **Round**: one execution of a workflow shell.
- **Shot**: one step inside a round.
- **Safety shot**: a human approval checkpoint.
- **Breech**: the local daemon that owns detached rounds, round history, watch events, audit events, and safety decisions.

## Build And Help

From source:

```bash
mix deps.get
mix escript.build
./twelvgaige --help
./twelvgaige version
```

Use `./twelvgaige` in the examples below when running from the repo.

Common development and CI targets are controlled by the Makefile:

```bash
make ci
make package
make release-smoke
make package-burrito-smoke BURRITO_TARGET=linux
```

`make ci` runs dependency fetch, formatter check, warnings-as-errors compile,
normal tests, and persistence tests. GitHub Actions calls the same targets for
CI, packaging, and release jobs.

For a native Elixir release bundle:

```bash
make release
_build/prod/rel/twelvgaige_native/bin/twelvgaige version
```

The release tarball is `_build/prod/twelvgaige_native-<version>.tar.gz`. It includes
ERTS and is specific to the OS/architecture where it was built. Inside the
release, use `bin/twelvgaige` for normal CLI commands and
`bin/twelvgaige_native` for Mix release lifecycle commands such as `start`,
`remote`, and `stop`.

For a Burrito single-file executable:

```bash
make burrito BURRITO_TARGET=macos_silicon
./burrito_out/twelvgaige_macos_silicon version
```

Choose the target for the machine you are publishing to: `macos`,
`macos_silicon`, `linux`, `linux_arm64`, or `windows`. Burrito needs Zig
`0.15.2` and `xz` to build; Windows targets also need `7z` or `7zz`. The output
is `burrito_out/twelvgaige_<target>` or `burrito_out/twelvgaige_<target>.exe`.
Run it like the normal CLI:

```bash
./burrito_out/twelvgaige_macos_silicon shell validate traphouse/workflows/simple.yaml
./burrito_out/twelvgaige_macos_silicon round run traphouse/workflows/simple.yaml --input '{}'
```

If your local OTP patch release is newer than the Burrito ERTS archive mirror,
point Burrito at the host ERTS explicitly for host-target builds:

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
BURRITO_CUSTOM_ERTS_MACOS_SILICON="$(elixir -e 'IO.puts(:code.root_dir())')" \
make package-burrito-smoke BURRITO_TARGET=macos_silicon
```

The target-specific variables are `BURRITO_CUSTOM_ERTS_MACOS`,
`BURRITO_CUSTOM_ERTS_MACOS_SILICON`, `BURRITO_CUSTOM_ERTS_LINUX`,
`BURRITO_CUSTOM_ERTS_LINUX_ARM64`, and `BURRITO_CUSTOM_ERTS_WINDOWS`.
`BURRITO_CUSTOM_ERTS` applies to every target. Only use a custom ERTS that
matches the target OS and architecture. On macOS with newer SDKs, Homebrew's
patched `zig@0.15` has proven more reliable than the upstream Zig binary.

GitHub workflows live in `.github/workflows`:

- `ci.yml`: formatter, compile, normal tests, persistence tests.
- `build.yml`: smoke-builds escript, Mix release artifacts, and Burrito
  executables. Burrito runs as a multi-platform matrix for `linux`,
  `linux_arm64`, `windows`, `macos`, and `macos_silicon`.
- `release.yml`: publishes tag/manual release artifacts. Burrito binaries are
  the primary multi-platform release artifacts.

Reusable actions are pinned to full commit SHAs. Keep workflow logic thin; add
commands to the Makefile first.

## A Minimal Workflow

The repo includes the same minimal workflow as YAML, JSON, and TOML under
`traphouse/workflows/`. The YAML shape is:

```yaml
kind: workflow
id: simple
name: Simple Format Demo
version: 1.0.0
shots:
  - id: first
    kind: slug
    agent: mock_agent
    prompt: first prompt
  - id: second
    kind: slug
    agent: mock_agent
    depends_on:
      - first
    prompt: second prompt
```

The adjacent mock agent lives at `traphouse/workflows/agents/mock_agent.yaml`:

```yaml
kind: agent
id: mock_agent
name: Mock Agent
version: 1.0.0
provider: mock
model: mock-model
system_prompt: Run the mock shot.
```

Agent shells in an `agents/` directory next to the workflow are discovered
automatically for trusted local roots. For shells stored elsewhere, pass one or
more explicit paths:

```bash
twelvgaige round run traphouse/workflows/simple.yaml --input '{}' --agent-shell traphouse/workflows/agents/mock_agent.yaml
```

When testing a workflow from an unreviewed repository, disable adjacent agent
discovery and pass only reviewed agent shells:

```bash
twelvgaige round run ./downloaded/workflow.yaml --input '{}' --untrusted-root --agent-shell ./reviewed-agents/mock_agent.yaml
twelvgaige round run ./downloaded/workflow.yaml --input '{}' --no-agent-discovery --agent-shell ./reviewed-agents/mock_agent.yaml
```

`--untrusted-root` keeps explicit `--agent-shell` paths working but blocks
workflow-relative auto-discovery unless a privileged API caller opts back in.

Validate it:

```bash
twelvgaige shell validate traphouse/workflows/simple.yaml
twelvgaige shell validate traphouse/workflows/simple.yaml --format json
twelvgaige shell reload traphouse --format json
twelvgaige shell list --format json
twelvgaige shell show simple
```

Normalize or convert shells when reviewing generated definitions or moving
between YAML, JSON, and TOML:

```bash
twelvgaige shell normalize traphouse/workflows/simple.yaml
twelvgaige shell normalize traphouse/workflows/simple.toml --format json
twelvgaige shell convert traphouse/workflows/simple.yaml --to toml --output traphouse/workflows/simple.toml
twelvgaige shell convert traphouse/workflows/simple.toml --to yaml
```

Run it in the foreground:

```bash
twelvgaige round run traphouse/workflows/simple.yaml --input '{}'
```

Input can be inline JSON, a JSON file, or stdin:

```bash
twelvgaige round run traphouse/workflows/simple.yaml --input '{"cluster":"dev"}'
twelvgaige round run traphouse/workflows/simple.yaml --input input.json
cat input.json | twelvgaige round run traphouse/workflows/simple.yaml --input -
```

Use JSON output for scripts:

```bash
twelvgaige round run traphouse/workflows/simple.yaml --input '{}' --format json
```

## Foreground Safety Flow

A safety shot pauses the round for approval.

```yaml
kind: workflow
id: safety_simple
version: 1.0.0
shots:
  - id: approval
    kind: safety
    description: "Review before continuing"
  - id: after
    kind: slug
    agent: mock_agent
    depends_on: [approval]
    prompt: "run after approval"
```

Run and auto-approve local safety shots:

```bash
twelvgaige round run traphouse/workflows/safety.yaml --input '{}' --approve-safety
```

Without `--approve-safety`, the foreground run returns an awaiting-safety snapshot. Use the daemon flow when you want to approve later from another command.

## Daemon Flow

The daemon is used for detached rounds, inspection, watch, audit, cancellation, and external safety approval.

When the daemon is started with configured shell cache paths, workflow IDs can be used instead of file paths. Foreground runs still use explicit workflow paths.

```elixir
config :twelvgaige, :shell_paths, ["./workflows"]
```

Serve it in one terminal:

```bash
twelvgaige daemon serve
```

Use a durable SQLite store:

```bash
TWELVGAIGE_STORE_SQLITE=/tmp/twelvgaige.sqlite3 twelvgaige daemon serve
```

Then use another terminal for CLI commands:

```bash
twelvgaige status
twelvgaige daemon paths
```

Submit a detached round:

```bash
twelvgaige round run traphouse/workflows/simple.yaml --input '{}' --detach
```

Inspect rounds:

```bash
twelvgaige round list
twelvgaige round list --status running
twelvgaige round show <round-id>
twelvgaige round show <round-id> --format json
```

Stop the daemon:

```bash
twelvgaige daemon stop
```

## Watch And Audit

Watch committed round events:

```bash
twelvgaige round watch <round-id>
twelvgaige round watch <round-id> --format ndjson
twelvgaige round watch <round-id> --after-seq 10 --follow --timeout-ms 30000
twelvgaige round watch <round-id> --follow --until-terminal --format ndjson
```

`--follow` writes each committed event batch as it arrives. `--until-terminal` keeps advancing the cursor until the round reaches a terminal state, a timeout bound is hit, or the configured event limit is reached.

Read the audit trail:

```bash
twelvgaige round audit <round-id>
twelvgaige round audit <round-id> --format json
twelvgaige round audit <round-id> --format ndjson --after-seq 20 --limit 100
twelvgaige round audit <round-id> --format checkpoint
```

Use watch for operational progress. Use audit when you need durable evidence of
state transitions, tool attempts, safety decisions, and recovery events.
`--format checkpoint` emits a SHA-256 hash-chain export so saved audit evidence
can be checked for mutation later.

## Safety Approval In The Daemon

When a detached round pauses on a safety shot:

```bash
twelvgaige round show <round-id>
twelvgaige round approve <round-id> --shot approval --reason "reviewed"
```

Rejecting halts or fails the round according to the workflow policy:

```bash
twelvgaige round reject <round-id> --shot approval --reason "too risky"
```

Cancel a round:

```bash
twelvgaige round cancel <round-id> --reason "operator stopped it"
```

## Common Use Cases

### Local Workflow Development

Use foreground runs while editing workflow shells:

```bash
twelvgaige shell validate traphouse/workflows/simple.yaml
twelvgaige round run traphouse/workflows/simple.yaml --input '{}' --format json
```

This is the fastest loop. No daemon is required.

### CI Or Automation

Use JSON output and deterministic exit codes:

```bash
twelvgaige round run ci/check.yaml --input ci-input.json --format json
```

The command exits non-zero for failed, halted, timed out, invalid, or unavailable runs.

### Long-Running Laptop Work

Use the daemon when a round may run longer than one terminal session:

```bash
twelvgaige daemon serve
twelvgaige round run workflows/report.yaml --input input.json --detach
twelvgaige round watch <round-id> --follow --until-terminal
```

The daemon keeps the round observable and applies local resource limits so multiple rounds do not overwhelm a laptop.

Use `--profile minimal|laptop|workstation|server` to choose local resource
budgets for a run. `laptop` is the default; `minimal` is best for battery or CI.

```bash
twelvgaige round run workflows/report.yaml --input input.json --profile minimal
TWELVGAIGE_PROFILE=workstation twelvgaige daemon serve
```

Scheduled daemon jobs can use fixed intervals or a portable five-field UTC cron expression in application config:

```elixir
config :twelvgaige, :scheduler_jobs, [
  %{id: "report_5m", workflow: "workflows/report.yaml", input: %{}, interval_ms: 300_000},
  %{id: "weekday_0900", workflow: "workflows/report.yaml", input: %{}, cron: "0 9 * * 1-5"}
]
```

### Human-Gated Operations

Use safety shots before any sensitive step:

```bash
twelvgaige round run workflows/remediate.yaml --input incident.json --detach
twelvgaige round show <round-id>
twelvgaige round approve <round-id> --shot approval --reason "approved by on-call"
```

This keeps approval outside the LLM. The model cannot bypass the checkpoint.

### Read-Only Infrastructure Inspection

Use read-only workflows for cluster, HTTP, shell-read, or Git inspection:

```bash
twelvgaige round run workflows/k8s_inspect.yaml --input '{"namespace":"default"}' --detach
twelvgaige round audit <round-id>
```

The useful pattern is: collect state, summarize it, validate structured output, then require safety approval before any later write-oriented workflow.

### Local Kubernetes Smoke

Live Kubernetes tests are opt-in. Prefer a disposable k3d cluster:

```bash
k3d cluster create twelvgaige-smoke --servers 1 --agents 0 --wait
kubectl get nodes --context k3d-twelvgaige-smoke
TWELVGAIGE_K8S_LIVE=1 TWELVGAIGE_K8S_CONTEXT=k3d-twelvgaige-smoke mix test --include k8s_live
k3d cluster delete twelvgaige-smoke
```

Normal tests must not require a live cluster.

## Output Formats

Most commands support human output by default and JSON for automation:

```bash
twelvgaige status --format json
twelvgaige round list --format json
twelvgaige round show <round-id> --format json
```

Event streams also support NDJSON:

```bash
twelvgaige round watch <round-id> --format ndjson
twelvgaige round audit <round-id> --format ndjson
```

If the optional HTTP listener is enabled with `:twelvgaige, :http_listener`, it
can push round events over chunked SSE or NDJSON:

```elixir
config :twelvgaige, :http_listener,
  ip: {127, 0, 0, 1},
  port: 4567,
  bearer_token: System.fetch_env!("TWELVGAIGE_HTTP_TOKEN")
```

```bash
curl -N -H "authorization: Bearer $TWELVGAIGE_HTTP_TOKEN" \
  "http://127.0.0.1:4567/api/v1/rounds/<round-id>/events?stream=true&format=sse&until_terminal=true"
curl -N -H "authorization: Bearer $TWELVGAIGE_HTTP_TOKEN" \
  "http://127.0.0.1:4567/api/v1/rounds/<round-id>/events?stream=true&format=ndjson&after_seq=10"
```

## Daemon Discovery

By default, CLI commands discover the local Breech endpoint file. You can inspect paths with:

```bash
twelvgaige daemon paths
```

Default IPC is a Unix socket on macOS/Linux and authenticated loopback TCP on Windows. Windows named-pipe addresses can be encoded and discovered, and the IPC protocol is tested through injected pipe transports; `--transport npipe` is still an explicit platform-verification path until native Windows pipe listener I/O is validated.

Useful overrides:

```bash
twelvgaige daemon serve --transport tcp --runtime-dir /tmp/twelvgaige
twelvgaige daemon serve --transport unix --endpoint /tmp/twelvgaige/endpoint.json
twelvgaige daemon paths --transport npipe
TWELVGAIGE_BREECH_ENDPOINT=/tmp/twelvgaige/endpoint.json twelvgaige status
TWELVGAIGE_BREECH_ADDR=tcp://127.0.0.1:4567 twelvgaige status
TWELVGAIGE_BREECH_ADDR=npipe:////./pipe/twelvgaige-<user-hash>-breech twelvgaige status
```

## Release Checklist

Before publishing, use [`release-checklist.md`](docs/design/release-checklist.md). It tracks
required gates, packaging smoke checks, resource-profile measurements, security
checks, and no-go criteria.

## Command Reference

```bash
twelvgaige --help
twelvgaige version
twelvgaige status [--format human|json]

twelvgaige daemon serve [--transport unix|tcp|npipe] [--runtime-dir <path>] [--endpoint <path>]
twelvgaige daemon stop [--runtime-dir <path>] [--endpoint <path>]
twelvgaige daemon paths [--transport unix|tcp|npipe] [--runtime-dir <path>] [--endpoint <path>]

twelvgaige shell validate <path> [--format human|json]
twelvgaige shell normalize <path> [--format json|yaml|toml]
twelvgaige shell convert <path> --to json|yaml|toml [--output <path>]
twelvgaige shell reload [path ...] [--format human|json]
twelvgaige shell list [--kind workflow|agent|all] [--format human|json]
twelvgaige shell show <shell-id> [--kind workflow|agent] [--format human|json]

twelvgaige round run <workflow-shell-path-or-id> --input <json-or-path> [--agent-shell <path>] [--no-agent-discovery] [--untrusted-root] [--profile minimal|laptop|workstation|server] [--format human|json] [--approve-safety] [--detach]
twelvgaige round list [--format human|json] [--status <status>]
twelvgaige round show <round-id> [--format human|json]
twelvgaige round watch <round-id> [--format human|ndjson] [--after-seq <seq>] [--limit <count>] [--follow] [--until-terminal] [--timeout-ms <ms>]
twelvgaige round audit <round-id> [--format human|json|ndjson|checkpoint] [--after-seq <seq>] [--limit <count>]
twelvgaige round approve <round-id> --shot <safety-shot-id> [--reason <text>] [--format human|json]
twelvgaige round reject <round-id> --shot <safety-shot-id> [--reason <text>] [--format human|json]
twelvgaige round cancel <round-id> [--reason <text>] [--format human|json]
```
