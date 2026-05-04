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
Remote bind requires explicit opt-in, bearer auth, and an explicit
`behind_tls_proxy?: true` deployment mode with configured
`trusted_proxy_cidrs`. Native TLS/mTLS is not implemented in the current
listener, so `tls_options` are rejected for non-loopback serving instead of
being treated as protection. Forwarded identity headers such as
`Forwarded`, `X-Forwarded-For`, and `X-Forwarded-User` are rejected unless the
connection comes from a configured trusted proxy CIDR.

Important limitation: the current HTTP server is raw HTTP over `:gen_tcp`. Do
not expose it to a network without trusted TLS/mTLS termination in front of it.
Native TLS/mTLS support is tracked in
[`crypto-tls-encryption-plan.md`](design/crypto-tls-encryption-plan.md).

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
for post-export mutation detection. Saved checkpoint JSON can be verified with
`twelvgaige audit verify <checkpoint-path|->`; verification detects mutation,
deletion, and reordering after export.

Checkpoint exports can also include optional HMAC-SHA-256 signatures with
`twelvgaige round audit <round-id> --format checkpoint --sign-hmac-env <env>`.
Verification with `twelvgaige audit verify <checkpoint-path|-> --hmac-env <env>`
checks both the hash chain and the shared-secret signature. HMAC signatures are
not public signatures; any verifier needs the same secret.

Current local stores are not encrypted at rest and live audit records are not
cryptographically signed as they are written. The live store itself is not
tamper-proof. Use
full-disk encryption, encrypted home directories, or OS-managed encrypted
volumes for local secret protection until a SQLCipher/keychain/KMS design is
implemented. File and SQLite stores plus JSON log files use private POSIX modes
where supported; Windows ACL verification remains tracked in
[`security-plan.md`](design/security-plan.md).

`twelvgaige crypto sqlcipher-spike` probes the current `ecto_sqlite3`/`exqlite`
driver for SQLCipher support. It first checks `PRAGMA cipher_version`; if the
packaged driver is normal SQLite, the probe reports `unavailable` and does not
claim encryption. When a SQLCipher-built driver is present and a key is supplied
through `TWELVGAIGE_SQLCIPHER_SPIKE_KEY` or `--key-env`, the probe creates a
keyed test database, runs migrations, closes it, reopens it with the key, and
checks that opening without the key is rejected. This is still a feasibility
probe, not the production encrypted store.

The current key-manager abstraction includes a test backend plus explicit env
and file backends for CI/headless development. Env and file key backends are not
OS keychains and require `allow_insecure_key_backend?: true`; `crypto status`
reports that posture. Raw key material and wrapped data-encryption keys use
redacted inspect implementations. The file backend creates private key files and
rejects group/world-readable key files where POSIX modes are exposed.

The macOS keychain backend is implemented as a narrow wrapper around
`/usr/bin/security` generic password items. It stores a JSON payload with key
metadata and base64 key material in the user's Keychain. Locked keychains may
prompt or fail depending on the session, keychain policy, and release packaging
context. Unit tests use an injected command runner; real login-keychain and
Burrito verification remain tracked before encrypted SQLite can depend on this
backend.

Run the opt-in live verification on macOS with:

```bash
make keychain-smoke-macos KEYCHAIN_LIVE=1
```

That target runs an ExUnit test tagged `:keychain_live`. It creates a unique
temporary generic password item in the login Keychain, fetches it, rotates it,
and deletes it. The tag is excluded from normal `mix test` so unattended unit
tests never prompt or mutate Keychain state.

The Windows key backend decision is DPAPI protected files, not Credential
Manager. Windows Credential Manager command-line tooling can write credentials
but does not provide the narrow read/rotate contract this local encrypted-store
design needs. `WindowsDPAPIBackend` writes a JSON file whose payload is protected
with current-user DPAPI. The file can be backed up, but it cannot be decrypted
without the same Windows user profile material. The backend uses a PowerShell
wrapper and passes plaintext over stdin instead of argv. Unit tests use an
injected runner; real Windows ACL, user-profile, and release-package
verification remain pending before encrypted-store support depends on it.

The Linux key backend decision is FreeDesktop Secret Service for desktop Linux,
not a blanket Linux-server promise. `LinuxSecretServiceBackend` wraps
`secret-tool`, which requires a user D-Bus session and an unlocked secret
collection. That is reasonable for developer laptops and desktops, but it is
not reliable in WSL, containers, SSH-only sessions, or headless servers. Unit
tests use an injected runner. Headless Linux should use the explicit env/file
backends only with `allow_insecure_key_backend?: true` until a passphrase,
external-command, Vault, or KMS backend is implemented.

Backup and rotation semantics are now defined before encrypted SQLite is wired
in. `BackupPolicy` makes encrypted backup the default, marks redacted exports as
non-restorable, and rejects plaintext export unless the caller explicitly opts
in with a plaintext-export allowance. `EnvelopeCipher` wraps store DEKs with
AES-256-GCM and supports rewrap rotation: decrypt the wrapped DEK with the old
active key, wrap the same DEK with the new active key, and replace only the
envelope. A failed rewrap leaves the old envelope valid. Full SQLite backup,
restore verification, and backup-before-rotation enforcement remain future
encrypted-store work.

`Store.SQLiteEncrypted` is now a separate fail-closed SQLCipher store surface.
It requires a key through `:key` or `:key_env`, probes `PRAGMA cipher_version`
before creating the target database, and refuses to start on bundled plain
SQLite with `:sqlcipher_unavailable`. `TWELVGAIGE_STORE_SQLCIPHER` selects this
store and `TWELVGAIGE_STORE_SQLCIPHER_KEY` is the default key environment
variable. `make sqlcipher-store-system` is the opt-in live verification path for
developer machines with system SQLCipher. It runs the shared store contract
against `Store.SQLiteEncrypted` and checks that a raw canary is absent from
DB/WAL/SHM files. `make sqlcipher-escript-smoke-system` and
`make burrito-sqlcipher-smoke-system` are opt-in package smoke checks for
SQLCipher open, backup, migration, restore, and reopen. This still does not make
SQLCipher a default release dependency.

SQLite backup now has an implementation-level and CLI-level safety gate.
`Store.SQLite.backup/2` uses SQLite `VACUUM INTO`; because a plaintext SQLite
backup is itself plaintext, it returns `:plaintext_export_not_allowed` unless
the caller passes `allow_plaintext_export?: true`. The CLI mirrors that as
`twelvgaige store backup <destination> --allow-plaintext-export`.
`Store.SQLiteEncrypted.backup/2` exposes the same API for SQLCipher-enabled
builds, where the backup remains encrypted under the open database key and does
not require plaintext-export consent. `twelvgaige store restore <source>
<destination>` is an offline file restore and refuses to overwrite an existing
target unless `--replace` is supplied.

Plaintext SQLite to SQLCipher migration is also explicit and offline:
`twelvgaige store migrate-sqlcipher --source <plain.db> --destination
<encrypted.db> --key-env <env>`. The command requires the source, destination,
and key environment variable; leaves the source untouched; refuses overwrite
unless `--replace` is supplied; and checks `PRAGMA cipher_version` before
creating the encrypted target. The key is read from the named environment
variable so operators do not pass encryption material directly in argv.

DEK envelope rewrap is explicit and backup-gated:
`twelvgaige store rewrap-envelope <envelope.json> --backup <backup.json>
--old-key-env <env> --new-key-env <env>`. This rotates only the wrapped DEK
envelope and metadata. It does not rekey SQLCipher database pages. Failed unwrap
or rewrap leaves the original envelope in place, and the pre-rotation backup is
kept for recovery.

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
- Configure `trusted_proxy_cidrs` for the concrete reverse-proxy source
  addresses before accepting forwarded identity headers.

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
