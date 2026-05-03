# Security

Twelvgaige is a local-first agent orchestration tool. Its main security goal is
to keep workflow control in Elixir/OTP while treating LLM output, tool output,
workflow input, and external service responses as untrusted data.

This document describes the current security posture. It intentionally separates
implemented controls from planned hardening work.

## Supported Versions

Twelvgaige is pre-release. Security review currently targets the active `main`
branch and the local single-node CLI/daemon shape described in
[`spec.md`](design/spec.md).

Before a public production release, the project should configure a private
vulnerability reporting channel, such as GitHub private vulnerability reporting
or a published security contact.

## Security Model

Twelvgaige assumes:

- The local OS user running Twelvgaige is trusted.
- Runtime configuration and environment variables are trusted operator input.
- Workflow and agent shells are trusted policy, not untrusted data.
- LLM responses, tool outputs, logs fetched from infrastructure, web pages, and
  round input are untrusted.
- Kubernetes RBAC, kubeconfig scope, cloud IAM, Git credentials, filesystem
  permissions, and OS process isolation remain primary host/infrastructure
  security boundaries.

Twelvgaige does not currently defend against:

- a malicious same-user local process,
- a compromised OS account,
- root/admin on the host,
- malicious `kubectl`, `git`, or other binaries on `PATH`,
- a malicious workflow/agent bundle loaded from an untrusted repository,
- a compromised provider endpoint or provider API key.

## Implemented Controls

### Deterministic Control Plane

Workflow routing, dependency checks, retries, timeouts, safety pauses, resource
limits, persistence, and recovery are owned by Elixir/OTP. The LLM produces data
inside a shot; it does not choose the workflow DAG path.

Relevant code:

- [`Round.Server`](../lib/twelvgaige/round/server.ex)
- [`Round.Runner`](../lib/twelvgaige/round/runner.ex)
- [`Shot.Executor`](../lib/twelvgaige/shot/executor.ex)

### Provider Secrets

Agent shells select provider IDs and model names. They must not contain API
keys, bearer tokens, provider base URLs, proxy settings, or auth headers.

Provider credentials are resolved from explicit process options, trusted
application config, or environment variables. See
[`secrets-and-providers.md`](secrets-and-providers.md).

OpenAI is API-key based. Twelvgaige does not use Codex CLI sessions, ChatGPT
sessions, browser sessions, or local Codex config as OpenAI credentials.

Relevant code:

- [`ProviderConfig`](../lib/twelvgaige/llm/provider_config.ex)
- [`LLM provider router`](../lib/twelvgaige/llm.ex)

### Tool Policy Boundary

Tool calls are normalized and executed through `Tool.Executor`. The executor
enforces:

- a shot-level tool allowlist,
- tool safety threshold,
- input schema validation,
- resource permits,
- per-tool timeout,
- output byte limits,
- durable tool intent/result journaling when a store is configured.

The default POSIX command runner captures stdout and stderr into separate
bounded temp files, polls output size while the command is still running, and
uses a separate process group for timeout cancellation when `setsid` and `kill`
are available. Windows keeps the conservative fallback runner until native
process-tree behavior is verified on Windows hardware or CI.

Relevant code:

- [`Tool.Executor`](../lib/twelvgaige/tool/executor.ex)
- [`Tool.Safety`](../lib/twelvgaige/tool/safety.ex)
- [`Tool.IntentJournal`](../lib/twelvgaige/tool/intent_journal.ex)

This is a policy gate, not an OS sandbox. Current tools run inside the local
Twelvgaige OS process boundary and may spawn local subprocesses.

### Built-In Tool Guardrails

Current built-in tools are structured operations rather than arbitrary shell
strings.

Examples:

- `shell_read` reads bounded files under an allowed root and denies symlink path
  components.
- `http_get` and `http_post` require trusted `allowed_hosts` policy, validate
  schemes, deny URL userinfo, deny obvious private hosts by default, check
  resolved addresses, deny redirects after response, and bound response size.
- Kubernetes tools build fixed `kubectl` argv rather than shell command strings.
- Kubernetes write tools require `confirm=true` and deny cluster-scope writes.
- `kubectl_exec` is irreversible, requires runtime opt-in, structured argv, and
  blocks shell interpreters unless trusted runtime policy allows them.
- `git_commit` is destructive, requires `confirm=true`, and operates only on
  explicit regular files under a trusted root.

These controls reduce accidental damage and common injection paths. They do not
make read-only tools harmless: reads can still expose sensitive data or feed
prompt-injection content back into later model calls.

### Local IPC

Breech uses a local control protocol. On macOS/Linux the default control path is
a Unix socket. On Windows the default is authenticated loopback TCP until native
named-pipe listener I/O is fully verified.

Endpoint files are written under the user runtime directory with owner-only
permissions where the OS supports them. Stale endpoints are cleaned only after
the daemon lock proves no live owner exists.

Relevant code:

- [`Breech.IPC.Endpoint`](../lib/twelvgaige/breech/ipc/endpoint.ex)
- [`Breech.Lock`](../lib/twelvgaige/breech/lock.ex)
- [`Breech.IPC.Protocol`](../lib/twelvgaige/breech/ipc/protocol.ex)

Unix socket filesystem permissions and local OS user separation are the main
trust boundary for the Unix socket path. Loopback is not a security boundary
against same-user local processes.

### Release Artifacts

Package targets generate `BUILD-METADATA.txt` and `SHA256SUMS` under
`artifacts/` for the files produced by that job. Build and release workflows
upload these files with the escript, Mix release, and Burrito artifacts.

Checksums provide transport and publication integrity checks, while build
metadata records the local target, git SHA, Elixir version, and OTP release.
They are not a substitute for future signing, notarization, SBOMs, or
provenance attestations.

### HTTP API

The HTTP API implements bearer-token handling and rejects tokens in query
strings. Mutating control-plane routes require bearer auth even on loopback.
Remote bind requires explicit opt-in, bearer auth, and either native TLS options
or an explicit `behind_tls_proxy?: true` deployment mode.

Important limitation: the current HTTP server is raw HTTP over `:gen_tcp`. Do
not expose it to a network without trusted TLS/mTLS termination in front of it.
Native TLS/mTLS support is tracked in [`security-plan.md`](design/security-plan.md).

Relevant code:

- [`API.Server`](../lib/twelvgaige/api/server.ex)
- [`API.Router`](../lib/twelvgaige/api/router.ex)

### Webhooks

Webhook handling requires an explicit secret and verifies HMAC signatures with
timestamp and nonce handling. Rejected triggers return structured errors without
leaking secret values.

Relevant code:

- [`API.Webhook`](../lib/twelvgaige/api/webhook.ex)

### Redaction And Logging

Logs, audit events, and provider error metadata use shared redaction helpers.
The JSON log formatter omits raw prompt/message/tool-output fields.

Relevant code:

- [`Redactor`](../lib/twelvgaige/redactor.ex)
- [`Log.JSON`](../lib/twelvgaige/log/json.ex)
- [`Audit.Event`](../lib/twelvgaige/audit/event.ex)
- [`Tool.IntentJournal`](../lib/twelvgaige/tool/intent_journal.ex)

Redaction is defense-in-depth, not a hard data-loss boundary. Tool and attempt
journals are redacted before durable retention, logs/audit events use the same
redaction helpers, and API/CLI round projections redact nested secret-shaped
values before output. Stores also support opt-in `sensitive_retention: :summary`
for high-sensitivity local runs; that mode retains journal metadata while
summarizing prompt/message/tool input/output payload fields by type and size.
Prompts, tool outputs, Kubernetes data, provider responses, and workflow inputs
may still contain sensitive operational data. Treat local stores and logs as
sensitive files.

Kubernetes tool audit payloads use an allowlist: target context, namespace,
resource, name/selector/container, redacted exec argv, verb, duration, exit
status, byte counts, and truncation flags. Raw stdout/stderr, kubeconfig
contents, bearer tokens, and certificate material are not included in audit
payload projections.

### Persistence And Audit

Twelvgaige persists round state, events, audit records, attempts, and tool
journals for recovery and inspection. This is operational durability, not
tamper-proof forensics. Audit and event replay can be exported with
`format=checkpoint`, which adds a deterministic SHA-256 hash chain and root hash
for post-export mutation detection.

Current local stores are not encrypted at rest and audit records are not
cryptographically signed, and the live store itself is not tamper-proof. Use
full-disk encryption, encrypted home directories, or OS-managed encrypted
volumes for local secret protection until a SQLCipher/keychain/KMS design is
implemented. File and SQLite stores plus JSON log files use private POSIX modes
where supported; Windows ACL verification remains tracked in
[`security-plan.md`](design/security-plan.md).

## Current High-Risk Gaps

The first security review identified these as the highest-priority gaps:

- Non-loopback HTTP is plaintext unless protected by an external TLS/mTLS proxy.
- Provider HTTPS URL policy now configures TLS verification in the default
  transport, but invalid certificate/hostname regression tests are still needed.
- HTTP tools now require explicit `allowed_hosts` policy and reject any resolved
  private address before transport. They still use the original hostname for
  transport, so use narrow trusted host allowlists rather than wildcarding
  attacker-controlled domains.
- Command tools now scrub ambient environment by default, support explicit cwd,
  capture stdout/stderr separately on POSIX, enforce streaming output caps, and
  cancel the POSIX process group on timeout where OS helpers are available.
  Native Windows process-tree behavior still needs verification.
- Kubernetes tools now support runtime-owned context/kubeconfig, runtime
  allowlists for contexts, namespaces, resources, names, and selectors, and an
  option to require runtime-owned context for unattended workflows.
- `approve_all_safety?` is blocked over HTTP/IPC unless a privileged runtime
  policy explicitly enables it; local foreground `--approve-safety` remains for
  controlled local use.
- Store/log directories and files now use private POSIX modes where supported;
  native Windows ACL behavior still needs real-Windows verification.
- Redaction is best-effort. Journals are redacted before persistence, but stores
  may still contain sensitive workflow inputs, prompts, and tool data.

The tracked remediation plan is in [`security-plan.md`](design/security-plan.md).

## Secure Operation Guidance

For local development:

- Run Twelvgaige as a normal user, not root/admin.
- Use `mock` or `ollama` agents for untrusted data experiments.
- Treat workflow and agent shells as executable policy. Review them before
  running.
- Avoid `--approve-safety` except in controlled local tests.
- Use `--untrusted-root` or `--no-agent-discovery` for workflows from
  unreviewed repositories. Explicit `--agent-shell` paths still work, so you can
  load only reviewed agent policy.

For provider use:

- Prefer `TWELVGAIGE_*` provider environment variables to avoid accidental
  credential reuse by unrelated tools.
- Do not put provider keys in shell files, workflow input, prompts, or logs.
- Treat provider `base_url` overrides as equivalent to giving credentials to
  that endpoint.
- Prefer official provider endpoints. Cloud provider endpoint overrides require
  explicit opt-in and public DNS validation before credentials are sent.

For Kubernetes:

- Use a dedicated kubeconfig or service account with least-privilege RBAC.
- Avoid broad admin kubeconfigs in the daemon environment.
- Prefer trusted runtime `kubernetes_context`/`kube_context` and
  `kubernetes_kubeconfig`/`kubeconfig` tool options over model-supplied context
  values.
- Set `require_runtime_context?: true` for unattended workflows so the model
  cannot choose a Kubernetes context.
- Require safety shots before write-capable Kubernetes tools. The compiler now
  rejects non-read-only tool shots that lack a direct `kind: safety`
  dependency unless the local-development override is explicitly set.
- Keep `kubectl_exec` disabled unless a human explicitly enables it for a
  narrow local run.
- Prefer namespace-scoped credentials and avoid cluster-scope reads/writes.

For HTTP/API:

- Keep the HTTP API disabled unless needed.
- Use bearer auth for all control-plane access.
- Do not expose raw HTTP remotely.
- Put any remote access behind a trusted TLS/mTLS reverse proxy until native
  TLS/mTLS support is implemented.

For storage/logs:

- Treat local store and log files as sensitive operational records.
- Keep runtime, store, and log directories under user-private paths.
- Treat audit checkpoints as tamper-evident export artifacts, not as proof that
  the live local store cannot be modified by a same-user process.

## Security Review Process

Security review is tracked as multiple passes in
[`security-plan.md`](design/security-plan.md):

1. Boundary inventory and documentation.
2. Control-plane auth, TLS/mTLS, provider transport, and network egress.
3. Host/tool/Kubernetes isolation.
4. Storage, redaction, audit integrity, and canary-secret tests.
5. Prompt-injection, adversarial E2E, packaging, and supply chain review.
