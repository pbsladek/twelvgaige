# Twelvgaige Delegated Agent Control Plane Design

Date: 2026-08-01

Status: Complete and qualified for the supported single-user local mode

Audience: Maintainers and contributors

## Implementation status — 2026-08-09

The code slices for all seven phases are implemented. The default repository gate, both sandbox backends, the Codex compatibility paths, broker-only egress, and the single-user operational release matrix pass on the named host.

| Phase | Implementation state | Qualification state |
|---|---|---|
| 0 — Correctness foundations | Complete | Provider codecs, cumulative budgets, limit enforcement, result contracts, condition validation, limiter fairness, and performance gates are covered by tests. |
| 1 — Durable single-user scheduler | Complete | The scheduler path is unified; durable manifests, redacted snapshots, encrypted artifacts, bounded events, audit chains, recovery seams, and hard deadlines are covered by tests. |
| 2 — Workspace and session foundations | Complete | Workspace leases, exact delegated-session identity, adapter contracts, integration admission, typed handoffs, and bounded event ingress are covered by conformance tests. |
| 3 — Podman enforcement | Complete and qualified on the named host | Secure launch manifests, exact machine-mount attestation, image admission, non-root/read-only launch, bind and `copy_snapshot` workspace transport, network-none and broker-only egress, inspected resource limits, crash resume, drift quarantine, descendant cancellation, credential revocation, and concurrent launch pass live qualification. |
| 4 — Codex driver | Complete and provider-qualified | The supported driver is pinned to Codex CLI `0.146.0` and its generated stable protocol-v2 schema digest. The real stable App Server stdio handshake, digest-bound approval, exact resume, and provider-authenticated coding fixtures pass through the qualified Podman worker. |
| 5 — Apple container backend | Complete and qualified on the named host | The signed Apple CLI, pinned runtime, exact image identity, per-worker VM identity, resource-bound manifest seal, non-root/read-only launch, dropped capabilities, network-none, mount, limits, recovery, cancellation, credential revocation, concurrency, repeated-session memory, and Codex fixture pass live qualification. |
| 6 — Manager orchestration | Complete | Typed plans, exact approvals, registered authority, bounded tree depth/children/fan-out, aggregate budgets, atomic durable admission, fair scheduling, resource permits, isolated child identities, native-subagent inheritance, integration isolation, independent verification, one repair attempt, deadlines, cancellation, crash recovery, and load accounting are covered by tests. |
| 7 — Single-user operations | Complete and qualified on the named host | Local-user-bound control, operator session and sandbox commands, durable scheduling, provider limits, retention, backup/restore, artifact rotation, cross-repository provenance, broker-only egress, SLO/error-budget evaluation, and the ten-check fail-closed release matrix pass tests and live qualification. |

Current evidence:

- `make check`: passed for the recorded qualification, including the default
  tests, properties, and Phase 0 performance gates.
- `make typecheck`: passed with zero Dialyzer errors.
- `make coverage-export`: passed against the 75% repository gate. Six critical
  Codex authorization/schema modules have an 85% line-coverage floor, and two
  subprocess/protocol boundary modules have a 55% floor.
- Codex App Server: real stable stdio `initialize`/`initialized` handshake passed with `experimentalApi` disabled.
- Podman: the dedicated VM is running with 4 CPUs, 6 GiB memory, a 64 GiB virtual disk, and one declared `virtiofs` application-data mount. The health check validates the guest's observed mount table and rejects missing or additional mounts.
- Worker image: Alpine `3.23.5` and Codex CLI `0.146.0` are digest/checksum pinned. The signed image record, SPDX SBOM, full Grype result, and applicability review record zero critical and zero unreviewed high findings. The one reported high is a Git-for-Windows NTLM issue and is inapplicable to the Linux/ARM64 image.
- Live Podman baseline on macOS `26.6`, 18 logical CPUs, and 64 GiB host memory: 284 ms first cached-image launch, 284–304 ms subsequent launches, 394 ms wall time for two concurrent launches, 1,205 ms cancellation, and 75 ms reconciliation.
- Live Apple baseline on the same host: signed CLI `1.2.0`, 2,943–2,997 ms across five repeated launches, two concurrent per-worker VMs, 2,899 ms cancellation, 563 ms reconciliation, 3.8 MB peak reported guest memory, 77.6 MB peak observed host VM RSS, and no remaining managed resources. These timings include signature verification on every control call.
- Provider fixtures: authenticated Codex workers created and verified the requested file on both backends. Local account auth existed only in guest tmpfs, exact long credential values were absent from workspaces and captured outputs, and each worker was destroyed. The compatibility descriptors explicitly make the attested outer backend authoritative and use Codex's documented externally sandboxed mode. Earlier failures were traced to an incompatible bundled `zsh` in the Alpine worker image, not to missing container capabilities; the qualified image uses `/bin/sh`.
- Broker-only egress: the signed, digest-pinned proxy image has zero critical and zero high findings. Podman and Apple workers cannot use direct egress, must present a short-lived session capability, and can reach only declared hosts and ports after DNS resolution and private-address rejection. Both live paths passed audit-redaction and cleanup checks.
- Operational qualification: both named backend profiles recorded 100% success in the five-launch qualification sample, passed their launch, cancellation, recovery, queue, and retention targets, and retained positive error budgets. This is release-candidate evidence, not a substitute for a rolling production availability window.

### Test hardening completed on 2026-08-09

The test strategy distinguishes broad regression coverage from boundary-specific proof. Default macOS and Linux suites remain credential-free and deterministic. Persistence, daemon, and other specialized profiles export coverage into one merged report instead of presenting isolated percentages as repository coverage. The aggregate gate prevents broad erosion, while the critical-module floor protects Codex authorization, protocol, recovery, sandbox-launch, and manager handoff paths.

Codex App Server tests exercise real JSON-RPC framing, strict schema validation, approvals, exact resume identity, malformed and late frames, overload, recovery drift, budget enforcement, and cleanup. Persistence and restart suites assert the durable transition journal rather than only final state.

### Developer workflow completed on 2026-08-09

The single-user CLI now exposes the control-plane contracts as one developer
workflow instead of requiring callers to assemble low-level commands:

- `init` writes a secret-free project profile and example task; `doctor --fix`
  performs explicitly authorized project and sandbox repairs.
- User and project developer profiles resolve below task-file values and
  explicit CLI flags. They select authority defaults, not ambient credentials.
- `task validate` checks the resolved task request, while `session plan`
  resolves the Git commit and compiles the exact envelope without durable or
  external effects.
- `session start --follow` and `session watch` consume durable session events.
  `session review` returns session state, manager children, handoffs,
  verification, usage, failures, and events without applying work.
- `session retry` reuses the stored start request. Normal retries are capped;
  `--repair` is single-attempt, failure-informed, and cannot expand the original
  authority boundary.

## Executive decision

Twelvgaige should become the control plane for two complementary forms of agent execution:

1. **Provider-native shots**, where Twelvgaige owns the LLM conversation, tool loop, policy, and output parsing.
2. **Delegated agent sessions**, where Twelvgaige hands a bounded objective to Codex and lets that runtime manage its own context, tools, and native subagents.

Twelvgaige remains the authority around both paths. It decides whether work may run, where it runs, which credentials and network destinations it may use, how much it may cost, which approvals are required, how it recovers, and whether the result may be integrated.

The implementation must proceed in dependency order. Live provider behavior and durable recovery need repair before manager-agent fan-out. Delegated sessions need a common workspace, session, sandbox, authentication, event, and approval model before adding runtime-specific drivers. Podman should be the first outer sandbox backend. Apple's container runtime should follow as the stronger per-session VM option on supported Macs.

The intended end state is:

> A governed team of internal and delegated agents, each working within explicit authority, isolated workspaces, durable state, bounded resources, and verifiable handoffs.

## Goals

- Make live provider tool use correct across OpenAI and Ollama adapters.
- Make daemon-owned rounds recoverable without repeating ambiguous side effects.
- Persist enough normalized policy and identity to resume exactly or fail closed.
- Keep sensitive values out of ordinary snapshots, manifests, logs, and workspaces.
- Make workspaces, delegated sessions, sandbox manifests, credential leases, approvals, and handoff artifacts first-class data.
- Let Codex manage the inner coding-agent loop through structured integration surfaces.
- Support Podman and Apple container backends behind one sandbox contract.
- Let manager agents propose bounded fan-out without giving them process, credential, or approval authority.
- Make verification, audit, cancellation, and resource accounting work across nested execution.
- Put measurable latency, memory, queue, throughput, and recovery gates on supported host profiles.
- Manage third-party runtimes, images, SDKs, MCP servers, and protocol upgrades through one support lifecycle.

## Non-goals

- Building a general-purpose container or VM orchestrator.
- Reimplementing the coding-agent loop already provided by Codex.
- Giving manager agents unrestricted DAG mutation or a generic process-spawn tool.
- Treating prompt instructions as authorization.
- Treating OTP supervision as a filesystem, network, credential, or operating-system sandbox.
- Sharing one writable checkout between parallel workers.
- Automatically merging, deploying, or executing destructive external actions without explicit policy and approval.
- Supporting every host platform and sandbox backend in the first delegated-session release.
- Using terminal scraping as the durable protocol for an agent runtime.

## Product strategy and deployment modes

### Build versus integrate

Twelvgaige should build the parts that determine authority and compose work:

- Workflow compilation and durable scheduling
- Policy intersection and admission
- Workspace, credential, sandbox, and budget leases
- Approval, intent/result, audit, and recovery state
- Typed manager plans, handoffs, integration, and verification

It should integrate complete coding-agent runtimes rather than reproduce their inner loops. Codex already manage context, commands, edits, native tools, and native subagents. The adapter boundary exists to govern those runtimes, not to normalize away every useful native capability.

The two execution paths should remain independent products sharing a control plane. A broken provider-native tool loop must not be hidden behind delegated sessions, and a delegated-session failure must not trigger silent fallback to a provider-native shot. Operators choose the execution kind in policy or authoring.

### Supported deployment modes

The supported product scope is one trusted local OS user running untrusted agent code. Team, remote-control-plane, and multi-tenant deployment modes are outside this plan. They require a separate product and security design rather than dormant complexity in the single-user implementation.

| Mode | Trust boundary | Earliest milestone | Support decision |
|---|---|---:|---|
| `local_single_user` | One trusted OS user; agent code and repository content are untrusted | A | The only supported deployment mode in this plan |

No milestone authorizes exposing the HTTP or daemon interface to another user or an untrusted network. Localhost access is an implementation transport, not a remote deployment boundary.

### Release strategy

- Ship vertical slices that finish one safe user journey, not disconnected infrastructure.
- Keep new execution paths behind independent feature flags until their full contract suite passes.
- Treat Podman as the portability baseline and Apple container as a stronger macOS isolation option, not as interchangeable implementations with identical trust properties.
- Default to Podman on macOS. Apple container selection remains explicit until it passes the common qualification suite and has enough release data to reconsider automatic preference.
- Support one pinned and tested runtime range at a time. New runtime releases enter through a canary and conformance process.
- Never change provider, driver, model, auth principal, sandbox backend, or workspace during recovery. A policy-authorized fallback creates a new attempt with a new identity and an explicit handoff.
- Optimize the product and its operating model for a single local user; do not add speculative multi-user machinery.

## Design invariants

These rules apply across every phase:

1. **Fail closed.** Missing agents, credentials, sandboxes, policies, capabilities, or recovery identities stop execution.
2. **Use exact identity.** Resume an exact round, session, turn, workspace, image, auth profile, and policy revision. Never use “last session” in a multi-session daemon.
3. **Narrow authority.** Child capabilities can only remain equal or become narrower than their parent.
4. **One writer per workspace.** Every parallel write-capable worker gets a distinct worktree or isolated repository snapshot.
5. **Keep secrets behind references.** Durable state stores credential-profile and lease identities, never provider keys or refresh tokens.
6. **Bind approval to an action.** Approval covers a normalized action digest, scope, actor, session, workspace, and expiry—not a free-form intention.
7. **Journal before and after side effects.** Recovery treats an intent without a conclusive result as ambiguous.
8. **Separate control state from payloads.** Resumable state stays small and redacted; large or sensitive content becomes an encrypted artifact reference.
9. **The outer runtime owns enforcement.** Agent prose, plans, and self-reported success are evidence, not authority.
10. **Detect capabilities.** Runtime and sandbox adapters probe supported features instead of assuming behavior from a version string.

## Baseline At The Start Of The Review

Before the delegated-session work began, Twelvgaige was already a deterministic
workflow and control-plane harness. It could manage multiple named agents when
their relationships were encoded as a static workflow DAG.

| Existing layer | Current role |
|---|---|
| Agent shell | Identity, provider, model, prompt, and intended limits |
| Shot executor | One bounded agent/tool interaction |
| Round | DAG scheduling, conditions, retries, safety, and state |
| Breech daemon | Admission, persistence, recovery, API, and operations |

That baseline had useful foundations:

- LLM output is treated as untrusted input.
- Workflows compile into immutable graphs.
- Tools have schemas, safety levels, idempotency metadata, output limits, and journals.
- Write-capable shots require an external safety dependency.
- OTP supervision and bounded resource profiles are already present.
- Attempts, tool intents, results, state, and audit events have separate concepts.
- HTTP, filesystem, command, and Kubernetes tools apply substantial scope checks.
- The authoring patch subsystem already demonstrates digest-bound approval.
- SQLite, file, memory, encrypted-store, daemon, integration, and slow tests exist.

At the start of this review, the code was not yet a safe base for dynamic
multi-agent execution. The findings below drove the implementation phases; the
current implementation and qualification outcomes are recorded at the top of
this document.

| Finding | Severity | Phase |
|---|---:|---:|
| Live provider tool calls lose schemas and conversation structure | P0 | 0 |
| Detached recovery can repeat side effects | P0 | 1 |
| Recovery loses normalized agent definitions and loadouts | P0 | 1 |
| Raw sensitive values enter durable snapshots | P0/P1 | 1 |
| Agent limits and workflow policies are parsed but not fully enforced | P1 | 0–1 |
| Token budgets are checked per response instead of cumulatively | P1 | 0 |
| Result and condition contracts are unstable and can race | P1 | 0 |
| Resource limiter can leave eligible waiters asleep | P1 | 0 |
| Performance script has no regression gates and does not cover delegated-session paths | P1 | 0–8 |
| No integration catalog or third-party support/upgrade policy exists | P1 | 2–6 |
| Local daemon and HTTP surfaces need an explicit same-user access boundary | P1 | 3, 8 |

## Target architecture

```text
User or manager proposal
          │
          ▼
Twelvgaige admission and policy
          │
          ├──────── Provider-native shot
          │           └─ Twelvgaige LLM and tool loop
          │
          └──────── Delegated agent session
                      ├─ Workspace lease
                      ├─ Credential and egress lease
                      ├─ Podman or Apple container sandbox
                      ├─ Codex runtime
                      └─ Native tools and subagents
                                  │
                                  ▼
                         Typed handoff artifact
                                  │
                                  ▼
                        Integration and verifier
                                  │
                                  ▼
                         Runtime or human gate
```

### Authority boundary

| Delegated agent owns | Twelvgaige owns |
|---|---|
| Local planning and replanning | Admission and scheduling |
| Context and transcript management | Durable round and session identity |
| Selection among permitted tools | Maximum capabilities and approval policy |
| Its internal tool loop | Workspace, sandbox, network, credentials, and budgets |
| Native subagent topology | Maximum depth, fan-out, cost, time, and aggregate usage |
| Editing and testing inside its workspace | Validation, integration, merge, recovery, and audit |

### OTP boundary

OTP provides fault and lifecycle isolation. It does not provide security isolation.

| OTP provides | OTP does not provide |
|---|---|
| Supervision, links, and monitors | Filesystem access control |
| Timeouts and cancellation coordination | Network isolation or egress filtering |
| Mailbox and process ownership | Separate OS users or address spaces |
| Admission and resource accounting | Secret or environment isolation |
| Event routing and backpressure | Containment of arbitrary code running as the same OS user |

BEAM processes share a VM, operating-system identity, environment, and application state. A process can still call `System.cmd`, `File`, socket APIs, ETS, application state, or loaded native code. An Erlang Port gives Twelvgaige subprocess ownership and I/O, but the child retains whatever filesystem, network, and environment access the operating system gives it.

Use OTP to supervise the real security boundary:

```text
DelegatedSession.DynamicSupervisor
  └─ DelegatedSession.Controller
       ├─ Workspace lease
       ├─ Credential lease
       ├─ Sandbox.Manager
       │    └─ Podman or Apple container resource
       ├─ Runtime adapter
       └─ Durable event journal
```

[Application](../../lib/twelvgaige/application.ex), [ResourceLimiter](../../lib/twelvgaige/resource_limiter.ex), and the subprocess handling in [CommandRunner](../../lib/twelvgaige/tool/command_runner.ex) are useful precedents for ownership, admission, and termination. They do not change what the child is allowed to access.

## Threat model and security architecture

### Protected assets

- Provider, cloud, source-control, and MCP credentials
- Source code, uncommitted work, proprietary context, and generated artifacts
- Host filesystem, sockets, processes, local services, and network identity
- Git object stores, branches, signatures, and release provenance
- Round, approval, audit, usage, and billing records
- Other users' sessions, workspaces, credentials, and quota
- The Breech daemon, store, credential broker, sandbox control plane, and Erlang runtime

### Adversaries and failure sources

- Prompt injection in repositories, web content, tool output, MCP resources, and dependency metadata
- Malicious or compromised package, build script, compiler plugin, image, MCP server, or agent plugin
- A coding agent that makes an unsafe decision without malicious intent
- A user attempting to cross another user's workspace, credential, or quota boundary
- Stolen session, OAuth, broker, daemon, or sandbox-control credentials
- Runtime protocol drift that changes approval, tool, or persistence semantics
- Crash, timeout, partial write, network partition, or duplicate delivery during a side effect

The design does not claim to contain a malicious host administrator or a compromised macOS kernel, hypervisor, container runtime, or Twelvgaige release binary.

### Trust zones

```text
Untrusted content and repository
        │
        ▼
Agent process and native tools                  untrusted
        │
        ▼
Outer container or lightweight VM              enforcement boundary
        │ narrow authenticated protocols
        ▼
Twelvgaige session controller and policy        trusted control plane
        │
        ├─ Credential/egress broker             trusted secret boundary
        ├─ Durable store and artifact service   trusted data boundary
        └─ Sandbox engine control               privileged control boundary
```

The worker never receives a control-plane socket. A narrow session capability authenticates any callback from the worker, binds it to one session and operation set, expires with the session, and cannot create sandboxes, issue credentials, or approve actions.

### Security profiles

| Profile | Workspace | Network | Credentials | Intended use |
|---|---|---|---|---|
| `analysis_only` | Read-only snapshot | None | None or read-only provider lease | Review and classification |
| `coding_restricted` | Isolated writer | Provider proxy plus approved package sources | Session-scoped provider lease | Default delegated coding |
| `coding_unrestricted_network` | Isolated writer | Unrestricted internet egress | Session-scoped provider lease | Explicit operator flag for work that cannot use an allowlist |
| `integration_test` | Disposable copy | Explicit test dependencies | Test-only secrets | Builds and integration tests |
| `operations_read_only` | Read-only | Approved operational APIs | Read-only service identity | Inspection and diagnosis |
| `operations_approved_write` | No general host workspace | Exact approved endpoints | Narrow action credential | Later operational automation |

Profiles describe a maximum. Agent, workflow, and operator policies intersect with the profile and can only remove capabilities. A profile cannot enable an ambient plugin, MCP server, mount, or credential merely because the agent runtime discovers it.

Unrestricted network access is never inferred from an agent request or missing allowlist entry. It requires an explicit session or workflow flag, is recorded in the launch manifest and audit trail, and does not grant host filesystem, control-socket, credential, private-network, loopback, link-local, or metadata-service access.

### Defense in depth

1. Compile and persist the effective policy.
2. Create an isolated workspace with explicit inputs.
3. Launch a pinned image through an attested outer sandbox.
4. Enable the agent's native sandbox and deny unsafe fallback.
5. Route provider and approved external traffic through policy-enforcing brokers.
6. Convert capability expansion into digest-bound approval.
7. Validate commits, diffs, artifacts, and evidence in a separate verifier boundary.
8. Export tamper-evident audit checkpoints before destructive integration or retention expiry.

### Software supply chain

Every executable component in the worker path is third-party code and needs provenance:

- Pin container images by digest and maintain an allowlisted image catalog.
- Record the Codex CLI, sandbox runtime, and MCP server artifact versions and digests.
- Build sidecars and images from lockfiles; generate an SBOM and vulnerability scan result for each supported image.
- Verify available signatures or checksums before admitting an artifact to the catalog.
- Separate image build credentials from runtime credentials.
- Define patch and revocation policy. A revoked digest blocks new sessions and marks resumable sessions for operator review rather than silently changing their image.
- Run upgrade candidates against protocol fixtures, security tests, and representative workloads before promotion.
- Ship signed, digest-pinned project images as the supported path. A local user may explicitly select a digest-pinned custom image, but it is marked unsupported and still must satisfy sandbox manifest and capability checks.

### MCP, plugins, hooks, and external tools

Ambient discovery is disabled in service profiles. Each MCP server, plugin, hook, or custom agent must be named in a signed or operator-approved integration catalog with:

- Source and artifact digest
- Protocol and schema version
- Required filesystem, network, secret, and user scopes
- Tool annotations and side-effect classification
- Authentication method and token audience
- Data-retention and residency notes
- Owner, support status, and revocation state

MCP tools remain subject to Twelvgaige capability and approval policy even when the native runtime would approve them. Follow the [MCP security guidance](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices): do not pass through tokens issued for another audience, require per-client consent for third-party OAuth proxies, validate redirect URIs exactly, and route discovery and redirects through SSRF-resistant egress that blocks private, loopback, link-local, and metadata destinations.

The initial supported release includes write-capable MCP integrations. Every such integration must declare its write and destructive-action classes, exact destination scopes, credential audience, and idempotency behavior in the catalog. Twelvgaige journals external write intents and results; native auto-approval may cover only actions already authorized by the resolved outer policy. Destructive operations require exact digest-bound approval and must be safely reconcilable after interruption.

Required integrations fail session startup when missing or unhealthy. Optional integrations are omitted from the effective tool set and produce a durable warning; they never disappear silently after approval.

Repository instructions such as `AGENTS.md` may be admitted as untrusted task context in an explicit profile, but they cannot alter sandbox, credential, approval, integration-catalog, or retention policy.

### Audit integrity

Critical audit events include the prior event digest, canonical event digest, sequence, actor, policy revision, and server timestamp. Periodic signed or externally stored checkpoints make later truncation or rewriting detectable. High-volume message deltas may be compacted, but admission, identity, policy, approval, intent, result, credential, sandbox, and terminal events are never omitted from the audit chain.

## Shared domain design

### Workspace

Every write-capable coding session receives a `Workspace` record:

```text
workspace_id
round_id / shot_id / attempt
repository identity / base reference / base commit
workspace transport / absolute path or volume identity
branch / head commit / dirty state
allowed paths / read-only references
retention policy / artifact references
created_at / finalized_at
```

Supported workspace transports:

| Transport | Behavior | Intended use |
|---|---|---|
| `bind_worktree` | Mount only a session worktree read/write | Fast local coding and interactive review |
| `copy_snapshot` | Copy a repository snapshot into sandbox-owned storage and export declared results | Default for unattended or higher-risk work |

A linked git worktree can point back to shared repository metadata. Restricted profiles must not expose a shared `.git` object store to untrusted workers. Unattended sessions default to `copy_snapshot`; `bind_worktree` requires an explicit interactive profile. Use an isolated git directory whenever a worktree is allowed and shared metadata cannot be safely scoped.

### Delegated session

```text
DelegatedSession
  round_id / shot_id / attempt
  runtime / driver / runtime_version / capabilities
  external_session_id / external_turn_id
  workspace_id / base_commit / head_commit
  auth_profile_id / auth_revision / principal / provider_tenant
  sandbox_profile / sandbox_manifest_digest / resource_id
  policy_revision / budgets / deadline
  status / last_event_sequence / last_usage
  result / exit_reason / artifact_refs
```

Lifecycle:

```text
prepare
  → authenticate
  → create sandbox
  → start or resume exact session
  → stream events
  → approve or deny requested expansion
  → cancel or complete
  → reconcile
  → finalize
```

Possible authoring shape:

```yaml
kind: agent_session
runtime: codex
driver: app_server
auth_profile: coding_service
workspace:
  type: git_worktree
sandbox:
  backend: podman              # or apple_container
  profile: coding_restricted
  workspace_transport: copy_snapshot  # unattended default; bind_worktree is explicit and interactive
limits:
  time: 45m
  tokens: 80000
  cost_usd: 25
handoff:
  include: [summary, commits, diff, tests, open_questions]
```

Normalized event vocabulary:

```text
session_started
turn_started
message_delta
plan_updated
tool_requested
approval_required
tool_started
tool_finished
subagent_started
subagent_finished
usage_updated
artifact_created
turn_completed
session_failed
session_stopped
```

Every event carries the native session and event identities, a monotonic Twelvgaige sequence, timestamp, and payload digest. Persist the normalized event and retain a redacted native event artifact for protocol debugging. Deduplicate on native identity plus digest.

### Agent adapter

```text
capabilities(config)
prepare(session_spec)
authenticate(auth_lease)
start(session_spec)
resume(external_session_id, session_spec)
send(input)
decide(approval_id, decision)
cancel(reason)
snapshot()
reconcile(durable_state)
finalize()
```

Do not scrape terminal output to infer durable state or approval. An interactive PTY may be offered for human attachment, but the scheduler and store use the structured protocol.

### Integration descriptor

Every runtime and external tool resolves to a durable `IntegrationDescriptor` before admission:

```text
integration_id / kind / vendor / product
adapter / adapter_version
artifact_path / artifact_version / artifact_digest
protocol_version / schema_digest / capabilities
support_status / tested_platforms
auth_modes / endpoint_classes / data_regions
license_or_terms_revision
catalog_revision / approved_at / revoked_at
```

`support_status` is one of `experimental`, `supported`, `deprecated`, `blocked`, or `removed`. Experimental integrations cannot run in unattended profiles. Deprecated integrations may resume an existing safe session during a bounded migration window but cannot start new work. Blocked integrations cannot start or resume.

The descriptor is part of session identity. An executable upgrade, schema change, capability change, or adapter change creates a new descriptor revision and cannot enter an existing session through recovery.

### Sandbox backend

The sandbox is layered when the runtime's native sandbox composes with the selected outer backend:

```text
Twelvgaige policy and approval
        → isolated workspace and artifact store
        → outer Podman container or Apple lightweight VM
        → optional Codex native sandbox and permissions
        → post-run diff, test, policy, and merge validation
```

The outer backend remains authoritative because native agent sandboxes cover different tools and subprocess paths and may require kernel capabilities that the outer boundary deliberately removes. Every integration descriptor states whether the native layer is required, compatible, or deliberately disabled for an externally sandboxed worker. Failure never causes an automatic downgrade. The qualified Codex descriptors use the documented externally sandboxed mode while preserving the attested outer boundary. This does not justify adding capabilities to the worker: the actual image failure found during qualification was an incompatible bundled shell, which was fixed by using Alpine's `/bin/sh`.

```text
Sandbox.Backend
  probe()                  → availability, version, capabilities
  prepare(spec)            → resolved launch manifest
  create(manifest)         → stable resource ID
  start(resource_id)       → process and protocol stream
  inspect(resource_id)     → observed state and policy evidence
  stop(resource_id, grace) → graceful termination
  kill(resource_id)        → forced termination
  copy_in/out(...)         → controlled workspace and artifact transfer
  destroy(resource_id)     → cleanup
  reconcile(identity)      → running, stopped, missing, ambiguous, inconsistent
```

Backend choice is resolved before execution and persisted. `backend: auto` may be an operator convenience, but recovery must never change an existing session's backend.

The launch manifest contains:

```text
backend / backend_version / capabilities
resource_id / vm_or_machine_id
image_reference / image_digest
workspace_transport / mounts / mount_modes
uid / gid / rootfs_mode / capabilities / security_options
network_mode / allowed_destinations / proxy_lease_id
cpu / memory / pids / deadline
environment_names / credential_lease_id
created_at / started_at / observed_state
manifest_digest / policy_revision
```

Secret values never enter this manifest. `inspect/1` must produce evidence that can be checked against it before the agent starts.

### Authentication and egress

Workflows and session records contain only `auth_profile_id`. Twelvgaige resolves that reference at launch and issues a session-scoped lease.

Two explicit modes are allowed:

1. **Local user-owned session.** An interactive session may use supported Codex local-account login through an isolated configuration directory associated with the local user. Twelvgaige must not silently copy the operator's default credentials into a container. An explicit one-run transfer uses container tmpfs, records the selected auth profile without credential values, and destroys the sandbox afterward.
2. **Headless service session.** Unattended daemon execution uses an API key, approved enterprise token, cloud-provider identity, or gateway. Prefer a short-lived proxy token over the upstream credential.

The credential and egress broker must:

- Bind the lease to round, shot, attempt, runtime, local principal, provider account, model allowlist, destinations, budget, and expiry.
- Refresh and revoke without exposing upstream refresh credentials.
- Deny direct provider egress when a provider proxy is configured.
- Strip secrets from prompts, events, logs, crash reports, snapshots, artifacts, and child environments.
- Audit issuance, refresh, use, denial, and revocation without logging the secret.
- Never mount a host keychain, SSH agent, cloud credential directory, container-engine socket, or daemon control socket into the sandbox.

For Codex, App Server account methods support local account lifecycle. Cached credentials such as `auth.json` are password-equivalent. Unattended operation should use [API-key or approved enterprise authentication](https://learn.chatgpt.com/docs/auth).


### Approval and side-effect journals

A delegated runtime approval request becomes a Twelvgaige `ActionIntent`:

```text
runtime / session / turn / native_tool_call_id
tool_kind / normalized_arguments / arguments_digest
workspace / filesystem_scope / network_scope
requested_capability / reason / expiry
```

The approval receipt binds those values plus the actor and policy revision. Any changed runtime, session, arguments, workspace, scope, or policy makes it stale.

Action classes:

- Work already contained by the approved workspace and sandbox may be handled by the native runtime, including through its configured auto-approval or bypass mode.
- Network expansion, mounts, secrets, external MCP servers, and writes outside the workspace become Twelvgaige approval requests.
- Cataloged MCP writes are supported when admitted by the outer policy. Destructive external actions require exact digest-bound approval and durable intent/result reconciliation.

The agent runtime's bypass or auto-approval mode is respected inside the already granted workspace, sandbox, network, credential, MCP, and budget envelope. It is not authority to expand that envelope, approve a Twelvgaige safety gate, integrate results, or affect the host directly.

### Handoff artifacts

Workers pass typed evidence, not whole unfiltered transcripts:

```json
{
  "objective_status": "complete",
  "summary": "Implemented and tested the endpoint",
  "workspace_id": "ws_...",
  "base_commit": "...",
  "head_commit": "...",
  "diff_artifact": "artifact://...",
  "test_artifact": "artifact://...",
  "open_questions": [],
  "claims": [
    {"claim": "unit tests pass", "evidence": "artifact://..."}
  ]
}
```

Runtime-observed facts and agent-authored claims stay distinguishable. A verifier reproduces important claims from the committed or captured result.

Successful delegated work returns a commit or captured patch, declared artifacts, and a verification report for human review. Twelvgaige does not merge automatically. Native runtime auto-approval governs work inside the session boundary; it does not authorize final integration.

## Third-party integration lifecycle

### Initial support matrix

| Integration | Primary surface | Production status target | Pinning and compatibility rule |
|---|---|---|---|
| Codex | App Server over stdio | Supported in Phase 4 | Pin CLI; generate version-specific JSON Schema; stable API only |
| Codex automation fallback | `codex exec --json` | Compatibility | Pin CLI; captured JSONL fixtures; no interactive parsing |
| Podman | CLI plus inspection | Supported in Phase 3 | Pin supported major/minor range; attest machine and container capabilities |
| Apple container | Signed CLI | Supported on eligible Macs in Phase 5 | Pin tested release; use release-tag documentation; probe service and capabilities |
| MCP server | Stdio or HTTPS through catalog | Per-integration | Pin artifact/schema; explicit scopes; required/optional startup policy |


### Protocol rules

- Negotiate capabilities at connection startup and store the negotiated set.
- Generate or vendor machine-readable schemas from the exact supported runtime artifact where available.
- Stay on stable protocol surfaces by default. Experimental methods require a separate descriptor, feature flag, threat review, and fixture suite.
- Ignore unknown optional events after recording a redacted compatibility warning. Reject unknown required states, approval types, terminal statuses, or identity fields.
- Treat missing configured integrations as startup failures when marked required.
- Record raw redacted events so adapter bugs can be diagnosed without making raw payloads the control-plane truth.
- Keep request IDs, event IDs, and idempotency keys stable across safe retries.

For Codex, initialize once per App Server connection and use stdio inside the sandbox. The current App Server documentation marks TCP WebSocket transport experimental and notes unsafe non-loopback defaults during rollout, so it is not part of the supported Twelvgaige transport. Generate the App Server JSON Schema from the pinned CLI, leave `experimentalApi` disabled, identify the Twelvgaige client in `clientInfo`, and use `model/list` or capability reads instead of hard-coding optional model behavior. App Server overload (`-32001`) receives bounded exponential backoff with jitter before a turn is accepted.


### Upgrade and deprecation process

1. Discover a new third-party release without changing the supported descriptor.
2. Fetch and verify the artifact, release metadata, signature or checksum, license/terms changes, and generated schemas.
3. Run unit fixtures, adapter conformance, sandbox security, fault injection, and representative performance workloads.
4. Run canary sessions with synthetic repositories and non-production credentials.
5. Promote the descriptor for new sessions only.
6. Keep the immediately previous descriptor available for exact resume for 30 days after promotion when security policy permits. It cannot start new work during that window.
7. Revoke immediately for a critical security issue; require explicit operator disposition for affected sessions.

No automatic installer or marketplace update may mutate a running or resumable session. Auto-discovered plugins, MCP servers, hooks, skills, or configuration are disabled in service profiles.

### Failure taxonomy and fallback

Normalize third-party failures into:

```text
configuration
authentication
authorization
policy_denied
quota_exhausted
rate_limited
overloaded
transient_transport
protocol_incompatible
sandbox_unavailable
runtime_crash
ambiguous_side_effect
invalid_output
cancelled
deadline_exceeded
```

Retry rules are owned by Twelvgaige policy:

- Retry rate limits, overload, and transient transport failures only when the native protocol says the operation is retryable and identity/idempotency is preserved.
- Do not retry authentication, authorization, policy, schema, unsupported capability, or invalid configuration failures.
- Do not stack Twelvgaige retries on top of opaque native retries without counting both against one attempt and deadline budget.
- Reconcile after a process or connection loss before restarting or resending.
- Never fall back to another provider, agent runtime, sandbox backend, model, provider account, or credential inside the same attempt.
- An approved fallback starts a new attempt and records why prior evidence and workspace state are safe to hand off.

Circuit breakers operate per integration descriptor, credential profile, endpoint, and failure class. They stop new admission while allowing cancellation, reconciliation, and operator inspection. Half-open probes use synthetic credentials and work, not a user's live session.

### Data governance

Before admission, policy resolves which data may cross each provider or MCP boundary:

- Provider organization, account, endpoint, region, and auth mode
- Repository and artifact classification
- Whether prompts, files, tool results, images, and telemetry may leave the host
- Provider retention or enterprise policy required by the user
- Redaction rules and prohibited secret classes
- Audit and deletion obligations

The resolved data-routing decision is persisted without secrets. A runtime cannot add a new provider, MCP endpoint, plugin marketplace, telemetry endpoint, or region after approval.

## Performance and capacity model

### Performance principles

- No unbounded mailbox, Port stream, event buffer, artifact upload, scheduler queue, or retry loop.
- Admission uses reserved resources, not optimistic observed RSS. Apple VM memory that is freed in the guest may not return promptly to macOS.
- Backpressure reaches the external process before a controller mailbox or store is exhausted.
- Critical state is durable before acknowledgement; high-volume presentation data may be coalesced.
- Cold image pulls, warm sandbox launch, agent initialization, model latency, tool execution, and final artifact export are measured separately.
- A faster path cannot weaken isolation, skip attestation, or make audit events best-effort.

### Event and I/O flow

Classify events into three persistence classes:

| Class | Examples | Handling |
|---|---|---|
| Critical | Identity, admission, policy, approval, intent/result, credential, sandbox, terminal state | Synchronous durable append before acknowledgement |
| Operational | Tool lifecycle, usage, subagent lifecycle, retry, health | Ordered buffered append with bounded latency |
| Presentation | Message and progress deltas | Coalesce up to 64 KiB or 250 ms; compact after terminal state |

The Port reader uses demand-driven or `active: :once`-style flow control. A bounded per-session queue separates protocol decoding from store writes. Crossing the high-water mark pauses reads or rejects new turns; it does not continue accepting bytes into a GenServer mailbox. Terminal and approval messages receive reserved queue capacity so a flood of deltas cannot prevent cancellation or policy decisions.

Raw logs and artifacts stream to capped files or object storage rather than accumulating in BEAM binaries. Output caps apply before JSON decoding where possible. Large events use artifact references, and watchers receive cursors rather than whole histories.

Metrics keep low-cardinality labels such as profile, backend, driver, status, and failure class. Round, session, turn, tool-call, and workspace identifiers belong in structured traces and audit events, not metric labels. Trace propagation across controller, sandbox, broker, driver, and verifier makes queue time distinguishable from provider and tool time.

### Admission and fairness

Extend runtime profiles beyond current round, shot, LLM, tool, and retained-byte permits:

```text
active_delegated_sessions
active_sandboxes
reserved_cpu
reserved_memory_bytes
reserved_pids
workspace_bytes
artifact_inflight_bytes
provider_requests_per_minute
provider_tokens_per_minute
provider_cost_inflight
```

Admission reserves the full declared sandbox memory and CPU before launch, including headroom for the agent, compiler, test processes, and sidecar. At least 25% of host memory remains outside sandbox reservations by default. Queue scheduling is fair across active rounds, then FIFO within one round. Cancellation, approval response, and reconciliation bypass ordinary work queues.

The Podman machine stays warm, and supported image digests may be pre-pulled. Session containers remain ephemeral. Apple containers remain per-session VMs; warm image/content caches are allowed, but warm agent processes are not reused across principals or workspaces. `copy_snapshot` uses incremental/content-addressed transfer where possible and reports import/export bytes and duration.

### Provisional service objectives

These are starting gates for the local reference profile and must be replaced by measured, versioned baselines for each supported host profile:

| Measure | Provisional gate |
|---|---|
| Critical event durable acknowledgement | p95 ≤ 250 ms on local SQLite |
| Non-delta event visible to a watcher | p95 ≤ 500 ms |
| Presentation-delta flush | ≤ 250 ms or 64 KiB |
| Cancellation accepted by controller | p95 ≤ 1 s |
| Forced process/container cleanup after grace | ≤ 15 s |
| Controller queue | Bounded; high-water behavior tested with zero critical-event loss |
| Host memory headroom | ≥ 25% after declared reservations |
| Performance regression | ≤ 20% against the blessed median unless explicitly reviewed |

Warm and cold launch targets should be set after Phase 3 records Podman measurements and Phase 5 records Apple measurements on named hardware. Image pull time and provider response time are reported separately rather than hidden inside sandbox startup.

### Benchmark and load gates

The existing [performance review script](../../scripts/perf_review.exs) measures several core parsing, compilation, validation, and retention paths, but it has no pass/fail thresholds and does not exercise delegated sessions. Convert its output to versioned JSON baselines and add:

- DAG compile and condition evaluation at supported graph limits
- Durable event append, watch, replay, and compaction
- Session stream decoding under large delta and tool-output loads
- Controller mailbox and Port backpressure
- Workspace create, `bind_worktree`, `copy_snapshot`, diff, and artifact export
- Podman warm/cold start, inspection, cancellation, and reconciliation
- Apple warm/cold start, peak reservation, cleanup, and repeated-session memory behavior
- Credential proxy throughput, rate limiting, and cancellation
- 1, 2, 4, and profile-maximum concurrent delegated sessions
- Manager fan-out with nested usage and cancellation propagation

Benchmarks record host model, OS, runtime versions, image digest, repository fixture, warm/cold state, and sample distribution. CI runs stable microbenchmarks with regression thresholds; hardware-dependent sandbox and load tests run on named qualification hosts.

## Phased delivery

```text
Phase 0 ── Phase 1 ── Phase 2 ── Phase 3 ── Phase 4: Codex ── Phase 6: manager ── Phase 7: operations
                                      └── Phase 5: Apple container (parallel backend qualification)
```

Phases 4 and 5 share the Phase 3 contracts and may overlap after those contracts stabilize. Phase 6 ships Codex-backed manager orchestration after Codex works through the production Podman boundary. Phase 5 does not block Podman-based manager orchestration, but it blocks claiming Apple-backend support and the shared-host isolation mode that depends on per-session VMs.

## Phase 0 — Correct the internal execution path

### Objective

Make provider-native shots behave correctly with real providers and enforce the limits already represented in authoring.

### Work

- Introduce a provider-neutral conversation representation that preserves assistant tool calls, call IDs, names, and tool results.
- Add provider-specific codecs for OpenAI and Ollama message structures.
- Pass shot tool schemas and native structured-output requirements into `LLM.complete/4`.
- Track cumulative usage across iterations and translate remaining budget into provider output limits.
- Apply the most restrictive effective limit across operator, runtime profile, workflow, agent, and shot policy.
- Fail closed when a referenced agent is missing. Deterministic adapters are
  used only through explicit test or development injection and are never an
  operations-plane fallback.
- Define a stable shot result contract for status, text, structured output, usage, and artifacts.
- Require condition references to name declared ancestors and validate structured paths when schemas exist.
- Fix `ResourceLimiter` so released capacity is granted atomically and all eligible waiters are drained fairly.
- Turn the existing performance review into a reproducible baseline with machine-readable results.
- Clear the current warnings-as-errors failures so `make check` is a release gate again.

### Deliverables

- Canonical conversation and result data structures.
- Provider codecs and captured request/response fixtures.
- Effective-policy calculation and persisted loadout.
- End-to-end tool-round tests for each provider.
- Condition and limiter regression tests.
- Versioned Phase 0 performance baseline.

### Exit criteria

- A real or captured provider performs a multi-turn tool call with the original assistant call and tool-call ID preserved.
- Tools and structured-output schemas reach every provider in the correct native form.
- Two six-token responses cannot succeed under a ten-token cumulative budget.
- A missing agent never changes execution to a fallback provider.
- Agent iteration, token, and timeout limits change runtime behavior.
- Conditions cannot race against undeclared dependencies.
- Releasing several permits wakes and grants all eligible waiters up to capacity.
- `make check`, tests, and type checking pass on supported Elixir versions.
- Core benchmark medians remain within the approved regression budget.

### Deferred

- Dynamic child workflows.
- External coding-agent sessions.
- Remote production hardening.

## Phase 1 — Unify durable execution and safe persistence

### Objective

Make one durable state machine responsible for every daemon-owned round and prevent unsafe replay after a crash.

### Work

- Consolidate [Round.Runner](../../lib/twelvgaige/round/runner.ex) and [Round.Server](../../lib/twelvgaige/round/server.ex) behavior around the durable scheduler.
- Make foreground execution a wrapper over the same state machine.
- Commit every meaningful shot, attempt, approval, tool, and round transition.
- Consult attempt and tool intent/result journals before classifying a round as resumable.
- Persist normalized agent definitions and effective per-shot loadouts in [Round.Manifest](../../lib/twelvgaige/round/manifest.ex).
- Reject missing or hash-mismatched agents on recovery.
- Introduce a canonical redacted snapshot representation at the store boundary.
- Move large or sensitive payloads into encrypted artifacts with retention policy.
- Implement critical, operational, and presentation event classes with bounded coalescing and replay cursors.
- Chain critical audit-event digests and support exportable checkpoints.
- Enforce round timeouts, failure policies, condition-error policies, and store-error policies end to end.
- Version manifest and snapshot encodings independently of Erlang term hashes.

### Deliverables

- One daemon execution state machine.
- Versioned manifest and persistable snapshot schemas.
- Normalized agent/loadout snapshots.
- Encrypted artifact references and retention controls.
- Event compaction, cursor replay, and audit checkpoint support.
- Recovery reconciler based on state plus intent/result journals.
- Crash-injection test harness.

### Exit criteria

- Killing the daemon at every transition cannot silently rerun a completed or ambiguous side effect.
- Recovery restores the same provider, model, prompt, limits, tools, and policy or fails closed.
- A secret placed in prompt, output, dependency data, tool arguments, or tool output is absent from ordinary snapshots and logs.
- A workflow timeout changes the round state at the declared deadline.
- Every accepted policy value has a tested runtime effect; unsupported values are rejected during compilation.
- Foreground and detached runs produce the same state and event semantics.
- Critical transitions meet the local durable-acknowledgement objective under the supported event load.
- Delta floods cannot delay approval, cancellation, or terminal events beyond their reserved queue capacity.

### Deferred

- External session identity.
- Worktree and container lifecycle.
- Manager-agent fan-out.

## Phase 2 — Introduce workspace and delegated-session foundations

### Objective

Add backend-neutral workspace and delegated-session state without yet depending on a real coding-agent CLI or production sandbox.

### Work

- Add `Workspace.Manager` and isolated git-worktree lifecycle.
- Add `DelegatedSession`, normalized event storage, exact native identity, and result artifacts.
- Define `DelegatedSession.Adapter` and `Sandbox.Backend` behaviours.
- Add the integration catalog and durable `IntegrationDescriptor` resolution.
- Implement deterministic contract-test agent and sandbox adapters.
- Add bounded protocol queues, demand-driven test streams, overload signaling, and reserved control-event capacity.
- Add typed cancellation, reconciliation, and finalization state transitions.
- Add `bind_worktree` and `copy_snapshot` transport contracts.
- Generate an optional human-readable round record from immutable events.
- Keep agent-authored explanation separate from runtime-observed facts.

### Deliverables

- `Workspace.Manager` and `Workspace.Git`.
- `DelegatedSession.Supervisor`, controller, records, and adapter behaviour.
- `Sandbox.Backend` behaviour and deterministic contract-test implementation.
- Integration catalog, descriptor validation, and support-status policy.
- Handoff artifact schema.
- Round-record renderer.
- Adapter contract-test suite.

### Exit criteria

- Two deterministic write-capable test sessions cannot share a writable workspace.
- Exact-session resume rejects workspace, policy, sandbox, or auth-profile drift.
- Cancellation and daemon restart preserve one unambiguous session outcome.
- A fork receives a separate worktree; conversation history alone never implies filesystem isolation.
- `copy_snapshot` imports and exports only declared files and artifacts.
- The round record can be regenerated from persisted events.
- An unsupported, deprecated-for-new-work, blocked, or capability-incompatible integration fails admission deterministically.
- A synthetic delta flood cannot grow a controller mailbox without bound or starve approval and cancellation.

### Deferred

- Real provider credentials inside delegated sessions.
- Podman and Apple container process launch.
- Codex protocol integration.

## Phase 3 — Add Podman, credential brokering, and sandbox enforcement

### Objective

Create the first production outer boundary for delegated sessions on macOS and Linux-compatible hosts.

### Backend decision

Podman is first because it is OCI-compatible, established, and close to Linux deployment behavior. On macOS, [Podman runs containers inside a Linux VM](https://docs.podman.io/en/latest/markdown/podman-machine.1.html). The machine is shared by its session containers, so Twelvgaige must treat machine configuration as part of the security boundary.

### Work

- Implement `Sandbox.Backend.Podman` through a supervised Port and machine-readable inspection.
- Create or require one dedicated Twelvgaige Podman machine for the local installation.
- Reject restricted profiles when the machine exposes undeclared broad host mounts.
- Launch one labeled, ephemeral container per delegated session.
- Resolve images to digests and require non-root execution, read-only rootfs, dropped capabilities, `no-new-privileges`, PID, CPU, memory, and deadline limits.
- Admit only cataloged images with recorded provenance, SBOM, vulnerability result, and revocation state.
- Mount only declared workspaces and artifacts. Never expose the Podman socket, SSH agent, keychain, cloud credentials, daemon control channel, or Erlang distribution secrets.
- Canonicalize mount sources under Twelvgaige-owned roots, reject symlink or parent traversal, and compare the created container's observed mount sources with the approved manifest before launch.
- Add `network: none` and broker-only egress profiles.
- Validate every proxy destination and redirect after DNS resolution, pin the validated address for the connection, and block private, loopback, link-local, metadata, and undeclared endpoints.
- Implement the credential and provider-egress broker with short-lived session leases.
- Attest image, mounts, network, user, limits, security options, and labels before starting the agent.
- Extend resource admission to reserve sandbox count, CPU, memory, PIDs, workspace bytes, artifact bytes, and provider quota before create.
- Keep the machine and allowlisted images warm while keeping session containers ephemeral.
- Reconcile labeled containers, workspaces, and credential leases after a daemon crash.
- Quarantine unknown or mismatched resources instead of resuming them.

### Deliverables

- `Sandbox.Backend.Podman`.
- `Sandbox.Manager` and `Sandbox.Reconciler`.
- Dedicated machine bootstrap and health checks.
- Credential and egress broker.
- Versioned sandbox profiles and launch manifests.
- Podman security and fault-injection tests.
- Podman warm/cold launch, stream, proxy, cancellation, and concurrent-session baselines.

### Qualification record — 2026-08-02

The named local host now has a dedicated rootless Podman machine and a digest-pinned Linux/ARM64 worker. The checked-in qualification record includes the Containerfile, signed provenance, full SPDX SBOM, full vulnerability result, applicability review, image inspection, live boundary results, performance samples, and provider-authenticated Codex compatibility fixture under `qualification/evidence/podman-worker`.

The supply-chain gate reports zero critical and zero unreviewed high findings. The live boundary suite passed non-root/read-only execution, exact workspace mounting, `network: none`, inspected CPU/memory/PID limits, capability removal, `no-new-privileges`, crash resume, drift quarantine, descendant cancellation, credential revocation, and two concurrent sessions. The measured cached-image samples are recorded rather than promoted to cross-host SLOs from one run.

The qualified compatibility descriptor makes the outer Podman boundary authoritative and deliberately selects Codex's externally sandboxed automation mode. Restricted profiles must not silently switch modes. A future nested-sandbox descriptor must pass the same live suite without weakening the outer boundary. Qualification did not identify a reason to add worker capabilities: the concrete worker failure was a glibc-linked bundled shell that could not run on Alpine, and the qualified image now uses `/bin/sh`.

### Exit criteria

- A missing Podman VM, unsupported capability, or failed attestation prevents launch.
- A restricted profile rejects undeclared home, repository-parent, engine-socket, and credential mounts.
- The worker cannot reach the network except through declared egress.
- A real secret never appears in a child shell, prompt, event, snapshot, artifact, git diff, or crash report.
- Resource limits are visible in inspection and enforced by the container runtime.
- Declared sandbox reservations preserve the configured host headroom and cannot be oversubscribed by concurrent admission.
- `copy_snapshot` completes a coding fixture without a writable host mount.
- Killing Twelvgaige at every sandbox transition leaves resources recoverable, quarantined, or cleanly finalized.
- Cancellation stops descendant processes, revokes credentials, blocks egress, and reconciles the workspace.
- Egress tests reject DNS rebinding, redirects to private addresses, token passthrough, and undeclared telemetry endpoints.
- The supported Podman descriptor meets its recorded warm/cold and concurrency performance gates on the qualification host.

### Deferred

- Per-session VM isolation on macOS.
- Multi-agent manager plans.
- Broad operational actions from coding workers.

## Phase 4 — Add the Codex delegated-session driver

### Objective

Hand bounded coding objectives to Codex while Twelvgaige retains outer policy and recovery authority.

### Integration decision

Use the [Codex App Server](https://learn.chatgpt.com/docs/app-server) over stdio for the primary driver. It exposes thread and turn lifecycle, structured events, approvals, account state, and exact thread resume or fork. OpenAI recommends the Codex SDK for ordinary jobs and CI; Twelvgaige chooses the underlying App Server because it is building a long-lived product control plane and needs direct lifecycle and approval ownership from Elixir. Re-evaluate the SDK if maintaining the generated client becomes more expensive than a pinned sidecar. Keep `codex exec --json` as a simpler compatibility driver. TCP WebSocket transport and experimental App Server methods are outside the supported profile.

### Work

- Pin the Codex CLI artifact and generate JSON Schema from that exact version during integration packaging.
- Implement App Server startup, `initialize`/`initialized`, client identity, stable capability probing, and schema validation inside the Podman sandbox.
- Use a stable Twelvgaige `clientInfo.name`; complete OpenAI's known-client process before claiming enterprise compliance-log attribution.
- Map thread, turn, item, usage, file, command, network, and MCP events into normalized events.
- Use model and provider capability discovery rather than assuming optional features.
- Persist exact thread and turn identities.
- Bridge native approvals into digest-bound Twelvgaige action intents.
- Support exact resume, explicit fork, steering, cancellation, and finalization.
- Support isolated local user auth and brokered service auth as separate profiles.
- Keep sandbox mode and approval policy explicit per turn.
- Refuse no-sandbox/no-approval bypass in restricted profiles.
- Keep `experimentalApi` disabled and reject experimental out-of-sandbox process requests.
- Handle bounded-queue overload with deadline-aware exponential backoff and jitter before turn acceptance.
- Capture redacted raw protocol fixtures for compatibility testing.

### Deliverables

- `DelegatedSession.Adapter.CodexAppServer`.
- Optional `DelegatedSession.Adapter.CodexExec`.
- Codex event, approval, auth, and recovery codecs.
- Generated schema bundle and integration descriptor for the pinned CLI.
- End-to-end coding fixture producing commit, diff, test evidence, and handoff artifact.

### Exit criteria

- Twelvgaige starts, observes, cancels, resumes, and finalizes an exact Codex session through structured protocol messages.
- A daemon restart cannot resume the wrong thread or workspace.
- The driver rejects schema or stable-capability drift before accepting user work.
- Tool and network expansion requires a valid Twelvgaige approval receipt.
- Native subagent activity is observable and counted against the parent session budget.
- The same fixture passes in `bind_worktree` and `copy_snapshot` modes.
- A verifier can reproduce the worker's test claim from its captured result.
- App Server overload cannot create an unbounded Twelvgaige retry or mailbox queue.
- No TCP listener or experimental API is enabled in the supported sandbox profile.

### Deferred

- Automatic manager-driven fan-out.
- Apple container execution.
- Interactive PTY as a source of durable state.

## Phase 5 — Add the Apple container backend

### Objective

Provide stronger per-session isolation for supported Macs without changing agent, workspace, auth, approval, or handoff contracts.

### Backend decision

Apple's [`container` tool](https://github.com/apple/container) uses OCI images and runs [each container in a lightweight Linux VM](https://github.com/apple/container/blob/main/docs/technical-overview.md). It requires Apple Silicon and is supported on macOS 26. This provides a cleaner worker-to-worker boundary than multiple containers sharing one Podman VM.

### Work

- Implement `Sandbox.Backend.AppleContainer` through the signed CLI and an Erlang Port.
- Probe Apple Silicon, macOS version, runtime version, system-service health, and required capabilities.
- Pin a tested release and use documentation from that release tag rather than assuming the current development branch describes it.
- Persist the per-container VM identity in the common launch manifest.
- Apply the same image, user, rootfs, mount, network, credential, resource, and attestation policies used by Podman.
- Avoid exposing `container-apiserver`, XPC control channels, host Keychain data, or registry credentials to guests.
- Prefer `copy_snapshot` for high-risk profiles.
- Reserve declared VM memory at admission, measure peak host memory, and destroy completed or abandoned VMs promptly because freed guest pages may not promptly return to macOS.
- Run the complete backend-neutral security, recovery, cancellation, and agent-driver suite.
- Keep the backend contract open to a future Swift sidecar using Containerization APIs directly.

### Deliverables

- `Sandbox.Backend.AppleContainer`.
- Feature probe, health check, inspection, and reconciliation codecs.
- Podman/Apple parity test suite.
- Apple warm/cold launch, concurrent-session, cancellation, and repeated-session memory baselines.
- Backend selection and operator diagnostics.

### Qualification record — 2026-08-03

Phase 5 is implemented and qualified on the named Apple Silicon host. The backend resolves one absolute CLI path and verifies its code signature, identifier, and team before every control call; probes pinned release `1.2.0`; resolves the exact OCI repository and digest; binds the allocated VM identity into a newly sealed launch manifest; and attests the created VM before start. Podman and Apple share the same backend behavior and conformance suite, but backend selection remains explicit and never falls back automatically.

The checked-in [live qualification](../../qualification/evidence/apple-container/live-qualification.json) passed non-root and read-only execution, dropped capabilities, exact mounts, `network: none`, inspected CPU/memory/process limits, distinct VM identities, matching-identity resume, drift quarantine, denied guest control channels, credential revocation, cancellation, and cleanup. Five repeated workers and two concurrent workers stayed below the declared memory high-water policy. The [Codex provider qualification](../../qualification/evidence/apple-container/codex-provider-qualification.json) passed the same coding fixture used by the Podman compatibility path and destroyed the guest credential state and VM afterward.

The qualified outer-authoritative profile does not add Linux capabilities for Codex. Earlier failures were traced to the worker account's incompatible bundled shell; the digest-pinned worker now uses Alpine's `/bin/sh`. Codex's unified PTY execution path remains disabled only in the Apple compatibility fixture until that inner path receives its own qualification. It is not used as evidence that the outer VM needs more privilege.

### Exit criteria

- The Codex fixture passes unchanged on the Apple backend.
- Every worker receives a distinct lightweight VM identity.
- Missing or mismatched VM identity, image, mounts, network, or limits prevents resume.
- No Apple control or credential channel is reachable from the guest.
- Cancellation and crash recovery clean up or quarantine the correct VM and workspace.
- The backend meets the same credential, network, artifact, and side-effect acceptance criteria as Podman.
- Repeated sessions remain within the declared host-memory envelope, with backend restart policy when memory reclamation crosses its high-water mark.

### Deferred

- Automatic backend switching for an existing session.
- VirtualBox or another general full-VM backend.
- Making a deprecated custom macOS Seatbelt profile the primary outer boundary.

## Phase 6 — Add manager-agent orchestration

### Objective

Let an agent propose bounded parallel work while Twelvgaige remains the scheduler and authority.

### Plan shape

```json
{
  "tasks": [
    {
      "id": "api",
      "agent": "codex",
      "workflow": "coding.change.v1",
      "base_ref": "main",
      "objective": "Implement the API endpoint",
      "allowed_paths": ["lib/api", "test/api"],
      "budget": {"tokens": 50000, "time": "30m"}
    }
  ]
}
```

### Work

- Add typed manager plans validated against registered agents, workflows, repositories, budgets, capabilities, and fan-out limits.
- Allow a manager to create children without additional approval when every child remains within the already approved plan, aggregate budget, sandbox, credential, repository, network, and capability envelope.
- Pause for approval when a proposed child or plan revision expands that envelope, and before any external or destructive effect not already covered by an exact approval receipt.
- Add bounded `map`, deterministic `reduce`, `quorum`, `verify`, and registered `run_workflow` primitives.
- Propagate parent round, shot, deadline, cancellation, and budget identities.
- Enforce maximum depth, children, fan-out, tokens, cost, time, and tool calls.
- Reserve aggregate child resources before fan-out and admit children incrementally as permits become available.
- Schedule fairly across parent rounds so one large manager plan cannot monopolize workers.
- Give every write-capable child its own workspace and delegated-session identity.
- Add integration workspaces and an independent verifier role.
- Return committed or captured changes, artifacts, and verification evidence for human review; never merge automatically.
- Permit one verifier-driven automatic repair attempt, charged to the original plan budget, then stop for review if verification still fails.
- Pass selected artifacts and typed claims between workers instead of entire histories.

### Native subagents versus Twelvgaige children

| Child type | Owner | Boundary |
|---|---|---|
| Native subagent | Codex | Shares the parent session workspace, sandbox, credential boundary, deadline, and aggregate budget |
| Twelvgaige child session | Twelvgaige | Receives a separate workspace, sandbox resource, credential lease, budget, event journal, cancellation, and recovery identity |

Twelvgaige observes native subagent events and usage but does not replace the runtime's internal scheduler. A child that needs separate privileges, a writable branch, a different credential, or independent recovery becomes a Twelvgaige child session.

Supported delegated runtimes may create native subagents without a separate Twelvgaige approval when they remain inside the parent's workspace, sandbox, credential boundary, deadline, and aggregate budget. Phase 6 qualifies this behavior with Codex.

### Deliverables

- Typed manager-plan schema and compiler.
- Child-workflow scheduler and parent/child records.
- Bounded fan-out primitives.
- Integration and verifier workflows.
- Manager-level cost, progress, disagreement, and cancellation views.
- Fan-out load tests and tree-wide budget reconciliation.

### Implementation record — 2026-08-03

Phase 6 compiles each proposal as a complete, typed, bounded tree before submission. Parent relationships determine depth; dependencies form a separately validated DAG. Any later proposal is compiled and admitted again rather than mutating a running plan in place. Registered authority and the parent's effective envelope remain the source of truth, and an exact independently signed receipt is required for expansion, destructive work, or external effects.

The durable scheduler commits a plan and its initial children atomically, reserves the plan budget before fan-out, records each incremental resource permit before workspace preparation, and derives stable child workspace and delegated-session identities. It schedules parent plans fairly, enforces plan and child deadlines using observed wall time, rejects missing usage accounting, and reconciles both the aggregate reservation and child permits after restart. Parallel writers receive distinct `copy_snapshot` workspaces. Integration requires a separate workspace and an explicit artifact applier; no automatic merge operation exists.

The verifier must use a principal distinct from every contributing worker and repair ancestor. One failed verification may add one charged repair and one verifier retry if the original budget, child count, and queue limits still permit both; otherwise the plan stops for review. Native Codex subagents remain inside the parent's workspace, sandbox, auth profile, capability set, deadline, and aggregate budget, while Codex's structured subagent and usage events stay observable through the delegated-session event stream.

Requirement-to-evidence map:

| Phase 6 requirement | Evidence |
|---|---|
| Registered agents, workflows, repositories, credentials, mounts, networks, and tool capabilities | Compiler registry and expansion tests, including write-capable MCP authority |
| Full-tree depth, child, fan-out, deadline, token, cost, wall-time, and tool-call limits | Typed tree/DAG compiler tests plus scheduler deadline, maximum-fan-out, observed-time, and usage-reconciliation tests |
| Independent approval and no manager self-approval | Digest-bound intent/receipt tests covering self-approval, tampering, and exact expansion scope |
| Isolated writers and stable recovery identity | Deterministic child-factory tests and the 16-child load test with 16 distinct workspace and delegated-session IDs |
| Durable admission and restart safety | Atomic submission-store test, persisted resource-permit test, reservation reconciliation, and in-flight crash quarantine without duplicate execution |
| Independent integration and verification | Separate integration-workspace checks, explicit artifact-applier requirement, typed claims, verifier-principal checks, and repair-ancestry checks |
| Bounded queue, fair scheduling, and responsive cancellation | Cross-plan fairness, incremental admission, queue backpressure, 16-way bounded load, and 16-way cancellation tests |
| One repair attempt charged to the original plan | Repair and verifier-retry tests proving one attempt, aggregate allocation, provenance, and stop-for-review behavior |

The focused manager suite passes 28 tests. The current repository-wide `make check` gate passes 1,111 tests and properties, and `make typecheck` reports zero Dialyzer errors.

### Exit criteria

- A manager cannot create an unregistered agent, workflow, repository, mount, credential, or tool capability.
- Child permissions never exceed the parent's effective policy.
- Fan-out, depth, budget, deadline, and cancellation limits apply across the full tree.
- Parallel writers use separate workspaces.
- A manager cannot approve its own safety gate.
- Integration uses committed or captured artifacts, and an independent verifier can reject unsupported claims.
- Restart does not duplicate child creation or lose parent/child accounting.
- A saturated manager plan applies backpressure without unbounded queued children, and cancellation remains responsive at maximum supported fan-out.

### Deferred

- Arbitrary runtime-generated workflow code.
- Unbounded recursive spawning.
- Automatic production deployment by a coding manager.

## Phase 7 — Operational hardening and unattended local operation

### Objective

Make the system support reliable unattended operation for one local user without weakening earlier guarantees.

### Work

- Add session inventory, attach/takeover, backend health, orphan reconciliation, and retention controls.
- Add cost, token, rate, queue, sandbox, and nested-agent dashboards.
- Bind daemon access, session capabilities, files, and runtime resources to the current local OS user.
- Add token rotation, session revocation, and authenticated audit export for local unattended operation.
- Implement provider RPM, TPM, cooldown, and `Retry-After` handling.
- Make scheduler state, misfire behavior, and overlap policy durable.
- Make any enabled local automation trigger replay-safe across restarts.
- Reject non-loopback control-plane binding in supported configurations.
- Replace whole-file store rewrites for serious daemon workloads.
- Add schema migrations, backup/restore, encrypted artifact rotation, and retention enforcement.
- Default raw transcript and artifact retention to 30 days and security/audit retention to 90 days. Allow the local user to configure both periods without weakening retention required for an active or safely resumable session.
- Add cross-repository workspace support with recorded input and output commits.
- Add protocol compatibility fixtures and backend conformance runs to release gates.
- Define availability, launch, cancellation, recovery, queue, and data-retention SLOs for the supported local host profiles and connect them to error budgets.

### Implementation and qualification record — 2026-08-08

Phase 7 implements the supported deployment as a single-user local control plane. The daemon endpoint, control token, session epochs, runtime directories, database, artifacts, workspaces, credential leases, and managed runtime labels are bound to the current OS user. Supported control listeners remain on loopback. Session inventory, show, attach, epoch-checked takeover, revoke, sandbox health and reconciliation, dashboard, token rotation, authenticated audit export, store backup and restore, retention, artifact inventory and key rotation, and release-check operations are exposed through the local authenticated IPC path.

The operational store uses versioned SQLite migrations and transactional updates. Durable scheduler state records misfire and overlap decisions, and trigger claims prevent replay after restart. Provider admission enforces RPM, TPM, daily cost, cooldown, and `Retry-After` state. Raw transcripts and artifacts default to 30-day retention; security and audit records default to 90 days. The user can configure both periods, and the setting governs session data, audit events, credentials, egress leases, provider state, and encrypted artifacts. Active and resumable sessions, active or orphaned credential leases, and unfinished cross-repository sets retain durable holds until they reach a safe terminal or reconciliation state.

Backup creation strips control tokens and live session authority before it reports success. Restore uses a staged database, increments session control epochs, clears credential and egress lease bindings, places active sessions into reconciliation, verifies the latest signed audit checkpoint, and installs the result only after every check passes. A failed restore does not replace or delete an existing destination. The audit chain supports retained-prefix pruning through a durable chain anchor. A separately signed append-only NDJSON checkpoint chain lives outside the database, can be mirrored to an optional private external destination, repairs a valid one-sided append seam after a crash, and reports healthy, stale, missing, invalid, or divergent state through the dashboard and authenticated CLI.

Reconciliation now acts on every resource class it reports. Unknown backend resources can be destroyed only under the explicit destructive flag. Unknown workspaces move into a private recoverable quarantine. Unbound or restart-orphaned credential and egress leases are revoked, and any otherwise running session tied to an orphaned lease is moved to `awaiting_reconciliation`. Cross-repository workspace sets persist the repository identity and every input and resulting commit in the operational store; a store restart test proves that provenance survives the workspace-manager process.

Broker-only egress is now a real data-plane boundary, not just a policy object. Every session receives a dedicated internal network and an ephemeral authenticated proxy capability. The worker has no direct outbound route. A separate non-root, read-only, capability-free proxy validates the capability, host, port, expiry, connection budget, DNS answer, and pinned destination address before connecting. It rejects loopback, private, link-local, mapped, metadata, and undeclared destinations, and its audit records exclude the capability. Revocation destroys the proxy before worker cleanup. An explicit unrestricted profile remains available only when the user selects that authority.

The same boundary passes on Podman and Apple containers. Apple container `1.2.0` required one backend-specific ordering rule: a dual-homed VM must attach to the outbound `default` network first and the worker-facing host-only network second. The runtime gives the first interface the default route, and the inverse order caused incorrect peer ARP behavior in the live probe. The qualified order preserves both outbound proxy access and isolated worker-to-proxy access. No Linux capabilities were added to either the worker or proxy, and the runtime never falls back automatically to a weaker topology.

The proxy image is built without network access from a scratch image, runs as `65532:65532`, and is referenced by exact digest. Its signed record binds source, Containerfile, image inspection, OCI archive, SPDX SBOM, and vulnerability results. The release gate verifies the signature against the checked-in trusted-key policy, checks all evidence digests, requires zero critical and zero high findings, and rejects a stale or invalid vulnerability database. Live qualification then proves direct denial, capability enforcement, allowed access, private and undeclared denial, DNS pinning, audit redaction, and cleanup on both backends.

Versioned SLO profile `1` covers availability, launch success and latency, cancellation, recovery success and latency, queue admission, retention success, and retention lag. Candidate qualification records five successful launches per backend plus live queue and retention samples, then evaluates the associated error budgets. Rolling availability and error-budget consumption still require real elapsed operational history; the candidate artifact does not pretend that five launches equal a 30-day production window.

The [release qualification artifact](../../qualification/evidence/release-qualification.json) evaluates ten mandatory checks covering Codex schema and protocol conformance, both sandbox backends, signed egress supply-chain evidence, broker-only egress, and operational SLOs. Evidence binds named security checks to source digests, so a changed contract fails closed until qualification is regenerated. Tests prove that a backend security regression, driver schema regression, incomplete evidence, unsigned image record, or stale source digest blocks release.

Qualification traceability:

| Phase 7 contract | Authoritative proof |
|---|---|
| Session inventory, attach, takeover, revoke, backend health, resource reconciliation, and local-user binding | `session_control_test.exs`, `operator_ipc_test.exs`, and `cross_session_isolation_test.exs` |
| Cost, token, rate, queue, sandbox, nested-agent, automation, and audit-checkpoint visibility | Authenticated dashboard assertions in `operator_ipc_test.exs`, plus provider and scheduler status tests |
| Loopback-only control and protected runtime files | `api/server_test.exs`, Breech IPC/daemon tests, `operations/keys_test.exs`, and operations supervisor tests |
| RPM, TPM, daily cost, cooldown, and `Retry-After` behavior | `provider_limiter_test.exs` and `provider_runtime_integration_test.exs` |
| Durable misfire, overlap, next-occurrence, and replay decisions | `scheduler_durability_test.exs` and the scheduler restart tests |
| SQLite migration, retention, backup, restore, authority stripping, and audit normalization | `store_test.exs`, including a version-2 migration fixture, configurable retention boundaries, staged replacement safety, and signed-checkpoint restore rejection |
| Signed external audit anchoring | `audit_anchor_test.exs`, covering restart, staleness, tampering, retained-prefix pruning, private files, and one-sided append recovery |
| Active holds and encrypted artifact lifecycle | `retention_integration_test.exs`, artifact-store tests, credential and egress broker tests, and key-rotation tests |
| Cross-repository inputs and outputs | `workspace/set_test.exs`, including persistence and store-restart recovery of every base and resulting commit |
| Protocol and backend release failure | `protocol_conformance_test.exs`, backend live evidence, and `release_gate_test.exs` regression cases |
| Published SLOs and error budgets | `operations/live-qualification.json`, source-bound security evidence, and the ten-check `release-qualification.json` matrix |

Runtime activation remains explicit for this single-user mode. `TWELVGAIGE_OPERATIONS_ENABLED=1` enables the operations supervisor; runtime configuration registers both supported backends, uses the dedicated Podman machine name, retains the OS-protected master key, and accepts user overrides for the data root, both retention periods, and an optional private external audit-checkpoint path.

### Deliverables

- Operator session and sandbox commands.
- Local-user identity and control-transport policy.
- Durable scheduler and local API protections.
- Rate and cost control plane.
- Store and artifact operational tooling.
- Release qualification matrix.

### Exit criteria

- Orphaned sessions, containers, VMs, workspaces, and credential leases are discoverable and reconcilable.
- Cross-session workspace, credential, capability, quota, and audit isolation is enforced by integration tests.
- Local automation admission, replay protection, and scheduler decisions survive restart.
- Provider backoff and rate behavior are visible and tested.
- Backup and restore preserve exact recovery identity without restoring live credentials.
- Cross-repository results record every base and resulting commit.
- A release cannot pass when a supported driver or sandbox backend fails its conformance suite.
- The supported local single-user mode meets its published SLOs and security gate.

## Release milestones

| Milestone | Included phases | User-visible result |
|---|---:|---|
| A: Reliable internal harness | 0–1 | Correct live tools, enforced policy, crash-safe durable rounds |
| B: Delegated-session foundation | 2–3 | Workspace, session, credential, and Podman contracts validated with a deterministic test worker |
| C: Codex handoff | 4 | Supported stable-schema Codex session start, observe, approve, cancel, resume, and handoff |
| D: Strong macOS isolation | 5 | Per-session lightweight VM backend on supported Macs |
| E: Governed Codex teams | 6 | Typed manager plans, bounded Codex workers, integration, and verification |
| F: Unattended local operations | 7 | Scheduled, observable, rate-controlled operation for one local user |

Each milestone is independently useful. Manager-agent execution is intentionally late because it multiplies every correctness, recovery, credential, and sandbox failure beneath it.

## Cross-phase verification strategy

### Contract tests

- Provider conversation and tool codecs.
- Agent adapter behavior.
- Sandbox backend behavior.
- Credential lease and egress behavior.
- Workspace import/export and handoff schemas.
- Store and manifest encoding.
- Integration descriptor, support status, capability negotiation, and error taxonomy.
- Audit digest chain and checkpoint verification.

### Fault injection

Terminate Twelvgaige, the controller, agent process, container, VM, broker, and store at every state transition. Verify that the result is one of:

- Safely resumable
- Conclusively completed
- Conclusively failed or cancelled
- Explicitly ambiguous and blocked for reconciliation

It must never become an unrecorded replay.

### Security tests

- Attempt to read host home, repository parents, credentials, sockets, daemon state, and Erlang distribution material.
- Attempt undeclared network access and access to local/private addresses.
- Inspect child environments and persisted artifacts for seeded secrets.
- Attempt workspace traversal, symlink escape, shared git corruption, and engine-socket access.
- Attempt unsigned or revoked images, runtime artifacts, sidecars, MCP servers, and schema substitutions.
- Attempt MCP token passthrough, confused-deputy consent bypass, redirect manipulation, session hijack, and OAuth/MCP SSRF.
- Modify a launch manifest after approval and confirm the run is rejected.
- Disable or break the inner and outer sandboxes and confirm fail-closed behavior.

### Integration matrix

| Dimension | Required variants |
|---|---|
| Agent path | Provider-native, Codex |
| Sandbox | Test adapter, Podman, Apple container on supported Macs |
| Workspace | `bind_worktree`, `copy_snapshot` |
| Auth | Isolated local profile, brokered service profile |
| Recovery | Clean restart, controller crash, runtime crash, sandbox loss, ambiguous intent |
| Work shape | Single worker, native subagent, Twelvgaige child, verifier |
| Integration version | Supported descriptor, prior resumable descriptor, canary candidate, revoked descriptor |
| Deployment mode | Local single-user only |

## Cross-cutting release gates

| Dimension | Required evidence before promotion |
|---|---|
| Strategy | The phase completes one named user journey, honors its deployment-mode boundary, has an operator rollback/disable path, and does not depend on a deferred security claim |
| Security | Threat-model delta reviewed; no open critical/high finding in the shipped path; secret, sandbox-escape, cross-session, approval-replay, and supply-chain tests pass |
| Performance | Named-host benchmark and load results meet absolute SLOs and regression budgets; queues remain bounded; cancellation and recovery remain responsive at capacity |
| Third-party integration | Descriptor, artifact and schema digests, capability negotiation, terms/license review, conformance fixtures, canary run, failure mapping, and revocation path are complete |
| Durability | Fault injection at every new state transition yields completed, safely resumable, failed/cancelled, or explicitly ambiguous state without duplicate effects |
| Operations | Health, metrics, traces, audit events, runbook, feature flag, and compatibility/deprecation notes exist for the shipped surface |

The phase owner records this evidence in a release qualification artifact. A green unit-test suite alone does not satisfy a cross-cutting gate.

## Migration and compatibility

- Add schema versions before persisting new delegated-session or sandbox records.
- Feature-gate `delegated_sessions`, `podman_backend`, `apple_container_backend`, and `manager_plans` independently.
- Refuse to recover an old round when exact agent, auth, workspace, or sandbox identity is unavailable.
- Never select deterministic test adapters as an automatic runtime fallback.
- Preserve old read APIs where practical, but do not fabricate missing security identity for compatibility.
- Resolve `backend: auto` into a concrete manifest before approval and persistence.
- Keep runtime-native transcripts as supporting artifacts; Twelvgaige events remain the control-plane record.
- Persist integration descriptor revisions and generated schema digests before enabling real drivers.
- Promote new third-party descriptors for new sessions only; do not rewrite resumable session identity.
- Version performance baselines by host profile, fixture, integration descriptor, and sandbox backend.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Provider protocol drift | Capability probes, redacted fixtures, adapter conformance tests |
| Third-party update changes security or terms | Pinned descriptors, artifact verification, terms review, canary promotion, revocation |
| Credential reaches child tools | Short-lived proxy token, scrubbed environment, egress broker, seeded-secret tests |
| Shared git metadata corruption | Isolated git directory or `copy_snapshot`; one writer per workspace |
| Container escape reaches shared Podman VM | Dedicated machine, no broad host mounts, no engine socket, Apple per-session VM for stronger profiles |
| Daemon restart duplicates effects | One durable state machine, intent/result journals, explicit ambiguity |
| Manager multiplies cost or fan-out | Tree-wide hard budgets, depth and child caps, admission before creation |
| Native subagent usage is incomplete | Aggregate parent budget, normalized subagent events, provider usage reconciliation |
| Agent claims success without evidence | Typed artifacts and independent verifier |
| MCP or plugin crosses an authority boundary | Default-off catalog, scoped OAuth, no token passthrough, SSRF-resistant egress, Twelvgaige approval |
| Event flood exhausts BEAM memory | Bounded Port reads and queues, delta coalescing, reserved control capacity, output caps |
| Warm pools leak state between users | Warm images and machines only; never reuse an agent process across principals or workspaces |
| Apple backend is unavailable | Explicit Podman fallback only for new sessions; never change an existing session backend |
| New lifecycle code enlarges existing modules | Separate workspace, sandbox, delegated-session, credential, scheduler, and recovery components |

## Initial Engineering Recommendations And Validation Gates

These were the implementation baselines used to answer the review's remaining
engineering questions. The table preserves the original validation gates; the
implementation-status and evidence sections at the top of this document record
the resulting qualified behavior. A later validation may refine a mechanism or
target, but it must not silently weaken the security boundary.

| Area | Recommended baseline | Validation gate |
|---|---|---|
| Provider proxy exposure | Give each sandbox a dedicated guest-visible broker gateway authenticated by a short-lived, session-specific capability. Route only declared destinations through it. Do not expose general host loopback, unrelated host services, control sockets, or an unrestricted route to the host. | Phase 3 must prove destination enforcement, capability expiry and revocation, DNS-rebinding resistance, and denial of host, private, loopback, link-local, and metadata addresses on Podman. Phase 5 repeats the same suite on Apple containers. |
| Mandatory sandbox capabilities | Maintain one backend conformance matrix covering filesystem and mount isolation, read-only roots, user identity, process and PID limits, network policy, credential delivery, resource limits, cancellation, cleanup, and launch-manifest attestation. Each profile marks capabilities as required or optional. Admission fails closed when a backend cannot enforce a required capability. | A backend cannot become supported until every required profile passes the common contract and escape suite. Capability loss during an upgrade blocks new sessions and exact resume when the original boundary cannot be restored. |
| Performance and concurrency targets | Measure cold launch, warm launch, cancellation, cleanup, memory overhead, workspace transfer, and stable concurrent-session capacity on named Mac models and OS/runtime versions. Publish targets only after repeatable qualification runs; do not invent thresholds before measurement. | Phases 3 and 5 establish Podman and Apple baselines. Phase 7 turns the measured baselines into versioned release gates and reruns them for runtime, image, OS, or backend upgrades. |
| Third-party maintenance ownership | Assign one integration maintainer role initially. That owner reviews terms and licenses, security advisories, image patches, SBOM and vulnerability results, runtime descriptors, MCP catalog entries, deprecations, and emergency revocations using a checked-in release checklist. Catalog promotion and revocation are explicit, auditable changes. | Phase 2 defines the role, checklist, review evidence, and emergency path. Every supported integration must name an owner before promotion; an unowned integration cannot remain supported. |
| Audit checkpoint anchor | Periodically sign the audit-chain head with a key held by the host control plane and protected by macOS Keychain. Export signed checkpoints to an append-only local file outside the primary database, with an optional configurable external destination. Verify the chain and latest exported checkpoint during audit, restore, and recovery checks. The signing key is never available inside an agent sandbox. | Phase 1 proves signing, export, verification, rotation, truncation detection, and restore behavior. Phase 7 adds retention enforcement and operator-visible health for stale, missing, or invalid checkpoints. |

## Decision log

| Decision | Status |
|---|---|
| Twelvgaige is the outer control plane for internal and delegated agents | Accepted |
| Codex retains its native inner tool and subagent loops | Accepted |
| Structured protocols are authoritative; PTY attachment is optional | Accepted |
| OTP supervises sandboxes but is not a security sandbox | Accepted |
| Podman is the first production sandbox backend | Accepted |
| Apple container is the stronger macOS-specific backend | Accepted |
| Podman is the macOS default; Apple container is explicit until qualified | Accepted |
| Every parallel writer gets an independent workspace | Accepted |
| Unattended sessions default to `copy_snapshot`; `bind_worktree` is explicit and interactive | Accepted |
| Exact session IDs replace “last session” recovery | Accepted |
| Credential references and short-lived leases replace durable secrets | Accepted |
| Interactive sessions may use supported local account login; unattended sessions require API, cloud, or gateway credentials | Accepted |
| Restricted egress is the default; unrestricted internet egress is an explicit audited flag | Accepted |
| Approvals bind exact normalized actions and scopes | Accepted |
| Native subagents and Twelvgaige child sessions remain distinct | Accepted |
| Native subagents may run inside the parent's authority without separate approval | Accepted |
| Manager agents propose work; the runtime creates and governs children | Accepted |
| Managers may create children inside an approved plan envelope; expansion or external/destructive effects require approval | Accepted |
| Service profiles disable ambient MCP, plugins, hooks, skills, and config discovery | Accepted |
| Cataloged write-capable MCP integrations are supported in the initial release | Accepted |
| Stable protocol surfaces are required for supported integrations | Accepted |
| Results return as commits or patches plus evidence for human integration; Twelvgaige never auto-merges | Accepted |
| Native runtime auto-approval is honored only within Twelvgaige's granted authority envelope | Accepted |
| The outer sandbox is authoritative; native sandbox composition is descriptor-specific and never downgraded automatically | Accepted |
| A failed verifier permits one budgeted automatic repair attempt | Accepted |
| Supported images are signed and digest-pinned; custom images are explicit and unsupported | Accepted |
| Raw transcripts and artifacts default to 30 days; security and audit records default to 90 days | Accepted |
| New work uses the current pinned runtime descriptor; the previous descriptor may resume for 30 days | Accepted |
| Queues and external streams are bounded with reserved control capacity | Accepted |
| Local single-user operation is the only supported deployment mode | Accepted |
| Native custom Seatbelt and VirtualBox backends | Deferred |

## Appendix A — Evidence behind Phase 0 and Phase 1

### Live provider tool protocol

[Shot.Executor](../../lib/twelvgaige/shot/executor.ex) does not currently pass shot tool schemas or native structured-output requirements into `LLM.complete/4`. Provider adapters serialize generic role/content maps and lose the assistant's original tool calls, tool-call IDs, names, and provider-specific result structures.

A captured OpenAI transport showed:

- No `tools` in the first request.
- A follow-up assistant message containing only empty content.
- A tool result without its `tool_call_id`.
- No original assistant tool-call record.

Hosted providers require different native message structures, which is why Phase 0 introduces a provider-neutral representation with provider-specific codecs.

### Detached recovery

Ordinary detached runs use [Round.Runner](../../lib/twelvgaige/round/runner.ex), while scheduler-owned runs use [Round.Server](../../lib/twelvgaige/round/server.ex). Runner journals attempts and tools but does not commit every intermediate transition. After a whole-daemon crash, the snapshot can still show every shot pending even though side effects ran. Existing recovery may classify that state as resumable before inspecting ambiguity in the journals.

Phase 1 removes this split and makes journal reconciliation mandatory.

### Agent identity loss

[Round.Manifest](../../lib/twelvgaige/round/manifest.ex) records hashes and source paths, but not normalized definitions or effective shot loadouts. [Breech](../../lib/twelvgaige/breech.ex) restores the workflow without the original agents. [Loadout](../../lib/twelvgaige/loadout.ex) may then fall back to the default provider.

Phase 1 persists normalized identity and fails closed on drift.

### Sensitive snapshots

Attempt and tool journals are redacted, but ordinary snapshots can contain raw prompts, output, dependency data, and tool arguments or results. A reproduction against the memory store returned a seeded secret intact from `get_round/1`. [Redactor.redact_json/1](../../lib/twelvgaige/redactor.ex) also leaves arbitrary structs unchanged.

Phase 1 places redaction and artifact extraction at the store boundary.

### Parsed but unenforced policy

Agent shells accept token, iteration, and timeout limits, but effective loadouts currently omit them. Workflow timeout is parsed without scheduling a round timer. Failure, condition-error, and store-error policies do not consistently govern transitions. Token budgets are checked against the current response rather than accumulated use.

Phase 0 enforces per-shot and cumulative limits; Phase 1 enforces round and recovery policy.

### Conditions and limiter

Completed shot state exposes a provider envelope rather than a stable result shape. Condition references are not required to name ancestors, so parallel scheduling can make their result order-dependent. The resource limiter can release several permits while notifying only one queued waiter.

Phase 0 defines the result contract, validates dependencies, and grants available permits atomically.

## Appendix B — Session-harness comparison distilled

A session-oriented coding harness and Twelvgaige work at different layers:

| Area | Session-oriented harness | Twelvgaige target |
|---|---|---|
| Unit of work | Coding task or session | Shot, round, delegated session, and child workflow |
| Agent execution | Complete external coding agent | Internal provider loop or external coding agent |
| Coordination | Human-managed parallel tasks | Typed DAG plus bounded manager proposals |
| Isolation | Worktree and container | Workspace, sandbox backend, narrow tools, and runtime policy |
| Recovery | Native agent session | Round, agent, tool, workspace, auth, and sandbox reconciliation |
| Approval | Often plan or prompt based | Typed runtime state and digest-bound action receipts |
| Output | Branch, commits, task record | Structured result, artifacts, journals, events, and commits |

Useful ideas retained in this plan:

- First-class isolated workspaces.
- Resuming the native agent session, not only the workflow.
- Host-side credentials and provider egress.
- Human-readable task records generated from runtime events.
- Explicit cross-repository inputs and outputs.
- A control plane above complete coding-agent runtimes.

Ideas intentionally rejected:

- Unrestricted shell access as the default execution model.
- Prompt instructions as authorization.
- Broad host mounts and shared git metadata for unattended workers.
- Letting backend-specific terminal or session quirks leak into core state.
- Adding more giant modules for workspace, sandbox, session, and recovery lifecycle.

## Appendix C — Baseline verification

At the time of the review:

- `make test-all`: **931 passed**, with 14 live or environment-specific tests excluded.
- `make typecheck`: **passed**, with zero Dialyzer errors.
- `make check`: **failed** under supported Elixir 1.20 because warnings are errors:
  - Redundant parser clause in [output/parser.ex](../../lib/twelvgaige/output/parser.ex).
  - Unused and unreachable clauses in [loadout.ex](../../lib/twelvgaige/loadout.ex).
  - Redundant boolean normalization in [metrics.ex](../../lib/twelvgaige/metrics.ex).

This baseline describes the reviewed code. Each phase establishes a new verification gate rather than treating the baseline test count as proof of the new behavior.

## Appendix D — Performance baseline evidence

The existing review script was run with `MIX_ENV=test mix run scripts/perf_review.exs` on 2026-08-01 using macOS 26.6 on arm64, Erlang/OTP 29, and Elixir 1.20.2. CPU model and memory were not captured, so this is evidence from the review host rather than a blessed comparison baseline. Results are microseconds per operation:

| Case | Iterations | Best | Median | Worst |
|---|---:|---:|---:|---:|
| Old quadratic duplicate scan | 3 | 101,941 | 102,640 | 103,614 |
| MapSet duplicate scan | 30 | 715 | 779 | 797 |
| Condition shot references | 30 | 298 | 319 | 339 |
| Compile 1,000-shot chain | 10 | 1,074 | 1,201 | 1,379 |
| Validate 300-field object | 20 | 288 | 296 | 312 |
| Retention stats for 5,000 rounds | 30 | 1,515 | 1,540 | 1,595 |
| Output parser candidates | 100 | 3 | 4 | 5 |

The results confirm that recent MapSet and single-pass changes substantially improve selected core paths, but the script currently prints observations rather than enforcing thresholds. It does not measure durable stores, event streaming, Port backpressure, workspaces, sandboxes, credentials, third-party drivers, recovery, or concurrent sessions. The performance plan therefore treats this as the starting microbenchmark suite, not evidence that the target architecture meets a service objective.

The run also reproduced the warnings-as-errors issues listed in Appendix C. Phase 0 keeps warning cleanup and baseline conversion in the same gate so future performance runs are clean and machine-readable.

## Appendix E — Primary integration references

- [Codex App Server](https://learn.chatgpt.com/docs/app-server)
- [Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Codex approvals and sandbox security](https://learn.chatgpt.com/docs/agent-approvals-security)
- [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
- [Podman machine](https://docs.podman.io/en/latest/markdown/podman-machine.1.html)
- [Apple container](https://github.com/apple/container)
- [Apple container technical overview](https://github.com/apple/container/blob/main/docs/technical-overview.md)
- [MCP security best practices](https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices)
