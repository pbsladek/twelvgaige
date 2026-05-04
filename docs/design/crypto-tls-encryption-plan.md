# Crypto, TLS, And Encryption Plan

This plan tracks Twelvgaige's encryption-at-rest, cryptography, TLS/mTLS, key
management, and audit-integrity work. It is separate from the workflow authoring
plan because these are platform security capabilities, not shell authoring
features.

The current security posture is intentionally conservative:

- Local stores are durable but not encrypted by Twelvgaige.
- File, SQLite, SQLite WAL/SHM sidecars, and JSON log files use private file
  modes where supported.
- Sensitive retention can store summaries instead of raw prompts, messages, and
  tool payloads.
- Provider HTTPS uses TLS verification in the default transport.
- Twelvgaige's own HTTP API is raw HTTP unless it is loopback-only or placed
  behind a trusted TLS/mTLS proxy.
- Audit checkpoint exports are tamper-evident after export, but the live store
  is not cryptographically immutable.

## Goals

- Report the active security posture truthfully before adding new crypto
  features.
- Prioritize transport security, data minimization, audit/export integrity, and
  release integrity ahead of application-level store encryption.
- Provide a clear path to optional application-level encryption at rest for
  SQLite stores.
- Keep laptop usage simple on macOS, Windows, and Linux.
- Use OS-native secret storage for encryption keys wherever practical.
- Add native TLS/mTLS for the Twelvgaige HTTP API without weakening the current
  local-first defaults.
- Harden provider TLS verification with regression tests.
- Make audit exports and, later, live audit records cryptographically verifiable.
- Avoid overclaiming. Documentation must distinguish private file permissions,
  redaction, encryption, signing, and tamper evidence.

## Non-Goals

- Do not invent custom cryptographic primitives.
- Do not store encryption keys in workflow or agent shells.
- Do not make bearer auth alone acceptable for remote HTTP exposure.
- Do not make encryption-at-rest a hidden default before key recovery, backup,
  rotation, and support implications are understood.
- Do not position Twelvgaige-managed encryption as a replacement for OS full-disk
  or volume encryption on laptops.
- Do not block the local-first product on SQLCipher or OS keychain support.
- Do not require a cloud KMS for local laptop usage.
- Do not claim tamper-proof audit unless append-only storage, signing keys, and
  verification tooling are implemented.

## Threat Model

Security guarantees depend on attacker state. This plan should not describe
"stolen laptop" as one case:

| Attacker State | Expected Protection |
| --- | --- |
| Powered-off stolen laptop with OS disk encryption enabled | OS disk encryption is the primary defense; Twelvgaige store encryption adds defense in depth. |
| Copied SQLite/file store without key material | SQLCipher can protect SQLite contents; file store, logs, exports, and temp files need separate handling. |
| Unlocked desktop or active user session | OS keychain and SQLCipher provide limited protection because the daemon or user session may already have key access. |
| Malware running as the same OS user | Out of scope for strong secrecy; it may read process memory, env vars, key files, local sockets, and decrypted outputs. |
| Root/admin compromise | Out of scope for local cryptographic guarantees. |
| Network observer between client and Twelvgaige API | TLS/mTLS protects transport confidentiality and peer authentication; bearer/mTLS policy still controls authorization. |
| Malicious release mirror or modified artifact | Checksums, signatures, and attestations detect artifact tampering when users verify them. |

### In Scope

- A stolen laptop or copied SQLite/file store.
- Accidental persistence of sensitive prompts, provider responses, tool outputs,
  Kubernetes metadata, or workflow input.
- A user accidentally binding the HTTP API to a non-loopback interface.
- Provider TLS regressions that would accept an invalid certificate or hostname.
- Release artifact tampering after build.
- Audit/event export mutation after export.

### Out Of Scope For This Plan

- A compromised OS user account while Twelvgaige is running.
- A malicious kernel, hypervisor, or administrator.
- Fully untrusted workflow execution.
- Cryptographic isolation between agents in the same local daemon.
- Remote multi-tenant service hosting.

## Security Guarantees Matrix

| Mechanism | Protects | Does Not Protect |
| --- | --- | --- |
| Private file permissions | Casual cross-user local reads where OS permissions are enforced. | Same-user malware, copied files, root/admin access, backups with broader permissions. |
| Redaction | Accidental secret persistence in known log/audit/store fields. | Unknown secret shapes, raw source files, shell outputs before redaction, process memory. |
| `sensitive_retention: :summary` | Persistent raw prompt/tool/message payload reduction. | Runtime exposure, metadata leaks, outputs written by external tools. |
| SQLCipher SQLite | Copied encrypted SQLite DB without its key. | JSON logs, file store, exports, temp files, crash dumps, unlocked sessions with key access. |
| OS keychain/keyring | Key material at rest under the OS user/session security model. | Compromised user session, process memory, weak OS account security. |
| TLS | Network confidentiality/integrity between client and server endpoint. | Authorization, compromised endpoints, logs after decryption. |
| mTLS | Client certificate authentication at transport layer. | Route authorization unless mapped into an explicit auth policy. |
| Hash chain | Detects mutation/reordering in an exported event stream. | Confidentiality, public verification, live-store tamper resistance. |
| HMAC chain | Detects mutation for verifiers holding the HMAC key. | Public verification and key compromise. |
| Signature | Public verification of exported data or release artifacts. | Runtime confidentiality and malicious signed content. |

## Encryption Coverage Boundary

Application-level encryption must be precise about what is covered:

| Surface | Current State | Target State |
| --- | --- | --- |
| SQLite store | Private modes, redaction, optional summary retention. | SQLCipher-backed encrypted store. |
| SQLite WAL/SHM | Private modes where supported. | Encrypted DB plus private sidecars; verify WAL/temp behavior. |
| File store | Private modes, redaction, optional summary retention. | Remains unencrypted unless a separate encrypted file-store design lands. |
| JSON logs | Private modes and redaction. | Not covered by SQLite encryption; consider separate encrypted log sink later. |
| Audit checkpoint exports | Hash-chained, not encrypted. | Optional signed export; optional encrypted export mode. |
| Plaintext exports/backups | Operator-controlled risk. | Require explicit `--allow-plaintext-export`; default to encrypted or redacted output. |
| Temp files | Best effort today. | Use private temp dirs, avoid plaintext temp copies, test migration temp behavior. |
| Crash dumps/core dumps | Out of scope today. | Document OS-level controls; disable or redirect where practical later. |
| Shell stdout/stderr before capture | Out of scope for at-rest encryption. | Bound and redact captured output; external command behavior remains operator risk. |
| OS swap/hibernation | Out of scope. | Rely on OS full-disk encryption. |

## Current State

### At Rest

Current local stores:

- `Store.File`
- `Store.SQLite`
- JSON log files
- SQLite sidecars: `-wal`, `-shm`

Current protections:

- private POSIX permissions where supported,
- world-writable parent directory rejection on POSIX,
- best-effort redaction before store/log/audit persistence,
- `sensitive_retention: :summary` for high-sensitivity local runs,
- bounded retention cleanup.

Current gaps:

- no application-level encryption at rest,
- no SQLCipher-backed SQLite store,
- no OS keychain/keyring integration,
- no key rotation or recovery story,
- Windows ACL behavior still needs stronger verification,
- live store is not cryptographically immutable.

### Transport

Provider calls:

- hosted provider URLs must be HTTPS,
- unsafe schemes and userinfo are rejected,
- private/cloud endpoint policy is enforced before auth headers are sent,
- TLS verification is configured in the default provider transport,
- invalid CA/hostname regression tests are still pending.

Twelvgaige HTTP API:

- loopback is the default,
- mutating control-plane routes require bearer auth,
- non-loopback bind requires explicit remote opt-in, bearer auth, and
  `behind_tls_proxy?: true`,
- non-loopback `tls_options` are rejected until a real native TLS listener is
  implemented,
- native TLS/mTLS listener support is not implemented yet.

IPC:

- Unix sockets rely on filesystem permissions and lock ownership,
- Windows defaults to authenticated loopback TCP until native named-pipe listener
  I/O is verified,
- loopback TCP fallback requires bearer auth,
- IPC auth comparison uses constant-time comparison.

### Cryptographic Integrity

Current mechanisms:

- constant-time token comparison,
- webhook HMAC verification with timestamp and nonce replay protection,
- release SHA-256 checksums,
- audit checkpoint SHA-256 hash chain.

Current gaps:

- release artifacts are not signed or attested,
- audit records are not signed as they are written,
- no HMAC key management for live audit signing,
- no external transparency log or notarization flow.

### Evidence References

Current-state claims should stay tied to code or tests. If the reference is not
covered by tests yet, the status should say so.

| Claim | Evidence | Status |
| --- | --- | --- |
| Provider default transport configures TLS verification. | `lib/twelvgaige/llm/providers/common.ex` | Implemented; policy tests present, certificate fixture tests pending. |
| Constant-time token comparison exists. | `lib/twelvgaige/security.ex` | Implemented. |
| Webhooks use HMAC, timestamp, and nonce handling. | `lib/twelvgaige/api/webhook.ex` and API tests. | Implemented. |
| Mutating HTTP routes require bearer auth. | `lib/twelvgaige/api/router.ex`, `test/twelvgaige/standards_contract_test.exs`. | Implemented. |
| File/SQLite stores use private modes where supported. | `lib/twelvgaige/store/file.ex`, `lib/twelvgaige/store/sqlite.ex`, store tests. | Implemented on POSIX; Windows ACL verification pending. |
| Audit checkpoint export uses a hash chain. | audit checkpoint modules/tests. | Implemented for exports, not live-store immutability. |

## Design Principles

- **Use boring crypto.** Prefer SQLCipher, TLS through OTP/SSL, HMAC-SHA-256,
  Ed25519/minisign/cosign for signatures, and OS-native key stores.
- **Separate secrecy from integrity.** Encryption protects confidentiality;
  signatures/hash chains protect mutation detection.
- **Keys are runtime secrets.** Shells may reference key IDs later, but never key
  material.
- **Local-first remains usable.** Users should be able to run with OS disk
  encryption only, then opt into Twelvgaige-managed store encryption.
- **Fail closed for remote control.** Non-loopback API serving should fail unless
  TLS/mTLS or explicit trusted-proxy mode is configured.
- **Test with fake transports.** TLS policy and failure modes need deterministic
  tests rather than live provider calls in normal test runs.

## Target Architecture

The roadmap is split into subtracks so implementation can proceed without
turning one security plan into one oversized feature. The order is intentional:
truthful status, provider/API transport safety, audit and release integrity, and
only then optional encrypted SQLite.

| Subtrack | Scope | First Useful Slice |
| --- | --- | --- |
| Status And Claims | CLI status, config truth, docs, guarantee language. | `crypto status` with no behavior change. |
| Provider Transport | Hosted provider TLS, URL policy, auth-header suppression, DNS policy. | Provider TLS and URL-policy regression tests. |
| API Transport | Fail-closed remote bind, trusted-proxy mode, later native TLS/mTLS. | Reject raw non-loopback HTTP and unsupported native TLS claims. |
| Audit Integrity | Hash chains, HMAC chains, signed exports, verification. | Clarify hash/HMAC/signature semantics and add `audit verify`. |
| Release Integrity | Checksums, signed checksums, attestations, SBOM later. | Signed `SHA256SUMS` plus GitHub artifact attestations. |
| At Rest | Optional SQLite encryption, key management, backup/restore, rotation. | SQLCipher packaging spike after higher-priority controls. |

### Product Stance On Encryption At Rest

Twelvgaige-managed encryption at rest is useful defense in depth, not the
default security boundary for ordinary laptop usage. The recommended default is:

- use OS full-disk encryption or encrypted home directories,
- keep local stores private with restrictive filesystem permissions,
- prefer `sensitive_retention: :summary` when prompts, tool outputs, or provider
  responses may be sensitive,
- redact before persistence,
- avoid storing raw secrets in workflow inputs, shell files, logs, and tool
  outputs.

Encrypted SQLite should be opt-in until key storage, backup, restore, and
rotation are reliable across supported release targets. It protects a copied
database without key material. It does not protect a running daemon, an unlocked
user session, same-user malware, process memory, terminal output, JSON logs,
file stores, exports, crash dumps, or external tool side effects.

### Encryption At Rest

Recommended target:

```text
Store.SQLiteEncrypted
  -> SQLCipher SQLite database
  -> per-store DEK unwrapped by KeyManager
  -> WAL/SHM private permissions
  -> backup/export commands understand encrypted source

KeyManager
  -> macOS Keychain KEK/reference
  -> Windows DPAPI / Credential Manager KEK/reference
  -> Linux backend decision: Secret Service, passphrase, external command, or KMS
  -> env/file fallback for explicit CI/headless/dev only
  -> future Vault/KMS backend
```

### Key Hierarchy

Use envelope encryption instead of storing one raw SQLite key directly in config:

```text
OS key backend / KMS / explicit insecure backend
  -> KEK or backend key reference
  -> unwraps per-store random DEK
  -> SQLCipher opens DB with DEK

Audit signing/HMAC
  -> separate key material from store encryption
```

Definitions:

- **DEK:** per-store random data encryption key used by SQLCipher.
- **KEK:** key-encryption key or OS/KMS-protected reference used to wrap the DEK.
- **Key ref:** stable reference such as `os:twelvgaige/default`, not raw key
  material.
- **Rewrap rotation:** unwrap the existing DEK and wrap it with a new KEK or
  backend record. This should be the first rotation mode.
- **Rekey rotation:** generate a new DEK and re-encrypt/rekey the database. This
  is riskier and needs backup, crash recovery, and verification.

The database may store key metadata, wrapped DEK, salt, KDF/cipher parameters,
and key ID. It must not store a plaintext DEK. Shells must never contain key
material.

Key records should include:

- key ID,
- algorithm/backend,
- creation time,
- rotation generation,
- store path binding,
- wrapped DEK metadata when applicable,
- KDF/cipher parameters,
- whether export/backup is allowed,
- backend-specific reference, not raw key material.

Early implementation can start with explicit env/file key input for tests and
CI, but user-facing laptop encryption should prefer OS key storage. Env/file key
backends are `test/dev/headless` only unless the operator explicitly sets
`allow_insecure_key_backend?: true`. File keys must use private permissions and
group/world-readable key files must be rejected.

### Backup, Restore, And Rotation

Encryption is not ready for broad recommendation until backup and recovery are
defined:

| Operation | Default | Explicit Risky Mode |
| --- | --- | --- |
| Backup encrypted store | Encrypted copy or encrypted backup artifact. | None. |
| Export operational data | Redacted export where possible. | `--allow-plaintext-export`. |
| Audit checkpoint export | Hash-chained; signature optional in later phase. | Plain unsigned export remains allowed but clearly labeled. |
| Restore | Requires key ref or recovery material before opening. | No silent plaintext fallback. |
| Rewrap rotation | Offline or controlled maintenance window, backup first. | None. |
| Rekey rotation | Later phase, backup first, crash-safe verification required. | None. |

Rotation must define online/offline behavior, mandatory pre-rotation backup,
mid-rotation crash behavior, verification after rotation, and rollback/recovery
steps. Encrypted store startup must fail closed when encryption is configured but
the key ref cannot be resolved.

### TLS/mTLS For API Serving

Native API TLS should support:

- `certfile`,
- `keyfile`,
- optional `cacertfile`,
- server name / SNI behavior,
- minimum TLS version of TLS 1.2, preferring TLS 1.3,
- peer verification mode for mTLS,
- certificate EKU validation for `clientAuth` when mTLS is enabled,
- SAN URI/DNS/email allowlist or mapping to actor identity,
- subject/CN fallback disabled by default,
- certificate expiry and CA chain validation,
- revocation explicitly unsupported at first, with short-lived client certs
  recommended,
- restart-required certificate changes in the first implementation,
- explicit errors when non-loopback bind lacks TLS/proxy mode.

Suggested config shape:

```elixir
config :twelvgaige, :http_listener,
  bind: {0, 0, 0, 0},
  port: 4040,
  bearer_token_ref: {:env, "TWELVGAIGE_HTTP_TOKEN"},
  tls: [
    certfile: "/etc/twelvgaige/server.crt",
    keyfile: "/etc/twelvgaige/server.key",
    cacertfile: "/etc/twelvgaige/clients-ca.crt",
    verify: :verify_peer,
    fail_if_no_peer_cert: true,
    versions: [:"tlsv1.3", :"tlsv1.2"]
  ]
```

`behind_tls_proxy?: true` remains valid for deployments where Envoy, Caddy,
nginx, Tailscale, or a platform ingress terminates TLS/mTLS. That mode must stay
explicit so operators know Twelvgaige is not doing TLS itself.

Trusted-proxy mode is an operator assertion, not cryptographic proof inside
Twelvgaige. It must require either loopback/private binding or explicit
`trusted_proxy_cidrs`, and Twelvgaige must reject forwarded identity headers from
untrusted source addresses. Operators are responsible for TLS from client to
proxy and should prefer TLS or private networking from proxy to Twelvgaige when
the app bind is not loopback.

TLS policy matrix:

| Mode | Allowed | Requirements |
| --- | --- | --- |
| Loopback HTTP | Yes | Mutating routes still require bearer auth. |
| Non-loopback native TLS | Yes | `allow_remote?: true`, bearer auth, TLS cert/key. |
| Non-loopback native mTLS | Yes | Native TLS requirements plus client CA and SAN policy. |
| Non-loopback trusted proxy | Yes | `behind_tls_proxy?: true`, bearer auth, trusted proxy CIDRs/bind policy. |
| Raw non-loopback HTTP | No | Rejected at config validation. |

Authentication policy:

- First implementation remains bearer-based for authorization.
- mTLS establishes transport identity and may add audit actor metadata.
- Mutating routes still require bearer auth even when mTLS is enabled.
- mTLS-only authorization is future work and needs a full authorization model.
- Audit records should include bearer actor, client certificate fingerprint, SAN
  identity, issuer, and verification mode when present.

### Provider TLS

Provider transport should keep:

- HTTPS-only for hosted providers,
- official provider host allowlists for defaults,
- trusted-runtime-only base URL overrides,
- DNS resolution checks before auth headers are sent,
- pinned resolved destination or a custom resolver/transport path when practical
  to avoid DNS policy/check time-of-use drift,
- TLS peer and hostname verification,
- TLS 1.2/1.3 only,
- redirect disabled unless explicitly designed per provider.

Tests should prove:

- invalid CA is rejected,
- hostname mismatch is rejected,
- HTTP downgrade is rejected,
- userinfo URLs are rejected,
- auth headers are not sent after URL policy denial,
- redirects do not bypass URL policy,
- CNAME/private resolution and IPv6 loopback/link-local/private ranges are
  denied unless policy allows them,
- private resolved addresses are denied unless policy allows them.

If the default HTTP client cannot pin the checked resolved address through to
connect, the plan must document the residual DNS time-of-check/time-of-use risk
or add a transport seam that can enforce it.

### Audit Integrity

Current checkpoint export hash chains should remain. Future live audit integrity
can add:

- hash chains for exported stream ordering and mutation detection,
- per-record HMAC over canonical audit JSON for private-key verification,
- signed exports with Ed25519/minisign/cosign for public verification,
- periodic checkpoint roots,
- optional external timestamp/transparency evidence later,
- verification command that reports first broken record.

Use separate key material for audit HMAC/signing and store encryption. Store
encryption protects confidentiality; audit integrity has different rotation,
verification, and sharing requirements. Do not make live audit HMAC mandatory
until key storage exists. Otherwise users will be forced into weak local key
files.

### Release Integrity

Target release integrity:

- keep `SHA256SUMS`,
- add signed `SHA256SUMS`,
- add GitHub artifact attestations,
- choose one first user-verifiable signing path before adding alternatives,
- document verification steps in `docs/release.md`,
- defer SBOM generation until release signing is stable,
- avoid claiming reproducible builds until builds are actually reproducible.

## Configuration Model

Proposed CLI/config surfaces:

```bash
twelvgaige crypto status
twelvgaige crypto key init --store sqlite --backend os
twelvgaige crypto key rotate --store ~/.local/share/twelvgaige/twelvgaige.sqlite3
twelvgaige crypto verify-store ~/.local/share/twelvgaige/twelvgaige.sqlite3
twelvgaige audit verify checkpoint.json
twelvgaige daemon serve --tls-cert server.crt --tls-key server.key --client-ca clients-ca.crt
```

`crypto status --format json` should have a stable output contract:

```json
{
  "status": "ok",
  "store": {
    "backend": "sqlite",
    "encrypted": false,
    "encryption": "none",
    "key_ref": null,
    "key_backend": null,
    "warnings": ["local store is not encrypted by Twelvgaige"]
  },
  "http_listener": {
    "enabled": true,
    "bind": "127.0.0.1",
    "tls_mode": "loopback_http",
    "mutating_routes_require_bearer": true
  },
  "providers": {
    "hosted_tls_verification": "configured",
    "tls_regression_tests": "policy_tests_present"
  },
  "audit": {
    "checkpoint_hash_chain": true,
    "live_signing": false
  },
  "release": {
    "checksums": true,
    "signed_checksums": false,
    "attestations": false
  }
}
```

Human output should be short and warning-heavy. If an env/file key backend is
active, it must say that the backend is intended for test/dev/headless use and
requires explicit risk acceptance.

Environment/config examples:

```bash
TWELVGAIGE_STORE_SQLITE=/path/to/twelvgaige.sqlite3
TWELVGAIGE_STORE_ENCRYPTION=sqlcipher
TWELVGAIGE_STORE_KEY_REF=os:twelvgaige/default
TWELVGAIGE_ALLOW_INSECURE_KEY_BACKEND=false
TWELVGAIGE_HTTP_TOKEN_REF=env:TWELVGAIGE_HTTP_TOKEN
```

Open questions:

- Should encrypted SQLite be a separate store module or an option on
  `Store.SQLite`?
- Should first-run key initialization be interactive or explicit-only?
- Should encrypted backups be first-class before default encryption is enabled?
- Which first release-signing path should be the MVP after GitHub attestations:
  cosign keyless, minisign, or GPG?

## Implementation Phases

Phase dependencies:

```text
CTE0 claims/config/status
  -> CTE1 provider TLS tests
  -> CTE2 API transport enforcement and trusted-proxy hardening
  -> CTE3 audit export verification
  -> CTE4 release signing and attestation
  -> CTE5 SQLCipher/Burrito feasibility spike
      -> CTE6a KeyManager behaviour and test backends
      -> CTE6b macOS keychain
      -> CTE6c Windows key backend
      -> CTE6d Linux key backend decision
      -> CTE6.5 backup, restore, and rotation semantics
          -> CTE7 encrypted SQLite store
              -> CTE8 live audit signing
```

The sequence is intentionally cautious. Provider TLS tests and config truth can
land early. Encrypted SQLite is intentionally late because it should not become
a committed product feature until SQLCipher packaging, key management,
backup/restore, and rotation behavior are proven across the release targets.

### Phase CTE0 - Claims And Config Boundary

Status: in progress. `crypto status` is implemented as a truthful current-state
report. API transport validation rejects unsupported native TLS claims and
requires trusted proxy CIDRs for non-loopback trusted-proxy mode.

- Keep docs clear that local stores are not encrypted at rest.
- Add a dedicated crypto status surface to report what is enabled and what is
  only protected by OS/file permissions.
- Define config keys for store encryption, key refs, TLS certs, and proxy mode
  without implementing all backends.
- Add security guarantee and encryption coverage language to user-facing docs.

Acceptance:

- `docs/security.md` and `docs/design/spec.md` distinguish redaction, private
  permissions, encryption, and audit integrity.
- No CLI output claims encryption-at-rest unless an encrypted store is actually
  active.
- `crypto status --format json` reports store encryption, key backend, HTTP TLS
  mode, provider TLS test status, audit signing, and release signing status.
- Config validation rejects impossible combinations, such as non-loopback HTTP
  without explicit trusted-proxy mode while native TLS is not implemented.
- Env/file key backend config is rejected unless explicit insecure-backend risk
  acceptance is present.

### Phase CTE1 - Provider TLS Regression Tests

Status: in progress. Hosted-provider HTTPS downgrade rejection, URL-policy
denial before transport, redirect-disable policy, DNS/private-address policy,
and default TLS option coverage are implemented. Local invalid-certificate and
hostname-mismatch fixture tests remain.

- Add deterministic TLS test fixtures or fake TLS transport tests.
- Prove invalid CA and hostname mismatch fail.
- Prove hosted provider requests always use TLS verification.
- Prove auth headers are not passed to transport when URL policy denies the
  request.
- Add redirect, DNS rebinding, CNAME/private resolution, and IPv6 private range
  policy tests.

Acceptance:

- Normal `mix test` covers provider TLS policy without live network calls.
- URL policy/auth-header suppression has pure tests.
- Local TLS fixture tests cover certificate and hostname failure behavior.
- Security docs can say provider TLS verification is tested, not just
  configured.

### Phase CTE2 - API Transport Enforcement And Trusted-Proxy Hardening

Status: mostly complete for the current raw HTTP listener. Non-loopback raw
HTTP is rejected, non-loopback `tls_options` are rejected until native TLS
lands, trusted-proxy mode requires explicit remote opt-in, bearer auth, and
trusted proxy CIDRs, and forwarded identity headers are rejected unless the peer
is trusted. Remaining work is deeper trusted-proxy source-address coverage on
real non-loopback interfaces and eventual native TLS/mTLS in CTE2.5.

- Keep loopback HTTP allowed.
- Reject raw non-loopback HTTP.
- Reject non-loopback `tls_options` until native TLS is actually implemented.
- Require explicit `behind_tls_proxy?: true` for current non-loopback serving.
- Require bearer auth for mutating routes in all current remote modes.
- Enforce trusted-proxy CIDR/bind requirements when `behind_tls_proxy?: true` is
  used.
- Reject untrusted forwarded identity headers.

Acceptance:

- Non-loopback HTTP without trusted-proxy mode fails.
- Non-loopback `tls_options` fail with an explicit unsupported-native-TLS error.
- Trusted-proxy mode starts only with explicit remote opt-in and bearer auth.
- Mutating routes still require bearer auth.
- Security docs say native TLS/mTLS is future work, not active protection.

### Phase CTE2.5 - Native API TLS/mTLS Design And Listener

- Add real TLS socket support to `API.Server` or replace the listener with a TLS
  capable adapter.
- Add mTLS peer verification options.
- Map mTLS client identity to audit actor metadata when present.
- Require daemon restart for certificate changes in the first implementation;
  hot reload is future work.

Acceptance:

- TLS listener starts with test cert fixtures.
- mTLS rejects missing or untrusted client certs.
- mTLS validates CA chain, expiry, EKU `clientAuth`, and configured SAN policy.
- Audit records include certificate fingerprint/SAN metadata when mTLS is
  present.

### Phase CTE3 - Audit Export Verification

- Add `audit verify` for JSON checkpoint exports. `[x]`
- Keep hash chain, HMAC chain, and public signature modes separate in command
  output and docs. `[x]`
- Verify deletion, mutation, and reordering of exported checkpoint records. `[x]`
- Defer live audit HMAC/signing until key management exists.

Acceptance:

- Export verification detects mutation, deletion, and reordering. `[x]`
- Docs avoid calling the live local store tamper-proof. `[x]`

### Phase CTE4 - Release Signing And Attestation

- Sign `SHA256SUMS` through the GitHub artifact attestation path. `[x]`
- Add GitHub provenance attestations for release artifacts. `[x]`
- Pick one MVP user-verifiable signing path before adding alternatives. `[x]`
- Document verification. `[x]`
- Defer SBOM generation until release signing is stable.

Acceptance:

- Release workflow publishes checksums plus signature/attestation artifacts. `[x]`
- `docs/release.md` explains verification. `[x]`
- README install section links to verification docs without overstating
  reproducibility. `[x]`

### Phase CTE5 - SQLCipher And Burrito Feasibility Spike

- Add a standalone `crypto sqlcipher-spike` command that does not modify
  `Store.SQLite`. `[x]`
- Add Make targets for a deliberate system-SQLCipher `exqlite` rebuild and
  spike run. `[x]`
- Prove whether `ecto_sqlite3`/`exqlite` can use SQLCipher without destabilizing
  the existing SQLite store. `[~]`
- Prove migrations can run against an encrypted database. `[~]`
- Decide whether `Store.SQLiteEncrypted` is feasible as a separate backend. `[ ]`
- Test Mix and Burrito execution for supported release targets. `[~]`
- Document native library, OpenSSL/LibreSSL, NIF, and Zig/Burrito constraints. `[~]`

Acceptance:

- A spike command detects bundled SQLite versus SQLCipher before creating a
  target store. `[x]`
- A spike command can create, open, migrate, close, and reopen an encrypted DB
  when the loaded NIF is SQLCipher-backed. `[~]`
- The same spike command is included in escript, native release, and Burrito
  smoke flows. `[x]`
- The same spike works from a Burrito-built binary on macOS Silicon and Linux
  with SQLCipher-backed `exqlite`. `[~]`
- Windows feasibility is documented before claiming Windows encrypted-store
  support. `[ ]`
- If SQLCipher packaging is too brittle, the plan is revised before CTE7. `[ ]`

Current finding: the default bundled `exqlite` NIF reports no
`PRAGMA cipher_version`, so the shipped development build is normal SQLite. The
opt-in `sqlcipher-escript-smoke-system` and `burrito-sqlcipher-smoke-system`
targets now rebuild `exqlite` against system SQLCipher and exercise CLI-level
open, backup, plaintext-to-encrypted migration, encrypted open, encrypted
backup, restore, and restored encrypted open. These targets are still manual
host checks; they do not make SQLCipher a default release dependency.
The spike returns `status=unavailable` and does not create a target database in
that case. To test the encrypted path, rebuild `exqlite` against SQLCipher using
the adapter-supported system flags, then run:

```bash
make sqlcipher-env SQLCIPHER_PREFIX=/path/to/sqlcipher
make sqlcipher-spike-system SQLCIPHER_PREFIX=/path/to/sqlcipher
make sqlcipher-escript-smoke-system SQLCIPHER_PREFIX=/path/to/sqlcipher
make burrito-sqlcipher-smoke-system SQLCIPHER_PREFIX=/path/to/sqlcipher BURRITO_TARGET=macos_silicon
```

The Make target only rebuilds the local `exqlite` build artifact; it does not
change `mix.exs`, `mix.lock`, or the default release path. Re-run normal
dependency compilation without `EXQLITE_USE_SYSTEM=1` when returning to the
default bundled SQLite build.

Packaging constraint: Burrito and Mix releases must carry the same
SQLCipher-linked NIF and any required native SQLCipher/OpenSSL/LibreSSL runtime
libraries for the target OS/architecture. Do not claim encrypted-store support
for macOS, Linux, or Windows until the spike has passed from the packaged
artifact on that platform.

### Phase CTE6a - Key Manager Behaviour And Explicit Backends

- Add `Twelvgaige.Crypto.KeyManager` behaviour. `[x]`
- Add test backend. `[x]`
- Add env/file backend for explicit CI/headless/dev use. `[x]`
- Add key metadata and key ID resolution. `[x]`
- Add envelope-encryption metadata structs for wrapped DEK records. `[x]`

Acceptance:

- Tests can create, fetch, rotate, and retire keys through the behaviour. `[x]`
- Raw key material is redacted from logs, inspect output, audit, and errors. `[x]`
- Missing key errors are actionable and do not leak backend details. `[x]`
- Env/file backend requires explicit insecure-backend acceptance. `[x]`
- File key backend rejects group/world-readable files where the OS exposes modes. `[x]`

Current implementation note: `EnvBackend` and `FileBackend` are explicit
CI/headless/dev backends, not OS keychains. They require
`allow_insecure_key_backend?: true` and `crypto status` reports them as not
OS-protected. `TestBackend` is process-local and exists for unit tests. None of
these backends are wired into encrypted store behavior until CTE7.

### Phase CTE6b - macOS Keychain Backend

- Add macOS Keychain backend or a narrow command-wrapper integration. `[x]`
- Add excluded-by-default live verification for real macOS Keychain behavior. `[x]`
- Verify behavior in Burrito builds on macOS Silicon. `[ ]`
- Document prompts, locked keychain behavior, and headless limitations. `[x]`

Acceptance:

- Key create/fetch/delete flows work through the backend contract. `[x]`
- Real macOS Keychain manual verification is documented before claiming release
  support. `[x]`
- Burrito smoke test can open an encrypted test DB with a keychain-backed key. `[ ]`
- `crypto status` reports macOS keychain backend without exposing key material. `[x]`

Current implementation note: `MacOSKeychainBackend` wraps `/usr/bin/security`
generic password items. The stored item password is a JSON payload containing
key version metadata and base64 key material. Unit tests use an injected runner
to verify create/fetch/rotate/retire command behavior without touching the
developer's login keychain. The backend returns
`:unsupported_key_backend_platform` outside macOS. This backend is not wired into
encrypted SQLite until CTE7. Live verification is available with
`make keychain-smoke-macos KEYCHAIN_LIVE=1`; it creates, rotates, and deletes a
unique temporary generic password item in the user's login keychain and is
excluded from normal tests.

### Phase CTE6c - Windows Key Backend

- Decide between DPAPI, Credential Manager, or a supported wrapper approach. `[x]`
- Add Windows DPAPI protected-file backend with injected-runner tests. `[x]`
- Verify ACL and user binding behavior. `[ ]`
- Verify behavior in Windows release packaging before documenting support. `[ ]`

Acceptance:

- Key create/fetch/delete flows work through the backend contract. `[x]`
- Key create/fetch/delete flows work on real Windows. `[ ]`
- Lost Windows user profile/key material produces a clear recovery error. `[ ]`
- Docs explain backup and recovery limitations. `[x]`

Current implementation note: `WindowsDPAPIBackend` stores a DPAPI-protected JSON
key payload in a local file. DPAPI is scoped to the current Windows user profile,
so copied files are not useful without that user's profile material. The backend
uses a PowerShell command wrapper and passes plaintext over stdin rather than
argv. Unit tests use an injected runner; real Windows, ACL, and Burrito release
verification remain pending before encrypted SQLite can depend on this backend.

### Phase CTE6d - Linux Key Backend Decision

- Evaluate Secret Service/libsecret for desktop Linux. `[x]`
- Add desktop Linux Secret Service backend with injected-runner tests. `[x]`
- Define a supported non-desktop/headless Linux mode, such as passphrase-based
  wrapping, external command, or future Vault/KMS. `[x]`
- Document WSL/container/server limitations. `[x]`

Acceptance:

- The selected Linux path has tests or documented manual verification. `[x]`
- Secret Service is not presented as universal Linux server support. `[x]`
- Headless fallback requires explicit operator acceptance. `[x]`

Current implementation note: `LinuxSecretServiceBackend` wraps `secret-tool`
for FreeDesktop Secret Service. It is a desktop Linux backend that requires
`secret-tool`, a user D-Bus session, and an unlocked collection. Unit tests use
an injected runner; real Linux desktop and Burrito verification remain pending.
It is not a WSL/container/headless-server guarantee. For headless Linux today,
the supported fallback is still explicit env/file key backends with
`allow_insecure_key_backend?: true`; future passphrase wrapping, external KMS,
or Vault-style integrations are tracked separately before encrypted SQLite
defaults depend on Linux server key management.

### Phase CTE6.5 - Backup, Restore, And Rotation Semantics

- Add encrypted backup and restore design before default encrypted-store
  recommendations. `[x]`
- Add explicit redacted export and plaintext export behavior. `[x]`
- Define rewrap rotation first. `[x]`
- Define rekey rotation as later/higher-risk work. `[x]`
- Require backup before rotation. `[~]`
- Define crash behavior and verification after rotation. `[x]`

Acceptance:

- Encrypted backup never emits plaintext by default. `[x]`
- Plaintext export requires `--allow-plaintext-export`. `[x]`
- Rewrap rotation can be tested without database re-encryption. `[x]`
- Rotation failures leave either the old key state valid or a clear recovery
  path. `[x]`

Current implementation note: `BackupPolicy` defines the export safety contract:
`:encrypted` is the default, `:redacted` is allowed but marked non-restorable,
and `:plaintext` requires explicit opt-in. `EnvelopeCipher` implements
AES-256-GCM wrapping for a store DEK plus rewrap rotation from an old active key
to a new active key. Rewrap decrypts only the wrapped DEK and emits a new
envelope; it does not re-encrypt database pages. Failed rewrap returns a clear
error and leaves the old envelope decryptable with the old key. Actual SQLite
backup commands, restore verification, and enforcing "backup before rotation" in
the encrypted store remain CTE7 work because no encrypted SQLite store exists
yet.

### Phase CTE7 - SQLCipher Local Store

Status: tabled. The exploratory fail-closed code and manual smoke targets may
remain available for local investigation, but encrypted SQLite is not on the
active implementation path. Do not spend more implementation effort here until
provider/API transport, audit/release integrity, and authoring-management work
are stable. Product docs must continue to recommend OS or volume encryption as
the default laptop at-rest boundary.

- Evaluate `ecto_sqlite3` plus SQLCipher support or a dedicated SQLCipher
  adapter path. `[x]`
- Add encrypted SQLite open/migration path. `[~]`
- Ensure WAL/SHM sidecars remain private. `[~]`
- Define SQLCipher cipher/KDF PRAGMAs and migration behavior. `[~]`
- Add opt-in SQLCipher live shared store contract and raw canary scan. `[x]`
- Verify encrypted WAL/temp behavior or document required SQLite settings. `[~]`
- Add encrypted backup/restore commands. `[x]`
- Add migration path from plaintext SQLite to encrypted SQLite with explicit
  operator command. `[x]`
- Add rewrap rotation integration after CTE6.5. `[x]`

Acceptance:

- `Store.SQLiteEncrypted` is separate from `Store.SQLite` unless the spike proves
  an option-based implementation is safer. `[x]`
- Encrypted SQLite store passes the shared store contract. `[~]`
- Opening encrypted DB without the key fails. `[~]`
- Plaintext canary values do not appear in the DB/WAL/temp files with normal raw
  retention. `[~]`
- Redacted/summary retention separately prevents sensitive values from entering
  logical records where configured.
- Migration command requires explicit source, destination, and key ref. `[x]`
- Burrito smoke tests cover encrypted open/migrate/verify on supported release
  targets. `[~]`
- Rewrap crash-safety tests exist before rekey is exposed. `[x]`

Current implementation note: `Twelvgaige.Store.SQLiteEncrypted` now exists as a
separate store module that delegates to the SQLite implementation with
`encrypted?: true`. Startup requires a key through `:key` or `:key_env` and
probes `PRAGMA cipher_version` before creating the target database. On bundled
plain SQLite it fails closed with `:sqlcipher_unavailable` and does not create
the target store. `TWELVGAIGE_STORE_SQLCIPHER` selects this backend and
`TWELVGAIGE_STORE_SQLCIPHER_KEY` supplies the default key env. The plaintext
`Store.SQLite` path is unchanged. `make sqlcipher-store-system` rebuilds
`exqlite` against system SQLCipher and runs an excluded-by-default
`:sqlcipher_live` test file. That live suite applies the shared store contract to
`Store.SQLiteEncrypted` and verifies a raw canary does not appear in DB/WAL/SHM
files. `Store.SQLite.backup/2` now uses SQLite `VACUUM INTO` through the live
store process and blocks plaintext backups unless `allow_plaintext_export?: true`
is supplied. `Store.SQLite.restore_backup/3` performs an offline private-file
restore and refuses overwrite unless `replace?: true`. `Store.SQLiteEncrypted`
exposes the same backup/restore API for SQLCipher-enabled builds. CLI wrappers
are now exposed as `twelvgaige store backup <destination>` and
`twelvgaige store restore <source> <destination>`. Plaintext SQLite backup still
requires `--allow-plaintext-export`; encrypted SQLite backup does not. Restore is
offline and writes a destination file that the operator can later select through
the normal store environment variables. Plaintext-to-encrypted migration is now
exposed as `twelvgaige store migrate-sqlcipher --source <plain.db>
--destination <encrypted.db> --key-env <env>`. The migration uses SQLCipher's
attach/export path, leaves the source in place, refuses overwrite unless
`--replace` is supplied, and fails before creating the target when the loaded
driver does not expose `PRAGMA cipher_version`. Rewrap integration is exposed as
`twelvgaige store rewrap-envelope <envelope.json> --backup <backup.json>
--old-key-env <env> --new-key-env <env>`. It requires a backup before writing,
rewraps only the DEK envelope, leaves database page rekeying for a later phase,
and has failure tests proving an unwrap error leaves the original envelope and
backup intact. Burrito smoke coverage is still pending.

### Phase CTE8 - Live Audit Signing And Verification

- Extend checkpoint export with optional signature metadata. `[x]`
- Add live audit HMAC design only after key management exists.
- Add key rotation behavior for signed audit chains.
- Keep hash chain, HMAC chain, and public signature modes separate in command
  output and docs. `[x]`

Acceptance:

- Export verification detects mutation, deletion, and reordering. `[x]`
- Signed exports can be verified with the public/verification material or key ref
  appropriate to the chosen algorithm. `[~]`
- Docs avoid calling the live local store tamper-proof. `[x]`

Current implementation note: checkpoint exports remain SHA-256 hash chains by
default. CLI `round audit --format checkpoint --sign-hmac-env <env>` can add an
HMAC-SHA-256 signature block, and `audit verify --hmac-env <env>` verifies both
the hash chain and shared-secret signature. This is intentionally distinct from
future public-signature mode; the HMAC verifier must hold the same secret. Live
audit records are still not signed as they are written.

## Testing Strategy

Unit tests:

- config validation for TLS/proxy/encryption options,
- key ref parsing and redaction,
- audit canonicalization and hash/HMAC verification,
- secure comparison behavior.

Integration tests:

- provider TLS fake server invalid cert/hostname cases,
- TLS listener with fixture certs,
- mTLS listener with trusted and untrusted client certs,
- trusted-proxy mode with trusted and untrusted source addresses,
- encrypted SQLite store contract,
- plaintext-to-encrypted migration command,
- encrypted backup/restore and key rewrap command.

Platform tests:

- Burrito smoke test for encrypted SQLite spike before feature commitment,
- macOS Keychain backend,
- Windows DPAPI/Credential Manager backend,
- Linux Secret Service backend,
- fallback env/file backend for CI.

Canary tests:

- no raw encryption keys in logs/errors,
- no raw secrets in audit/store/API/watch outputs where redaction applies,
- no plaintext canary in encrypted DB/WAL/temp files with raw retention,
- no plaintext canary in logical persisted records when summary retention is
  enabled.

## Documentation Updates

Update these files as phases land:

- `docs/security.md`
- `docs/secrets-and-providers.md`
- `docs/release.md`
- `docs/design/spec.md`
- `USAGE.md`

Required language:

- Before CTE7: "Local stores are not encrypted by Twelvgaige; use OS or volume
  encryption."
- After CTE7: "Encrypted SQLite is available when configured with a supported
  key backend."
- Before CTE2.5: "Use a trusted TLS/mTLS proxy for remote API exposure."
- After CTE2.5: "Native TLS/mTLS is available when configured; loopback HTTP
  remains the default local mode."

## Recommended First Slice

Start with CTE0, CTE1, and CTE2:

1. Add crypto status/config terminology without changing store behavior.
2. Add provider TLS regression tests.
3. Update docs to clarify exactly what is and is not encrypted.
4. Reject unsupported native TLS config instead of treating `tls_options` as
   protection before the listener implements TLS.
5. Harden trusted-proxy validation.

This creates immediate security value without taking on SQLCipher, OS keychain,
or native mTLS as product commitments first. The SQLCipher/Burrito feasibility
spike starts later at CTE5, after transport and integrity basics are in place.
