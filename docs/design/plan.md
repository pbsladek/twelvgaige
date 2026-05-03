# Twelvgaige Plan

> Infrastructure-grade agent orchestration in Elixir, exposed through a pragmatic CLI.
> The BEAM owns the action. LLMs take assigned shots. Policies decide when to chamber, fire, retry, safe, or eject a round.

## 1. Reviewed Direction

The original draft has a strong core: deterministic workflow control belongs in OTP, not in the LLM context window. That remains the thesis for Twelvgaige.

This review makes several corrections before the project moves into `spec.md`:

- Use `twelvgaige` for the CLI and `Twelvgaige` for Elixir modules.
- Treat the CLI as the primary product surface, with a daemon behind it only when the workflow engine needs long-running execution.
- Treat Phase 1 as foreground-only execution. Detached rounds, cross-command `show/watch/approve/cancel`, and durable async behavior start with the daemon.
- Default to a laptop resource profile. Multiple agents are admitted through explicit concurrency and byte-budget gates, not spawned without bounds.
- Use shotgun terminology as project vocabulary without letting the metaphor obscure the engineering model.
- Narrow the first implementation phase to a working local CLI plus in-memory workflow engine before daemonization, persistence, HTTP, scheduler, and production hardening.
- Correct optimistic OTP claims: GenServer state is useful hot state, but durable recovery only exists after checkpointing to a store.
- Correct recovery semantics: after a VM restart, in-flight step processes are gone. They cannot be re-monitored. They must be reconciled from durable state and retried, skipped, or marked interrupted according to explicit policy.
- Require immutable run manifests, transition IDs, structured outputs, and attempt/tool journals before claiming durable recovery for side-effect-capable workflows.
- Make telemetry non-blocking. State and audit writes can be transactional; telemetry emission should not be required for a transition to succeed.
- Treat shell and infrastructure tools as hostile by default. An allowlist of command names is insufficient without argv parsing, environment control, timeout control, cwd control, output limits, secret redaction, and explicit destructive-action policy.
- Treat retained prompts, tool output, traces, and round history as resource risks. They must have caps from day one.

## 2. Product Thesis

Most agent orchestration systems let the LLM drive the control flow. That works for demos and small personal assistants. It fails for unattended infrastructure work because:

- A model can hallucinate routing decisions.
- State can disappear into prompt history.
- Tool calls can become unauditable side effects.
- Retries can happen at unsafe times.
- Crash recovery is usually an application convention rather than a runtime property.

Twelvgaige inverts that model. OTP owns the action:

- Workflow order is compiled from definitions.
- Step readiness is deterministic.
- Retries are policy-driven.
- Timeouts are enforced by the runtime.
- Tool permissions are checked outside the model.
- Human approval is a state transition, not a blocking conversation.
- Every meaningful state change is persisted and auditable once persistence lands.

LLMs still do useful work: summarization, investigation, analysis, response drafting, structured data extraction, and bounded tool selection inside a single step. They do not decide the whole shot pattern.

## 3. Shotgun Vocabulary

Twelvgaige should use shotgun terminology consistently where it improves the CLI and mental model.

| Term | Meaning |
| --- | --- |
| `round` | One workflow run. |
| `shell` | A workflow or agent definition file. |
| `shot` | One executable workflow step. |
| `pattern` | The compiled workflow DAG and its fan-out shape. |
| `loadout` | The agent model, prompt, tool permissions, and limits for a shot. |
| `choke` | A policy constraint that narrows behavior: timeout, retry, token budget, tool scope, approval rule. |
| `safety` | A hard gate that prevents unsafe execution, usually human approval or policy denial. |
| `buckshot` | Parallel fan-out across multiple independent shots. |
| `slug` | A single focused step that should produce one precise structured output. |
| `breech` | The local daemon control plane and IPC boundary. |
| `eject` | Cancel, halt, or finalize a failed round. |

The CLI should prefer clear operational language over forced metaphor. For example, `twelvgaige round run` is acceptable; `twelvgaige eject` alone is too vague. Prefer explicit commands like `twelvgaige round cancel`.

## 4. Target Users

Primary users:

- Platform engineers
- DevOps and SRE teams
- Infrastructure-adjacent developers
- Teams that need agent-assisted workflows to run unattended, repeatably, and with audit trails

Non-goals for the first version:

- Personal assistant chat UX
- Autonomous agent swarms
- Visual workflow builder
- Multi-tenant SaaS control plane
- General-purpose remote shell automation

## 5. Architecture Overview

Twelvgaige should be built as an OTP application with a CLI-first control surface.

Early versions run foreground-only in-process:

```text
twelvgaige CLI
  |
  | starts local OTP app
  v
Twelvgaige.Application
  |
  +-- Store.Memory
  +-- Shell.Cache
  +-- Tool.Catalog
  +-- ResourceLimiter
  +-- RoundSupervisor
       |
       +-- RoundRunSupervisor
            |
            +-- RoundServer
            +-- ShotSupervisor
```

Later versions add a daemon:

```text
twelvgaige CLI
  |
  | Unix socket or local HTTP
  v
Twelvgaige Breech Daemon
  |
  +-- CommandRouter
  +-- RoundSupervisor
  +-- DurableStore
  +-- RoundEventLog
  +-- AuditLog
  +-- Optional HTTP API
```

The daemon should not be required before the engine is useful. A local single-command path is important for fast iteration and testability, but it must not pretend to leave work running after the CLI VM exits.

## 6. OTP Topology

Recommended supervision tree:

```text
Twelvgaige.Application
+-- Twelvgaige.Telemetry
+-- Twelvgaige.Repo                         # Added when persistence lands
+-- Twelvgaige.Registry.Round               # Active round process lookup only
+-- Twelvgaige.Store.Memory                 # App-level in-VM state/event store
+-- Twelvgaige.Shell.Cache                  # Workflow and agent shell definitions
+-- Twelvgaige.Tool.Catalog                 # Available tools
+-- Twelvgaige.ResourceLimiter              # Local concurrency and byte-budget gates
+-- Twelvgaige.LLM.Supervisor               # Provider clients and rate limiters
+-- Twelvgaige.RoundSupervisor              # DynamicSupervisor
    +-- Twelvgaige.RoundRunSupervisor       # One per round
        +-- Twelvgaige.RoundServer          # Round state machine
        +-- Twelvgaige.ShotSupervisor       # Task.Supervisor or DynamicSupervisor
```

Design notes:

- Use one `RoundRunSupervisor` per round so the round server, shot supervisor, timers, and future per-round resources have a clear lifecycle.
- Use `:one_for_all` inside each `RoundRunSupervisor`. If the coordinator or shot supervisor crashes, all in-flight shot tasks are killed and the round restarts from the app-level memory store in Phase 1 or durable store in Phase 4.
- Use `RoundServer` as the state machine and coordinator.
- Use `Task.Supervisor.async_nolink/2` for simple shot execution so shot crashes are reported to `RoundServer` as monitored task failures instead of crashing the coordinator. Move to per-shot GenServers only if shots need long-lived protocol state.
- Use OTP `Registry` only for active round process lookup. Definition caches and tool catalogs are separate modules.
- Use `ResourceLimiter` for admission control. Ready shots queue when laptop profile limits are saturated instead of spawning more tasks.
- Keep LLM provider calls behind a behaviour so tests can run without network access.
- Keep tool execution behind a behaviour so destructive tools can be tested with safe fakes.

## 7. Core State Machine

Round lifecycle:

```text
chambered -> firing -> {complete | failed | halted | cancelled}
              |
              +-- awaiting_safety
              +-- awaiting_reconciliation
              +-- blocked_on_store
```

Shot lifecycle:

```text
pending -> running -> {complete | failed | retrying | interrupted | awaiting_reconciliation}
pending -> skipped
pending -> awaiting_safety -> {complete | failed}
```

`ready` is derived by the pattern evaluator; it is not a stored shot status.

State transition rule:

- In phase 1, transitions update the app-level in-VM memory store and emit telemetry.
- Once persistence is introduced, durable state, round event, and audit writes must happen before a transition is acknowledged.
- Durable transition commits use a transition ID and expected round version so retrying a failed commit is idempotent.
- Telemetry emission remains best-effort and should not block the transition.
- Audit events should be written in the same database transaction as the state transition where practical.

## 8. Workflow Shells

Workflow definitions are declarative shells. They define the pattern. The LLM does not.

Example:

```yaml
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
  cluster: string
  namespace: string
  alert_details: object

shots:
  - id: gather_cluster_state
    agent: k8s_inspector
    kind: slug
    description: Collect pod status, events, and recent logs.
    timeout: 2m
    tools: [kubectl_get, kubectl_describe, kubectl_logs]
    output_schema:
      pods: array
      events: array
      resource_pressure: boolean
    retry:
      max_attempts: 3
      backoff: exponential
      base_delay: 5s

  - id: analyze_root_cause
    agent: incident_analyst
    kind: slug
    depends_on: [gather_cluster_state]
    timeout: 3m
    tools: []
    output_schema:
      root_cause: string
      confidence: number
      recommended_actions: array
      requires_safety: boolean

  - id: safety_check
    kind: safety
    depends_on: [analyze_root_cause]
    condition: "shots.analyze_root_cause.requires_safety == true"
    timeout: 30m

  # Future phase example: write-capable remediation requires persistence,
  # audit, safety approval, and attempt/tool journaling before it is enabled.
  # - id: apply_remediation
  #   agent: k8s_remediator
  #   kind: slug
  #   depends_on: [analyze_root_cause, safety_check]
  #   timeout: 10m
  #   tools: [kubectl_apply, kubectl_rollout_restart, kubectl_scale]
  #   choke:
  #     tool_safety: idempotent_write
  #     audit: all
  #   output_schema:
  #     actions_taken: array
  #     success: boolean
```

`spec.md` locks the external shell field as `shots`. Documentation should define a shot as "one workflow step" on first use. YAML, JSON, and TOML are implemented today; any gated programmatic authoring format must parse into the same normalized shell map before validation.

## 9. Agent Shells

Agent definitions describe a loadout.

```yaml
id: k8s_inspector
name: Kubernetes Inspector
provider: anthropic
model: claude-opus-4-20250514
system_prompt: |
  You inspect Kubernetes infrastructure. Report observed state clearly.
  Do not recommend actions.

tools:
  allowed: [kubectl_get, kubectl_describe, kubectl_logs, kubectl_events]
  denied: [kubectl_delete, kubectl_apply, kubectl_exec]

choke:
  token_budget: 4096
  max_iterations: 6
  timeout: 2m

memory:
  type: none
```

Agent shells must not store secrets. Provider keys and infrastructure credentials resolve at runtime from environment variables or a configured secret backend. Provider selection is explicit through `provider`, not inferred from the model string.

## 10. Round Engine

The round engine compiles workflow shells into a pattern before execution.

Compile-time validation:

- Unique shot IDs
- Shot IDs do not contain dots, keeping condition paths unambiguous
- All dependencies exist
- No dependency cycles
- Referenced agents exist
- Referenced tools exist
- Conditions parse successfully
- Retry and timeout values are valid
- Tool safety level is compatible with the shot choke
- Output schema is present for LLM shots and fits the supported schema subset
- Round policy values are explicit and valid

Runtime evaluation:

- A shot becomes ready when all dependencies are complete or explicitly skipped by condition.
- Ready shots fire in parallel when their dependencies allow it.
- Ready shots still require resource permits. If the laptop profile is saturated, they remain pending until capacity is released.
- Shot output must pass schema validation before dependent shots can fire.
- Failed shots follow their retry choke.
- Non-retryable failures halt or fail the round according to round policy.
- Safety shots move the round into `awaiting_safety` until the specific safety shot is approved or rejected.
- `policy.safety_scope` decides whether a safety shot pauses the whole round or only blocks dependent descendants.

## 11. LLM Execution

All LLM providers implement a common behaviour:

```elixir
defmodule Twelvgaige.LLM.Provider do
  @callback provider_id() :: String.t()
  @callback capabilities(config :: map()) :: Twelvgaige.LLM.Capabilities.t()
  @callback complete(model :: String.t(), messages :: list(map()), opts :: keyword()) ::
              {:ok, Twelvgaige.LLM.Response.t()} | {:error, term()}
end
```

First-class provider targets:

- `mock` for deterministic tests
- `anthropic`
- `openai`
- `gemini`
- `ollama`

Execution constraints:

- Provider calls are bounded by timeout.
- Provider responses are normalized before the engine sees them.
- Tool calls are permission-checked before execution.
- ReAct loops have a hard iteration limit.
- Token budgets are enforced before provider calls and checked after responses when usage data is available.
- All provider errors are classified into retryable, non-retryable, and policy-denied categories.
- Provider capability checks decide whether native tools, native structured output, streaming, and token usage are available.
- Ollama is treated as a local runtime and defaults to lower laptop concurrency than hosted providers.

The current implementation supports a mock provider plus fixture-tested adapters for Anthropic, OpenAI, Gemini, and Ollama. Normal tests must not call live providers.

## 12. Local Resource Model

Twelvgaige must run comfortably on ordinary MacBooks and Windows laptops while other apps are open. The default profile is `laptop`.

Approximate planning targets with remote LLM providers:

| Scenario | Expected memory | Expected CPU |
| --- | ---: | --- |
| CLI start or idle daemon | 50-150 MiB RSS | near idle after startup |
| One foreground round, one running shot | 80-200 MiB RSS | low, with short parse/tool spikes |
| Laptop default, four running shots | 150-400 MiB RSS | mostly low if tools are light |
| Heavy tool output near caps | 300-700 MiB RSS | depends on external tools |

These targets exclude local LLM model hosting. Running local models can require multiple GB of RAM or VRAM and is not part of the default design.

Laptop profile defaults:

- Active rounds: 1
- Running shots globally: 4
- Running shots per round: 3
- LLM calls globally: 4
- Tool calls globally: 4
- Tool calls per shot: 1
- Tool output per call: 256 KiB
- Tool output per shot: 1 MiB
- LLM message bytes per shot attempt: 2 MiB
- Stored trace bytes per shot attempt: 512 KiB
- Retained store byte watermark: 512 MiB

The other built-in profiles are `minimal`, `workstation`, and `server`. A run
may request a profile with `--profile`; a local daemon may clamp that request
with its configured maximum profile.

When limits are reached, work queues. It does not spawn additional shot tasks, LLM calls, or tool calls.

Resource limiter rules:

- Permits are explicit tokens tied to owner pid, round ID, shot ID, and attempt.
- Shot admission is all-or-nothing for global and per-round shot permits.
- Queue fairness is weighted round-robin across rounds and FIFO within a round.
- Owner death, cancellation, timeout, or task-start failure releases permits and removes waiters.
- Shot execution timeout starts after task start; round timeout includes queued time.
- Optional `queue_timeout` can fail a shot that waits too long for resources.
- Prompt assembly, tool execution, trace collection, event logs, and memory/file/SQLite stores each enforce their own byte caps or retention caps and expose accounting through status and metrics.

## 13. Tool System

Tool behaviour:

```elixir
defmodule Twelvgaige.Tool do
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback safety_level() :: :read_only | :idempotent_write | :destructive | :irreversible
  @callback idempotency() :: Twelvgaige.Tool.Idempotency.t()
  @callback execute(input :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
end
```

Safety levels are ordered explicitly: `read_only < idempotent_write < destructive < irreversible`. Non-read-only tools must declare idempotency and reconciliation metadata; a boolean is not enough to decide retry safety.

Tool execution rules:

- A shot can only call tools listed in its loadout.
- A tool call must validate against the tool input schema.
- Tool results must be bounded in size.
- Tool output must be sanitized before being inserted into later LLM messages.
- Destructive and irreversible tools require explicit policy and usually safety approval.
- Side-effect-capable tools require durable attempt/tool intent journaling before execution once persistence lands.
- Tool calls should emit audit events with redacted inputs and outputs.

Initial built-in tools should be conservative:

- `http_get`
- `http_post`
- `git_commit`
- `shell_read`
- `kubectl_get`
- `kubectl_describe`
- `kubectl_logs`
- `kubectl_events`
- `kubectl_apply`
- `kubectl_scale`
- `kubectl_rollout_restart`
- `kubectl_delete`
- `kubectl_exec`

Kubernetes Phase 2 support is structured:

- Tools use local `kubectl` through internally constructed argv only.
- `context` is required.
- `namespace` is required unless cluster scope is explicitly allowed by policy.
- No arbitrary kubectl args are accepted from the LLM.
- `kubectl_get` prefers JSON output.
- `kubectl_logs` enforces `tail_lines`, byte caps, and redaction before storage or LLM insertion.
- `kubectl_apply` is safety level `:idempotent_write`, requires `confirm=true`, and accepts only YAML/JSON manifest files below a trusted root.
- `kubectl_scale` is safety level `:idempotent_write`.
- `kubectl_rollout_restart` and `kubectl_delete` are safety level `:destructive` and require `confirm=true`.
- `kubectl_exec` is safety level `:irreversible`, requires `confirm=true`, requires trusted runtime `allow_kubectl_exec: true`, targets named namespaced pods only, accepts structured argv only, and blocks shell interpreters unless trusted runtime policy also sets `allow_shell: true`.
- Write tools require explicit namespaced targets and deny cluster-scope writes.
- Kubernetes audit events record context, namespace, verb, resource, name, selector, redacted exec argv when applicable, duration, exit status, and truncation flag, never kubeconfig contents or raw logs.
- `http_post` is safety level `:destructive`, requires `confirm=true`, applies the same destination checks as `http_get`, rejects sensitive LLM-supplied headers, accepts trusted runtime headers through tool options, bounds request/response bytes, and redacts response bodies.
- `git_commit` is safety level `:destructive`, requires `confirm=true`, accepts only explicit regular files under a trusted root, rejects root escapes, directories, and symlink paths, and constructs fixed `git -C <root> status/add/commit` argv.

Delay this until the extra policy surface is designed:

- arbitrary `shell_exec`; structured tools are the supported execution model.

`kubectl_exec` is present in the catalog but remains disabled by default through runtime policy.

## 14. Security Model

Security should be designed before useful destructive tools exist.

Minimum controls:

- No arbitrary command strings. Tools receive structured inputs and construct argv internally.
- Command argv, cwd, env, timeout, output limit, and stderr handling are explicit.
- Environment variables passed to tools are allowlisted.
- Secrets are redacted from logs, audit events, telemetry metadata, and LLM messages.
- Prompt-injection-prone tool output is tagged as untrusted data.
- Safety approval is required before destructive or irreversible actions unless explicitly disabled in a local development profile.
- Each tool declares a safety level and idempotency.
- Write-capable tools declare idempotency metadata, reconciliation strategy, and side-effect phase.
- Retrying non-idempotent tools is denied unless the tool provides its own reconciliation key.

## 15. Persistence And Recovery

Persistence should not be part of phase 1, but the engine should be designed so it can be added cleanly.

Phase 1 still uses an app-level in-VM memory store so a per-round supervisor restart can recover coordinator state inside the same BEAM. This is not durable and disappears when the CLI process exits.

Durable tables:

- `round_runs`
- `round_manifests`
- `shot_runs`
- `shot_attempts`
- `tool_calls`
- `round_events`
- `audit_events`
- `workflow_shells`
- `agent_shells`

Each round gets an immutable run manifest at creation time. The manifest stores the compiled pattern, normalized shot definitions, effective loadouts, parsed conditions, schema hashes, redacted shell snapshots, and tool policy snapshot. Recovery must use this manifest, not current files on disk.

Recovery rules:

- On daemon restart, load incomplete rounds from the durable store.
- Any shot marked `running` at the time of process death is no longer running.
- Completed shot outputs needed by conditions or dependents are stored as redacted-but-structured data.
- The engine must reconcile each interrupted shot according to policy:
  - retry if retryable and idempotent enough
  - mark failed if policy says failure is correct
  - require manual reconciliation if unsafe or ambiguous
- Awaiting-safety rounds remain paused.
- Completed shot outputs are reused if their schema version still matches.
- Transition commits use `transition_id` and expected round version; retrying a failed commit must be idempotent.
- Non-read-only tool attempts must durably record attempt start, tool intent, and idempotency/reconciliation metadata before execution.

Storage rules:

- The store persists a durable round snapshot, not the live `Round.State` struct.
- Durable snapshots must never contain pids, monitor refs, timeout refs, queued waiters, open ports, or process-local pending transitions.
- `round_events` need a per-round monotonic sequence so `round watch` and API event streams can replay from `after_seq`.
- `Store.File` is a Phase 4 bootstrap backend that persists the existing store contract atomically to one local file. It is used to prove recovery semantics before the SQL path becomes the default.
- `Store.SQLite` is the target local store. It persists the same store contract in normalized SQLite tables with foreign keys, WAL mode, bounded busy timeout, conservative write concurrency, queryable round columns for shell identity/timing/errors, and explicit retention cleanup.
- If the store is unavailable at daemon start, Breech refuses work. If a transition commit fails during a round, that round blocks on store and fires no dependent shots until the same transition ID commits or recovery reconciles from the last committed snapshot.

Postgres can be added for multi-node or production use after the single-node model is stable.

## 16. CLI Surface

The CLI should expose the domain model clearly.

Preferred command groups:

```bash
# Phase 1 foreground usage
twelvgaige shell validate path/to/workflow.yaml
twelvgaige shell normalize path/to/workflow.yaml --format json
twelvgaige shell convert path/to/workflow.yaml --to toml --output path/to/workflow.toml
twelvgaige round run path/to/workflow.yaml

# Daemon-backed shell cache usage
twelvgaige shell validate path/to/workflow.yaml
twelvgaige shell normalize path/to/workflow.toml
twelvgaige shell reload path/to/workflows
twelvgaige shell list
twelvgaige shell show k8s_incident_response

twelvgaige round run k8s_incident_response --input input.json --detach
twelvgaige round list
twelvgaige round show <round-id>
twelvgaige round watch <round-id>
twelvgaige round audit <round-id>
twelvgaige round approve <round-id> --shot safety_check --reason "reviewed"
twelvgaige round reject <round-id> --shot safety_check --reason "too risky"
twelvgaige round cancel <round-id>
twelvgaige round retry <round-id> --shot apply_remediation

twelvgaige agent list
twelvgaige agent show k8s_inspector
twelvgaige agent dry-run k8s_inspector --input input.json

twelvgaige tool list
twelvgaige tool show kubectl_get
twelvgaige tool test kubectl_get --input input.json

twelvgaige status
```

Phase 1 `round run` is foreground-only. Detached run, `show`, `list`, `watch`, approval, rejection, cancellation, and cross-command retry require the Breech daemon.

`--profile` may select `minimal`, `laptop`, `workstation`, or `server`. If omitted, `laptop` is used.

All read commands should support:

```bash
--format human
--format json
```

Exit codes:

- `0` success
- `1` round failed
- `2` round halted by safety rejection
- `3` timeout
- `4` invalid input or invalid shell
- `5` daemon unavailable
- `6` round, shell, agent, tool, or definition not found
- `7` policy denied
- `8` internal, crash, store, IPC response, or otherwise unclassified control-plane error

## 17. API Surface

The HTTP API is useful but should not precede the CLI and core engine.

Breech networking defaults to local-only. The CLI talks to the daemon through Unix domain sockets on macOS/Linux and authenticated loopback TCP on Windows by default. Windows named-pipe addresses and injected pipe transport tests exist, but native Windows named-pipe listener I/O remains opt-in until it is verified on Windows. Remote HTTP binding is opt-in and requires bearer-token auth or mTLS behind a trusted proxy.

Candidate endpoints:

```text
POST   /api/v1/rounds
GET    /api/v1/rounds
GET    /api/v1/rounds/:id
DELETE /api/v1/rounds/:id
POST   /api/v1/rounds/:id/safety/:shot_id/approve
POST   /api/v1/rounds/:id/safety/:shot_id/reject
POST   /api/v1/rounds/:id/retry
GET    /api/v1/rounds/:id/events?after_seq=<seq>&format=<format>&follow=<bool>&until_terminal=<bool>
GET    /api/v1/audit/:round_id
GET    /api/v1/health
GET    /api/v1/metrics
```

Use SSE or NDJSON for event streams. Avoid WebSockets unless there is a concrete need.

Event streams come from explicit round events, not telemetry.

Networking safety rules:

- HTTP API binds to `127.0.0.1` by default.
- `/metrics` and `/health` must not expose secrets; remote metrics requires auth.
- Provider base URLs, proxies, API keys, and auth headers come only from trusted runtime config, never from workflow or agent shells.
- Provider transport has separate connect/read/total timeouts and preserves retry hints for the round retry policy.
- `http_get` is treated as an SSRF surface: schemes, redirects, DNS resolution, private IP ranges, response bytes, and timeouts are policy-controlled.

## 18. Standards And RFC Targets

Twelvgaige should follow external standards where they reduce ambiguity:

- JSON uses RFC 8259.
- Timestamps use RFC 3339.
- Workflow and agent shells target YAML 1.2.
- Planned JSON workflow and agent shells use RFC 8259 and the same normalized shell map as YAML.
- TOML workflow and agent shells target TOML 1.0.0 and remain declarative.
- Any future programmatic shell language must be pinned by an RFC, disabled by default, sandboxed, deterministic, and limited to generating declarative shells.
- Input/output schemas target a declared JSON Schema 2020-12 subset.
- URI parsing and normalization follow RFC 3986 before network policy checks.
- HTTP API behavior follows RFC 9110 and RFC 9112.
- HTTP errors use RFC 9457 Problem Details.
- Remote HTTP bearer auth follows RFC 6750.
- API rate-limit headers follow RFC 9333, with `Retry-After` where applicable.
- Stable HTTP API is documented with OpenAPI 3.1.
- Metrics use Prometheus/OpenMetrics-compatible exposition.
- NDJSON streams emit one RFC 8259 JSON object per line.
- SSE streams follow WHATWG Server-Sent Events if SSE is implemented.
- Webhook/event normalization should map cleanly to CloudEvents 1.0.
- Kubernetes tools should follow Kubernetes API conventions and parse structured JSON output.
- Linux paths follow XDG Base Directory; macOS uses Library/Application Support and Library/Logs conventions; Windows uses Known Folders, authenticated loopback TCP by default, and named-pipe paths only for explicit verification.
- Later binary/container releases should support SBOM/provenance targets such as SPDX or CycloneDX, SLSA provenance, and OCI images where relevant.

## 19. Observability

Observability has four separate channels:

- Round events power `round watch`.
- Audit events are the durable compliance trail.
- Telemetry and metrics report operational health.
- Logs provide human/operator diagnostics.

Logging:

- Human-readable logs by default during development and foreground CLI use.
- JSON logs behind `TWELVGAIGE_LOG_FORMAT=json`.
- Required fields include timestamp, level, event, round ID, shell ID, shot ID, attempt, provider/model or tool, duration, status, error class/reason, and resource profile when available.
- Never log raw prompts, raw LLM responses, raw tool output, API keys, bearer tokens, cookies, kubeconfigs, environment dumps, or full command environments.
- Repeated identical warnings should be rate-limited.

Metrics:

- Prefix metrics with `twelvgaige_`.
- Use base units in metric names: `_total`, `_seconds`, `_bytes`.
- Keep labels low-cardinality. Do not label metrics by round ID, shot ID, full error message, prompt hash, user input, or file path.
- Required metric groups: round counters/duration, shot counters/duration/retries, LLM call counters/duration/tokens, tool call counters/duration/output bytes, resource permit gauges/queue depth, safety decision counters, retained memory/event gauges.

Telemetry is diagnostic and best-effort. It must not be used as the source of truth for audit or `round watch`; those come from round events and durable audit records.

## 20. Dependency Direction

Initial dependencies should stay small:

- `jason` for JSON
- `yamerl` for YAML
- existing `jason` for JSON shell loading behind the parser dispatch boundary
- a small in-project schema subset validator for Phase 1
- a small in-project resource limiter for Phase 1
- `nimble_options` for internal option validation
- `req` or `finch` for HTTP provider calls
- `mox` for provider/tool mocks in tests
- `stream_data` for property tests after the compiler exists

Added in Phase 4:

- `ecto_sql`
- `ecto_sqlite3`

Added in Phase 6:

- `toml_elixir` for TOML 1.0 shell loading

Defer until needed:

- any Starlark/CUE runtime, until a programmatic-shell security RFC is accepted
- `postgrex`
- `bandit`
- `plug`
- `quantum`
- `prom_ex`
- full JSON Schema validation library, unless Phase 1 subset becomes insufficient

Added for packaging:

- `burrito` for single-file native executable builds

CLI parser decision for `spec.md`:

- Evaluate `optimus`, `owl`, `table_rex`, and plain `OptionParser`.
- Prefer the smallest dependency that gives reliable subcommands, help text, and predictable parsing.

## 21. Proposed Project Structure

```text
twelvgaige/
+-- config/
+-- lib/
|   +-- twelvgaige.ex
|   +-- twelvgaige/
|       +-- application.ex
|       +-- resource_limiter.ex
|       +-- shell/
|       |   +-- workflow.ex
|       |   +-- agent.ex
|       |   +-- loader.ex
|       |   +-- cache.ex
|       +-- pattern/
|       |   +-- compiler.ex
|       |   +-- graph.ex
|       |   +-- condition.ex
|       +-- round/
|       |   +-- server.ex
|       |   +-- supervisor.ex
|       |   +-- run_supervisor.ex
|       |   +-- state.ex
|       +-- shot/
|       |   +-- executor.ex
|       |   +-- supervisor.ex
|       |   +-- retry_policy.ex
|       +-- agent/
|       |   +-- prompt_assembler.ex
|       |   +-- output_parser.ex
|       +-- llm/
|       |   +-- provider.ex
|       |   +-- capabilities.ex
|       |   +-- router.ex
|       |   +-- response.ex
|       |   +-- providers/
|       |       +-- anthropic.ex
|       |       +-- openai.ex
|       |       +-- gemini.ex
|       |       +-- ollama.ex
|       +-- tool/
|       |   +-- behaviour.ex
|       |   +-- executor.ex
|       |   +-- catalog.ex
|       |   +-- builtins/
|       +-- cli/
|       |   +-- main.ex
|       |   +-- commands/
|       +-- audit/
|       +-- store/
|       |   +-- behaviour.ex
|       |   +-- memory.ex
|       |   +-- manifest.ex
|       |   +-- transition.ex
|       +-- event/
|       +-- telemetry/
+-- priv/
|   +-- docs/traphouse/
|       +-- drills/
|       +-- shells/
|       +-- agents/
+-- test/
|   +-- support/
|   |   +-- fakes/
|   +-- unit/
|   +-- integration/
+-- mix.exs
+-- readme.md
+-- docs/
|   +-- design/
|       +-- plan.md
|       +-- spec.md
```

## 22. Implementation Phases

### Phase 0 - SPEC And Skeleton

Goal: settle the vocabulary, command surface, and minimal engine contract.

- Define `docs/design/spec.md`.
- Use the `docs/design/spec.md` vocabulary decisions: external CLI and shell files use `round`, `shell`, and `shot`.
- Lock the external standards matrix: JSON, timestamps, YAML, TOML shells, schema, HTTP, metrics, events, and platform paths.
- Create Mix project.
- Add formatter, Credo optional, ExUnit baseline.
- Add CLI entrypoint that can print help.

Milestone: `mix test` passes and `twelvgaige --help` works from source.

### Phase 1 - In-Memory Round Engine

Goal: run a deterministic foreground workflow with a mock LLM and no daemon.

- Workflow shell structs.
- YAML loader.
- App-level `Store.Memory` for in-VM state and event history.
- Laptop-profile `ResourceLimiter`.
- Resource permit cleanup, opt-in waiter queueing, queue timeouts, cancellation, owner-death cleanup, and fairness tests.
- Pattern compiler with cycle detection.
- RoundServer state machine.
- ShotExecutor with mock provider.
- Provider router with explicit provider IDs.
- Phase 1 schema subset validation.
- RFC 8259 JSON output and RFC 3339 timestamp output.
- Unit tests for compiler and condition logic.
- GenServer tests for round advancement.

Milestone: `twelvgaige round run docs/traphouse/workflows/simple.yaml` completes locally in the foreground with default `{}` input.

### Phase 2 - Tools And Safety

Goal: execute safe read-only tools under explicit shot permissions.

- [x] Tool behaviour.
- [x] Tool catalog.
- [x] Tool executor with allowlist, safety, schema, timeout, resource, crash, and output-size checks.
- [x] Shot executor normalizes and executes provider tool calls serially through the tool executor.
- [x] Built-in read-only tools: `shell_read` and `http_get`.
- [x] Output parsing and supported-subset schema validation before shot completion.
- [x] Retry policy with max-attempt enforcement and fixed, linear, and exponential backoff.
- [x] Safety shot type with foreground pause, inline approval, and rejection handling.
- [x] Read-only Kubernetes tools with structured `kubectl` argv and fake-runner tests.
- [x] Kubernetes write tools, including runtime-gated `kubectl_exec`, with structured `kubectl` argv and fake-runner tests.
- [x] Tool output size limits and redaction.
- [x] Provider fixture tests for Anthropic, OpenAI, Gemini, and Ollama adapters.
- [x] Opt-in local-cluster Kubernetes tests gated by `:k8s_live` and `TWELVGAIGE_K8S_LIVE=1`.

Milestone: a local inspection workflow gathers real read-only Kubernetes data and produces structured output.

Current note: `http_get` now enforces the intended local network policy, including scheme, userinfo, redirect, host allowlist, private host/IP denial, DNS resolved-address checks, timeouts, fake transports, and response byte caps.

### Phase 3 - Daemon And Watch

Goal: support long-running rounds and human approval.

- [x] Breech daemon process.
- [x] Foreground `daemon serve`, `daemon stop`, and `daemon paths` CLI lifecycle commands.
- [x] OTP-owned shell cache for configured workflow and agent shell paths.
- [x] Daemon-owned in-VM round submission.
- [x] `round show` and `round list` against the in-memory daemon store.
- [~] Authenticated loopback TCP, Windows default loopback TCP, macOS/Linux Unix socket IPC, and Windows named-pipe address support with the length-prefixed JSON protocol, including event replay and bounded follow. Client injected named-pipe transport tests and server injected named-pipe listener dispatcher tests are implemented; native named-pipe listener I/O remains pending Windows verification.
- [x] Endpoint JSON discovery for TCP, Unix socket, and named-pipe IPC with generated TCP bearer tokens, owner-only file permissions, daemon singleton locks, and lock-gated stale cleanup.
- [~] Windows named-pipe IPC address/discovery support remains opt-in; Windows defaults use authenticated loopback TCP until native listener I/O can be verified on Windows. Server-side pipe listener injection now verifies endpoint publishing and Breech dispatcher behavior without platform-specific pipe APIs.
- [x] `round watch` event replay and bounded follow, including `--until-terminal` cursor advancement and callback-delivered CLI batches that avoid collecting the whole stream first.
- [x] `round approve --shot <safety-shot-id>`.
- [x] `round reject --shot <safety-shot-id>`.
- [x] `round cancel`.
- [x] Deterministic CLI exit-code mapping for snapshots and command errors.
- [x] Event replay and bounded follow are backed by round events, not telemetry; CLI/API can advance event cursors until terminal state within explicit bounds. The real CLI watch entrypoint streams batches as they arrive. Pure API router event responses are fixed-length bounded replay bodies with a response byte cap, and the concrete HTTP listener supports bounded chunked push streams.

Milestone: a round can pause at safety, be approved from another CLI command, and continue.

### Phase 4 - Persistence And Recovery

Goal: survive daemon restart.

- [x] File-backed durable store contract for snapshots, manifests, journals, transition IDs, and round events.
- [x] Breech can run against a configured store backend; terminal file-store rounds and events survive store/Breech restart.
- [x] Application supervision starts the configured store backend from app config, `TWELVGAIGE_STORE_SQLITE`, or `TWELVGAIGE_STORE_FILE` and passes the normalized store module to Breech.
- [x] Awaiting-safety file-store rounds survive store/Breech restart and can resume after approval.
- [x] Breech scans incomplete file-store rounds on startup.
- [x] Breech refuses to start when the configured store process is unavailable.
- [x] Clean queued file-store rounds resume from stored manifest and input.
- [x] Unsafe or ambiguous in-flight snapshots move to `awaiting_reconciliation` instead of silently replaying work.
- [x] SQLite store backed by Ecto/SQLite with WAL, foreign keys, transactional transitions, persisted events, manifests, attempt/tool journals, queryable round columns, retention cleanup, and Breech restart coverage.
- [x] Ecto schemas and migrations for the SQLite store tables, including persisted migration metadata.
- [x] Immutable round manifest with stored workflow snapshot, workflow source metadata/content hash, normalized workflow hash, accepted agent source metadata, and agent shell hashes.
- [x] Durable round snapshot that excludes runtime-only OTP fields, plus backend-neutral shot-run projection and SQLite typed `shot_runs` table.
- [x] Attempt and tool intent journal across Runner, ToolExecutor, Breech, and Round.Server paths.
- [x] Shot attempt start is recorded before execution when a store is configured.
- [x] Shot attempt completion/failure is recorded after execution when a store is configured.
- [x] Tool intent is recorded before tool execution when a store is configured.
- [x] Tool observed result/failure is recorded after execution when a store is configured.
- [x] Recovery loads attempt/tool journal records for incomplete rounds and includes a journal summary in reconciliation state.
- [x] Store journal failures stop execution before side effects run.
- [x] Recovery classifies interrupted shots from journals as retryable no-tool, retryable read-only, retryable idempotent-write with key, or manual reconciliation.
- [x] Retryable partial file-store rounds commit recovery state and resume from the stored snapshot without rerunning completed dependencies.
- [x] Tool journals with missing or unsafe side-effect metadata require reconciliation.
- [x] Per-round event sequence for watch/API replay.
- [x] Cursor-based audit replay through store, Breech API, IPC, and `round audit`, with audit records redacted before persistence and output.
- [x] Transactional versioned state transition plus round event and audit write.
- [x] Recovery of incomplete rounds across file and SQLite durable stores.
- [x] Reconciliation of interrupted running shots across file and SQLite durable stores.

Milestone: an awaiting-safety round survives daemon restart and resumes after approval.

### Phase 5 - Production Interfaces

Goal: add platform-team integrations.

- [x] HTTP API: transport-neutral router covers health, round create/list/show/cancel, safety approve/reject, event replay, audit replay, webhook triggers, and metrics; `Twelvgaige.API.Server` exposes it through a supervised local HTTP/1.1 listener.
- [x] OpenAPI 3.1 contract for the current pure HTTP router at `GET /api/v1/openapi.json`.
- [x] HTTP standards: RFC 9457 problem details, RFC 6750 bearer auth, RFC 9333 rate-limit headers, API `Retry-After`, OpenAPI 3.1, fixed-length HTTP/1.1 framing, response `Content-Length`, request limits, and remote bind policy are implemented.
- [x] Local-only Breech IPC defaults use Unix sockets on macOS/Linux and authenticated loopback TCP on Windows, with Windows named-pipe address/discovery support kept opt-in until native listener I/O can be verified on Windows.
- [x] Webhook trigger: pure router supports opt-in signed webhook endpoints with timestamp freshness, nonce replay protection, JSON body limits, OpenAPI coverage, and Breech-backed round creation.
- [x] Event stream API: router replays round events and audit records as JSON arrays, NDJSON, SSE, or CloudEvents batch JSON from `after_seq`; bounded follow, terminal follow, idle SSE heartbeats, bounded-replay headers, and response byte caps are implemented. The concrete HTTP listener supports resource-bounded `stream=true` chunked push for SSE and NDJSON round events with cursor advancement, heartbeats, stream-client caps, send timeouts, and terminal/limit/deadline stops. CLI `round watch` streams callback-delivered event batches from the same cursor contract.
- [x] Event standards: NDJSON, SSE, and CloudEvents batch mapping are implemented and tested.
- [x] Metrics endpoint: API route emits Prometheus text for daemon, store, and resource limiter state through the router and local HTTP listener.
- [x] Runtime metrics: in-process collector records round, shot, LLM, tool, safety, and resource metrics with low-cardinality labels; Prometheus exposes retained store/event/journal/byte gauges, retention eviction counters, and queued-resource histograms.
- [x] Resource metrics: active permits, configured limits, live queue depth, and limiter denials are observable.
- [x] Provider rate limiting: shot LLM calls acquire `:llm_call` permits and fail with retryable `:resource_queue_timeout` before transport when saturated.
- [x] JSON logs: `Twelvgaige.Log.JSON` formats required JSON-line fields with redaction and raw prompt/tool-output omission; `Twelvgaige.Log.emit/5` is wired into Breech lifecycle and round events when JSON logging is enabled, and optional JSONL file sinks enforce retained-byte caps by dropping oldest complete lines.
- [x] `http_get` network safety policy: scheme, userinfo, redirect, host allowlist, private host/IP, DNS resolved-address, timeout, fake transport, and byte policies are enforced.
- [x] Provider transport: provider URLs are validated before transport, unsafe schemes/userinfo/private destinations are denied by default, timeouts are clamped, fake transports stay first-class, and retry hints are preserved.
- [x] Token/message budget enforcement: shot execution rejects oversized LLM message payloads before provider calls and rejects provider-reported token usage above shot budget.
- [x] Optional scheduler: configured interval and five-field cron jobs run through Breech and are only started when `:scheduler_jobs` is configured.
- [x] Native Mix release bundle: `twelvgaige_native` builds as a target-specific tarball with included ERTS, release lifecycle scripts, and generated product CLI wrappers for Unix and Windows. Generated release overlay directories are ignored and are not checked into git.
- [x] Burrito single-file executable: `twelvgaige` builds configured Burrito targets and launches the existing CLI dispatcher from Burrito runtime startup.
- [x] GitHub Actions automation: CI, build, and release workflows call Makefile targets and pin every reusable action to a full commit SHA. Burrito executables are built in a multi-platform matrix and are the primary cross-platform release artifacts.

Milestone: Twelvgaige can run unattended for a representative infrastructure workflow with audit logs and metrics.

### Phase 6 - Shell Authoring Formats

Goal: support JSON workflows and add developer-friendly authoring surfaces while
keeping one deterministic runtime model.

Tracking document: [`shell-formats-plan.md`](shell-formats-plan.md).

- [x] Refactor shell loading so file parsing is separate from shell
  construction and validation.
- [x] Keep YAML behavior compatible through the new dispatch path.
- [x] Add JSON workflow and agent shells using existing `jason` parsing.
- [x] Update daemon shell-cache loading, explicit `--agent-shell` paths, and
  adjacent `agents/` discovery to accept `.json`.
- [x] Add equivalence tests proving JSON and YAML fixtures normalize to the
  same shell map.
- [x] Add TOML workflow and agent shells after selecting a maintained TOML 1.0
  parser.
- [x] Add mixed YAML/JSON/TOML agent discovery and duplicate-ID tests.
- [x] Write a programmatic-shell RFC before accepting Starlark or CUE. The
  accepted option must be disabled by default, sandboxed, deterministic, and
  limited to producing a declarative shell map.
- [x] Add `shell normalize` and `shell convert` only after JSON support is
  implemented.
- [x] Update usage docs and traphouse examples so "shell" is format-neutral.
- [x] Wire package smoke checks to validate, normalize, convert, and run the
  traphouse YAML, JSON, and TOML workflow shells through the real CLI.

Milestone: YAML, JSON, and TOML workflows can run with mixed-format agent
shells; equivalent fixtures compile to the same pattern; normalize/convert
output validates immediately; package smoke tests exercise each supported
authoring format.

## 23. Testing Strategy

Normal tests must be deterministic and offline. External effects sit behind replaceable seams:

- `Clock` and `IdGenerator` for deterministic time and IDs
- LLM provider and HTTP client behaviours for provider tests
- `CommandRunner` for shell and Kubernetes tools
- Store behaviour for shared memory/file/SQLite contract tests plus a controllable fake store for failure-path tests
- Fake resource limiter backend for queue/admission tests
- Pure redactor, log formatter, schema validator, condition evaluator, retry policy, and graph modules

Test priority:

- Pattern compiler rejects invalid shells.
- Pattern compiler identifies parallel-ready shots.
- Condition evaluator is safe and deterministic.
- Resource limiter queues ready shots when laptop concurrency limits are saturated.
- Resource limiter releases permits on owner crash, cancellation, timeout, and task-start failure.
- Resource limiter applies weighted round-robin fairness across rounds.
- RoundServer advances only when dependencies are satisfied.
- Tool executor denies unauthorized tools.
- Tool executor denies destructive tools without policy.
- Retry policy never exceeds max attempts or max delay.
- Output parser rejects malformed output.
- Durable transition commits are idempotent by transition ID and expected version once persistence exists.
- Watch streams read round events rather than telemetry.
- Recovery marks interrupted shots correctly after restart once persistence exists.
- Shell format parsers normalize YAML, JSON, and TOML fixtures to the same maps.
- Programmatic shell sandbox tests deny host access before that format can be enabled.

Use mocks for LLM providers. Do not make real LLM calls in normal tests.

Normal `mix test` excludes live or slow tags:

- `:integration`
- `:daemon`
- `:persistence`
- `:provider_live`
- `:k8s_live`
- `:slow`

Provider and Kubernetes live tests also require explicit environment opt-in.

Property-based tests are most valuable for:

- DAG validation
- ready-shot calculation
- retry delay bounds
- condition evaluation edge cases
- resource limiter invariants

Integration tests can come later for:

- CLI command parsing
- daemon IPC
- read-only Kubernetes tools against a local cluster
- recovery from restart

Kubernetes live tests must be opt-in and never run in normal test suites.

Contract tests should be shared across behaviour implementations: store, provider adapters, command runner, and built-in tools.

## 24. Key Risks

1. Scope creep

The original plan included daemon, HTTP, scheduler, persistence, metrics, multi-node, tools, ReAct, and binary packaging. That is too much before the engine is proven. Keep phase 1 small.

2. Unsafe tool execution

Shell automation is the highest-risk area. Avoid arbitrary shell strings. Start with structured read-only tools.

3. Over-branded vocabulary

Shotgun terms can make the tool memorable, but infrastructure teams need clarity. Use the vocabulary where it maps cleanly and keep command names explicit.

4. Recovery ambiguity

Retried infrastructure actions can be dangerous. Every write-capable tool needs idempotency metadata, durable attempt journaling, and retry policy must respect it.

5. Audit volume and secrecy

Full LLM messages and tool outputs are useful for audit, but they may contain secrets. Redaction and configurable retention must be part of the design.

6. Multi-node complexity

Do not design distributed execution first. Build a correct single-node engine with durable state. Add Postgres and distributed coordination later only if real use cases require it.

7. Laptop resource creep

Unbounded parallel shots, large tool outputs, retained LLM traces, and terminal round history can make a laptop sluggish even if OTP processes are cheap. Keep the `laptop` profile conservative until measurement proves higher defaults are safe.

## 25. Release Follow-Ups

Release gates and manual smoke checks are tracked in [`release-checklist.md`](release-checklist.md).

- Verify native Windows named-pipe listener I/O on Windows hardware. Authenticated loopback TCP remains the Windows default until then.
- Measure `minimal`, `laptop`, and `workstation` resource profiles on common MacBook and Windows laptop hardware.
- Decide whether `queue_timeout` stays disabled by default or gets a conservative laptop default after measurement.
- Validate durable retention defaults with real local workloads, especially retained bytes, retained terminal rounds, and cleanup cadence.
- Decide whether cleanup must require an audit export checkpoint before terminal round records are removed.
- k3d is now the preferred disposable local Kubernetes live-test target. Existing kind, minikube, or dev-cluster contexts remain supported through `TWELVGAIGE_K8S_CONTEXT`.
- Build and smoke-test Mix release bundles on Linux and Windows CI runners. Mix releases are target-specific; the macOS bundle does not validate Linux or Windows runtime behavior.
- Build and smoke-test Burrito binaries on runners with Zig `0.15.2`, `xz`, and `7z`/`7zz` for Windows targets. macOS Apple Silicon host smoke is verified locally with Homebrew `zig@0.15` and `BURRITO_CUSTOM_ERTS_MACOS_SILICON`; Linux, Linux ARM64, and Windows targets still need runner-native smoke coverage.

## 26. One-Sentence Pitch

Twelvgaige is a CLI-first OTP control plane for reliable agent rounds: deterministic patterns, bounded shots, explicit safety, and audit-ready infrastructure workflows.
