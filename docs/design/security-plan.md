# Security Plan

This file tracks security review and hardening work for Twelvgaige. The goal is
zero-trust within reason for a local-first agent orchestration tool: untrusted
LLM output, untrusted tool output, trusted runtime configuration, narrow host
authority, and explicit operator approval for risky side effects.

## Review Passes

| Pass | Focus | Status | Exit Criteria |
| --- | --- | --- | --- |
| 0 | Security boundary inventory and docs | In progress | `security.md` exists, known gaps are listed without overclaiming, and findings are tracked here. |
| 1 | Control-plane auth, TLS/mTLS, IPC limits, provider transport | In progress | Mutating HTTP routes require auth, remote HTTP requires TLS/mTLS or explicit proxy mode, provider TLS verification is tested, IPC frames are bounded. |
| 2 | Host, tool, HTTP egress, and Kubernetes authority | In progress | Command runner uses scrubbed env/cwd/output caps, Kubernetes context/namespace/resource policies are runtime allowlists, HTTP tools close DNS-rebinding gaps. |
| 3 | Storage, logs, redaction, audit integrity | In progress | Stores/logs use private modes, raw sensitive journals are reduced/redacted, canary-secret tests cover logs/audit/store/API, audit integrity design exists. |
| 4 | Prompt injection, adversarial E2E, packaging, supply chain | Planned | Prompt-injection regression suite exists, k3d least-privilege E2E exists, release artifacts have checksums, dependency/update review is documented. |

Each pass should record:

- claims checked,
- code paths reviewed,
- tests added,
- known residual risks,
- docs weakened or strengthened.

## Findings Register

| ID | Severity | Finding | Status | Target Pass |
| --- | --- | --- | --- | --- |
| SEC-001 | High | Mutating loopback HTTP routes can run without bearer auth when no token is configured. | Fixed | 1 |
| SEC-002 | High | Non-loopback HTTP API uses plaintext `:gen_tcp`; bearer tokens require TLS/mTLS or a trusted proxy. | Mitigated | 1 |
| SEC-003 | High | `approve_all_safety?` can bypass safety gates through trusted runtime/API paths. | Mitigated | 1 |
| SEC-004 | High | Provider TLS verification is not explicitly configured/tested in the default transport. | Partial | 1 |
| SEC-005 | High | Provider endpoint overrides block literal private hosts but do not DNS-resolve before sending credentials. | Fixed | 1 |
| SEC-006 | High | HTTP tools pre-resolve DNS but connect through original hostnames, leaving DNS rebinding risk. | Fixed | 2 |
| SEC-007 | High | Command subprocesses inherit ambient environment/cwd and lack runner-level streaming output caps. | Fixed | 2 |
| SEC-008 | High | Kubernetes `context` and `namespace` are model/tool input, not runtime-only allowlisted policy. | Fixed | 2 |
| SEC-009 | Medium | Workflow-adjacent `agents/` auto-discovery expands trust to nearby repo files. | Fixed | 2 |
| SEC-010 | Medium | Store/log files do not consistently enforce private directory/file permissions. | Fixed | 3 |
| SEC-011 | Medium | Audit/events are durable but not tamper-evident. | Mitigated | 3 |
| SEC-012 | Medium | Tool journals may persist raw sensitive inputs and outputs. | Fixed | 3 |
| SEC-013 | Medium | Redaction is best-effort and lacks broad canary-secret coverage across every output surface. | Partial | 3 |
| SEC-014 | Medium | Prompt injection remains a first-class risk when tool/dependency output re-enters model context. | Open | 4 |
| SEC-015 | Medium | HTTP/IPC connection handlers are linked to listener accept loops more tightly than desired. | Mitigated | 1 |
| SEC-016 | Medium | IPC auth uses plain equality and IPC envelopes lack explicit max frame limits. | Fixed | 1 |
| SEC-017 | Medium | Destructive tools do not require a compiler-enforced dependency on a prior safety shot. | Mitigated | 2 |
| SEC-018 | Medium | Kubernetes-specific audit payloads do not yet fully match the spec-level audit claim. | Mitigated | 3 |

## Pass 1: Control Plane And Transport

### Objectives

- Make HTTP control-plane mutation authenticated by default.
- Prevent accidental remote plaintext control-plane exposure.
- Add native TLS/mTLS design or require explicit trusted-proxy mode.
- Harden provider TLS verification.
- Bound IPC envelopes and token comparisons.

### Work Items

- [x] Require bearer auth for all mutating HTTP routes, even on loopback.
- [x] Add tests for unauthenticated `POST`, `DELETE`, approve, reject, cancel,
      and any future mutation endpoint.
- [x] Reject `access_token` query parameters for all routes; keep RFC 6750
      challenge behavior.
- [x] Forbid non-loopback `API.Server` bind unless one of these is true:
      native TLS/mTLS is configured, or an explicit `behind_tls_proxy?: true`
      mode is set with strong documentation.
- [ ] Add native TLS/mTLS design: CA, server cert/key, client CA, SNI,
      minimum TLS version, rotation behavior, and test fixtures.
- [x] Remove or restrict `approve_all_safety?` over HTTP/IPC. It should be
      local test/dev-only unless a privileged runtime policy enables it.
- [x] Add IPC max envelope size before JSON decode.
- [x] Replace IPC bearer equality with constant-time comparison.
- [x] Move API/IPC connection workers to isolated, unlinked, supervised tasks
      or prove current link behavior cannot take down listeners.
- [ ] Add provider default transport TLS verification options and tests for
      invalid CA/hostname cases.
- [x] Add official provider host allowlists for default endpoints.
- [x] Add DNS resolution checks for provider endpoint overrides before auth
      headers are sent.

### Acceptance Tests

- [x] Unauthenticated mutating HTTP routes return `401`.
- [x] Query bearer tokens return `400` with `WWW-Authenticate`.
- [x] Non-loopback HTTP bind without TLS/proxy mode fails.
- [ ] Provider requests fail on invalid cert/hostname in live/fake TLS tests.
- [x] IPC oversized envelope is rejected before decode.
- [x] IPC auth comparison does not use direct string equality.

## Pass 2: Host, Tool, Egress, And Kubernetes Boundaries

### Objectives

- Reduce ambient host authority for subprocess tools.
- Make Kubernetes target selection runtime policy, not model discretion.
- Close HTTP egress DNS/redirect gaps.
- Treat workflow/agent bundles as trusted policy with provenance.

### Work Items

- [x] Add command runner options for absolute binary paths.
- [x] Add command runner `cwd` and refuse implicit ambient cwd for tools that
      can mutate state.
- [x] Add environment scrub mode with explicit env allowlist.
- [x] Preserve only needed variables such as trusted `KUBECONFIG` when
      configured by runtime policy.
- [x] Add runner-level captured output caps.
- [x] Add streaming stdout/stderr caps before full output is buffered.
- [x] Separate stdout and stderr instead of merging all stderr into stdout.
- [x] Add process-tree cancellation strategy where the OS supports it.
- [x] Add Kubernetes runtime policies:
      `allowed_contexts`, `allowed_namespaces`, `allowed_resources`,
      `allowed_name_patterns`, and `allowed_selector_patterns`.
- [x] Move Kubernetes context/kubeconfig selection to trusted runtime policy.
- [x] Add explicit docs for least-privilege kubeconfig/service-account use.
- [x] Require an unconditional safety-shot dependency for non-read-only tools
      unless a local-dev override is set.
- [x] Make workflow-relative agent auto-discovery configurable and disabled for
      untrusted roots.
- [x] Store shell/agent provenance and hashes in the run manifest.
- [x] Disable HTTP redirect following in default transports, or ensure each
      redirect is revalidated before follow.
- [x] Close DNS-rebinding gap by connecting to vetted IPs with Host/SNI
      preserved, rechecking peer IP, or requiring explicit `allowed_hosts` for
      HTTP tools.

### Acceptance Tests

- [x] Kubernetes tool rejects non-allowlisted context/namespace/resource.
- [x] Command runner does not inherit a canary secret env var in scrubbed mode.
- [x] Command runner captures stdout and stderr separately on POSIX.
- [x] Command runner fails before loading oversized stdout/stderr into memory.
- [x] Command runner timeout cancels the POSIX process group when `setsid` and
      `kill` are available.
- [x] HTTP tools require explicit `allowed_hosts` and reject resolver results
      containing any private IP before transport.
- [x] Destructive workflow shots fail validation unless unconditional safety
      dependency policy is satisfied.

## Pass 3: Storage, Logs, Redaction, And Audit Integrity

### Objectives

- Treat persistence as sensitive local data.
- Make file permissions conservative.
- Reduce stored sensitive data by default.
- Add tamper-evidence for audit/event streams.

### Work Items

- [x] Enforce `0700` runtime/store/log directories where supported.
- [x] Enforce `0600` store/log files where supported.
- [x] Handle SQLite `-wal` and `-shm` sidecar permissions.
- [x] Refuse obviously world-writable parent directories on POSIX platforms.
- [x] Redact or omit raw tool journal input/output by default.
- [x] Add high-sensitivity retention mode that stores summaries instead of raw
      prompts/tool outputs.
- [~] Add canary-secret regression tests across:
      logs, audit events, round watch, IPC, HTTP API, File store, SQLite store,
      provider errors, tool errors, Kubernetes output, HTTP tool headers.
- [x] Add audit hash chaining or HMAC signing design.
- [x] Add audit export checkpoint format for future external notarization.
- [x] Add allowlisted tool audit payload projections for Kubernetes target and
      execution metadata without raw command output.
- [x] Document that there is no encryption at rest until an explicit SQLCipher
      or OS keychain/KMS design is implemented.

### Acceptance Tests

- [x] File and SQLite stores create private files/directories in POSIX tests.
- [~] Canary secrets do not appear in logs/audit/API/watch outputs.
- [x] Raw journals are redacted or intentionally marked sensitive in tests.
- [x] Audit hash-chain tests detect record mutation after export.
- [x] Kubernetes tool audit payloads include context, namespace, resource,
      target, command argv when applicable, verb, duration, exit status, and
      truncation flags without raw output.

## Pass 4: Prompt Injection, E2E, Packaging, And Supply Chain

### Objectives

- Make prompt-injection risk explicit and tested.
- Validate infrastructure workflows against a constrained local Kubernetes
  cluster.
- Harden packaging and release provenance.

### Work Items

- [ ] Add system/developer prompt text that labels tool output as untrusted
      evidence, not instructions.
- [ ] Add prompt-injection fixtures for logs, HTTP pages, Kubernetes events,
      and dependency outputs.
- [ ] Add approval views that show exact proposed tool calls, targets, diffs,
      and safety level before human approval.
- [ ] Add k3d E2E suite with least-privilege kubeconfig.
- [ ] Add tests proving Kubernetes write tools fail under insufficient RBAC.
- [x] Add release artifact checksums.
- [ ] Add dependency audit workflow.
- [ ] Add `mix deps.audit` or equivalent when dependency policy is selected.
- [ ] Add SBOM/provenance plan for Burrito and Mix release artifacts.
- [ ] Add Windows named-pipe security verification on real Windows hardware.

### Acceptance Tests

- [ ] Prompt-injection fixtures cannot cause non-allowlisted tool calls.
- [ ] Approval output displays tool target and safety metadata.
- [ ] k3d E2E uses scoped RBAC and cannot access cluster-scope resources unless
      explicitly allowed.
- [x] Release workflow publishes checksums.
- [x] Release workflow records build environment.

## Security Review Checklist

Use this checklist for each pass:

- [ ] What did we assume was trusted?
- [ ] What data crossed from untrusted to trusted code?
- [ ] Could a model influence provider, network, filesystem, Kubernetes, or Git
      authority?
- [ ] Could a local webpage or same-user process trigger a control-plane
      mutation?
- [ ] Could a provider key, kube token, cookie, or bearer token appear in logs,
      stores, audit, metrics, API output, or model context?
- [ ] Does a timeout kill the whole OS process tree or only the direct process?
- [ ] Does a failed store write block dependent work before side effects?
- [ ] Are docs claiming more than the implementation proves?
- [ ] Is every new security claim backed by a test?

## Claims To Avoid Until Implemented

- “Safe to run untrusted workflows.”
- “Sandboxed tools.”
- “TLS verified.”
- “mTLS supported.”
- “Remote API is secure with bearer auth alone.”
- “Human approval cannot be bypassed.”
- “Logs/audit are secret-free.”
- “Audit is tamper-proof.”
- “Kubernetes access is constrained by Twelvgaige alone.”

Use narrower wording:

- “Policy-gated tools.”
- “Best-effort redaction.”
- “Local operational audit.”
- “Provider HTTPS URL policy.”
- “External TLS/mTLS proxy required for remote exposure until native TLS/mTLS
  support lands.”
