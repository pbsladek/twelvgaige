# Twelvgaige Implementation Spec

> This file is the normative implementation spec for Twelvgaige.
> If this file conflicts with `plan.md`, this file wins and `plan.md` should be updated.

## 1. Status

Project status: The tracked Phase 0-5 local single-node implementation is complete for macOS/Linux and Windows default loopback TCP operation. Native Mix release packaging is implemented as a target-specific tarball bundle with included ERTS and product CLI wrappers. Burrito packaging is implemented as a single-file executable release path for configured macOS, Linux, and Windows targets. Native Windows named-pipe listener I/O remains the only tracked partial and is pending verification on Windows hardware.

Release gates and manual smoke checks are tracked in [`release-checklist.md`](release-checklist.md).

Legend:

- `[ ]` planned
- `[~]` in progress
- `[x]` implemented
- `[!]` blocked or needs redesign

## 2. Locked Product Decisions

Twelvgaige is a CLI-first Elixir/OTP system for deterministic agent orchestration.

Locked terminology:

| Term | External CLI | Shell files | Internal modules | Meaning |
| --- | --- | --- | --- | --- |
| round | yes | round metadata | `Twelvgaige.Round` | One workflow run. |
| shell | yes | workflow or agent file | `Twelvgaige.Shell` | A declarative definition file. |
| shot | yes | `shots` | `Twelvgaige.Shot` | One executable workflow step. |
| pattern | mostly internal | compiled shell | `Twelvgaige.Pattern` | The validated DAG. |
| loadout | docs/internal | agent plus chokes | `Twelvgaige.Loadout` if needed | Model, prompt, tools, limits. |
| choke | docs/shells | `choke` | policy structs | Timeout, retry, token, tool, safety constraints. |
| safety | yes | `kind: safety` | `Twelvgaige.Safety` if needed | Human or policy approval gate. |
| breech | yes | no | `Twelvgaige.Breech` | Local daemon and IPC boundary. |

External shell files use `shots`, not `steps`. Documentation may describe a shot as "a workflow step" on first use.

Initial product shape:

- Phase 1 runs foreground-only in the CLI process. Detached rounds do not exist until the Breech daemon is introduced.
- The default runtime profile targets ordinary developer laptops. Multiple agents must be bounded by explicit concurrency, output, and retention limits.
- The daemon is introduced only after the in-memory round engine is correct.
- Single-node correctness comes before distributed execution.
- Destructive tools are out of scope until read-only tools, audit, safety, recovery semantics, and durable attempt journaling are proven.

## 3. Non-Negotiable Design Principles

1. The LLM never controls the pattern.

The workflow DAG, dependency rules, conditions, retries, timeouts, and safety gates are evaluated by Elixir code. LLM output is data, not control authority.

2. `Round.Server` is the only process that advances round and shot state.

Shot executors can call LLMs and tools, and they can return traces, outputs, and classified errors. They do not decide whether dependent shots fire.

3. Shot execution is isolated from the coordinator.

Round coordination uses `Task.Supervisor.async_nolink/2` or equivalent non-linked execution. A crashed shot task must not crash the round server.

4. All process messages are correlated.

Every in-flight shot has a shot ID, attempt number, task pid, monitor ref, and timeout ref. Late messages from previous attempts are ignored.

5. Recovery is explicit.

After a VM or daemon restart, in-flight processes are gone. Running shots are reconciled from durable state. They are never assumed to still be running.

6. Side effects are policy-controlled.

Read-only tools can be retried. Idempotent writes require idempotency metadata. Destructive and irreversible tools require safety policy and durable audit before use.

7. Persistence gates advancement once persistence exists.

After Phase 4, dependent shots must not fire until the state transition and audit events for the previous transition are durably committed.

8. Telemetry is not a gate.

Telemetry and metrics are best-effort. They must not prevent a state transition from succeeding.

9. Local resource use is bounded by default.

Twelvgaige must never spawn one OS process, task, LLM call, or tool call per ready shot without checking profile limits. Ready work queues behind `ResourceLimiter` when the laptop profile is saturated.

## 4. Requirements

### 4.1 Functional Requirements

- `[x]` Load workflow shells from YAML.
- `[x]` Load agent shells from YAML.
- `[x]` Load workflow and agent shells from JSON through the same normalized shell map and compiler path as YAML.
- `[x]` Load workflow and agent shells from TOML through the same normalized shell map and compiler path as YAML.
- `[x]` Complete a sandboxed programmatic-shell RFC before enabling any Starlark/CUE-style workflow generation.
- `[x]` Compile workflow shells into an acyclic pattern.
- `[x]` Validate dependencies, referenced agents, referenced tools, timeouts, retries, conditions, and output schemas. Dependency, cycle, optional agent-reference, built-in/custom tool-reference, agent tool-policy, duration, retry, sandboxed condition syntax, supplied-agent loadout resolution, explicit `--agent-shell` paths, adjacent `agents/` discovery, configured daemon shell-cache paths, example-agent discovery, supported schema-subset validation, and shell-cache reload/list/show CLI UX exist.
- `[x]` Run a round from the CLI with JSON input.
- `[x]` Validate round input against the workflow `input_schema` before a round is queued or any shot executes.
- `[x]` Report local Breech daemon status from the CLI.
- `[x]` Execute independent ready shots in parallel. Foreground no-store execution and scheduler execution both run independent ready executable shots concurrently with bounded resource admission; store-backed scheduler execution commits each `shot_started` transition before spawning its task.
- `[x]` Execute dependent shots only after dependencies are terminal-successful.
- `[x]` Support safety shots that pause a foreground round in Phase 2 and can be approved externally through the daemon in Phase 3.
- `[x]` Approve, reject, cancel, and inspect daemon-owned rounds in Phase 3.
- `[x]` Run LLM-backed shots through a provider behaviour.
- `[x]` Run tests with a test-only deterministic LLM provider and no network.
- `[x]` Execute read-only tools through a tool behaviour.
- `[x]` Enforce per-shot tool allowlists.
- `[x]` Classify LLM, output parser, tool, timeout, policy, and crash errors into the closed `%Twelvgaige.Error{}` taxonomy.
- `[x]` Retry retryable failures according to shot choke.
- `[x]` Persist round state and audit events in Phase 4. File-backed store, SQLite store, Ecto migration metadata, Breech store selection, restart recovery bootstrap, memory/file/SQLite retained-byte cleanup, retention metrics, and SQLite query columns for shell identity, timing, and error reason are implemented.
- `[x]` Recover incomplete rounds after daemon restart in Phase 4. Breech resumes clean queued durable-store rounds through `Round.Server.recover_sync/3`, preserves awaiting-safety rounds, resumes scheduler-owned safety decisions through `Round.Server`, resumes journal-proven retryable partial snapshots, and moves unsafe or ambiguous in-flight snapshots to reconciliation with file-store and SQLite coverage.

### 4.2 Non-Functional Requirements

- `[x]` Core pattern compilation and readiness logic are pure and unit-testable.
- `[x]` Round coordination is implemented with OTP supervision, not ad hoc process management.
- `[x]` The CLI returns deterministic exit codes.
- `[x]` Normal tests do not call real LLMs or mutate real infrastructure.
- `[x]` Logs and audit records redact secrets.
- `[x]` Tool output is bounded by the tool executor per call, per shot, and before re-entering LLM context; memory/file/SQLite store retention is bounded, and JSON log file retention caps trim oldest complete log lines when configured.
- `[x]` Concurrency, prompt size, tool output, shot trace budgets, and store retained history are bounded by named runtime profiles.
- `[x]` The first production-capable local single-node version can run representative unattended workflows with durable state, audit logs, metrics, bounded resources, and scheduler support. Native Windows named-pipe listener I/O and multi-node operation are outside this milestone.
- `[x]` Native packaging uses Mix releases for OS/architecture-specific bundles. The release is named `twelvgaige_native` so the Mix lifecycle script and the product CLI wrapper do not collide.
- `[x]` Burrito packaging produces single-file executables from the `twelvgaige` release. Burrito runtime detection launches the existing CLI dispatcher from the OTP application startup path without affecting normal Mix, escript, or Mix release operation.

## 5. OTP Architecture

### 5.1 Phase 1 Supervision Tree

```text
Twelvgaige.Application
+-- Twelvgaige.Telemetry
+-- Twelvgaige.Registry.Round             # Registry keys: {:round, round_id}
+-- Twelvgaige.Store.Memory               # App-level in-VM state/event store
+-- Twelvgaige.Shell.Cache                # Workflow and agent shell cache
+-- Twelvgaige.Tool.Catalog               # Built-in tool catalog
+-- Twelvgaige.ResourceLimiter            # Local concurrency and byte-budget gates
+-- Twelvgaige.LLM.Supervisor             # Provider clients and test adapters
+-- Twelvgaige.Round.Supervisor           # DynamicSupervisor
+-- Twelvgaige.Breech                     # Phase 3 local daemon control plane
```

`Twelvgaige.Round.Supervisor` starts one `Twelvgaige.Round.RunSupervisor` per active round.

### 5.2 Per-Round Supervision Tree

```text
Twelvgaige.Round.RunSupervisor
+-- Twelvgaige.Shot.TaskSupervisor
+-- Twelvgaige.Round.Server
```

Child spec for each round run:

```elixir
%{
  id: {:round_run, round_id},
  start: {Twelvgaige.Round.RunSupervisor, :start_link, [opts]},
  restart: :transient,
  type: :supervisor
}
```

`Round.RunSupervisor` uses `:one_for_all`.

Rationale:

- If `Round.Server` crashes, all in-flight shot tasks are killed and the round is restarted from the configured store.
- If the task supervisor crashes, the round server is also restarted because all in-flight shot refs are invalid.
- In Phase 1, the known state comes from `Twelvgaige.Store.Memory`, which is owned outside the per-round supervisor. It can recover coordinator crashes inside the same VM, but it is lost when the CLI VM exits.
- In Phase 4, the known state is durable and restart invokes recovery reconciliation.

The shot task supervisor is a `Task.Supervisor`. Shot tasks are started with `Task.Supervisor.async_nolink/2` from `Round.Server`.

### 5.3 Process Ownership Rules

`Round.Server` owns:

- Round status
- Shot statuses
- Ready-shot calculation
- In-flight task refs
- Timeout refs
- Retry scheduling
- Safety waiting state
- Cancellation state

`Shot.Executor` owns:

- Prompt assembly for one shot attempt
- LLM call loop for one shot attempt
- Tool execution for one shot attempt
- Output parsing for one shot attempt
- Returning one classified result to `Round.Server`

Process lookup and definition ownership are separate:

- `Twelvgaige.Registry.Round` is an OTP `Registry` used only for active round process lookup via `{:via, Registry, ...}`.
- `Twelvgaige.Shell.Cache` owns loaded workflow and agent definitions in memory.
- `Twelvgaige.Tool.Catalog` exposes available tool modules. It may be a pure module until runtime tool loading exists.

The store owns in-memory records in Phase 1 and durable records starting in Phase 4.

### 5.4 Resource Limiter

`Twelvgaige.ResourceLimiter` owns local resource admission. It is a small GenServer or ETS-backed process that tracks permits for active rounds, running shots, LLM calls, tool calls, and retained bytes.

It must provide these gates:

- active round admission
- per-round running shot admission
- global running shot admission
- global LLM call admission
- global tool call admission
- optional per-tool call admission for expensive tools
- retained in-memory round history cap
- retained event/log/trace byte caps

When a shot is ready but no permit is available, `Round.Server` leaves it pending and records why it is waiting. It does not spawn the task. When a permit is released, the limiter notifies affected rounds or the round is scheduled for another readiness pass.

The limiter is not a durable correctness mechanism. It is local backpressure so a laptop remains usable while rounds run.

#### 5.4.1 Permit API

Permits are explicit token structs. Callers must release the exact token they acquired.

```elixir
defmodule Twelvgaige.ResourceLimiter do
  @type resource_kind ::
          :active_round
          | :running_shot_global
          | :running_shot_per_round
          | :llm_call
          | :tool_call
          | {:tool_call, String.t()}
          | :retained_bytes

  @spec acquire(resource_kind(), map(), keyword()) ::
          {:ok, Twelvgaige.ResourceLimiter.Permit.t()}
          | {:queued, Twelvgaige.ResourceLimiter.Waiter.t()}
          | {:error, term()}

  @spec release(Twelvgaige.ResourceLimiter.Permit.t()) :: :ok
  @spec cancel_waiter(Twelvgaige.ResourceLimiter.Waiter.t()) :: :ok
end
```

Permit fields:

- `id`
- `resource_kind`
- `round_id`
- `shot_id`
- `attempt`
- `owner_pid`
- `bytes`
- `acquired_at`

Waiter fields:

- `id`
- `resource_kind`
- `round_id`
- `shot_id`
- `attempt`
- `owner_pid`
- `queued_at`
- `deadline_at`

Permit acquisition is all-or-nothing for a logical start. Executable shot start requires both global and per-round shot permits. If either permit is unavailable, neither is consumed and the shot remains pending.

#### 5.4.2 Queue Ownership

The limiter owns admission queues. Callers own domain state.

- `Round.Server` requests active-round and running-shot permits.
- `Shot.Executor` requests LLM and tool-call permits.
- Store/event/log modules enforce or report retained-byte budgets when they need bounded local retention.

If a request is queued, the limiter stores a waiter and later sends this message to `owner_pid`:

```elixir
{:resource_available, waiter_id, resource_kind}
```

The owner must re-check its own domain state before acting. A permit notification is not a command to start work. It only means the owner may try `acquire/3` again.

#### 5.4.3 Fairness

Queue discipline is deterministic weighted round-robin by `round_id` for round-scoped work. Within one round, waiters are FIFO by `queued_at`.

Fairness rules:

- No round may receive more than one newly released global shot permit while other rounds have eligible shot waiters.
- Active round permits are FIFO by queued round creation time.
- LLM and tool permit queues are FIFO within a shot and weighted round-robin across rounds.
- Retained-byte reservations are not queued indefinitely. If bytes cannot be reserved after one retry, the caller must truncate, drop optional debug data, or return a bounded-size error.

#### 5.4.4 Cancellation And Cleanup

Permit cleanup must be safe under crashes and races.

- Every permit is tied to `owner_pid`; the limiter monitors that process.
- If `owner_pid` dies, the limiter releases its permits and removes its waiters.
- If task start fails after permits are acquired, `Round.Server` releases the permits before applying the failure transition.
- If a shot is cancelled while queued, `Round.Server` calls `cancel_waiter/1`.
- If a shot is cancelled while running, `Round.Server` terminates the task and releases permits in the same cleanup path that removes the in-flight shot.
- Releasing an unknown permit is idempotent and logs a debug event, not an error that crashes the caller.

#### 5.4.5 Queue Timeouts

Resource queue time is distinct from shot execution timeout.

- Shot execution timeout starts only after the task starts.
- Round timeout includes queued time.
- Each shot may define `queue_timeout`; default is no per-shot queue timeout.
- If `queue_timeout` expires, the shot fails with `:resource_queue_timeout`.
- If round timeout expires while work is queued, the round follows normal timeout policy.

#### 5.4.6 Byte Budgets

Byte-budget enforcement is owned by the module that creates or retains bytes, with accounting reported to `ResourceLimiter`.

- Prompt assembly enforces `LLM message bytes, per shot attempt`.
- Tool executor enforces per-call and per-shot tool output bytes.
- Event log, memory store, file store, and SQLite store enforce round event and snapshot retention.
- Trace collector enforces stored trace bytes per attempt.
- `Twelvgaige.Shot.Executor` rejects oversized initial and ReAct-expanded LLM
  message payloads before provider calls and checks provider-reported
  `total_tokens` against the active shot token budget after each response.

Overflow behavior:

- Required structured output that exceeds limits fails with `:output_too_large`.
- Tool output over the per-call cap is truncated and marked with `truncated: true`, unless the tool declares truncation unsafe.
- Optional debug traces are dropped before user-visible output is dropped.
- Event logs evict oldest non-terminal debug events first, but must retain state-transition events until durable persistence exists.

#### 5.4.7 Effective Profile Capture

The effective, clamped runtime profile must be stored in the round state and in the Phase 4 run manifest. Recovery uses the stored effective profile, not current environment variables or CLI defaults.

### 5.5 Runtime Profiles

Default profile: `laptop`. `--profile` overrides workflow policy for one run,
`TWELVGAIGE_PROFILE` supplies a process default, and `max_profile` or
`TWELVGAIGE_MAX_PROFILE` may clamp requested profiles lower for the local
runtime.

| Limit | minimal | laptop | workstation | server | Notes |
| --- | ---: | ---: | ---: | ---: | --- |
| Active rounds | 1 | 1 | 4 | 16 | Additional daemon rounds queue. |
| Running shots, global | 1 | 4 | 8 | 32 | Caps concurrent agent executions. |
| Running shots, per round | 1 | 3 | 6 | 12 | Prevents one round from monopolizing a machine. |
| LLM calls, global | 1 | 4 | 8 | 32 | Remote provider calls are I/O-bound but still hold memory and sockets. |
| Tool calls, global | 1 | 4 | 8 | 32 | External tools can be expensive. |
| Tool calls, per shot | 1 | 1 | 2 | 4 | Parallel read-only calls need explicit profile headroom. |
| ReAct iterations, per shot | 4 | 6 | 8 | 10 | Shot-level chokes may be lower. |
| Tool output bytes, per call | 64 KiB | 256 KiB | 512 KiB | 1 MiB | Larger outputs are truncated with metadata. |
| Tool output bytes, per shot | 256 KiB | 1 MiB | 2 MiB | 8 MiB | Sum across calls. |
| LLM message bytes, per shot attempt | 512 KiB | 2 MiB | 4 MiB | 8 MiB | Checked before provider calls. |
| Stored trace bytes, per shot attempt | 128 KiB | 512 KiB | 1 MiB | 2 MiB | Full debug trace requires opt-in. |
| Store retained byte watermark | 128 MiB | 512 MiB | 1 GiB | 4 GiB | Local stores evict oldest terminal rounds while preserving incomplete and newest terminal rounds. |

Approximate local footprint with remote LLM providers:

| Scenario | Expected memory | Expected CPU |
| --- | ---: | --- |
| CLI start or idle daemon | 50-150 MiB RSS | near idle after startup |
| One foreground round, one running shot | 80-200 MiB RSS | low, with short parse/tool spikes |
| Laptop default, four running shots | 150-400 MiB RSS | mostly low if tools are light |
| Heavy tool output near caps | 300-700 MiB RSS | depends on tools |

These are planning targets, not guarantees. External tools can exceed them because their own processes allocate memory outside the BEAM. Local LLM model hosting is out of scope for these numbers; local model runtimes can require multiple GB of RAM or VRAM.

## 6. Public Elixir API

The CLI should call this API. Tests should prefer this API over shelling out unless command parsing is under test.

```elixir
defmodule Twelvgaige do
  @type round_id :: String.t()
  @type shell_id :: String.t()
  @type shot_id :: String.t()

  # Phase 1 foreground API.
  @spec run_round_sync(shell_id() | Path.t(), map(), keyword()) ::
          {:ok, Twelvgaige.Round.Snapshot.t()} | {:error, term()}

  # Phase 3+ daemon API. Without a daemon, detached run attempts return
  # {:error, :daemon_required}.
  @spec run_round(shell_id() | Path.t(), map(), keyword()) ::
          {:ok, round_id()} | {:error, term()}

  @spec await_round(round_id(), timeout()) ::
          {:ok, Twelvgaige.Round.Snapshot.t()} | {:error, term()}

  @spec get_round(round_id()) ::
          {:ok, Twelvgaige.Round.Snapshot.t()} | {:error, :not_found}

  @spec list_rounds(keyword()) :: {:ok, [Twelvgaige.Round.Snapshot.t()]}

  @spec approve_safety(round_id(), shot_id(), keyword()) :: :ok | {:error, term()}
  @spec reject_safety(round_id(), shot_id(), keyword()) :: :ok | {:error, term()}
  @spec cancel_round(round_id(), keyword()) :: :ok | {:error, term()}
  @spec retry_shot(round_id(), shot_id(), keyword()) :: :ok | {:error, term()}

  @spec validate_shell(Path.t(), keyword()) ::
          {:ok, Twelvgaige.Shell.Validation.t()} | {:error, term()}
  @spec load_shells(Path.t(), keyword()) :: {:ok, Twelvgaige.Shell.LoadResult.t()} | {:error, term()}
  @spec list_shells(keyword()) :: {:ok, [map()]}
  @spec list_agents(keyword()) :: {:ok, [map()]}
  @spec list_tools(keyword()) :: {:ok, [map()]}
end
```

The API is intentionally narrow around round advancement. Internal modules can be richer, but no public API may mutate round state except through `Round.Server`.

## 7. Data Model

### 7.1 Workflow Shell

Required workflow shell shape, shown in YAML:

```yaml
kind: workflow
id: k8s_incident_response
name: K8s Incident Response
version: 1.0.0
timeout: 30m

policy:
  on_shot_failure: fail_round
  on_condition_error: fail_round
  on_store_error: block_round
  on_safety_reject: halt_round
  safety_scope: dependency
  resource_profile: laptop
  queue_timeout: null

input_schema:
  type: object
  required: [cluster, namespace]
  properties:
    cluster:
      type: string
    namespace:
      type: string
    alert_details:
      type: object

shots:
  - id: gather_cluster_state
    kind: slug
    agent: k8s_inspector
    description: Collect pod status, events, and recent logs.
    depends_on: []
    condition: true
    timeout: 2m
    tools: [kubectl_get, kubectl_describe, kubectl_logs]
    retry:
      max_attempts: 3
      backoff: exponential
      base_delay: 5s
      max_delay: 30s
      retryable_errors: [llm_timeout, llm_rate_limited, output_parse_error, tool_retryable]
    choke:
      token_budget: 4096
      max_iterations: 6
      tool_safety: read_only
      audit: all
    output_schema:
      type: object
      required: [pods, events, resource_pressure]
      properties:
        pods:
          type: array
        events:
          type: array
        resource_pressure:
          type: boolean
```

Required workflow fields:

- `kind`
- `id`
- `version`
- `shots`

Defaults:

- `timeout`: no round timeout in Phase 1, required before daemon mode
- `depends_on`: `[]`
- `condition`: `true`
- `policy.on_shot_failure`: `fail_round`
- `policy.on_condition_error`: `fail_round`
- `policy.on_store_error`: `block_round`
- `policy.on_safety_reject`: `halt_round`
- `policy.safety_scope`: `dependency`
- `policy.resource_profile`: `laptop`
- `policy.queue_timeout`: `null`
- `retry.max_attempts`: `1`
- `retry.backoff`: `fixed`
- `retry.base_delay`: `0s`
- `retry.max_delay`: same as `base_delay`
- `choke.max_iterations`: `6`
- `choke.tool_safety`: `read_only`
- `choke.audit`: `summary`

### 7.2 Agent Shell

```yaml
kind: agent
id: k8s_inspector
name: Kubernetes Inspector
provider: ollama
model: llama3.2
system_prompt: |
  You inspect Kubernetes infrastructure. Report observed state clearly.

tools:
  allowed: [kubectl_get, kubectl_describe, kubectl_logs]
  denied: [kubectl_delete, kubectl_apply, kubectl_exec]

choke:
  token_budget: 4096
  max_iterations: 6
  timeout: 2m

memory:
  type: none
```

Required agent fields:

- `kind`
- `id`
- `provider`
- `model`
- `system_prompt`

Agent tool allowlists are intersected with shot tool allowlists. The effective tool set is:

```text
effective_tools = shot.tools intersect agent.tools.allowed minus agent.tools.denied
```

If a shot references a tool outside the effective set, compilation fails.

### 7.3 Shell Authoring Formats

YAML, JSON, and TOML are implemented today. A
programmatic shell language is not approved until a separate security-reviewed
RFC proves sandboxing and resource limits.

Format support is defined in [`shell-formats-plan.md`](shell-formats-plan.md).
Programmatic shell gating is defined in
[`programmatic-shell-rfc.md`](programmatic-shell-rfc.md).
The implementation contract is:

```text
source file
  -> format parser
  -> ordinary map with string keys
  -> shell normalization
  -> workflow or agent struct
  -> compiler validation
  -> compiled pattern
```

Requirements:

- Authoring format must not change round, shot, retry, dependency, safety,
  resource, persistence, provider, or tool semantics.
- Every supported format must reuse the same required fields, defaults, shell
  validation, pattern compiler, and error taxonomy.
- The loader owns file-extension dispatch and public error shape.
- Parsers must return ordinary string-key maps and arrays. They must not create
  atoms from untrusted input.
- Directory discovery and daemon shell-cache loading must use the same supported
  extension list. Workflow-relative `agents/` discovery must be disabled for
  untrusted roots unless a privileged caller explicitly allows it; explicit
  agent shell paths remain available.
- Round manifests must record source path, source format, source content hash,
  normalized shell hash, shell ID, shell version, accepted agent source
  metadata, and accepted agent shell hashes.
- Equivalent YAML, JSON, and TOML fixtures must normalize to the same shell map
  before compilation.

Format phases:

- AF1 refactors parsing behind a parser boundary while preserving YAML behavior.
- AF2 adds `.json` workflow and agent shells using RFC 8259 JSON.
- AF3 adds `.toml` workflow and agent shells using TOML 1.0 mapping rules.
- AF4 evaluates Starlark as a gated programmatic shell generator; if sandboxing
  is not strong enough, the phase is rejected rather than weakened.

### 7.4 Core Structs

```elixir
defmodule Twelvgaige.Round.State do
  defstruct [
    :id,
    :shell_id,
    :shell_version,
    :pattern,
    :manifest,
    :policy,
    :status,
    :version,
    :input,
    :shot_states,
    :inflight,
    :awaiting_safety,
    :started_at,
    :completed_at,
    :round_timeout_ref,
    :pending_transition,
    :store_status
  ]
end
```

```elixir
defmodule Twelvgaige.Shot.State do
  defstruct [
    :id,
    :kind,
    :status,
    :attempt,
    :depends_on,
    :condition,
    :started_at,
    :completed_at,
    :output,
    :error,
    :next_retry_at,
    :history
  ]
end
```

```elixir
defmodule Twelvgaige.Round.InflightShot do
  defstruct [
    :shot_id,
    :attempt,
    :pid,
    :ref,
    :timeout_ref,
    :started_at
  ]
end
```

Statuses are atoms internally and strings in JSON:

Round statuses:

- `:queued`
- `:chambered`
- `:firing`
- `:awaiting_safety`
- `:awaiting_reconciliation`
- `:complete`
- `:failed`
- `:halted`
- `:cancelled`
- `:blocked_on_store`

Shot statuses:

- `:pending`
- `:running`
- `:complete`
- `:retrying`
- `:failed`
- `:skipped`
- `:awaiting_safety`
- `:interrupted`
- `:awaiting_reconciliation`
- `:cancelled`

`:ready` is not a persisted or observable shot status. Readiness is a derived property computed from the pattern, dependency states, retry schedule, and condition result.

### 7.5 Normative State Transitions

Round transitions:

| From | To | Cause |
| --- | --- | --- |
| `:queued` | `:chambered` | Active round permit is acquired. |
| `:chambered` | `:firing` | Round initialized and first readiness pass begins. |
| `:firing` | `:awaiting_safety` | A ready safety shot requires approval under current policy. |
| `:awaiting_safety` | `:firing` | Targeted safety shot is approved. |
| `:awaiting_safety` | `:halted` | Targeted safety shot is rejected or times out. |
| `:firing` | `:awaiting_reconciliation` | Interrupted or ambiguous side-effect state requires manual reconciliation. |
| `:firing` | `:failed` | Round timeout or unrecoverable resource queue timeout occurs. |
| `:firing` | `:complete` | Every shot is `:complete` or `:skipped`. |
| `:firing` | `:failed` | Failure policy selects failure and no retry remains. |
| any non-terminal | `:cancelled` | User cancels the round. |
| any non-terminal | `:blocked_on_store` | A required state/audit/event commit fails. |
| `:blocked_on_store` | prior non-terminal status | Pending transition commit succeeds or is already committed. |

Shot transitions:

| From | To | Cause |
| --- | --- | --- |
| `:pending` | `:running` | Shot is ready and an executable attempt starts. |
| `:pending` | `:skipped` | Condition evaluates to false. |
| `:pending` | `:awaiting_safety` | Safety shot is ready and needs approval. |
| `:awaiting_safety` | `:complete` | Safety shot is approved. |
| `:awaiting_safety` | `:failed` | Safety shot is rejected or times out. |
| `:running` | `:complete` | Attempt returns valid output and transition commits. |
| `:running` | `:retrying` | Attempt fails with a retryable error and attempts remain. |
| `:running` | `:failed` | Attempt fails with no retry or non-retryable error. |
| `:running` | `:interrupted` | Recovery finds a shot that was running when the VM died. |
| `:interrupted` | `:retrying` | Recovery policy proves retry is safe. |
| `:interrupted` | `:awaiting_reconciliation` | Recovery cannot prove retry safety. |
| `:retrying` | `:running` | Retry delay expires and a new attempt starts. |
| any non-terminal | `:cancelled` | User cancels the round. |

Terminal round statuses are `:complete`, `:failed`, `:halted`, and `:cancelled`. Terminal shot statuses are `:complete`, `:failed`, `:skipped`, and `:cancelled`.

## 8. Pattern Compilation

`Twelvgaige.Pattern.Compiler.compile/2` is pure. Shell cache and tool catalog data are collected before compilation and passed in through the compile context.

```elixir
@spec compile(Twelvgaige.Shell.Workflow.t(), CompileContext.t()) ::
        {:ok, Twelvgaige.Pattern.t()} | {:error, [CompileError.t()]}
```

Validation rules:

- Workflow ID is non-empty and matches `^[a-zA-Z0-9_-]+$`.
- Version is non-empty.
- Shot list is non-empty.
- Shot IDs are unique and match `^[a-zA-Z0-9_-]+$`.
- Every `depends_on` reference exists.
- The shot graph is acyclic.
- Every non-safety shot references an existing agent.
- Every referenced tool exists.
- Effective tool set is non-empty when the shot needs tools.
- Effective tool set is empty or omitted for safety shots.
- Tool safety levels do not exceed the shot choke.
- Retry values are valid and bounded.
- Timeout values parse to positive milliseconds.
- Conditions parse under the safe condition grammar.
- Input schema and output schemas use the supported Phase 1 schema subset.
- Workflow policy values are known and compatible with the referenced shot/tool safety levels.

The compiler produces:

- Original workflow shell metadata
- Normalized shot definitions
- Adjacency lists
- Reverse dependency lists
- Topological ordering
- Per-shot effective loadout
- Parsed conditions

No LLM calls, tool calls, file writes, or process starts occur during compilation.

## 9. Condition Evaluation

Conditions must be deterministic and side-effect free.

Phase 1 grammar:

```text
condition  := true | false | comparison | condition "and" condition | condition "or" condition | "not" condition
comparison := path op literal
op         := "==" | "!=" | ">" | ">=" | "<" | "<=" | "in" | "exists"
path       := "input." segment* | "shots." shot_id "." segment*
literal    := string | number | boolean | null | list
```

No function calls. No arbitrary Elixir evaluation. No atoms from user input.

Shot IDs and workflow IDs deliberately disallow `.` so dotted condition paths are unambiguous. If future versions need dots in IDs, the condition grammar must first add quoted bracket syntax such as `shots["foo.bar"].field`.

Evaluation context:

```elixir
%{
  "input" => round_input,
  "shots" => %{
    "shot_id" => shot_output
  }
}
```

If a condition references missing data:

- `exists` returns `false`.
- Other operators return `{:error, {:condition_missing_path, path}}`.

Runtime handling:

- Condition `true`: shot can become ready when dependencies are satisfied.
- Condition `false`: shot is marked `:skipped`.
- Condition error: shot fails with `:condition_error`; round policy decides fail or halt.

### 9.1 Phase 1 Schema Subset

Phase 1 must validate input and output data before a shot can advance dependent shots. To avoid depending on full JSON Schema semantics before the engine exists, Phase 1 supports this subset:

- `type`: `object`, `array`, `string`, `number`, `integer`, `boolean`, or `null`
- `required`
- `properties`
- `items`
- `enum`
- `additionalProperties` as a boolean

Unsupported schema keywords must fail shell validation with `:unsupported_schema_keyword`. Later phases may replace the subset validator with a full JSON Schema library, but accepted Phase 1 schemas must keep working.

## 10. Round Execution Flow

### 10.1 Starting A Round In-Process

Phase 1 in-process execution is foreground-only. A Phase 1 CLI invocation must run the round to terminal state, timeout, or inline safety prompt before the OS process exits. Detached `round run` returns `{:error, :daemon_required}` until the Breech daemon exists.

Flow:

1. CLI parses `twelvgaige round run <shell> [--input <json>]`.
2. CLI starts the OTP application if it is not already running.
3. Shell loader loads workflow shell and referenced agent shells.
4. Input JSON is validated against `input_schema`.
5. Compiler returns a pattern.
6. `Twelvgaige.Round.Supervisor.start_round/2` starts a `Round.RunSupervisor`.
7. `Round.Server.init/1` builds `Round.State` with all shots `:pending`.
8. `Round.Server` returns `{:ok, state, {:continue, :chamber}}`.
9. `handle_continue(:chamber, state)` transitions round to `:firing`.
10. `Round.Server` evaluates and fires ready shots.
11. CLI waits on `Twelvgaige.await_round/2` by default in Phase 1.

In Phase 3 and later, daemon-owned rounds may return immediately with a round ID. `show`, `list`, `watch`, `approve`, `reject`, `cancel`, and detached `retry` commands require a daemon unless they are used from an in-process test API.

### 10.2 Firing Ready Shots

`Round.Server` computes ready shots with a pure function:

```elixir
@spec ready_shots(Pattern.t(), %{String.t() => Shot.State.t()}) :: [Shot.Definition.t()]
```

A shot is ready when:

- Its status is `:pending` or due `:retrying`.
- All dependencies are terminal-successful.
- Terminal-successful means `:complete` or `:skipped`.
- Its condition evaluates to `true`.

If the condition evaluates to `false`, the server marks it `:skipped` and immediately re-runs readiness evaluation.

Readiness is necessary but not sufficient for execution. Before starting an executable shot, `Round.Server` must atomically acquire permits from `ResourceLimiter` for the global shot pool and per-round shot pool. If permits are unavailable, the shot stays pending, a waiter is recorded, and the shot is retried on the next resource notification or scheduled readiness pass.

If the shot kind is `safety`, the server does not start a task. It transitions the shot to `:awaiting_safety` and the round to `:awaiting_safety`.

Safety scope is controlled by `policy.safety_scope`:

- `dependency` (default): the safety shot blocks only its dependent descendants. Independent branches that do not depend on the safety shot may continue.
- `round`: the safety shot pauses all new shot firing until the safety shot is approved, rejected, cancelled, or timed out.

Phase 2 may support inline foreground approval for `round run`. Phase 3 adds external approval through daemon IPC.

For executable shots:

1. Build immutable `Shot.Attempt` input:
   - round ID
   - shot ID
   - attempt number
   - effective loadout
   - round input
   - completed dependency outputs
2. Start task using `Task.Supervisor.async_nolink/2`.
3. Store `%InflightShot{}` by task ref and shot ID.
4. Start shot timeout with `Process.send_after/3`.
5. Transition shot to `:running`.
6. Release resource permits when the attempt reaches a terminal attempt result, timeout, crash, cancellation, or retry delay.

If task start fails after permits are acquired, `Round.Server` must release permits before applying the failure transition.

### 10.3 Handling Task Results

Expected task result:

```elixir
{:shot_result, shot_id, attempt, result}
```

Where result is one of:

```elixir
{:ok, %Twelvgaige.Shot.Success{}}
{:error, %Twelvgaige.Error{}}
```

`Round.Server.handle_info({ref, result}, state)` must:

1. Look up the ref in `state.inflight`.
2. Ignore the message if the ref is stale.
3. Confirm shot ID and attempt match.
4. Cancel the timeout ref.
5. `Process.demonitor(ref, [:flush])`.
6. Remove in-flight entry.
7. Apply success or failure transition.
8. Persist transition first in Phase 4 and later using an idempotent transition ID and expected round version.
9. Fire newly ready shots.

`Round.Server.handle_info({:DOWN, ref, :process, pid, reason}, state)` must:

- Ignore if the ref is unknown or already handled.
- Treat `reason == :normal` as a stale normal shutdown if a result was already processed.
- Treat non-normal exits as `:shot_crash`.
- Apply retry policy.

### 10.4 Handling Shot Timeouts

Timeout message:

```elixir
{:shot_timeout, shot_id, attempt, timeout_ref}
```

Handling:

1. Confirm the shot is still in-flight for the same attempt.
2. Terminate the task with `Task.Supervisor.terminate_child/2` or a controlled `Process.exit/2`.
3. Remove in-flight entry.
4. Classify error as `:shot_timeout`.
5. Apply retry policy.
6. Ignore later task results or DOWN messages for that attempt.

### 10.5 Completing A Round

After every transition, `Round.Server` checks terminal state.

Round is `:complete` when:

- No shots are running.
- No shots are retrying.
- No shots are awaiting safety.
- Every shot is `:complete` or `:skipped`.

Round is `:failed` when:

- A shot fails with no retry left and policy is `fail_round`.
- A condition error or schema error is non-retryable.
- A coordinator invariant is violated.

Round is `:halted` when:

- Safety is rejected.
- Policy denies execution and halt policy is selected.

Round is `:cancelled` when:

- User cancels the round.
- The server terminates in-flight shot tasks and marks unfinished shots cancelled.

Completed, failed, halted, and cancelled rounds must remain observable after they become terminal. Do not rely on `Round.Server` exiting normally as the terminal signal. In Phase 1, either keep the terminal `Round.Server` alive for a short retention window or copy a snapshot into an in-memory round history before a reaper terminates the per-round supervisor. In Phase 4, terminal state is durable and a reaper may terminate per-round supervisors after the final transition commits.

## 11. Shot Execution Flow

`Twelvgaige.Shot.Executor.run/1` performs one attempt.

Input:

```elixir
%Twelvgaige.Shot.Attempt{
  round_id: round_id,
  shot_id: shot_id,
  attempt: attempt,
  definition: shot_definition,
  loadout: effective_loadout,
  input: round_input,
  dependency_outputs: map
}
```

Flow:

1. Assemble messages.
2. Call LLM provider.
3. Normalize response.
4. If response contains tool calls, validate and execute them.
5. Append tool results as untrusted tool messages.
6. Repeat until final content or max iterations.
7. Parse final output.
8. Validate output schema.
9. Return success with output, usage, and trace.

Hard limits:

- Attempt timeout is enforced by `Round.Server`.
- LLM call timeout is enforced inside provider call.
- Max ReAct iterations is enforced by executor.
- Token budget is enforced before call and checked after call when provider usage is available.
- Tool output byte limit is enforced by tool executor.
- LLM and tool calls must acquire `ResourceLimiter` permits before they start.
- Prompt/message payloads, tool outputs, and retained traces must be truncated or rejected before they exceed the active runtime profile.

Executor may catch ordinary exceptions and expected provider/parser/tool errors at its boundary and return classified errors. It must not broadly catch exits. Cancellation, timeout termination, linked-port failures, and unexpected exits should terminate the task so `Round.Server` sees the authoritative task failure path.

## 12. LLM Provider Spec

Twelvgaige supports LLM providers through provider adapters. The round engine only sees normalized messages, normalized tool calls, normalized usage, and `%Twelvgaige.Error{}` values.

First-class provider IDs:

- `openai`
- `ollama`

Provider IDs are stable API values. Model names are provider-specific strings and must not be interpreted by the round engine.
Normal tests additionally compile a deterministic provider that is not present
in development or production builds.

Provider behaviour:

```elixir
defmodule Twelvgaige.LLM.Provider do
  @callback provider_id() :: String.t()
  @callback capabilities(config :: map()) :: Twelvgaige.LLM.Capabilities.t()
  @callback complete(model :: String.t(), messages :: [map()], opts :: keyword()) ::
              {:ok, Twelvgaige.LLM.Response.t()} | {:error, Twelvgaige.Error.t()}
end
```

Provider selection comes from the agent shell:

```yaml
kind: agent
id: incident_analyst
provider: openai
model: provider-specific-model-name
system_prompt: |
  Analyze incident context and produce structured output.
```

The provider adapter is selected by `provider`, not by parsing `model`.

### 12.1 Provider Capabilities

Each adapter reports capabilities at startup and when config changes:

```elixir
defmodule Twelvgaige.LLM.Capabilities do
  defstruct [
    :provider,
    :supports_tools,
    :supports_json_schema,
    :supports_streaming,
    :supports_system_messages,
    :supports_token_usage,
    :local_runtime,
    :default_timeout_ms,
    :default_max_concurrent_calls
  ]
end
```

Capability use:

- If a provider does not support native tools, Twelvgaige may use text-based tool-call prompting only when explicitly enabled for that shot.
- If a provider does not support native JSON schema, Twelvgaige still validates final output locally and may add schema instructions to the prompt.
- Streaming is optional and must not be required for correctness.
- Token usage may be unavailable. In that case, Twelvgaige records `usage.estimated: true` if it estimates locally.
- `local_runtime: true` lowers laptop-profile concurrency defaults unless explicitly overridden.
- Provider calls made by shot execution acquire an `:llm_call` permit from
  `Twelvgaige.ResourceLimiter` before invoking the adapter and release it after
  the adapter returns or raises. Saturation returns retryable
  `:resource_queue_timeout`; it does not call the provider.

Normalized response:

```elixir
defmodule Twelvgaige.LLM.Response do
  defstruct [
    :provider,
    :model,
    :content,
    :tool_calls,
    :usage,
    :finish_reason,
    :raw_redacted
  ]
end
```

Normalized message shape:

```elixir
%{
  role: "system" | "user" | "assistant" | "tool",
  content: String.t() | [map()],
  name: String.t() | nil,
  tool_call_id: String.t() | nil,
  source: :system | :human | :round_context | :tool_execution | :safety
}
```

Provider adapters translate normalized messages into provider-native request shapes. Provider-native fields must not leak into `Round.Server`.

Tool call shape:

```elixir
%{
  "id" => "call_123",
  "name" => "kubectl_get",
  "input" => %{"resource" => "pods", "namespace" => "default"}
}
```

Provider errors must be classified:

- `:llm_timeout`
- `:llm_rate_limited`
- `:llm_auth_failed`
- `:llm_bad_request`
- `:llm_provider_unavailable`
- `:llm_context_too_large`
- `:llm_unknown`

Provider adapters must preserve retry hints when available:

```elixir
%Twelvgaige.Error{
  class: :llm_error,
  reason: :llm_rate_limited,
  retryable: true,
  details: %{"retry_after_ms" => 2_000}
}
```

Retry defaults:

- Retryable: timeout, rate-limited, provider unavailable, unknown
- Non-retryable: auth failed, bad request, context too large unless trimming can fix it

### 12.2 Provider Configuration

Provider configuration is loaded from explicit process options, trusted runtime config, environment variables, or future secret backends. Workflow and agent shells must not contain API keys.

Common provider config:

| Field | Meaning |
| --- | --- |
| `provider` | Stable provider ID. |
| `api_key` | Runtime secret value supplied by process options, application config, or environment. Never from shells. |
| `api_key_ref` | Future secret key reference, not the key value. |
| `base_url` | Optional endpoint override. |
| `timeout_ms` | Provider call timeout. |
| `max_concurrent_calls` | Provider-specific concurrency cap. |
| `default_headers` | Redacted, provider-specific headers. |

`base_url`, `default_headers`, proxy settings, and credentials are trusted runtime config only. Workflow shells and agent shells must not set them. Runtime config precedence is explicit process options, then `Application.get_env(:twelvgaige, :llm_providers)`, then environment variables.

Provider-specific defaults:

| Provider | Secret source | Endpoint behavior | Laptop concurrency default |
| --- | --- | --- | ---: |
| `openai` | `TWELVGAIGE_OPENAI_API_KEY`, `OPENAI_API_KEY`, or secret ref | Hosted API, optional base URL override from `TWELVGAIGE_OPENAI_BASE_URL` | 4 |
| `ollama` | none by default | Local HTTP endpoint, default host from `TWELVGAIGE_OLLAMA_BASE_URL`, `OLLAMA_HOST`, or local default | 1 |

Ollama is treated as a local runtime. On the laptop profile, default global Ollama calls are capped at 1 because model inference can consume substantial CPU, RAM, and GPU/VRAM outside the BEAM. Users may raise this in `workstation` or `server` profiles.

### 12.3 Provider Adapter Requirements

OpenAI adapter:

- Maps normalized messages to OpenAI-native chat/responses request shape.
- Normalizes native tool calls to Twelvgaige tool-call shape.
- Normalizes structured-output responses when supported.
- Normalizes usage into input/output/total tokens when available.
- Maps rate limits, auth failures, bad requests, context length errors, provider errors, and timeouts into `%Twelvgaige.Error{}`.

Ollama adapter:

- Talks to the configured local Ollama HTTP endpoint.
- Supports models installed locally and reports model-not-found as non-retryable unless pull-on-demand is explicitly enabled.
- Treats provider unavailability as retryable only if the endpoint is expected to be running.
- Caps laptop concurrency to 1 by default.
- Normalizes usage if available; otherwise records estimated or unknown usage.
- Does not assume tool-call support unless the selected model and endpoint expose compatible behavior.

### 12.4 Provider Router And Rate Limits

`Twelvgaige.LLM.Supervisor` owns provider clients and rate/concurrency state. Shot executors call a provider router:

```elixir
Twelvgaige.LLM.complete(provider, model, messages, opts)
```

The router:

- validates provider ID
- loads provider config without exposing secrets
- checks provider capabilities
- acquires `ResourceLimiter` LLM permits
- applies provider-specific rate/concurrency limits
- dispatches to the adapter
- normalizes response/errors
- releases permits

Provider limits are layered:

1. resource profile limit, e.g. laptop global LLM calls
2. provider concurrency limit, e.g. `openai.max_concurrent_calls`
3. provider rate-limit backoff from retry hints

Provider transport policy:

- Cloud provider URLs must use HTTPS by default, must include a host, and must
  not include userinfo.
- Cloud provider URLs must not target obvious private/loopback hosts unless a
  trusted runtime override explicitly allows it.
- Ollama may use HTTP by default, but only to loopback destinations unless a
  trusted runtime override explicitly allows remote local-model hosts.
- Provider timeouts are clamped to a positive bounded value before transport.
- Fake transports in normal tests receive the same validated request shape that
  live transports will receive.

### 12.5 Provider Testing Contract

Normal tests must not call real providers.

Required provider tests:

- the test-only deterministic provider returns deterministic responses.
- each real adapter serializes normalized messages into expected provider request payloads.
- each real adapter normalizes provider tool calls.
- each real adapter normalizes usage.
- each real adapter maps auth, timeout, rate-limit, bad request, context-too-large, unavailable, and unknown errors.
- Ollama adapter handles endpoint unavailable and model not found.
- provider configs redact secrets in logs and error details.

Network/provider smoke tests are opt-in and must be excluded from normal `mix test`.

## 13. Tool Spec

Tool behaviour:

```elixir
defmodule Twelvgaige.Tool do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback safety_level() :: :read_only | :idempotent_write | :destructive | :irreversible
  @callback idempotency() :: Twelvgaige.Tool.Idempotency.t()
  @callback execute(input :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, Twelvgaige.Error.t()}
end
```

Safety levels form an explicit ordered policy lattice:

```text
read_only < idempotent_write < destructive < irreversible
```

The comparison is implemented by a Twelvgaige policy function, not by atom ordering.

Idempotency metadata:

```elixir
defmodule Twelvgaige.Tool.Idempotency do
  defstruct [
    :class,                    # :read_only | :idempotent | :non_idempotent
    :requires_key?,            # boolean
    :reconciliation_strategy,  # :none | :read_after_write | :external_id | :manual
    :side_effect_phase         # :none | :before_result | :after_result | :unknown
  ]
end
```

Any non-read-only tool must declare idempotency metadata. Boolean `idempotent?()` is intentionally not part of the behaviour because write safety needs more information than true or false.

Execution rules:

1. Tool name must exist in `Tool.Catalog`.
2. Tool name must be in the shot effective tool set.
3. Tool safety level must be allowed by the shot choke according to the safety lattice.
4. Tool input must validate against the input schema.
5. Destructive or irreversible tools require safety approval in a durable phase.
6. Tool execution receives a bounded timeout.
7. Tool result is bounded by bytes and optionally by line count.
8. Tool result is redacted before logging, storage, or LLM reuse.

Initial built-ins:

- `[x]` `http_get`
- `[x]` `http_post`
- `[x]` `git_commit`
- `[x]` `shell_read`
- `[x]` `kubectl_get`
- `[x]` `kubectl_describe`
- `[x]` `kubectl_logs`
- `[x]` `kubectl_events`
- `[x]` `kubectl_apply`
- `[x]` `kubectl_scale`
- `[x]` `kubectl_rollout_restart`
- `[x]` `kubectl_delete`
- `[x]` `kubectl_exec`

Current Phase 2 implementation notes:

- `Twelvgaige.Tool` defines the common behaviour.
- `Twelvgaige.Tool.Catalog` exposes the built-in catalog by stable name.
- `Twelvgaige.Tool.Call` normalizes provider tool-call maps into a stable local shape.
- `Twelvgaige.Tool.Executor` enforces catalog lookup, allowlist, safety threshold, schema validation, `ResourceLimiter` admission when a limiter is available, timeout, crash classification, and generic JSON output byte limits.
- `Twelvgaige.Schema.ValueValidator` validates runtime values against the supported JSON Schema subset with caller-specific error taxonomy.
- `Twelvgaige.Output.Parser` parses final assistant JSON content and rejects malformed or schema-invalid output before a shot completes.
- `Twelvgaige.Tool.InputValidator` validates the supported JSON Schema subset without creating atoms from user input.
- `Twelvgaige.Shot.RetryPolicy` makes pure retry decisions, caps attempts, denies policy/tool-denied retries, and computes fixed, linear, and exponential delays.
- `Twelvgaige.Shot.Executor` runs bounded ReAct iterations. Tool calls execute serially, are checked against the shot's effective tool list and safety choke, and produce untrusted tool-result messages for the next LLM call.
- Foreground safety shots move the round to `:awaiting_safety` when no inline decision is supplied. `--approve-safety`, `:approve_all_safety?`, `:safety_decisions`, or `:safety_handler` can approve in the same VM. Rejection halts by default or fails when `policy.on_safety_reject: fail_round`.
- `shell_read` is structured and read-only. It reads bounded bytes below a configured root, rejects root escapes, rejects symlink paths, and never accepts arbitrary command strings.
- `http_get` is structured and read-only. It enforces scheme, userinfo, redirect, explicit host allowlist, obvious private host/IP, DNS resolution with every resolved IP checked, timeout, and response byte checks.
- `http_post` is structured and destructive. It enforces the same network destination policy as `http_get`, requires `confirm=true`, rejects sensitive headers from LLM input, accepts trusted runtime headers through tool options, bounds request and response bytes, denies redirects, and redacts JSON/text response bodies before returning them.
- `git_commit` is structured and destructive. It requires `confirm=true`, accepts only explicit regular files under a trusted root, rejects root escapes, directories, and symlink paths, constructs fixed `git -C <root> status/add/commit` argv, bounds/redacts output, and never accepts arbitrary Git flags.
- Kubernetes read-only tools use internally constructed `kubectl` argv only. `kubectl_get`, `kubectl_describe`, `kubectl_logs`, and `kubectl_events` enforce context, namespace or trusted cluster-scope policy, global and runtime resource allowlists, optional context/namespace/name/selector runtime policies, timeouts, byte bounds, and redaction. Normal tests use fake command runners and do not require a live cluster.
- `kubectl_apply` is structured and file-based. It is `:idempotent_write`, requires `confirm=true`, requires context and namespace, accepts only YAML/JSON manifest files below a trusted root, rejects root escapes, directories, and symlink paths, constructs fixed `kubectl apply -f` argv, and bounds/redacts output.
- Kubernetes write tools are structured and safety-gated. `kubectl_scale` is `:idempotent_write`; `kubectl_rollout_restart` and `kubectl_delete` are `:destructive`, require `confirm=true`, require explicit namespaced objects, deny cluster-scope writes, construct argv internally, bound and redact output, and rely on durable tool journaling before side effects when executed inside rounds.
- `kubectl_exec` is structured but treated as remote execution. It is `:irreversible`, requires `confirm=true`, requires executor `max_safety: :irreversible`, requires runtime `allow_kubectl_exec: true`, targets a named namespaced pod only, accepts command argv as a list of strings, blocks shell interpreters unless `allow_shell: true` is also supplied by trusted runtime policy, constructs fixed `kubectl exec` argv, and bounds/redacts output.

Deferred built-ins:

- `[!]` arbitrary `shell_exec` is intentionally deferred. Structured tools are the supported execution model.

Shell command rule:

Tools must not accept arbitrary shell strings. They accept structured inputs and construct argv internally.

### 13.1 Kubernetes Tool Support

Kubernetes support starts with structured inspection tools:

- `kubectl_get`
- `kubectl_describe`
- `kubectl_logs`
- `kubectl_events`

The first write tools are intentionally narrow and namespaced:

- `kubectl_apply`
- `kubectl_scale`
- `kubectl_rollout_restart`
- `kubectl_delete`
- `kubectl_exec`

These write tools require the executor allowlist, an appropriate `tool_safety` threshold, bounded output, redaction, and durable intent/result journaling inside rounds. `kubectl_apply` is limited to trusted manifest files; destructive tools also require `confirm=true` in the structured input.

Workflow compilation also enforces a control-plane safety dependency: any shot
that declares a non-read-only tool must directly depend on an unconditional
`kind: safety` shot unless the caller sets the explicit local-development override
`allow_unsafe_tools_without_safety?: true`. This keeps model-generated write
actions behind a deterministic approval point before the round can advance to
the side-effecting shot, and prevents a conditional/skipped approval gate from
unlocking a write path.

`kubectl_exec` is treated as remote execution. It remains disabled by default at runtime even though it is present in the catalog, requires `:irreversible` safety, requires `confirm=true`, and requires trusted runtime policy `allow_kubectl_exec: true`. Shell interpreters such as `sh`, `bash`, `cmd`, `powershell`, and `pwsh` are denied unless trusted runtime policy also sets `allow_shell: true`.

Kubernetes tools call the local `kubectl` binary through structured argv only. They must not accept arbitrary kubectl argument strings.

Tool intent/result audit events include allowlisted target metadata for
Kubernetes tools: context, namespace, resource, name, selector, container,
redacted exec argv when applicable, verb, duration, exit status, output byte
count, and truncation flag. They intentionally omit raw stdout/stderr, raw log
excerpts, kubeconfig contents, bearer tokens, and client certificate material.

#### 13.1.1 Context And Authentication

Kubernetes tools use existing kubeconfig and RBAC. Twelvgaige must not bypass Kubernetes authorization.

Trusted runtime policy should identify the target kubeconfig and context. Tool
input may omit `context` when `kubernetes_context`/`kube_context` is supplied in
runtime tool options. If `require_runtime_context?: true` is set, model-supplied
context values are rejected. If both runtime policy and tool input provide a
context, they must match exactly.

Input identifies the rest of the target:

```json
{
  "namespace": "default",
  "resource": "pods",
  "name": "payments-abc123",
  "selector": "app=payments"
}
```

Rules:

- `context` is optional in tool input when trusted runtime policy supplies it;
  otherwise it is required for backward-compatible local use.
- `namespace` is required by default.
- Cluster-scoped requests require `allow_cluster_scope: true` in the tool input and must also be allowed by shot policy.
- Kubeconfig path defaults to the user's environment. Custom kubeconfig paths require explicit runtime config such as `kubernetes_kubeconfig`/`kubeconfig` and must not come from LLM tool input.
- Context names are passed only as argv values, never interpolated into shell strings. Runtime-owned context is preferred for unattended workflows.
- Trusted runtime policy may further constrain model-supplied targets with
  `allowed_contexts`, `allowed_namespaces`, `allowed_resources`,
  `allowed_name_patterns`, and `allowed_selector_patterns`.
- The tool must audit the effective context and namespace.

#### 13.1.2 Common Kubernetes Input Schema

Common fields:

| Field | Required | Notes |
| --- | --- | --- |
| `context` | runtime preferred | Optional when trusted runtime policy supplies `kubernetes_context`; required otherwise. |
| `namespace` | yes by default | Required unless cluster-scope is explicitly allowed. |
| `resource` | yes except fixed-resource tools | Resource type, e.g. `pods`, `deployments`, `events`; `kubectl_exec` fixes this to `pods`. |
| `name` | no | Specific resource name. |
| `selector` | no | Label selector. |
| `field_selector` | no | Field selector. |
| `container` | no | Logs and exec pod container name. |
| `command` | exec only | Non-empty argv list for `kubectl_exec`; shell strings are not accepted. |
| `confirm` | write/exec only | Required `true` for destructive or irreversible Kubernetes tools. |
| `tail_lines` | logs only default 200 | Hard capped by profile. |
| `since_seconds` | logs only | Bounded recent log window. |
| `limit` | no | Max returned items where supported. |
| `allow_cluster_scope` | no default false | Requires shot policy permission. |

Resource allowlist for Phase 2:

- `pods`
- `deployments`
- `replicasets`
- `statefulsets`
- `daemonsets`
- `services`
- `endpoints`
- `ingress`
- `jobs`
- `cronjobs`
- `configmaps`
- `events`
- `nodes` only when cluster-scope is explicitly allowed
- `namespaces` only when cluster-scope is explicitly allowed

Any resource outside the allowlist fails with `:kubernetes_resource_denied`.

#### 13.1.3 Command Construction

Commands are built as argv arrays. Example:

```elixir
[
  "kubectl",
  "--context", context,
  "-n", namespace,
  "get", resource,
  name,
  "-o", "json"
]
```

Rules:

- No shell interpolation.
- No arbitrary extra args.
- No environment dumps.
- Timeout is required for every call.
- stderr is captured and redacted.
- Exit status is classified.
- JSON output is preferred for `get`.
- `describe` output is treated as unstructured and aggressively bounded.

#### 13.1.4 Tool-Specific Behavior

`kubectl_get`:

- Safety level: `:read_only`
- Uses `kubectl get ... -o json`
- Supports `resource`, optional `name`, `selector`, `field_selector`, `limit`
- Returns structured JSON summary plus selected raw metadata when useful

`kubectl_describe`:

- Safety level: `:read_only`
- Requires `resource` and `name`
- Returns bounded text sections with redaction
- Should not be the default when `kubectl_get` can provide structured data

`kubectl_logs`:

- Safety level: `:read_only`
- Requires pod `name`
- Supports `container`, `tail_lines`, `since_seconds`
- Defaults to `tail_lines: 200`
- Hard caps lines and bytes according to active profile
- Redacts before storage, logging, audit, and LLM insertion
- Returns line count, byte count, truncation flag, and redacted excerpts

`kubectl_events`:

- Safety level: `:read_only`
- Uses events resource with namespace by default
- Supports field selectors and limit
- Returns normalized event objects sorted newest first

`kubectl_apply`:

- Safety level: `:idempotent_write`
- Requires `context`, `namespace`, trusted manifest `path`, and `confirm=true`
- Accepts only regular YAML or JSON files below the configured trusted root
- Rejects root escapes, directories, symlinks, inline manifests, and arbitrary flags

`kubectl_scale`:

- Safety level: `:idempotent_write`
- Requires a named namespaced workload and non-negative `replicas`
- Supports `deployments`, `replicasets`, and `statefulsets`

`kubectl_rollout_restart`:

- Safety level: `:destructive`
- Requires a named namespaced workload and `confirm=true`
- Supports `deployments`, `statefulsets`, and `daemonsets`

`kubectl_delete`:

- Safety level: `:destructive`
- Requires a named namespaced object and `confirm=true`
- Denies cluster-scope deletes and selector deletes

`kubectl_exec`:

- Safety level: `:irreversible`
- Requires a named namespaced pod, non-empty `command` argv list, and `confirm=true`
- Requires executor safety `:irreversible` and runtime `allow_kubectl_exec: true`
- Blocks shell interpreters unless trusted runtime policy also supplies `allow_shell: true`
- Returns redacted command argv metadata plus bounded, redacted stdout excerpt

#### 13.1.5 Output Shape

Kubernetes tools return structured output:

```json
{
  "context": "kind-dev",
  "namespace": "default",
  "verb": "get",
  "resource": "pods",
  "name": null,
  "selector": "app=payments",
  "items": [],
  "summary": {},
  "raw_excerpt": null,
  "truncated": false,
  "duration_ms": 123
}
```

Raw kubectl output must not be the primary output passed to the LLM. If included, it must be a bounded, redacted excerpt.

#### 13.1.6 Kubernetes Audit Fields

Every Kubernetes tool call audit event includes:

- `context`
- `namespace`
- `verb`
- `resource`
- `name`
- `selector`
- `field_selector`
- `container`
- `command` when applicable, redacted before storage
- `safety_level`
- `duration_ms`
- `exit_status`
- `truncated`
- `output_bytes`
- `error_reason`

Audit events must not include kubeconfig contents, bearer tokens, client certificates, raw logs, or unredacted command output.

## 14. Safety Gates

A safety shot is a first-class shot kind:

```yaml
- id: approve_remediation
  kind: safety
  depends_on: [analyze_root_cause]
  condition: "shots.analyze_root_cause.requires_safety == true"
  timeout: 30m
  prompt: "Approve remediation?"
```

When a safety shot is ready:

1. Mark shot `:awaiting_safety`.
2. Mark round `:awaiting_safety`.
3. Emit audit event `safety_requested`.
4. Apply `policy.safety_scope`.
5. Wait for `approve_safety(round_id, safety_shot_id, opts)`, `reject_safety(round_id, safety_shot_id, opts)`, cancel, or timeout.

`dependency` scope blocks only shots that depend on the safety shot. `round` scope blocks all new shot firing. In both modes, already running shots may finish unless cancellation or rejection policy terminates them.

Approval:

- Mark safety shot `:complete`.
- Record actor and reason.
- Mark round `:firing` unless another safety shot is still pending under round-wide scope.
- Continue readiness evaluation.

Rejection:

- Mark safety shot `:failed`.
- Mark round `:halted`.
- Record actor and reason.
- Cancel in-flight tasks if any exist.

Multiple safety gates may exist in one round. Approval and rejection APIs must address a specific safety shot ID. If a CLI call omits `--shot` and exactly one safety shot is awaiting approval, the CLI may infer it; otherwise it must return an ambiguity error.

Timeout:

- Default behavior: halt round with `:safety_timeout`.
- Future behavior may allow default approve or default reject, but default approve must not exist for destructive tools.

## 15. Round, Safety, And Retry Policy

Round policy is explicit shell configuration, not an implied implementation detail.

```yaml
policy:
  on_shot_failure: fail_round       # fail_round | halt_round
  on_condition_error: fail_round    # fail_round | halt_round
  on_store_error: block_round       # block_round | fail_round
  on_safety_reject: halt_round      # halt_round | fail_round
  on_cancel: cancel_round           # cancel_round
  safety_scope: dependency          # dependency | round
  resource_profile: laptop          # laptop | minimal | workstation | server
  queue_timeout: null               # duration or null
```

Policy defaults are conservative:

- Failed executable shots fail the round after retries are exhausted.
- Condition errors fail the round.
- Store errors block the round and prevent further shot firing.
- Safety rejection halts the round.
- Safety scope is dependency-scoped so unrelated branches can continue unless the workflow opts into round-wide pause.
- Resource profile is `laptop`, which prioritizes local machine usability over maximum parallelism.
- Resource queue timeout is disabled by default; round timeout still includes queued time.

### 15.1 Retry Policy

Retry struct:

```elixir
defmodule Twelvgaige.Shot.RetryPolicy do
  defstruct [
    max_attempts: 1,
    backoff: :fixed,
    base_delay_ms: 0,
    max_delay_ms: 0,
    retryable_errors: []
  ]
end
```

Backoff strategies:

- `:fixed`
- `:linear`
- `:exponential`

Jitter:

- Add bounded jitter only after deterministic tests can inject a seeded jitter function.
- Unit tests must be able to disable jitter.

Retry decision input:

- Error classification
- Current attempt
- Max attempts
- Tool safety level
- Whether any tool call may have produced side effects
- Idempotency metadata
- Durable attempt/tool journal state in Phase 4 and later

Rules:

- Never retry after `attempt >= max_attempts`.
- Never retry `:policy_denied`.
- Never retry `:tool_denied`.
- Never retry `:safety_rejected`.
- Retry read-only tool failures if classified retryable.
- Retry output parse/schema failures if attempts remain.
- Retry LLM timeout/rate-limit/unavailable if attempts remain.
- Do not retry destructive or irreversible tool failures unless the tool declares a reconciliation key and retry policy explicitly allows it.
- If side-effect status is ambiguous, move to safety/manual reconciliation once persistence exists.

## 16. Error Taxonomy

All subsystems return `%Twelvgaige.Error{}`.

```elixir
defmodule Twelvgaige.Error do
  defstruct [
    :class,
    :reason,
    :message,
    :retryable,
    :safety_required,
    :details
  ]
end
```

Classes:

- `:compile_error`
- `:input_error`
- `:condition_error`
- `:llm_error`
- `:output_error`
- `:tool_error`
- `:policy_error`
- `:timeout_error`
- `:crash_error`
- `:store_error`
- `:internal_error`

Reasons include:

- `:invalid_shell`
- `:cycle_detected`
- `:missing_dependency`
- `:unsupported_schema_keyword`
- `:unknown_agent`
- `:unknown_tool`
- `:missing_safety_dependency`
- `:yaml_parser_unavailable`
- `:condition_missing_path`
- `:unsupported_condition`
- `:llm_timeout`
- `:llm_rate_limited`
- `:llm_auth_failed`
- `:llm_bad_request`
- `:llm_provider_unavailable`
- `:llm_context_too_large`
- `:llm_unknown`
- `:input_schema_violation`
- `:output_parse_error`
- `:output_schema_violation`
- `:tool_denied`
- `:tool_input_invalid`
- `:tool_timeout`
- `:tool_retryable`
- `:tool_non_retryable`
- `:network_policy_denied`
- `:http_redirect_denied`
- `:http_request_too_large`
- `:http_response_too_large`
- `:kubernetes_resource_denied`
- `:kubernetes_context_denied`
- `:kubernetes_cluster_scope_denied`
- `:safety_rejected`
- `:safety_timeout`
- `:daemon_auth_failed`
- `:daemon_version_mismatch`
- `:policy_denied`
- `:shot_timeout`
- `:resource_queue_timeout`
- `:output_too_large`
- `:shot_crash`
- `:store_unavailable`

## 17. Persistence And Recovery

Persistence starts in Phase 4. The design must not require reworking the round engine.

### 17.1 Store Behaviour

```elixir
defmodule Twelvgaige.Store do
  @callback create_round(Round.Snapshot.t(), Round.Manifest.t(), [Audit.Event.t()]) ::
              :ok | {:error, term()}

  @callback record_attempt_started(Shot.AttemptJournal.t(), [Audit.Event.t()]) ::
              :ok | :already_recorded | {:error, term()}

  @callback record_attempt_finished(Shot.AttemptJournal.t(), [Audit.Event.t()]) ::
              :ok | :already_recorded | {:error, term()}

  @callback record_tool_intent(Tool.IntentJournal.t(), [Audit.Event.t()]) ::
              :ok | :already_recorded | {:error, term()}

  @callback record_tool_result(Tool.IntentJournal.t(), [Audit.Event.t()]) ::
              :ok | :already_recorded | {:error, term()}

  @callback list_attempt_journals(String.t()) :: {:ok, [Shot.AttemptJournal.t()]} | {:error, term()}
  @callback list_tool_journals(String.t()) :: {:ok, [Tool.IntentJournal.t()]} | {:error, term()}
  @callback list_audit_events(String.t(), keyword()) :: {:ok, [Audit.Event.t()]} | {:error, term()}

  @callback commit_transition(
              round_id :: String.t(),
              expected_version :: non_neg_integer(),
              transition_id :: String.t(),
              next_snapshot :: Round.Snapshot.t(),
              events :: [Round.Event.t()],
              audit_events :: [Audit.Event.t()]
            ) ::
              :ok
              | :already_committed
              | {:error, :version_conflict}
              | {:error, term()}

  @callback get_round(String.t()) :: {:ok, Round.Snapshot.t()} | {:error, :not_found}
  @callback get_manifest(String.t()) :: {:ok, Round.Manifest.t()} | {:error, :not_found}
  @callback list_shot_runs(String.t()) :: {:ok, [Round.ShotRun.t()]} | {:error, term()}
  @callback list_round_events(String.t(), keyword()) :: {:ok, [Round.Event.t()]} | {:error, term()}
  @callback await_round_events(String.t(), keyword()) :: {:ok, [Round.Event.t()]} | {:error, term()}
  @callback list_incomplete_rounds() :: {:ok, [Round.Snapshot.t()]} | {:error, term()}
end
```

Phase 1 uses `Twelvgaige.Store.Memory`, an app-level in-VM store. It supports process crash recovery inside one VM but is lost when the CLI process exits.

Phase 4 starts with `Twelvgaige.Store.File`, an atomic file-backed implementation of the store behaviour, to prove durable transition and recovery semantics without adding database migration risk at the same time. `Twelvgaige.Store.SQLite` is now the SQL-backed local store path. It uses Ecto/SQLite migrations, stores queryable identities, statuses, timestamps, and error reason columns in relational tables, and stores snapshots, manifests, events, and journals as external-term blobs so the existing recovery contract remains intact while the schema evolves.

`Twelvgaige.Application` starts the configured store child before Breech. Store config comes from explicit options, `:twelvgaige, :store` application config, `TWELVGAIGE_STORE_SQLITE`, or `TWELVGAIGE_STORE_FILE`, in that order. `Twelvgaige.Breech` must not call a concrete store directly. It selects a store module from startup options or resolved store config and uses the store behaviour for round creation, inspection, cancellation, safety resume, event replay, and terminal transition commits. This lets the daemon run against `Store.Memory` for fast tests, `Store.File` for bootstrap durability tests, and `Store.SQLite` for the target laptop-local durable path.

The store persists a durable projection, not the live `Round.State` struct. `Round.State` may contain pids, monitor refs, timeout refs, queued waiter refs, open ports, pending transition data, and other BEAM-only runtime fields. Those values must never be serialized.

`Round.Snapshot` contains only recovery-safe data:

- round ID, shell ID, shell version, status, version, timestamps, and redacted input
- shot snapshots with status, attempt number, retry schedule, output, and error
- awaiting-safety records with safety shot ID, requested actor, reason, and timeout deadline
- effective policy/profile identifiers needed to resume under the original run settings
- store status and error summaries that are safe to expose

`Round.Server` reconstructs live runtime state from `Round.Snapshot` plus `Round.Manifest`. Runtime fields such as `:inflight`, task pids, monitor refs, timeout refs, resource permits, and process-local pending transitions are rebuilt or discarded.

### 17.2 Durable Tables

- `round_runs`
- `round_manifests`
- `shot_runs`
- `shot_attempts`
- `tool_calls`
- `round_events`
- `audit_events`
- `workflow_shells`
- `agent_shells`

Minimum fields:

`round_runs`:

- `id`
- `shell_id`
- `shell_version`
- `status`
- `version`
- `input_redacted`
- `started_at`
- `completed_at`
- `error`
- `inserted_at`
- `updated_at`

`round_manifests`:

- `id`
- `round_run_id`
- `workflow_shell_snapshot_redacted`
- `workflow_shell_hash`
- `agent_shell_snapshots_redacted`
- `agent_shell_hashes`
- `compiled_pattern`
- `compiled_pattern_version`
- `normalized_shot_definitions`
- `effective_loadouts`
- `condition_asts`
- `input_schema_hash`
- `output_schema_hashes`
- `tool_policy_snapshot`
- `effective_resource_profile`
- `created_at`

`shot_runs`:

- `id`
- `round_run_id`
- `shot_id`
- `kind`
- `status`
- `attempt`
- `output_structured_redacted`
- `output_schema_hash`
- `error`
- `started_at`
- `completed_at`
- `inserted_at`
- `updated_at`

`shot_attempts`:

- `id`
- `round_run_id`
- `shot_id`
- `attempt`
- `status` (`started`, `completed`, `failed`, `interrupted`, `reconcile_required`)
- `safety_level`
- `idempotency_metadata`
- `started_transition_id`
- `completed_transition_id`
- `started_at`
- `completed_at`
- `error`

`tool_calls`:

- `id`
- `round_run_id`
- `shot_id`
- `attempt_id`
- `tool_name`
- `status` (`intent_recorded`, `started`, `observed_result`, `committed`, `failed`, `reconcile_required`)
- `safety_level`
- `idempotency_key`
- `reconciliation_strategy`
- `input_redacted`
- `output_structured_redacted`
- `started_at`
- `completed_at`
- `error`

`round_events`:

- `id`
- `round_run_id`
- `seq`
- `transition_id`
- `round_version`
- `event_type`
- `shot_id`
- `payload_redacted`
- `occurred_at`

`audit_events`:

- `id`
- `round_run_id`
- `shot_id`
- `event_type`
- `actor`
- `payload_redacted`
- `occurred_at`

Required durable constraints:

- `round_runs.id` unique primary key.
- `round_runs.version` is updated only by `commit_transition/6`.
- `round_manifests.round_run_id` unique.
- `shot_runs` unique on `{round_run_id, shot_id}`.
- `shot_attempts` unique on `{round_run_id, shot_id, attempt}`.
- `tool_calls` unique on deterministic tool call ID, and on idempotency key when one is supplied.
- `round_events` unique on `{round_run_id, seq}` and on `{round_run_id, transition_id, event_type, shot_id}` where practical.
- `audit_events` are append-only. Updates are not allowed except migration repair tooling.
- All child tables use foreign keys to `round_runs`.

### 17.3 Transition Commit Rule

For Phase 4 and later:

1. `Round.Server` computes `{next_state, round_events, audit_events}` and derives `next_snapshot`.
2. `Round.Server` assigns a unique `transition_id` and uses the current `state.version` as `expected_version`.
3. `Store.commit_transition(round_id, expected_version, transition_id, next_snapshot, round_events, audit_events)` runs in one database transaction where practical.
4. If commit returns `:ok` or `:already_committed`, `Round.Server` replaces memory state, increments the version if needed, and may fire dependent shots.
5. If commit returns `{:error, :version_conflict}`, `Round.Server` reloads durable state and reconciles.
6. If commit returns another error, `Round.Server` enters `:blocked_on_store`, keeps the pending transition in memory, schedules commit retry with the same `transition_id`, and fires no new shots.

This prevents dependent side effects from running on uncommitted prior state.

Before any non-read-only tool attempt, the store must durably record attempt start and tool intent, including idempotency key or reconciliation strategy. Current Phase 4 code records attempt start before shot execution, attempt completion/failure after shot execution, tool intent before tool execution, and tool observed result/failure after tool execution whenever a store is configured. If a pre-execution journal write fails, execution stops before the attempt/tool side effect runs. If a post-execution result write fails, execution returns a store error so dependent work cannot proceed on an unjournaled side effect. If a crash happens after tool execution but before the result transition commits, recovery must default to `:awaiting_reconciliation` unless the durable attempt/tool journal proves retry safety.

Attempt and tool journal IDs are deterministic. Attempt identity is `{round_id, shot_id, attempt}`. Tool-call identity is `{round_id, shot_id, attempt, provider_tool_call_id || generated_tool_call_index}`. Repeating `record_attempt_started/2` or `record_tool_intent/2` with identical data returns `:already_recorded`; repeating with conflicting data returns a structured conflict error.

### 17.4 Recovery Algorithm

At daemon startup:

1. Start store, process registry, shell cache, and tool catalog.
2. Load incomplete rounds.
3. For each round, start `Round.RunSupervisor` with recovery mode.
4. `Round.Server.init/1` reconstructs state from durable state plus the immutable round manifest.
5. Reconcile every shot:
   - `:complete` remains complete.
   - `:skipped` remains skipped.
   - `:awaiting_safety` remains awaiting safety.
   - `:running` becomes `:interrupted`.
   - `:retrying` remains retrying if retry time is in the future.
6. Interrupted shots are handled by policy:
   - read-only or no-tool shots may retry if attempts remain.
   - idempotent write shots may retry only with idempotency metadata.
   - destructive, irreversible, missing journal, or ambiguous shots become `:awaiting_reconciliation`.
7. Resume readiness evaluation.

No recovery path re-monitors old pids.

Recovery must use the stored manifest, not current shell files, current agent files, or current tool policy defaults. Completed shot outputs used by conditions or dependent shots must be stored as redacted-but-structured data, not only as human audit text.

Current Phase 4 bootstrap behavior with `Store.File`, `Store.SQLite`, and the synchronous Breech runner:

- Breech refuses to start when the configured store process is unavailable.
- `:queued`, version-zero rounds with only pending shots are restarted from their stored manifest and input.
- `:awaiting_safety` rounds remain paused and can resume after external approval.
- Interrupted no-tool shots, read-only tool shots, and idempotent-write tool shots with an idempotency key are committed as `:retrying` and resumed from the stored snapshot.
- Completed dependency outputs are preserved during partial resume and are not rerun.
- Non-idempotent, destructive, irreversible, missing-key, missing-metadata, or otherwise ambiguous interrupted shots move to `:awaiting_reconciliation` instead of silently replaying work.
- Recovery loads attempt/tool journal records for each incomplete round and stores a journal summary on the reconciliation error. This summary includes attempt count, tool journal count, observed tool results, failed tool results, write-intent count, affected shots, and per-shot recovery decisions.

### 17.5 SQLite Storage Contract

The in-memory store is the runtime default. SQLite is the recommended durable
store for local and laptop deployments; select it explicitly with
`TWELVGAIGE_STORE_SQLITE=/absolute/path/to/twelvgaige.sqlite3` or trusted
application configuration. It is a single-node correctness boundary, not a
distributed lock manager. Twelvgaige does not invent a default SQLite path for
the ordinary round store.

Directory creation must use owner-only permissions where the operating system supports them. The daemon must refuse to start if the database file or parent directory is obviously world-writable on a platform where that can be checked.

Startup rules:

1. Open the database before accepting daemon IPC or HTTP commands.
2. Run migrations before starting round recovery.
3. Fail fast on migration failure or unsupported schema version.
4. Enable `PRAGMA foreign_keys = ON`.
5. Use WAL mode for daemon operation.
6. Configure a bounded busy timeout; default `5_000ms`.
7. Keep SQLite write concurrency conservative. The default local store uses one writer connection; reads may use separate connections only if the adapter proves stable under tests.
8. Every transition commit, event append, and audit append for one transition happens in one transaction.

Store unavailable behavior:

- If the store cannot open at daemon start, the daemon does not accept work.
- If the store fails during a transition, the round enters `:blocked_on_store`.
- While blocked on store, no dependent shots fire and no non-read-only tool starts.
- The pending transition is retried in memory with the same `transition_id`.
- If the process dies while blocked, recovery uses the last committed snapshot and reconciles interrupted work. It does not assume the pending transition succeeded.

Retention:

- Default retained-byte watermark follows the active runtime profile.
- Target age/export retention policy: 30 days or 1 GiB database soft limit, whichever comes first, once audit export gates are implemented.
- Default full debug trace retention: disabled unless explicitly enabled.
- Redacted structured outputs needed for dependency conditions are retained at least as long as the round record.
- Cleanup deletes oldest terminal rounds under byte pressure while preserving incomplete rounds and the newest terminal round.
- Final cleanup policy must delete terminal rounds only after their audit/export policy allows deletion.
- Cleanup uses bounded batches so it does not monopolize SQLite.
- `VACUUM` is manual or scheduled only when no rounds are active.

Backup and corruption handling:

- The CLI exposes `twelvgaige store backup <path>` for durable SQLite stores.
- SQLite backup uses `VACUUM INTO` through the live store process. Plaintext SQLite
  backup requires `--allow-plaintext-export`. Encrypted SQLite uses the same API
  once SQLCipher is linked and remains encrypted under the open database key.
- Offline restore copies a backup into a private destination and refuses overwrite
  unless replacement is explicit through `twelvgaige store restore <source>
  <destination> --replace`.
- Plaintext SQLite to SQLCipher migration is an offline command:
  `twelvgaige store migrate-sqlcipher --source <plain.db> --destination
  <encrypted.db> --key-env <env>`. It requires all three arguments, leaves the
  source unchanged, refuses overwrite unless `--replace` is supplied, and fails
  before creating the destination if the loaded SQLite driver is not
  SQLCipher-backed.
- DEK envelope rewrap is an offline command:
  `twelvgaige store rewrap-envelope <envelope.json> --backup <backup.json>
  --old-key-env <env> --new-key-env <env>`. It requires a pre-rotation backup,
  writes envelope files atomically, and rotates only the wrapped DEK envelope.
  It does not rekey SQLCipher database pages.
- SQLCipher package verification is opt-in through
  `make sqlcipher-escript-smoke-system` and
  `make burrito-sqlcipher-smoke-system`. These targets rebuild `exqlite` against
  system SQLCipher, then exercise plaintext store creation, plaintext backup,
  plaintext-to-encrypted migration, encrypted open, encrypted backup, restore,
  and restored encrypted open.
- On database corruption, the daemon starts in read-only diagnostic mode if possible and refuses new rounds.

### 17.6 Durable Event Stream Contract

`round_events` is the source of truth for `round watch`, daemon event replay, and API event streams. Telemetry is not a watch source.

Each event has a per-round monotonically increasing `seq`. `seq` is assigned by the store transaction that commits the transition. Events from one transition are contiguous and share the same `transition_id` and `round_version`.

Read API:

```elixir
list_round_events(round_id, after_seq: non_neg_integer(), limit: pos_integer())
await_round_events(round_id,
  after_seq: non_neg_integer(),
  limit: pos_integer(),
  timeout_ms: non_neg_integer()
)
```

Rules:

- Default limit: 100 events.
- Maximum limit: 1,000 events.
- Ordering is ascending by `seq`.
- `after_seq: 0` starts from the beginning.
- Unknown or compacted cursors return a structured error with the oldest available `seq`.
- Terminal events are retained with the round record.
- Optional debug events may be compacted before state-transition events.

Slow consumers:

- A watch client receives historical events first, then live events through bounded waits or a future push stream.
- `Twelvgaige.Round.Watch.stream/3` is the CLI streaming contract. It delivers sorted, non-empty event batches to a caller callback, advances the cursor after each accepted batch, and returns a compact summary instead of accumulating all events in memory.
- `Twelvgaige.CLI.Main.main/1` uses `Watch.stream/3` for real `round watch` invocations so `--follow` and `--until-terminal` can write batches as they arrive. `Twelvgaige.CLI.Main.run/1` may still use collection semantics for tests and programmatic callers that need one returned string.
- Pre-durable local watch may use bounded long-poll against `Store.Memory`; durable watch should use the same cursor semantics over SQLite/Postgres events.
- If a client falls behind the server buffer, it must reconnect with its last seen `seq`.
- The server must not hold unbounded per-client buffers.
- Backpressure from watch clients must not block `Round.Server` transition commits.

## 18. Failure Mode Matrix

| Failure | Detection | State transition | Retry | Notes |
| --- | --- | --- | --- | --- |
| LLM timeout | Provider returns `:llm_timeout` or call timeout | shot failed attempt | yes if attempts remain | Backoff applies. |
| LLM auth failure | Provider classification | shot failed | no | Misconfiguration. |
| LLM rate limit | Provider classification | shot retrying | yes | Backoff should respect provider hints later. |
| Provider transport policy denied | Provider router config validation | shot failed | no | Base URL/proxy/auth came from untrusted or invalid config. |
| Output parse error | Output parser | shot failed attempt | yes if attempts remain | Retry with corrective prompt later. |
| Output schema violation | Schema validator | shot failed attempt | yes if attempts remain | Store violations in error details. |
| Tool denied | Tool executor policy | round halted or failed | no | Indicates shell/agent mismatch or injection attempt. |
| Tool input invalid | Tool input schema | shot failed attempt | yes if LLM-generated | Retry with feedback later. |
| Read-only tool timeout | Tool executor | shot retrying | yes | Safe to retry. |
| HTTP tool network denied | HTTP tool policy | shot failed attempt | no by default | SSRF or destination policy denial. |
| Destructive tool timeout | Tool executor | awaiting safety/manual reconciliation | no by default | Side effect may have happened. |
| Shot task crash | Task DOWN | shot failed attempt | depends | Safe only before side effects or for read-only/idempotent work. |
| Shot timeout | Round timer | shot failed attempt | depends | Kills task and applies retry policy. |
| Resource queue timeout | Resource waiter deadline | shot failed attempt or round failed | depends | Shot timeout has not started; round timeout still applies. |
| Resource limiter crash | Supervisor restart | queued/running work rechecks permits | n/a | Round state remains source of truth; permits are reconstructed conservatively. |
| Round server crash | Supervisor restart | recovery or restart | policy | `:one_for_all` kills in-flight shots. |
| Shot supervisor crash | Supervisor restart | recovery or restart | policy | Round server restarts because refs are invalid. |
| Store commit failure | Store error | round `:blocked_on_store` | retry commit with same transition ID | No dependent shots fire. |
| Telemetry failure | ignored/logged | no state change | n/a | Telemetry is best-effort. |
| Phase 1 CLI disconnect | OS process exits | round process exits | n/a | Phase 1 is foreground-only; detached rounds require daemon. |
| Daemon CLI disconnect | IPC close | no state change | n/a | Does not cancel round unless command was cancel. |
| Daemon auth failure | IPC/HTTP auth layer | no state change | n/a | Return structured auth error and redact credentials. |
| Daemon version mismatch | IPC/HTTP handshake | no state change | n/a | CLI reports required and actual protocol versions. |
| Safety timeout | round timer | round halted | no | Default reject/halt. |
| User cancel | API/CLI command | round cancelled | no | In-flight tasks terminated. |

## 19. CLI Spec

Phase 1 foreground command set:

```bash
twelvgaige --help
twelvgaige shell validate <path>
twelvgaige shell normalize <path> [--format json|yaml|toml]
twelvgaige shell convert <path> --to json|yaml|toml [--output <path>]
twelvgaige shell reload [path ...] [--format human|json]
twelvgaige shell list [--kind workflow|agent|all] [--format human|json]
twelvgaige shell show <shell-id> [--kind workflow|agent] [--format human|json]
twelvgaige round run <workflow-shell-path> [--input <json-or-path>] [--profile laptop|minimal|workstation] [--format human|json]
```

Phase 1 `round run` waits by default and exits only after terminal state, timeout, or inline safety prompt handling. A detached run without a daemon must return exit code `5` with `daemon_required`.

Phase 3 command set:

```bash
twelvgaige round run <workflow-shell-or-id> [--input <json-or-path>] [--detach] [--profile laptop|minimal|workstation|server] [--format human|json]
twelvgaige round show <round-id> [--format human|json]
twelvgaige round list [--format human|json]
twelvgaige round watch <round-id> [--format human|ndjson] [--after-seq <seq>] [--limit <count>] [--follow] [--until-terminal] [--timeout-ms <ms>]
twelvgaige round approve <round-id> --shot <safety-shot-id> [--reason <text>]
twelvgaige round reject <round-id> --shot <safety-shot-id> --reason <text>
twelvgaige round cancel <round-id>
twelvgaige round retry <round-id> --shot <shot-id>
```

For `approve` and `reject`, `--shot` may be omitted only when exactly one safety shot is awaiting approval.

Phase 2 support commands:

```bash
twelvgaige agent list
twelvgaige agent show <agent-id>
twelvgaige agent dry-run <agent-id> --input <json-or-path>
twelvgaige tool list
twelvgaige tool show <tool-name>
twelvgaige tool test <tool-name> --input <json-or-path>
```

Input parsing:

- Omitted `--input` defaults to `{}`.
- `--input '{"key":"value"}'` accepts inline JSON.
- `--input path.json` reads JSON from file.
- `--input -` reads JSON from stdin.

Shell document commands:

- `shell normalize` loads any supported declarative shell and emits a full
  canonical shell document. Default format is JSON.
- `shell convert` writes or prints a canonical shell document in JSON, YAML, or
  TOML. The output must validate immediately through `shell validate`.
- Conversion is syntax conversion only. It must not alter workflow semantics,
  shell IDs, agent IDs, shots, chokes, safety policy, or tool policy.

Resource profile selection:

- CLI `--profile` overrides the workflow default for that run.
- Environment variable `TWELVGAIGE_PROFILE` supplies a process default.
- Environment variable `TWELVGAIGE_MAX_PROFILE` may clamp a process to a lower maximum.
- If neither is set, the profile is `laptop`.
- A workflow may request a higher profile, but the local runtime may clamp it lower.

Exit codes:

- `0`: success, including accepted detached submissions and accepted async control commands
- `1`: round failed for a non-specialized execution error, or a foreground round is paused awaiting safety
- `2`: round halted by safety rejection
- `3`: timeout (`llm_timeout`, `tool_timeout`, `safety_timeout`, `shot_timeout`, or `resource_queue_timeout`)
- `4`: invalid input, invalid shell, invalid option, invalid IPC address, or condition/compile error
- `5`: daemon unavailable, daemon required, daemon authentication failed, or daemon API version mismatch
- `6`: round not found, missing shell file, unknown agent, unknown tool, or referenced definition not found
- `7`: policy denied, including tool, network, HTTP redirect, and Kubernetes policy denials
- `8`: internal, crash, store, malformed IPC response, or otherwise unclassified control-plane error

`Twelvgaige.CLI.ExitCode` is the authoritative implementation of this mapping. CLI commands must not infer process codes from formatted text.

### 19.1 Shell And Agent Discovery

Phase 1 requires explicit workflow shell paths. Referenced agent shells are discovered in this order:

1. Paths passed with repeated `--agent-shell <path>` flags.
2. `agents/` next to the workflow shell.
3. `priv/examples/agents/` for examples and tests.
4. Configured daemon shell-cache paths from `:twelvgaige, :shell_paths`.

Duplicate workflow or agent IDs discovered for one run or one cache load are compile errors unless the loaded definitions are identical. A workflow shell ID without a file path is daemon-only and is resolved through `Twelvgaige.Shell.Cache`.

Supported declarative shell extensions are `.yaml`, `.yml`, `.json`, and
`.toml`. All supported formats feed the same loader, shell structs, and compiler.

### 19.2 CLI JSON Contracts

All JSON output uses string statuses and stable top-level keys.

Round snapshot:

```json
{
  "id": "round_123",
  "shell_id": "k8s_incident_response",
  "shell_version": "1.0.0",
  "status": "firing",
  "started_at": "2026-05-01T12:00:00Z",
  "completed_at": null,
  "error": null,
  "shots": []
}
```

Shot snapshot:

```json
{
  "id": "gather_cluster_state",
  "kind": "slug",
  "status": "complete",
  "attempt": 1,
  "started_at": "2026-05-01T12:00:01Z",
  "completed_at": "2026-05-01T12:00:10Z",
  "error": null,
  "output": {}
}
```

Error shape:

```json
{
  "error": {
    "class": "tool_error",
    "reason": "tool_denied",
    "message": "tool is not allowed for this shot",
    "retryable": false,
    "safety_required": false,
    "details": {}
  }
}
```

Event stream items:

```json
{
  "id": "evt_123",
  "round_id": "round_123",
  "seq": 42,
  "transition_id": "tr_123",
  "type": "shot_completed",
  "shot_id": "gather_cluster_state",
  "occurred_at": "2026-05-01T12:00:10Z",
  "payload": {}
}
```

## 20. Breech Networking Spec

Breech is the local daemon control plane. It is introduced in Phase 3 after foreground execution is correct. Its default networking stance is local-only.

### 20.1 Daemon Lifecycle And Discovery

There is one active Breech daemon per user data directory and resource profile. The daemon owns:

- the process registry
- shell cache
- resource limiter
- provider clients
- store connection
- IPC listener
- optional local HTTP listener

Daemon startup order:

1. Acquire daemon singleton lock.
2. Open store and run migrations if persistence exists.
3. Start registries, shell cache, tool catalog, and resource limiter.
4. Recover incomplete rounds if persistence exists.
5. Start IPC listener.
6. Start optional HTTP listener.
7. Mark daemon healthy.

Phase 3 provides foreground lifecycle commands:

- `twelvgaige daemon serve` starts the local daemon listener in the current OS process and is intended for development, process managers, and future packaging.
- `twelvgaige daemon stop` requests shutdown through the discovered IPC endpoint.
- `twelvgaige daemon paths` prints the platform default runtime directory, endpoint file, lock path, socket path, and Windows named-pipe candidate.

The CLI discovers Breech from environment and platform defaults:

- `TWELVGAIGE_BREECH_ADDR` overrides discovery.
- `TWELVGAIGE_BREECH_ENDPOINT` may point to an explicit endpoint JSON file.
- macOS/Linux default runtime directory: `$XDG_RUNTIME_DIR/twelvgaige` or `~/.twelvgaige/run`.
- Windows default IPC transport: authenticated loopback TCP with endpoint-file discovery. This keeps standard Windows laptops usable until native named-pipe listener I/O can be verified on Windows.
- Windows named-pipe candidate: `twelvgaige daemon paths` still reports the per-user named-pipe path, and the implementation supports named-pipe endpoint encoding, discovery, CLI `--transport npipe`, `TWELVGAIGE_BREECH_ADDR=npipe:...`, client-side injected pipe transport tests, and server-side injected pipe listener tests that exercise the same Breech command dispatcher. A native Windows named-pipe listener remains pending until it can be verified on Windows.
- A daemon version mismatch returns a structured `daemon_version_mismatch` error.

Stale IPC endpoints are cleaned up only after the daemon lock proves no live owner exists. The lock is an atomic per-runtime-directory owner lock with an owner metadata file. The CLI must not delete a socket or pipe just because connect failed once.
Unix socket and loopback TCP fallback listeners write endpoint JSON with owner-only file permissions where supported and remove it when the listener stops.

### 20.2 Local IPC

macOS/Linux use a Unix domain socket by default:

```text
$XDG_RUNTIME_DIR/twelvgaige/breech.sock
```

If `$XDG_RUNTIME_DIR` is missing, use a user-owned directory under `~/.twelvgaige/run`. The socket directory must be owner-only. The implementation must account for Unix socket path length limits; if the default path is too long, it must fail with a clear error and suggested override.

Windows uses authenticated loopback TCP by default until native named-pipe listener I/O is verified on Windows. The endpoint file stores the loopback address plus a generated per-user bearer token with owner-only permissions where supported.

Windows named-pipe verification uses the candidate path:

```text
\\.\pipe\twelvgaige-<user-hash>-breech
```

Named-pipe endpoint strings use the URI form:

```text
npipe:////./pipe/twelvgaige-<user-hash>-breech
```

IPC protocol:

- request/response envelope is length-prefixed JSON unless a later binary protocol is justified
- every request includes `request_id`, `api_version`, `command`, and `body`
- every response includes `request_id`, `ok`, `body` or `error`
- streaming commands send newline-delimited event objects after the initial accepted response
- streaming event objects include round ID, event `seq`, transition ID, event type, timestamp, and redacted payload
- heartbeat interval for idle streams: 15 seconds

Local IPC authentication:

- Unix socket trust relies on filesystem permissions and daemon lock ownership.
- Windows named pipe trust relies on per-user ACLs where available.
- Loopback TCP fallback always requires bearer token auth.

### 20.3 HTTP API

HTTP is an integration surface, not the primary local CLI path. It starts in Phase 5 unless a narrow earlier need appears.

Default listener:

- bind address: `127.0.0.1`
- port: dynamically assigned or configured
- remote bind: disabled unless explicitly configured
- TLS: not required for loopback, required by reverse proxy or mTLS for remote access
- CORS: disabled by default
- cookie auth: unsupported by default; use bearer tokens to avoid CSRF ambiguity

Current listener implementation:

- `Twelvgaige.API.Server` is a supervised dependency-free HTTP/1.1 adapter
  around `Twelvgaige.API.Router`.
- It supports fixed `Content-Length` requests and closes each connection after
  one response. Chunked request bodies are rejected until streaming semantics
  are implemented.
- It starts only when `:http_listener` application config is supplied.
- Loopback bind is allowed by default, but mutating control-plane routes still
  require bearer auth. Non-loopback bind requires `allow_remote?: true`, a
  configured bearer token, and explicit `behind_tls_proxy?: true` deployment
  mode with configured `trusted_proxy_cidrs`. Native TLS/mTLS is not implemented
  in the current `:gen_tcp` listener; non-loopback `tls_options` are rejected
  until a real TLS listener exists.
- Forwarded identity headers are rejected unless `behind_tls_proxy?: true` is
  set and the socket peer is inside `trusted_proxy_cidrs`.

Authentication:

- mutating loopback HTTP control routes require bearer token auth.
- any non-loopback HTTP listener requires bearer token auth plus an explicitly
  configured trusted TLS/mTLS proxy and trusted proxy CIDR until native TLS/mTLS
  support lands.
- tokens are loaded from secret sources or generated into the user data directory with owner-only permissions.
- auth failures are logged without token values.
- The Phase 5 pure router accepts configured bearer tokens only through the
  `Authorization: Bearer <token>` header. Missing or invalid tokens return
  `401` with `WWW-Authenticate`; `access_token` query parameters are rejected
  with `400 invalid_request`.

Request limits:

- default max request body: 4 MiB
- default max header size: 16 KiB
- request read timeout: 15 seconds
- handler timeout for non-streaming control requests: 30 seconds
- idle connection timeout: bounded and configurable

Rate-limit response contract:

- A concrete listener or upstream limiter supplies rate-limit decisions to the
  pure router.
- Non-saturated responses may include `RateLimit-Limit`,
  `RateLimit-Remaining`, `RateLimit-Reset`, and `RateLimit-Policy`.
- Saturated responses return `429 application/problem+json` with
  `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`, and
  `Retry-After`.

Endpoint shape:

```text
GET    /api/v1/openapi.json
POST   /api/v1/rounds
GET    /api/v1/rounds
GET    /api/v1/rounds/:id
DELETE /api/v1/rounds/:id
POST   /api/v1/rounds/:id/safety/:shot_id/approve
POST   /api/v1/rounds/:id/safety/:shot_id/reject
POST   /api/v1/webhooks/:webhook_id
GET    /api/v1/rounds/:id/events?after_seq=<seq>&format=<format>&follow=<bool>&until_terminal=<bool>
GET    /api/v1/audit/:round_id
GET    /api/v1/health
GET    /api/v1/metrics
```

The Phase 5 pure router serves an OpenAPI 3.1 document at
`GET /api/v1/openapi.json`. The contract describes implemented endpoints only;
future retry, webhook, auth, and listener endpoints must update the document in
the same change that introduces the route.

Idempotency:

- `POST /api/v1/rounds` accepts an optional `Idempotency-Key`.
- approve, reject, cancel, and retry endpoints are idempotent by target state where practical.
- duplicate approvals with the same decision return success; conflicting decisions return conflict.

Metrics and health:

- `/health` must not expose secrets or raw config.
- `/metrics` is disabled or local-only by default.
- remote `/metrics` requires auth because labels can reveal operational information.

### 20.4 Event Streams

HTTP event streams use SSE or NDJSON. WebSockets are out of scope until there is a concrete bidirectional requirement.

`GET /api/v1/rounds/:id/events?after_seq=<seq>` reads from the durable event stream once persistence exists. Before durable persistence, daemon streams read from an explicit in-memory event log/PubSub process, not telemetry.

The Phase 5 router supports replay as JSON arrays by default, NDJSON with
`format=ndjson`, Server-Sent Events with `format=sse`, CloudEvents batch
JSON with `format=cloudevents`, and SHA-256 hash-chain checkpoint export with
`format=checkpoint` for
`GET /api/v1/rounds/:id/events` and `GET /api/v1/audit/:round_id`. Each NDJSON
response line is one complete RFC 8259 JSON object terminated by LF. Each SSE
event uses `id:`, `event:`, and `data:` fields; idle bounded-follow responses
return a heartbeat comment. CloudEvents use `specversion: "1.0"`, stable event
IDs, `/twelvgaige/rounds/<round_id>` sources, `dev.twelvgaige.<kind>.*`
types, and JSON payloads. CLI `twelvgaige audit verify <checkpoint-path|->`
verifies saved checkpoint JSON and reports post-export mutation, deletion, or
reordering without claiming live-store immutability. CLI `round audit --format
checkpoint --sign-hmac-env <env>` can add an HMAC-SHA-256 signature block to a
checkpoint export, and `audit verify --hmac-env <env>` verifies both the hash
chain and HMAC signature. HMAC mode is shared-secret verification, not public
signing. `GET /api/v1/rounds/:id/events` also supports
`follow=true&timeout_ms=<ms>`, which waits for the next event only when replay
is empty, and `until_terminal=true`, which advances the event cursor across
bounded follow batches until the round reaches a terminal state, the idle
timeout expires, or `limit` is reached. Socket push streaming and slow-client
drop behavior are implemented at the concrete listener boundary as a bounded
push stream. The pure router still returns fixed-length bounded replay
bodies: event responses include `x-twelvgaige-stream-mode: bounded-replay`,
enforce configurable `max_event_stream_bytes`, and return HTTP 413 when the
encoded response would exceed that cap instead of buffering without bound.

`Twelvgaige.API.Server` supports push streaming for round events with
`stream=true&format=sse` or `stream=true&format=ndjson`. It sends HTTP/1.1
`Transfer-Encoding: chunked`, `x-twelvgaige-stream-mode: chunked-push`, and no
`Content-Length`. The listener uses `Round.Watch.stream/3` in repeated bounded
waits, writes each accepted batch directly to the socket, advances by `seq`,
emits SSE heartbeats on idle waits, applies a concurrent-stream cap, closes slow
clients through socket send timeouts, and stops at terminal state, event limit,
fetch limit, client disconnect, or stream deadline. Unbounded endless streams
are intentionally out of scope for laptop safety.

Stream rules:

- send historical events after `after_seq` first
- then subscribe to live events
- include heartbeat messages every 15 seconds
- enforce max concurrent stream clients through a listener cap or `ResourceLimiter`
- drop slow clients with bounded socket send timeouts instead of buffering unbounded events
- clients reconnect with the last seen `seq`

### 20.5 Webhook Triggers

Webhook triggers are Phase 5+ and must be opt-in per loaded workflow shell.

Webhook requirements:

- each webhook has an explicit path or generated endpoint ID
- max body size defaults to 1 MiB
- JSON payloads are parsed with bounded depth and size
- signature verification is required for non-loopback webhooks
- timestamp and nonce replay protection are required when the upstream supports them
- accepted triggers return `202` with round ID
- rejected triggers return structured errors without leaking secret details

Webhook handlers must enqueue or start a round through the same public daemon API as CLI/API calls. They must not bypass shell validation, resource admission, or store commits.

Phase 5 pure-router webhook endpoint:

- `POST /api/v1/webhooks/:webhook_id`
- configured through the router `:webhooks` option
- verifies `x-twelvgaige-signature: sha256=<hex>` over
  `<timestamp>.<nonce>.<raw_body>`
- requires `x-twelvgaige-timestamp` and `x-twelvgaige-nonce`
- rejects stale timestamps and duplicate nonces through
  `Twelvgaige.API.WebhookReplayCache`
- uses the decoded JSON object as round input by default
- starts the round through `Breech.start_round/3` and returns `202` with the
  round ID

### 20.6 Provider Transport Policy

Provider network settings are trusted runtime configuration. Workflow shells and agent shells may select provider ID and model, but they must not provide API keys, bearer tokens, proxy settings, or provider base URLs. See [`secrets-and-providers.md`](../secrets-and-providers.md) for operator-facing configuration.

Transport rules:

- TLS verification is enabled by default for hosted providers.
- Hosted provider base URL overrides are allowed only from trusted runtime config.
- Ollama may use a local HTTP endpoint from `OLLAMA_HOST` or trusted config.
- Proxies are explicit runtime config and are never inferred from workflow input.
- connect timeout, read timeout, and total request timeout are separately configurable.
- adapter retries must not exceed the shot retry budget or hide retryable errors from `Round.Server`.
- provider rate-limit retry hints are preserved in `%Twelvgaige.Error{}`.
- cancellation and shot timeout must close or abandon in-flight provider requests promptly.
- all provider requests include a bounded user agent identifying Twelvgaige version.

Provider adapters must use a transport behaviour in tests so normal tests make no network calls.

### 20.7 HTTP Tool Network Policy

`http_get` is read-only, but it is still a network exfiltration and SSRF surface. It is disabled unless a shot explicitly allows it.

Default `http_get` policy:

- allowed schemes: `https` and `http`
- disallowed schemes: `file`, `ftp`, `gopher`, `data`, and custom schemes
- redirects disabled by default; if enabled, maximum 3 redirects
- response byte cap defaults to 1 MiB
- timeout defaults to 10 seconds
- no credentials, cookies, or auth headers are forwarded unless configured in tool policy
- private, loopback, link-local, multicast, and cloud metadata IP ranges are denied unless explicitly allowed by policy
- DNS is resolved by the tool runner and every resolved IP is checked against policy before connecting
- redirect targets are rechecked after resolution

Infrastructure teams may opt into private network access by CIDR/domain allowlist. That opt-in belongs in trusted tool policy, not LLM output.

CLI and daemon runs may supply trusted HTTP tool policy through process
environment:

- `TWELVGAIGE_HTTP_ALLOWED_HOSTS`
- `TWELVGAIGE_HTTP_ALLOW_PRIVATE_HOSTS`
- `TWELVGAIGE_HTTP_TIMEOUT_MS`
- `TWELVGAIGE_HTTP_DEFAULT_MAX_BYTES`

These values are merged into `tool_opts_by_name` for `http_get` and `http_post`
at shot execution time. Explicit programmatic tool options take precedence over
environment defaults. Model output can request a URL, but it cannot grant itself
network policy.

### 20.8 Networking Tests

Normal `mix test` must not open external network connections.

Required networking tests:

- `[x]` IPC envelope encode/decode over authenticated loopback TCP fallback
- `[x]` daemon discovery and version mismatch
- Unix socket or named-pipe command path under `:daemon`
- HTTP API request/response contract through local test server
- auth failure redaction
- event stream replay from `after_seq`
- slow event-stream client drop behavior
- provider adapters using fake transport
- `http_get` denial for blocked schemes and blocked IP ranges

## 21. Observability

Observability has four distinct channels:

- round events: source of truth for `round watch`
- audit events: durable compliance trail
- telemetry/metrics: operational counters, gauges, and timings
- logs: human/operator diagnostics

Telemetry is diagnostic only. `round watch` must read from `round_events` in durable phases or from an explicit in-memory event log/PubSub process in pre-durable daemon phases. Audit records and watch streams must not depend on telemetry handlers.

### 21.1 Telemetry Events

Telemetry events:

```elixir
[:twelvgaige, :round, :start]
[:twelvgaige, :round, :stop]
[:twelvgaige, :round, :exception]
[:twelvgaige, :shot, :start]
[:twelvgaige, :shot, :stop]
[:twelvgaige, :shot, :exception]
[:twelvgaige, :shot, :retry]
[:twelvgaige, :llm, :call, :start]
[:twelvgaige, :llm, :call, :stop]
[:twelvgaige, :llm, :call, :exception]
[:twelvgaige, :tool, :call, :start]
[:twelvgaige, :tool, :call, :stop]
[:twelvgaige, :tool, :call, :exception]
[:twelvgaige, :resource, :permit, :acquire]
[:twelvgaige, :resource, :permit, :release]
[:twelvgaige, :resource, :queue]
[:twelvgaige, :safety, :requested]
[:twelvgaige, :safety, :approved]
[:twelvgaige, :safety, :rejected]
```

Telemetry measurements:

| Event suffix | Measurements |
| --- | --- |
| `:start` | `system_time` |
| `:stop` | `duration` native units |
| `:exception` | `duration` native units when available |
| `[:shot, :retry]` | `attempt`, `delay_ms` |
| `[:llm, :call, :stop]` | `duration`, `input_tokens`, `output_tokens`, `total_tokens` |
| `[:tool, :call, :stop]` | `duration`, `input_bytes`, `output_bytes` |
| `[:resource, :permit, :acquire]` | `active_permits`, `queued_count` |
| `[:resource, :permit, :release]` | `active_permits`, `queued_count` |
| `[:resource, :queue]` | `queued_count`, `queue_time_ms` when known |

Telemetry metadata must include when available:

- `round_id`
- `shell_id`
- `shell_version`
- `shot_id`
- `attempt`
- `provider`
- `model`
- `tool_name`
- `status`
- `error_class`
- `error_reason`
- `resource_profile`
- `queued_for_resource`
- `resource_kind`
- `active_permits`
- `queued_count`

Never include raw secrets, raw prompts, raw tool output, or unredacted provider responses in telemetry metadata.

### 21.2 Metrics

Phase 1 metrics are in-memory snapshots exposed through CLI/debug APIs. Phase 5 exposes Prometheus-format metrics at `GET /api/v1/metrics`.

Metric naming rules:

- Prefix all metrics with `twelvgaige_`.
- Use base units in metric names: `_total`, `_seconds`, `_bytes`.
- Keep labels low-cardinality. Do not label by `round_id`, `shot_id`, full error message, prompt hash, user input, or file path.
- Allowed high-cardinality IDs may appear in logs and round events, not metrics.

Required counters:

| Metric | Labels | Description |
| --- | --- | --- |
| `twelvgaige_rounds_total` | `workflow_id`, `status`, `error_class` | Terminal rounds by workflow and status. |
| `twelvgaige_shot_attempts_total` | `kind`, `status`, `error_class` | Shot attempts completed or failed. |
| `twelvgaige_shot_retries_total` | `shell_id`, `error_reason` | Retry decisions. |
| `twelvgaige_llm_calls_total` | `provider`, `model`, `status`, `error_class` | LLM provider calls. |
| `twelvgaige_llm_tokens_total` | `provider`, `model`, `token_kind` | Provider-reported token usage. |
| `twelvgaige_tool_calls_total` | `tool_name`, `status`, `error_class` | Tool executions. |
| `twelvgaige_resource_queue_total` | `resource_kind`, `profile` | Times work queued for a permit. |
| `twelvgaige_resource_denials_total` | `resource_kind`, `profile`, `reason` | Permit denials or queue timeouts. |
| `twelvgaige_safety_decisions_total` | `decision` | Safety approvals, rejections, and timeouts. |

Required histograms:

| Metric | Labels | Buckets | Description |
| --- | --- | --- | --- |
| `twelvgaige_round_duration_seconds` | `workflow_id`, `status`, `error_class` | default seconds | Wall-clock round duration. |
| `twelvgaige_shot_duration_seconds` | `kind`, `status`, `error_class` | default seconds | Shot attempt duration after task start. |
| `twelvgaige_resource_queue_seconds` | `resource_kind`, `profile`, `status` | sub-second to minutes | Time waiting for resource permits, tagged as granted, timed out, cancelled, or owner-down. |
| `twelvgaige_llm_duration_seconds` | `provider`, `model`, `status`, `error_class` | default seconds | Provider call duration. |
| `twelvgaige_tool_duration_seconds` | `tool_name`, `status`, `error_class` | default seconds | Tool execution duration. |
| `twelvgaige_tool_output_bytes` | `tool_name`, `status` | byte buckets | Tool output sizes after redaction/truncation. |

Required gauges:

| Metric | Labels | Description |
| --- | --- | --- |
| `twelvgaige_rounds_active` | `status`, `profile` | Active daemon rounds by state. |
| `twelvgaige_shots_running` | `profile` | Running shot tasks. |
| `twelvgaige_resource_permits_active` | `resource_kind`, `profile` | Active permits. |
| `twelvgaige_resource_queue_depth` | `resource_kind`, `profile` | Waiting permit requests. |
| `twelvgaige_store_rounds_retained` | `profile` | Round snapshots retained by the active store. |
| `twelvgaige_store_terminal_rounds_retained` | `profile` | Terminal round snapshots retained by the active store. |
| `twelvgaige_store_round_events_retained` | `profile` | Round events retained by the active store. |
| `twelvgaige_store_audit_events_retained` | `profile` | Audit events retained by the active store. |
| `twelvgaige_store_attempt_journals_retained` | `profile` | Attempt journals retained by the active store. |
| `twelvgaige_store_tool_journals_retained` | `profile` | Tool journals retained by the active store. |
| `twelvgaige_store_retained_bytes` | `profile` | Approximate retained store bytes when measurable. |
| `twelvgaige_store_retained_bytes_limit` | `profile` | Configured retained-byte limit for stores that enforce one. |
| `twelvgaige_store_retained_bytes_over_limit` | `profile` | Whether retained bytes exceed the configured limit. |
| `twelvgaige_store_retention_evictions_total` | `profile` | Terminal rounds evicted by local store retention. |

Metric label constraints:

- `workflow_id`, `tool_name`, `provider`, and `model` must be normalized IDs, not user-provided free text.
- Unknown or dynamic error reasons collapse to `unknown`.
- `error_message` is never a metric label.
- `round_id` and `shot_id` are never metric labels.
- `Twelvgaige.Metrics.sanitize_labels/1` rejects known high-cardinality label
  keys, non-scalar values, and oversized label values before samples enter the
  collector.

### 21.3 Logging

Default logging:

- Runtime emission is quiet unless structured logging is configured.
- JSON logs are enabled with application config or
  `TWELVGAIGE_LOG_FORMAT=json`.
- `Twelvgaige.Log.JSON` owns JSON-line formatting for structured logs. It
  emits the required base fields, normalizes metadata into JSON-safe values,
  expands `%Twelvgaige.Error{}` into queryable error fields, omits raw
  prompt/message/tool-output fields, and redacts before encoding.
- `Twelvgaige.Log.emit/5` is the runtime emission boundary. It is quiet by
  default and emits JSON lines when `:twelvgaige, :log_format` or
  `TWELVGAIGE_LOG_FORMAT=json` is configured.
- When `:twelvgaige, :log_path`, `TWELVGAIGE_LOG_PATH`, or an explicit
  `path:` option is configured, JSON logs are written to a local JSONL file
  instead of stderr unless `io:` is explicitly supplied. `max_file_bytes:`,
  `:twelvgaige, :log_max_file_bytes`, or `TWELVGAIGE_LOG_MAX_BYTES` bounds the
  retained file by dropping oldest complete lines after each append.
- Breech emits daemon lifecycle, round queued, and round terminal events through
  this boundary.

Log levels:

| Level | Use |
| --- | --- |
| `debug` | Internal scheduling, permit acquisition/release, parser details, retry calculations. |
| `info` | Round started/completed, safety requested/decided, daemon start/stop. |
| `warn` | Retryable provider/tool errors, queue timeout, truncation, policy-denied tool call. |
| `error` | Round failed, unrecoverable store error, crash recovery requiring reconciliation. |

Required structured log fields:

- `timestamp`
- `level`
- `message`
- `event`
- `round_id` when available
- `shell_id` when available
- `shell_version` when available
- `shot_id` when available
- `attempt` when available
- `provider` and `model` for LLM events
- `tool_name` and `safety_level` for tool events
- `resource_kind`, `active_permits`, and `queued_count` for limiter events
- `duration_ms` when available
- `status`
- `error_class`
- `error_reason`
- `profile`

JSON log example:

```json
{
  "timestamp": "2026-05-01T12:00:00.000Z",
  "level": "info",
  "event": "shot_completed",
  "message": "shot completed",
  "round_id": "round_123",
  "shell_id": "k8s_incident_response",
  "shell_version": "1.0.0",
  "shot_id": "gather_cluster_state",
  "attempt": 1,
  "duration_ms": 3412,
  "status": "complete",
  "profile": "laptop"
}
```

Logging restrictions:

- Never log raw prompts, raw LLM responses, raw tool output, API keys, bearer tokens, cookies, environment dumps, kubeconfigs, or full command environments.
- Redact before logging, not in the log sink.
- Tool inputs and outputs are logged only as redacted summaries: byte counts, schema-validity status, truncation flag, and optional safe preview capped at 512 bytes.
- Debug logs may include parsed shell IDs and normalized config, but not input payloads unless explicitly enabled by a local-only unsafe debug flag.
- Repeated identical warnings should be rate-limited by event key.

### 21.4 Audit Versus Logs

Audit events answer "what happened and who approved it." Logs answer "what is the system doing." Metrics answer "how much and how fast."

Audit records are durable once persistence exists and include safety decisions, tool calls, state transitions, and actor identity. Logs are not compliance records and may be sampled or rotated.

### 21.5 Health And Diagnostics

`twelvgaige status` and `GET /api/v1/health` should report:

- daemon running status
- active profile
- active rounds
- queued rounds
- running shots
- resource queue depths
- store status
- LLM provider configured/unconfigured status without exposing secrets
- last unrecoverable error summary

`twelvgaige metrics` and `GET /api/v1/metrics` should expose the metrics above when the metrics feature is enabled.

## 22. Security And Redaction

Secret sources:

- Environment variables
- Future secret backend
- Explicit CLI config

Redaction rules:

- Redact values for keys matching `token`, `secret`, `password`, `apikey`, `api_key`, `authorization`, `cookie`, `credential`.
- Redact configured literal secret values if known.
- Redact bearer tokens and common key formats in strings.
- Apply redaction before logs, audit events, telemetry metadata, and JSON output unless user explicitly requests full debug output in a local-only mode.

Prompt injection handling:

- Tool output is untrusted.
- Tool output inserted into LLM messages must be tagged as tool output.
- Tool output must never be reinterpreted as system or developer instructions.
- Prompts should remind models that tool output may contain hostile instructions.

## 23. External Standards And Compatibility Targets

Twelvgaige should align with established standards where they reduce ambiguity, improve interoperability, or make security review easier. Standards are implementation constraints only for the phases where the related feature exists.

### 23.1 Normative From Phase 0

These apply as soon as the project skeleton exists:

| Area | Standard | Requirement |
| --- | --- | --- |
| JSON | RFC 8259 | All CLI JSON, API JSON, persisted JSON blobs, fixtures, and NDJSON line payloads must be valid UTF-8 JSON. |
| Timestamps | RFC 3339 | All externally visible timestamps use RFC 3339 strings. Prefer UTC with `Z`; include fractional seconds only when useful. |
| Versions | SemVer 2.0.0 | Workflow shell versions, agent shell versions, API versions, and persisted manifest schema versions use documented compatibility rules. |
| YAML | YAML 1.2 | Workflow and agent shells target YAML 1.2. Unsupported YAML features must fail validation clearly. |
| JSON shells | RFC 8259 | JSON workflow and agent shells use the same normalized shell map and validation path as YAML. |
| TOML shells | TOML 1.0.0 | TOML workflow and agent shells are declarative only and map cleanly to the normalized shell map. |
| Programmatic shells | Starlark dialect pinned by RFC | Any future programmatic shell authoring must be disabled by default, sandboxed, bounded, deterministic, and limited to generating a declarative shell map. |
| JSON Schema | JSON Schema 2020-12 | Input and output schemas use a declared supported subset. Unsupported keywords fail at shell validation. |
| URI parsing | RFC 3986 | Provider base URLs, webhook URLs, and `http_get` destinations are parsed and normalized before policy checks. |

Implementation notes:

- Do not accept timestamps without timezone offsets in external JSON.
- Do not emit non-JSON values such as `NaN`, `Infinity`, atoms, or tuples.
- Shell IDs, agent IDs, shot IDs, and tool names should be ASCII slugs unless a future spec explicitly allows Unicode identifiers.
- Schema validation must be deterministic and local; LLMs do not decide whether output satisfies a schema.

### 23.2 Operating System Conventions

Local paths should follow platform conventions:

| Platform | Convention |
| --- | --- |
| Linux | XDG Base Directory Specification for config, data, cache, and runtime paths. |
| macOS | `~/Library/Application Support/Twelvgaige` for durable app data, `~/Library/Logs/Twelvgaige` for logs, and a user-owned runtime directory for sockets. |
| Windows | Windows Known Folders, especially `%LOCALAPPDATA%\Twelvgaige` for user-local state. Default IPC is authenticated loopback TCP; per-user named-pipe paths are supported for explicit verification. |

The implementation may support environment overrides, but default paths should not surprise platform users.

### 23.3 HTTP API Standards

These apply when the HTTP API lands:

| Area | Standard | Requirement |
| --- | --- | --- |
| HTTP semantics | RFC 9110 | Use correct methods, status codes, headers, content negotiation, and cache behavior. |
| HTTP/1.1 | RFC 9112 | If using HTTP/1.1, respect message framing and connection handling rules through the chosen server library. |
| Problem Details | RFC 9457 | HTTP errors use `application/problem+json` with Twelvgaige extensions for `class`, `reason`, `retryable`, and `safety_required`. |
| Bearer auth | RFC 6750 | Remote HTTP bearer tokens use the `Authorization: Bearer` header with `WWW-Authenticate` challenges. Tokens must not be accepted in query strings. |
| Rate limits | RFC 9333 | Public API rate-limit responses use `RateLimit-Limit`, `RateLimit-Remaining`, and `RateLimit-Reset` where applicable. The pure router emits these when supplied limiter metadata. |
| Retry hints | RFC 9110 | Use `Retry-After` for API retry hints where applicable. The pure router emits it on configured `429` rate-limit responses. Provider retry hints are normalized internally. |
| OpenAPI | OpenAPI 3.1 | The HTTP API contract is served as JSON and must stay in sync with implemented routes before the API is considered stable. |

HTTP error responses:

```json
{
  "type": "https://twelvgaige.dev/problems/tool-denied",
  "title": "Tool denied",
  "status": 403,
  "detail": "tool is not allowed for this shot",
  "instance": "/api/v1/rounds/round_123",
  "class": "tool_error",
  "reason": "tool_denied",
  "retryable": false,
  "safety_required": false
}
```

CLI JSON may keep the simpler `{"error": ...}` shape, but the underlying error fields should map cleanly to Problem Details.

### 23.4 Streaming And Event Standards

| Area | Standard or Convention | Requirement |
| --- | --- | --- |
| NDJSON | Newline-delimited JSON convention | Each stream line is one complete RFC 8259 JSON object encoded as UTF-8 and terminated by LF. |
| SSE | WHATWG Server-Sent Events | If SSE is used, use standard `event:`, `id:`, `data:`, and heartbeat comment framing. |
| CloudEvents | CloudEvents 1.0 | Webhook normalization and future outbound event delivery should map cleanly to CloudEvents attributes. |

CloudEvents mapping:

| CloudEvents attribute | Twelvgaige value |
| --- | --- |
| `id` | round event ID or audit event ID |
| `source` | `twelvgaige://<daemon-id>` or configured deployment source |
| `type` | stable event type, for example `dev.twelvgaige.round.shot.completed` |
| `subject` | round ID and optional shot ID |
| `time` | RFC 3339 event timestamp |
| `datacontenttype` | `application/json` |
| `data` | redacted event payload |

### 23.5 Metrics And Tracing Standards

| Area | Standard | Requirement |
| --- | --- | --- |
| Metrics exposition | OpenMetrics / Prometheus text exposition | `/metrics` emits Prometheus-compatible metrics with stable names, base units, and low-cardinality labels. |
| Tracing and log correlation | OpenTelemetry semantic conventions | If tracing is added, trace/span IDs and resource attributes should follow OpenTelemetry conventions. |

Metrics remain operational data, not audit records.

### 23.6 Kubernetes Compatibility

Kubernetes support should follow Kubernetes API conventions rather than inventing local variants:

- Use Kubernetes resource names, namespaces, label selectors, field selectors, and API group/resource terminology consistently.
- Do not bypass kubeconfig, current-user auth, or RBAC.
- Do not parse human-formatted `kubectl` tables when structured output is available.
- Prefer JSON output from `kubectl` and parse it with a structured parser.
- Treat Kubernetes warnings and partial failures as structured tool output, not plain log text.

### 23.7 Security Guidance

These are guidance targets, not formal compliance claims:

- OWASP API Security Top 10 for the HTTP API.
- OWASP SSRF Prevention guidance for `http_get`, webhooks, and provider endpoint overrides.
- OWASP Logging guidance for audit/log separation, secret redaction, and event integrity.
- Platform TLS defaults through Erlang/OTP and the operating system certificate store where practical.

### 23.8 Release And Supply Chain Targets

These are later-phase release targets:

| Area | Standard | Requirement |
| --- | --- | --- |
| SBOM | SPDX or CycloneDX | Release artifacts should be able to produce an SBOM. |
| Provenance | SLSA provenance | Automated release artifacts should include provenance metadata when packaging is mature. |
| Containers | OCI Image Specification | If a daemon container is published, it should be an OCI-compliant image. |

### 23.9 Standards Compliance Tests

Required tests should be added as features land:

- RFC 8259 JSON fixture validation for CLI/API/persisted samples.
- RFC 3339 timestamp parse tests for emitted JSON and logs.
- YAML 1.2 valid/invalid shell fixtures.
- JSON Schema 2020-12 supported-subset contract tests.
- RFC 9457 Problem Details fixtures for HTTP errors.
- RFC 6750 bearer auth rejection tests for query-string tokens.
- RFC 9333 and `Retry-After` header tests for API rate-limit/retry responses.
- OpenAPI 3.1 schema validation once the API stabilizes.
- NDJSON stream framing tests.
- SSE framing tests if SSE is implemented.
- CloudEvents mapping tests for webhook/event normalization once webhooks exist.
- OpenMetrics text exposition tests for `/metrics`.

## 24. Module Layout

```text
lib/
+-- twelvgaige.ex
+-- twelvgaige/
    +-- application.ex
    +-- resource_limiter.ex
    +-- cli/
    |   +-- main.ex
    |   +-- commands/
    +-- shell/
    |   +-- workflow.ex
    |   +-- agent.ex
    |   +-- loader.ex
    |   +-- cache.ex
    |   +-- schema.ex
    +-- pattern/
    |   +-- compiler.ex
    |   +-- graph.ex
    |   +-- condition.ex
    |   +-- readiness.ex
    +-- round/
    |   +-- supervisor.ex
    |   +-- run_supervisor.ex
    |   +-- server.ex
    |   +-- state.ex
    |   +-- snapshot.ex
    +-- shot/
    |   +-- attempt.ex
    |   +-- executor.ex
    |   +-- retry_policy.ex
    |   +-- state.ex
    +-- llm/
    |   +-- provider.ex
    |   +-- capabilities.ex
    |   +-- router.ex
    |   +-- response.ex
    |   +-- providers/
    |       +-- openai.ex
    |       +-- ollama.ex
    +-- tool/
    |   +-- behaviour.ex
    |   +-- executor.ex
    |   +-- catalog.ex
    |   +-- idempotency.ex
    |   +-- builtins/
    +-- audit/
    |   +-- event.ex
    +-- store/
    |   +-- behaviour.ex
    |   +-- memory.ex
    |   +-- manifest.ex
    |   +-- transition.ex
    +-- event/
    |   +-- log.ex
    |   +-- pubsub.ex
    +-- telemetry.ex
    +-- error.ex
```

Avoid creating a module named just `Agent` outside the `Twelvgaige` namespace in order to avoid confusion with Elixir's built-in `Agent`.

## 25. Dependencies

Runtime dependencies are intentionally small:

- `[x]` `jason` for JSON encoding and decoding.
- `[x]` `yamerl` for YAML shell loading.
- `[x]` JSON shell loading reuses `jason` behind the loader dispatch boundary.
- `[x]` `toml_elixir` for TOML 1.0 shell loading.
- `[ ]` Programmatic shell loading must choose no runtime until the Starlark/CUE security RFC is accepted.
- `[x]` `ecto_sql` for durable SQL store plumbing.
- `[x]` `ecto_sqlite3` for the laptop-local durable store.
- `[x]` `burrito` for single-file native executable packaging. Burrito remains a packaging dependency; runtime CLI behavior is isolated in `Twelvgaige.CLI.Burrito`.

Implemented in project code instead of dependencies:

- `[x]` CLI parsing uses local command modules and `OptionParser`-style argument handling.
- `[x]` JSON Schema support is the Twelvgaige-declared 2020-12 subset implemented in `Twelvgaige.Schema.ValueValidator`.
- `[x]` Resource profiles and admission control are implemented in `Twelvgaige.RuntimeProfile` and `Twelvgaige.ResourceLimiter`.
- `[x]` HTTP/1.1 API serving, provider transports, and HTTP tools use project-owned transport seams and fake transports in tests.
- `[x]` Metrics and Prometheus text exposition use project-owned collectors and formatters.
- `[x]` Scheduler interval and five-field UTC cron support use project-owned modules.
- `[x]` Tests use hand-written fakes, injected transports, and shared contract modules rather than Mox.
- `[x]` Provider adapter request/response/error fixtures cover OpenAI and Ollama without network calls.

Deferred unless feature pressure justifies adding them:

- `[ ]` `nimble_options` if runtime option validation becomes hard to reason about.
- `[ ]` Full JSON Schema library if the declared subset blocks real workflows.
- `[ ]` `req` or another HTTP client if provider/tool transport requirements exceed the current seams.
- `[ ]` `bandit` and `plug` if the local HTTP listener needs a framework-backed server.
- `[ ]` `postgrex` when multi-node or external Postgres becomes a committed target.
- `[ ]` `quantum` if scheduler requirements exceed the current interval/cron subset.
- `[ ]` `prom_ex` if metrics need ecosystem integrations beyond the current Prometheus exposition.
- `[ ]` Native installers, signing/notarization, or updater support beyond Burrito single-file binaries and Mix release tarballs.

Dependency rule: do not add a dependency until its owning feature is being implemented.

## 26. Test Spec

### 26.0 Testability Requirements

Normal tests must be deterministic, isolated, and free of live provider, network, Kubernetes, or destructive filesystem side effects.

External effects must sit behind behaviours or explicit modules that can be replaced in tests:

| Effect | Required seam |
| --- | --- |
| Time and timers | `Twelvgaige.Clock` behaviour or explicit test timer messages |
| ID generation | `Twelvgaige.IdGenerator` behaviour |
| Retry jitter | injectable jitter function or seeded deterministic module |
| LLM providers | `Twelvgaige.LLM.Provider` behaviour |
| Provider HTTP | `Twelvgaige.HTTPClient` behaviour or adapter-local transport behaviour |
| Tool execution | `Twelvgaige.Tool` behaviour plus fake tools |
| OS command execution | `Twelvgaige.CommandRunner` behaviour |
| Kubernetes `kubectl` calls | `CommandRunner` fixture, not real `kubectl` in normal tests |
| Store | `Twelvgaige.Store` behaviour |
| Resource admission | `Twelvgaige.ResourceLimiter` API with test profile/fake limiter |
| Logging/redaction | pure formatter/redactor modules |
| Metrics | in-memory metrics collector for tests |
| Shell parsing | parser modules that return normalized string-key maps before shell construction |

Rules:

- Normal `mix test` must not call real LLM providers.
- Normal `mix test` must not access a real Kubernetes cluster.
- Normal `mix test` must not require network access.
- Normal `mix test` must not depend on wall-clock sleeps. Use `assert_receive`, direct test messages, fake clocks, or controlled processes.
- Tests must use temporary directories for filesystem state.
- Generated IDs and timestamps must be injectable or assertable through patterns.
- Provider, Kubernetes, and store fixtures must redact fake secrets even when the secret values are synthetic.

### 26.0.1 Test Tags

Default ExUnit exclusions:

```elixir
ExUnit.configure(exclude: [
  :integration,
  :daemon,
  :persistence,
  :provider_live,
  :keychain_live,
  :k8s_live,
  :slow
])
```

Tag meanings:

| Tag | Meaning | Default |
| --- | --- | --- |
| `:integration` | Cross-module tests that may start supervisors or CLI processes. | excluded |
| `:daemon` | Tests that start Breech daemon/IPC. | excluded |
| `:persistence` | Tests using SQLite or durable store migrations. | excluded |
| `:provider_live` | Live OpenAI/Ollama provider calls. | excluded |
| `:keychain_live` | Live OS keychain tests that may prompt or mutate user keychain state. | excluded |
| `:sqlcipher_live` | Live SQLCipher store tests requiring a SQLCipher-linked SQLite driver. | excluded |
| `:k8s_live` | Tests against a real local Kubernetes cluster. | excluded |
| `:slow` | Tests expected to exceed normal unit-test timing. | excluded |

Provider and Kubernetes live tests must require explicit environment opt-in in addition to tags, for example `TWELVGAIGE_PROVIDER_LIVE=1` or `TWELVGAIGE_K8S_LIVE=1`. The live Kubernetes smoke tests use `TWELVGAIGE_K8S_CONTEXT`, optional `TWELVGAIGE_K8S_NAMESPACE`, and optional `TWELVGAIGE_K8S_TIMEOUT_MS`; normal tests still use fake command runners.

### 26.0.2 Fixture Layout

Required fixture layout:

```text
test/support/
+-- fakes/
|   +-- clock.ex
|   +-- id_generator.ex
|   +-- http_client.ex
|   +-- command_runner.ex
|   +-- store.ex
|   +-- resource_limiter.ex
+-- fixtures/
    +-- shells/
    +-- agents/
    +-- providers/
    |   +-- openai/
    |   +-- ollama/
    +-- kubernetes/
    |   +-- get/
    |   +-- describe/
    |   +-- logs/
    |   +-- events/
    +-- stores/
    +-- logs/
```

Golden fixtures:

- Must be small and redacted.
- Must include both success and error cases.
- Must be updated intentionally, not rewritten automatically by default.
- Provider fixtures assert request serialization and response normalization.
- Kubernetes fixtures assert argv construction, output parsing, truncation, and redaction.

### 26.0.3 Controlled OTP Test Processes

GenServer tests must avoid timing races.

Required test helpers:

- controllable shot executor that blocks until the test sends success/failure/crash instructions
- fake resource limiter that can deny, queue, and later grant permits deterministically
- fake store that can return success, version conflict, store unavailable, or already committed
- helper to send stale task result messages with old refs/attempts
- helper to trigger timeout handling by direct message where appropriate

Shot task tests may use real processes, but assertions should use `assert_receive` with bounded timeouts and should not rely on arbitrary sleeps.

### 26.0.4 Contract Tests

Behaviour implementations must share contract tests where practical:

- Store contract for `Store.Memory`, `Store.File`, and `Store.SQLite`:
  - create round with manifest
  - idempotent transition commit by `transition_id`
  - version conflict handling
  - list incomplete rounds
  - replay round events
  - recover structured shot outputs
- Provider contract for the test-only deterministic adapter, OpenAI, and Ollama:
  - request serialization
  - tool-call normalization
  - usage normalization or estimated usage
  - error classification
  - secret redaction
- Command runner contract:
  - argv is preserved exactly
  - timeout is classified
  - stderr is captured and redacted
  - non-zero exit status is classified
- Tool contract:
  - input schema validation
  - output byte cap
  - audit summary shape
  - safety level/idempotency metadata present

### 26.1 Unit Tests

- `[x]` Workflow shell parser accepts valid shell.
- `[x]` Workflow shell parser rejects missing required fields.
- `[x]` JSON workflow and agent shell parser fixtures normalize to the same maps as equivalent YAML fixtures.
- `[x]` TOML workflow and agent shell parser fixtures normalize to the same maps as equivalent YAML fixtures.
- `[ ]` Programmatic shell sandbox tests deny filesystem, environment, network, imports, subprocesses, infinite loops, and oversized generated shells before the loader is enabled.
- `[x]` Pattern compiler rejects duplicate shot IDs.
- `[x]` Pattern compiler rejects missing dependencies.
- `[x]` Pattern compiler rejects cycles.
- `[x]` Pattern compiler rejects unknown agents.
- `[x]` Pattern compiler rejects unknown tools.
- `[x]` Readiness returns all root shots.
- `[x]` Readiness returns dependent shots only after dependencies complete.
- `[x]` Condition evaluator handles boolean, comparison, logical operators, membership, existence, and missing paths safely.
- `[x]` Condition evaluator rejects unsupported roots, invalid syntax, and unsupported path syntax.
- `[x]` Schema subset validator rejects unsupported keywords.
- `[x]` Round runner rejects input that violates workflow `input_schema` before shot execution.
- `[x]` Breech rejects daemon-owned rounds with invalid input before queuing.
- `[x]` Resource profile parser applies laptop defaults, profile-specific budgets, process defaults, and max-profile clamping.
- `[x]` Resource limiter denies new shot admission when global or per-round limits are saturated.
- `[x]` Resource limiter returns all-or-nothing permits for multi-permit shot admission.
- `[x]` Resource limiter releases permits and removes waiters when owner processes die.
- `[x]` Resource limiter applies weighted round-robin fairness across rounds for opt-in queued waiters.
- `[x]` Resource limiter handles queue timeout separately from shot execution timeout.
- `[x]` Retry policy respects max attempts.
- `[x]` Retry policy does not retry policy-denied errors.
- `[x]` Tool safety comparison follows the explicit safety lattice.
- `[x]` Error classifier maps provider errors correctly.
- `[x]` Provider router selects adapter by explicit provider ID.
- `[x]` Provider config resolver loads trusted runtime config and environment secrets without allowing shell-level credentials.
- `[x]` Loadout resolver applies referenced agent provider, model, and system prompt to foreground and scheduler shot execution.
- `[x]` Provider capability checks reject unsupported native tool/schema modes.
- `[x]` OpenAI adapter serializes requests and normalizes responses/errors from fixtures.
- `[x]` Ollama adapter serializes requests and normalizes responses/errors from fixtures.
- `[x]` Provider configs redact API keys, auth headers, URL query secrets, and inspected transport details in logs/errors.
- `[x]` Tool executor denies non-allowlisted tools.
- `[x]` Tool executor validates input schema.
- `[x]` Shot executor executes allowed read-only tool calls and rejects malformed or over-budget tool calls.
- `[x]` Kubernetes tools reject arbitrary args and denied resources.
- `[x]` Kubernetes tools require namespace unless cluster scope is explicitly allowed.
- `[x]` Kubernetes logs enforce tail, byte, and redaction caps.
- `[x]` Redactor removes common secret fields.
- `[x]` Audit event sanitizer redacts common secret fields before store persistence and JSON output.
- `[x]` Metric label sanitizer rejects high-cardinality labels.
- `[x]` Log formatter redacts prompts, tool output, and common secret fields.
- `[x]` Fake clock and fake ID generator make time/IDs deterministic.
- `[x]` Fake command runner captures argv without running OS commands.
- `[x]` Fake HTTP client captures provider requests without network access.

### 26.2 GenServer Tests

- `[x]` Round server starts with all shots pending.
- `[x]` Round server fires root shots on chamber.
- `[x]` Round server queues ready shots when resource permits are unavailable.
- `[x]` Round server fires queued shots after permits are released.
- `[x]` Round server cancels resource waiters when queued shots are cancelled.
- `[x]` Round server releases permits if task start fails after admission.
- `[x]` Round server handles successful task result and fires dependent shot.
- `[x]` Round server ignores stale task result from old attempt.
- `[x]` Round server handles task crash as classified shot failure.
- `[x]` Round server handles shot timeout and retries if policy allows.
- `[x]` Round server marks round complete when all shots are complete or skipped.
- `[x]` Foreground round runner pauses at safety shot.
- `[x]` Foreground round runner resumes after targeted inline safety approval.
- `[x]` Foreground round runner halts after targeted inline safety rejection.
- `[x]` Daemon round server pauses at safety shot.
- `[x]` Daemon round server resumes after targeted safety approval.
- `[x]` Daemon round server halts after targeted safety rejection.
- `[x]` Round server cancels in-flight tasks on cancel.
- `[x]` Round server enters `:blocked_on_store` without firing dependents when a required commit fails.
- `[x]` Round server tests use controllable stores/executors for store-block, stale-result, task-start failure, timeout, and resource cleanup paths; timeout tests block controlled tasks instead of sleeping inside handlers.

### 26.3 Integration Tests

- `[x]` CLI validates a workflow shell.
- `[x]` CLI runs a simple deterministic test workflow to completion.
- `[x]` CLI returns JSON output with stable schema.
- `[x]` CLI maps round snapshots and command errors to deterministic exit codes.
- `[x]` JSON logs contain required fields and no raw secrets; `Twelvgaige.Log.JSON` provides the tested formatter and `Twelvgaige.Log.emit/5` is wired into Breech lifecycle events.
- `[x]` Metrics snapshot exposes core runtime counters, resource gauges, queued-resource wait histograms, and retained store/event gauges with approved labels.
- `[x]` Read-only tool workflow runs with fake or local tool fixtures.
- `[x]` Read-only Kubernetes workflow runs against fixtures; opt-in `:k8s_live` smoke tests cover `kubectl_get` and `kubectl_events` against an explicitly configured local cluster.
- `[x]` Daemon round events can be replayed and followed with bounded long-poll from another CLI process in Phase 3, including `--until-terminal` cursor advancement. The actual CLI entrypoint streams event batches incrementally through `Round.Watch.stream/3`; the concrete HTTP listener supports bounded chunked push streams with `stream=true`.
- `[x]` Watch replay and bounded follow read from round events, not telemetry, and can continue until terminal state within explicit bounds. The CLI watch path and HTTP chunked stream path do not accumulate all events before output; the pure router keeps fixed-length bounded replay responses.
- `[x]` Awaiting-safety round survives restart in Phase 4 for both file and SQLite stores.

### 26.4 Contract Tests

- `[x]` Store contract runs through a shared reusable contract module against memory, file, and SQLite stores.
- `[x]` Store contract runs against SQLite store once persistence exists.
- `[x]` Provider contract runs against the test-only deterministic adapter, OpenAI, and Ollama with fixtures.
- `[x]` Command runner contract runs against fake command runner.
- `[x]` Tool contract runs against every built-in tool.
- `[x]` Kubernetes tool contract runs against fixture-backed command runner.
- `[x]` Standards contract validates RFC 8259 JSON, RFC 3339 timestamps, YAML 1.2 fixtures, and the supported JSON Schema 2020-12 subset.
- `[x]` Shell-format standards contract validates JSON shell fixtures.
- `[x]` Shell-format standards contract validates TOML shell fixtures.
- `[x]` HTTP standards contract validates RFC 9457 Problem Details, RFC 6750 bearer auth behavior, RFC 9333 rate-limit headers, `Retry-After`, and OpenAPI 3.1 when the HTTP API exists.
- `[x]` Stream standards contract validates NDJSON framing, SSE framing, and CloudEvents batch mapping for event replay.

### 26.5 Property Tests

- `[x]` Generated DAGs with cycles are rejected.
- `[x]` Generated acyclic DAGs compile and readiness order respects dependencies.
- `[x]` Ready-shot calculation never returns a shot with incomplete dependencies.
- `[x]` Retry delay never exceeds max delay.

## 27. Feature Tracking

### Phase 0 - SPEC And Skeleton

| Status | Feature | Acceptance |
| --- | --- | --- |
| `[x]` | `plan.md` exists | Plan reviewed and Twelvgaige-specific. |
| `[x]` | `spec.md` exists | This file defines implementation rules and tracking. |
| `[x]` | Standards matrix | External standards are documented with phase-specific implementation requirements. |
| `[x]` | Mix project skeleton | `mix test` runs. |
| `[x]` | Formatter config | `mix format --check-formatted` works. |
| `[x]` | ExUnit tag policy | Live, slow, daemon, provider, Kubernetes, and persistence tests are excluded by default. |
| `[x]` | Test support fakes | Clock, ID generator, command runner, store, and resource limiter fakes exist for deterministic unit and integration tests; provider tests use fake transports. |
| `[x]` | CLI help | `twelvgaige --help` prints command help from source. |

### Phase 1 - In-Memory Round Engine

| Status | Feature | Acceptance |
| --- | --- | --- |
| `[x]` | Shell structs | Workflow and agent shells load into structs. |
| `[x]` | YAML loader | Valid YAML loads, invalid YAML returns compile errors. |
| `[x]` | Schema subset validator | Supported schemas validate; unsupported keywords fail validation. |
| `[x]` | JSON and timestamp contracts | CLI JSON is RFC 8259-valid and externally visible timestamps are RFC 3339. |
| `[x]` | Resource limiter | Named profiles cap active rounds, shots, LLM calls, tools, and retained bytes. |
| `[x]` | Runtime input validation | Foreground and daemon-owned rounds reject invalid input before queuing or firing shots. |
| `[x]` | Resource fairness | `ResourceLimiter` supports opt-in queued waiters, queue-timeout notifications, and fair notifications by weighted round-robin across rounds and FIFO within a round. The `Round.Server` scheduler and `Round.Runner` queue active-round and active-shot admission; store-backed scheduler transitions commit before dependent work can fire and before independent store-backed shots are spawned. |
| `[x]` | Resource cleanup | Permits are released on owner crash, normal release, Breech shutdown, scheduler task-start failure, scheduler task result, scheduler task crash, scheduler shot timeout, scheduler round cancellation, and store-blocked scheduler shot-start transitions; blocked starts do not record attempts before the durable start commit, reacquire permits after store recovery, and remove queued waiters on cancellation, owner crash, or server exit. |
| `[x]` | Pattern compiler | Validates DAG and produces normalized pattern. |
| `[x]` | Condition evaluator | Safe string conditions evaluate input and prior shot outputs; false conditions mark shots skipped, and missing non-`exists` paths fail with classified condition errors. |
| `[x]` | Loadout resolver | Supplied agent definitions determine provider, model, and system prompt for referenced shots in foreground and scheduler execution paths. |
| `[x]` | Test-only deterministic LLM provider | Tests run without network. |
| `[x]` | Round supervisor | Dynamic supervisor starts per-round supervisors. |
| `[x]` | Round server | Executes state transitions and readiness. |
| `[x]` | Shot executor | Executes deterministic test LLM attempts, bounded ReAct iterations, and read-only tool calls. |
| `[x]` | CLI round run | Simple workflow completes in the foreground. |

### Phase 2 - Tools And Safety

| Status | Feature | Acceptance |
| --- | --- | --- |
| `[x]` | Tool behaviour | Built-ins implement common behaviour. |
| `[x]` | Tool catalog | Tools discoverable by name. |
| `[x]` | Tool executor | Permission, safety, schema, timeout, resource admission, crash, and output-size checks enforced. |
| `[x]` | Tool-call execution | `Shot.Executor` normalizes provider tool calls, runs them serially through `Tool.Executor`, appends untrusted tool-result messages, and returns classified failures. |
| `[x]` | Read-only built-ins | `shell_read` and `http_get` work in tests without arbitrary shell strings or live network calls. |
| `[x]` | HTTP write tool | `http_post` uses structured input, destructive safety, confirmation, destination policy checks, trusted runtime headers, request/response byte limits, redaction, and fake-transport tests. |
| `[x]` | Git write tool | `git_commit` stages and commits only explicit regular files under a trusted root with destructive safety, confirmation, bounded redacted output, and fake-runner tests. |
| `[x]` | Kubernetes read-only tools | `kubectl_get`, `kubectl_describe`, `kubectl_logs`, and `kubectl_events` use structured argv, bounded output, and redaction. |
| `[x]` | Kubernetes write tools | `kubectl_apply`, `kubectl_scale`, `kubectl_rollout_restart`, `kubectl_delete`, and runtime-gated `kubectl_exec` use structured argv, namespaced targets or trusted manifest paths, safety thresholds, confirmation where required, bounded output, and fake-runner tests. |
| `[x]` | Safety shot | Foreground round pauses and can use inline approval in the same VM. |
| `[x]` | Retry policy | Retryable failures retry with bounded backoff and never exceed max attempts. |
| `[x]` | Output validation | Malformed or schema-invalid output cannot advance dependents. |
| `[x]` | Provider router | Production provider IDs route only to OpenAI or Ollama adapters. |
| `[x]` | Provider fixtures | Adapter request/response/error normalization is tested without network calls. |

### Phase 3 - Breech Daemon

| Status | Feature | Acceptance |
| --- | --- | --- |
| `[x]` | Daemon process | Starts and reports status. |
| `[x]` | Daemon lifecycle CLI | `daemon serve` starts a foreground listener with default endpoint and lock paths; `daemon stop` shuts it down over IPC; `daemon paths` reports platform defaults. |
| `[x]` | Shell cache | `Twelvgaige.Shell.Cache` loads configured workflow/agent shell paths under OTP supervision, rejects conflicting duplicate IDs, exposes list APIs, and lets daemon-owned runs resolve workflow IDs with loaded agent loadouts. |
| `[x]` | Daemon-owned run submission | Breech accepts a workflow shell/path/map, starts a supervised in-VM round task, and stores queued/final snapshots. |
| `[x]` | Round inspection | `round list` and `round show` read daemon-owned snapshots from the in-memory store. |
| `[~]` | IPC | Loopback TCP fallback, Windows default loopback TCP, and macOS/Linux Unix sockets support status, run, list, show, event replay/follow, approve, reject, and cancel with length-prefixed JSON. Named-pipe address parsing, client injected transport tests, and server injected listener dispatcher tests are implemented; native Windows named-pipe listener I/O is pending Windows verification. |
| `[x]` | Daemon discovery | Explicit IPC addresses, `TWELVGAIGE_BREECH_ADDR`, endpoint JSON discovery, endpoint API-version mismatch errors, generated loopback bearer tokens, Unix socket endpoints, named-pipe endpoint encoding, owner-only endpoint files, daemon singleton locks, lock-gated stale cleanup, and Windows-safe TCP defaults are supported. |
| `[x]` | Watch stream | CLI can replay daemon-owned round events and bounded-follow from the store as human text or NDJSON, including `--until-terminal` cursor advancement through multiple callback-delivered batches without collecting the whole stream first. The concrete HTTP listener supports bounded chunked push for round events; unbounded PubSub streams remain intentionally out of scope. |
| `[x]` | Deterministic CLI exit codes | `Twelvgaige.CLI.ExitCode` maps snapshots and command errors to the documented `0..8` contract; command tests cover invalid input, missing rounds, missing shell files, and policy-denied safety decisions. |
| `[x]` | Targeted approval from second process | Paused safety shot can be approved or rejected externally by round ID and safety shot ID through Breech APIs and loopback IPC. |
| `[x]` | Cancellation | Active and awaiting-safety daemon-owned rounds can be cancelled externally; active runner tasks are terminated and nonterminal shots are marked cancelled. |

### Phase 4 - Persistence And Recovery

| Status | Feature | Acceptance |
| --- | --- | --- |
| `[x]` | File-backed store | `Store.File` persists snapshots, manifests, attempt/tool journals, committed transition IDs, audit records, and round events with atomic file replacement. |
| `[x]` | Store supervision config | `Twelvgaige.Application` starts the configured store child from app config, `TWELVGAIGE_STORE_SQLITE`, or `TWELVGAIGE_STORE_FILE` and passes the normalized store module to Breech. |
| `[x]` | Configurable Breech store | Breech uses the configured store behaviour module instead of hardcoded memory storage; terminal round snapshots and events can be read after `Store.File` and `Store.SQLite` process restarts. |
| `[x]` | Awaiting-safety restart resume | An awaiting-safety round stored in `Store.File` remains inspectable after Breech/store restart and resumes to completion after approval. |
| `[x]` | SQLite store | `Store.SQLite` persists snapshots, manifests, attempt/tool journals, committed transition IDs, audit records, and round events in SQLite with WAL, foreign keys, bounded busy timeout, transactional transition commits, retained-byte cleanup, and queryable round columns for shell identity, timing, and error reason. |
| `[x]` | Ecto schemas and migrations | SQLite table creation is owned by versioned Ecto migrations, persisted in `schema_migrations`; table schema modules exist for rounds, manifests, shot runs, events, audit events, transitions, and journals. |
| `[x]` | Audit store | Attempt/tool journal writes and Breech state transitions append durable audit records after audit-event redaction; `list_audit_events/2`, IPC `round.audit`, and CLI `round audit` expose cursor-based replay plus SHA-256 checkpoint export; CLI `audit verify` validates saved checkpoint exports for post-export mutation, deletion, and reordering. |
| `[x]` | Run manifest | `Round.Manifest` snapshots the accepted workflow with schema version, workflow source metadata/content hash, normalized workflow hash, accepted agent source metadata, and agent shell hashes; Breech recovery and safety resume use the stored manifest, not current shell files. |
| `[x]` | Durable snapshot | `Round.Snapshot` excludes runtime-only OTP fields; file and SQLite stores persist snapshots through the store contract; `Round.ShotRun` and SQLite `shot_runs` provide typed shot-level projection with startup backfill. |
| `[x]` | Attempt and tool journal | Attempt start, attempt outcome, tool intent, and tool observed result are recorded when a store is configured; store failures stop execution before side effects where applicable; Runner, ToolExecutor, Breech, and Round.Server paths are covered. |
| `[x]` | Transactional transition | `Store.File`, `Store.Memory`, and `Store.SQLite` enforce expected version, idempotent transition IDs, and event append in one accepted store mutation; SQLite uses a database transaction. |
| `[x]` | Durable event cursor | `Store.File` and `Store.SQLite` persist per-round `seq` event cursors and support replay from `after_seq`. |
| `[x]` | Restart recovery | Breech loads incomplete durable-store rounds on startup; clean queued rounds resume, awaiting-safety rounds remain paused, journal-proven retryable partial snapshots resume from stored state, scheduler-owned daemon starts use the persisted queued snapshot as `Round.Server.recover_sync/3` input, and scheduler-owned safety approval/rejection resumes through `Round.Server`; file-store and SQLite tests cover the durable recovery contract. |
| `[x]` | Interrupted-shot reconciliation | Breech durable-store recovery classifies interrupted shots as retryable no-tool, retryable read-only, retryable idempotent-write with key, or manual reconciliation with journal summaries. `Round.Server.recover_sync/3` applies the same reconciliation before scheduler resume, Breech uses it for scheduler-owned recovered rounds, and file-store plus SQLite startup tests cover ambiguous journal reconciliation. |

### Phase 5 - Production Interfaces

| Status | Feature | Acceptance |
| --- | --- | --- |
| `[x]` | HTTP API | `API.Router` handles local health, round create/list/show/cancel, safety approve/reject, event replay, audit replay, webhook triggers, and metrics with request body limits; `API.Server` exposes it through a local HTTP/1.1 listener. |
| `[x]` | HTTP standards | API router emits `application/problem+json` errors shaped for RFC 9457, RFC 6750 bearer auth with `WWW-Authenticate` challenges for mutating control routes, query-token rejection, RFC 9333 rate-limit headers, and `Retry-After` for configured 429 responses. `API.Server` adds fixed-length HTTP/1.1 framing, `Content-Length`, `Connection: close`, request header/body limits, and remote-bind auth plus TLS/proxy enforcement. |
| `[x]` | OpenAPI contract | The current pure HTTP API is described by `Twelvgaige.API.OpenAPI` and served at `GET /api/v1/openapi.json` as OpenAPI 3.1 JSON. |
| `[x]` | Event stream API | HTTP router replays round events and audit records from `after_seq` as JSON arrays, NDJSON with `format=ndjson`, SSE with `format=sse`, CloudEvents batch JSON with `format=cloudevents`, or tamper-evident SHA-256 checkpoint JSON with `format=checkpoint`; round events also support bounded follow via `follow=true&timeout_ms=<ms>` and bounded terminal follow with `until_terminal=true`. Responses include bounded-replay headers and a configurable byte cap. The concrete HTTP listener additionally supports bounded `stream=true` chunked push for SSE and NDJSON round events with cursor advancement, heartbeats, stream-client caps, send timeouts, and terminal/limit/deadline stops. |
| `[x]` | Event standards | NDJSON framing helper and tests ensure one RFC 8259 JSON object per LF-terminated line; SSE framing uses standard `id:`, `event:`, `data:`, and heartbeat comment records; CloudEvents batch mapping uses specversion 1.0 envelopes with stable IDs, source, type, time, datacontenttype, and data. |
| `[x]` | Webhook triggers | Pure API router supports opt-in `POST /api/v1/webhooks/:webhook_id` triggers with 1 MiB default body limit, JSON payload validation, HMAC-SHA256 signature verification, timestamp freshness, nonce replay protection, OpenAPI coverage, and `Breech.start_round/3` execution. |
| `[x]` | Metrics endpoint | `GET /api/v1/metrics` returns Prometheus text exposition for daemon, store, and resource limiter state through both the pure router and the local HTTP listener. |
| `[x]` | Structured logs | `Twelvgaige.Log.JSON` formats JSON-line log records with required fields, error expansion, raw prompt/tool-output omission, and redaction before encoding; `Twelvgaige.Log.emit/5` is wired into Breech daemon lifecycle and round events while remaining quiet unless JSON logging is enabled. |
| `[x]` | Metric contract | `Twelvgaige.Metrics` collects low-cardinality runtime counters and histograms for rounds, shots, LLM calls/tokens, tool calls/output bytes, queued resource waits, and safety decisions; Prometheus exposes them alongside daemon, store, retained event/byte, and resource limiter gauges. |
| `[x]` | Provider transport | Provider calls validate trusted runtime URLs before transport, deny userinfo and unsafe schemes, constrain cloud/private and Ollama/remote destinations by default, require explicit opt-in plus public DNS validation for cloud endpoint overrides, clamp timeouts, use fake transports in normal tests, configure TLS verification for the default transport, and preserve provider retry hints. |
| `[x]` | Provider rate limiting | Shot execution passes round/shot context to `Twelvgaige.LLM`; provider calls acquire and release `:llm_call` permits when a limiter is configured, and saturated limits return retryable `:resource_queue_timeout` before transport. |
| `[x]` | Token/message budget enforcement | `Shot.Executor` enforces max LLM message bytes before provider calls and after tool-result expansion, and rejects provider responses whose reported `total_tokens` exceeds the active shot token budget. |
| `[x]` | HTTP tool network policy | `http_get` enforces scheme, userinfo, redirect, explicit host allowlist, private host/IP denial, DNS resolution with every resolved IP checked, timeout, fake transport, and byte policies. |
| `[x]` | Resource metrics | Limiter snapshots and Prometheus output expose active permits, configured limits, live queue depth, and denial counters by resource kind/reason/profile. |
| `[x]` | Scheduler | Optional `Twelvgaige.Scheduler` GenServer runs configured interval and five-field cron jobs through `Breech.start_round/3`; Application starts it only when `:scheduler_jobs` is configured. Cron support covers the portable UTC subset `*`, numbers, comma lists, ranges, and stepped ranges with deterministic parser/next-run tests. |
| `[x]` | Native Mix release bundle | `mix.exs` defines the `twelvgaige_native` release with included ERTS, Unix and Windows lifecycle scripts, tarball generation, and generated product CLI wrappers. `rel/` and generated release overlay paths are ignored so release scaffolding and generated wrappers are not checked in accidentally. `bin/twelvgaige` delegates to `Twelvgaige.CLI.Release.main/0` through the release lifecycle script; Windows artifacts include `bin\twelvgaige.bat` and `bin\twelvgaige.ps1`. |
| `[x]` | Burrito single-file executable | `mix.exs` defines the `twelvgaige` Burrito release with targets `macos_silicon`, `linux`, `linux_arm64`, and `windows`. Target-specific `BURRITO_CUSTOM_ERTS_<TARGET>` overrides allow host builds to use a matching local ERTS when Burrito's archive mirror lacks the local OTP patch release. `Twelvgaige.Application` starts the normal supervision tree, then `Twelvgaige.CLI.Burrito` detects Burrito runtime, reads `Burrito.Util.Args.argv/0`, runs `Twelvgaige.CLI.Main.main_started/1`, and halts with the CLI result. |
| `[x]` | GitHub automation | `Makefile` owns CI and packaging commands. GitHub workflows cover CI, smoke-tested package artifacts, multi-platform Burrito build artifacts, build metadata capture, SHA-256 checksum generation, and tag/manual release publishing. Package smoke validates, normalizes, converts, and runs YAML, JSON, and TOML traphouse shells through the real CLI. Every reusable workflow action is pinned to a full commit SHA. E2E jobs remain deferred. |

### Phase 6 - Shell Authoring Formats

Goal: support JSON shells and add developer-friendly authoring formats without
fragmenting runtime semantics.

| Status | Feature | Acceptance |
| --- | --- | --- |
| `[x]` | Parser dispatch boundary | YAML parsing moves behind a format parser module; loader extension dispatch and public error shape remain stable. |
| `[x]` | Canonical shell map | YAML, JSON, and TOML produce ordinary string-key maps before shell construction; any future generated shell output must join the same path. |
| `[x]` | JSON workflow shells | `.json` workflow shells validate, load, run, reload through the daemon shell cache, and normalize equivalently to YAML fixtures. |
| `[x]` | JSON agent shells | `.json` agent shells load explicitly and through adjacent `agents/` discovery, including duplicate-ID checks across mixed formats. |
| `[x]` | TOML workflow shells | `.toml` workflow shells parse through documented TOML 1.0 mapping rules and normalize equivalently to YAML fixtures. |
| `[x]` | TOML agent shells | `.toml` agent shells parse through the same loader and participate in mixed-format loadout resolution. |
| `[x]` | Programmatic-shell RFC | Starlark/CUE-style generated shells remain disabled until an RFC proves deterministic sandboxing, bounded evaluation, denied host access, and manifest hashing. |
| `[x]` | Format conversion UX | `shell normalize` and `shell convert` produce canonical output that immediately validates. |
| `[x]` | Docs and examples | Usage, concepts, traphouse examples, and format guidance describe shells as format-neutral definitions. |
| `[x]` | Package smoke coverage | The shared Makefile smoke target validates, normalizes, converts, and runs traphouse YAML, JSON, and TOML shells for escript, native release, and Burrito artifacts. |

## 28. Resolved Decisions And Release Follow-Ups

Resolved implementation decisions:

- YAML shell loading uses `yamerl`.
- JSON and TOML shell loading are implemented authoring-format additions; they do not introduce separate runtime semantics.
- Arbitrary Elixir/JavaScript/Python workflow DSLs are rejected for untrusted shells because they execute host code. Programmatic authoring, if accepted, must be sandboxed and disabled by default.
- The CLI remains project-owned and lightweight; no CLI framework is required yet.
- The source-built development CLI remains `twelvgaige` through `mix escript.build`.
- The native bundle is a Mix release tarball named `twelvgaige_native`; the product CLI wrapper inside the release remains `bin/twelvgaige`.
- The single-file executable is built through Burrito from the `twelvgaige` release and writes artifacts to `burrito_out/twelvgaige_<target>`.
- Burrito CI pins OTP to `28.4` until Burrito's ERTS archive mirror publishes newer OTP patch releases; local host builds can use `BURRITO_CUSTOM_ERTS_<TARGET>` when the target ERTS matches the host.
- CI, build, and release automation must call Makefile targets rather than duplicating Mix command logic inside workflow YAML.
- Burrito binaries are the primary multi-platform GitHub release artifacts; Mix release tarballs remain target-specific secondary artifacts.
- Tests use hand-written fakes, injected transports, and contract modules instead of Mox.
- Provider support covers OpenAI and Ollama through adapter fixtures and explicit provider IDs.
- Provider live smoke tests use ExUnit tags and environment opt-in through the
  Makefile; normal tests remain offline.
- k3d is the preferred disposable local Kubernetes target for live smoke tests. Existing kind, minikube, or dev-cluster contexts can still be used by setting `TWELVGAIGE_K8S_CONTEXT`.
- ReAct tool calls execute serially inside one shot attempt. Parallel read-only tool calls are a future optimization, not a correctness requirement.
- Durable persistence keeps redacted snapshots, events, audit records, attempt
  journals, and tool journals by default. File-backed stores, SQLite sidecars,
  and JSON logs use private POSIX modes where supported. High-sensitivity mode
  summarizes prompt, message, and tool payloads. Checkpoint exports are
  tamper-evident after export but do not make the live store immutable. Default
  file and SQLite stores are unencrypted; use OS or volume encryption. The
  optional `Store.SQLiteEncrypted` is fail-closed, requires a key, verifies
  actual SQLCipher support before creating the target, and is selected by
  `TWELVGAIGE_STORE_SQLCIPHER` plus `TWELVGAIGE_STORE_SQLCIPHER_KEY`.
  Key-manager backends include test, explicit insecure env/file, macOS
  Keychain, Windows DPAPI, and desktop Linux Secret Service implementations.
  Platform qualification is stated separately from implementation. Backup and
  restore, plaintext-to-SQLCipher migration, and backup-gated DEK-envelope
  rewrap are implemented; full database-page rekey remains separate work.
- Arbitrary shell execution remains deferred. Structured tools construct argv internally.

Remaining release follow-ups:

- `[!]` Verify native Windows named-pipe listener I/O on Windows. Windows defaults to authenticated loopback TCP until this is proven.
- `[ ]` Measure `minimal`, `laptop`, and `workstation` profile defaults on common MacBook and Windows laptop hardware.
- `[ ]` Decide whether the default `queue_timeout` should stay disabled or receive a conservative laptop default after measurement.
- `[ ]` Validate durable retention defaults with real local workloads, especially retained bytes, retained terminal rounds, and cleanup cadence.
- `[ ]` Decide whether cleanup must require an audit export checkpoint before terminal round records are removed.
- `[ ]` Build and smoke-test Mix release bundles on Linux and Windows CI runners. Mix releases are target-specific; the macOS bundle does not validate Linux or Windows runtime behavior.
- `[~]` Build and smoke-test Burrito binaries on supported runners with Zig `0.15.2`, `xz`, and `7z`/`7zz` for Windows targets. macOS Apple Silicon host smoke is verified locally with Homebrew `zig@0.15` and `BURRITO_CUSTOM_ERTS_MACOS_SILICON`; Linux, Linux ARM64, and Windows executable artifacts still need runner-native smoke coverage.

## 29. Implementation Rules

- Prefer pure modules for compile, graph, readiness, condition, retry, and parsing logic.
- Keep side effects in OTP processes, provider adapters, tool adapters, and store modules.
- Keep external effects behind behaviours or explicit adapter modules so normal tests can replace them.
- Keep shell authoring formats as parser inputs only. They must normalize to the same shell map before validation and must not add runtime behavior.
- Do not enable programmatic shell authoring until sandboxing, resource bounds, and host-access denial are proven by tests and accepted in the spec.
- Do not use arbitrary sleeps in normal tests; use fake clocks, direct messages, controlled processes, or bounded `assert_receive`.
- Do not let a shot task call `Round.Server` to advance state. It returns a result to the task owner.
- Use non-linked tasks for shots.
- Correlate every async message by ref and attempt.
- Use transition IDs and expected state versions for durable transition commits.
- Use explicit round events or PubSub for watch streams; do not build watch on telemetry.
- Avoid adding destructive tools until persistence, audit, safety, and attempt/tool journaling are implemented.
- Avoid multi-node execution until single-node recovery is correct.
- Do not persist or log raw secrets.
- Do not infer provider from model string. Use explicit provider IDs.
- Do not call real LLM providers in normal tests.
- Do not add high-cardinality metric labels such as round ID, shot ID, file path, or raw error message.
- Do not use arbitrary shell command strings as a tool API.
- Update the feature tracking tables when implementation status changes.
