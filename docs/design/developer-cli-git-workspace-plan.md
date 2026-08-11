# Developer CLI, Git, and Workspace Plan

Date: 2026-08-11

Status: Core implementation substantially complete; release qualification active

Audience: Maintainers and contributors

## Implementation Checkpoint

This document is both the target design and the delivery checklist. A phase is
complete only when its normal, failure, restart, and recovery paths pass. Code
existing in one layer does not make the corresponding CLI feature supported.

As of 2026-08-11:

- Phase 0 is implemented. Result capture builds and verifies the
  complete result tree without repository filters, includes committed, staged,
  unstaged, untracked, binary, rename, deletion, and mode changes, and persists
  a versioned manifest plus encrypted artifact. Normal, failed, timed-out, and
  cancelled terminal paths pass through runtime quiescence and finalization.
  A digest-bound credential-free verification contract is integrated and
  rejects network access, provider environment, credentials, non-copy
  workspaces, and incomplete command evidence. Provider-reported tests are not
  labeled independent. A production executor now imports the finalized source
  through a one-shot initializer into a fresh sandbox-owned volume, then runs
  command-by-command verification without network or provider credentials. The
  same executor has live qualification evidence for Podman and Apple
  containers.
- Phase 1 is implemented through the public CLI. `repo inspect`, `session plan`,
  and `session start` expose `committed`, `staged`, and `working-tree` input,
  explicit untracked and ignored-file authority, source-state tokens, and base
  commits. Start revalidates the planned token before allocation. Private
  snapshots preserve ancestry and leave source HEAD, index, files, refs, and
  configuration unchanged in the covered fixtures.
- Phase 2 is implemented for the initial single-user lifecycle. Workspace
  creation, finalization, apply, reconciliation, review cleanup, and workspace
  cleanup use durable write-ahead operations and request-id idempotency. Restart
  converts interrupted mutations to `needs_reconciliation`; explicit
  reconciliation preserves evidence and records quarantine. Admission reserves
  execution, result, and verification capacity plus protected finalization
  capacity. Cleanup is exact-target, dry-run-first, epoch-checked, and refuses
  uncaptured work. A configurable automatic seven-day workspace retention sweep
  uses the same journaled cleanup path. Full-workspace import now has its own
  owner-only write-ahead journal: fault injection after every swap side effect
  proves that restart either restores the prior workspace or commits the
  validated replacement, removes exact abandoned staging, and never guesses at
  an unjournaled backup. The enumerated lifecycle matrix now covers 178
  before-and-after boundary cases across workspace, result, review, direct
  apply, cleanup, and sandbox-resource operations. Local macOS arm64 evidence
  passes without skipped cases; retained CI evidence for every advertised
  platform remains a release gate.
- Phase 3 is implemented for the main workflow. Markdown and YAML task files
  work positionally; repository and workspace inspection commands support
  repository scoping, unambiguous prefixes, and `--last`; session start is
  retry-safe across the CLI, IPC envelope, and durable inventory; and offline
  bash, zsh, and fish completion is available. A dispatcher-level global option
  layer accepts `--quiet`, `--verbose`, and `--color auto|always|never` in any
  position without changing JSON output; verbose command identity and timing go
  only to stderr. Completion dynamically reads developer profiles and local
  session/workspace record keys through an SQLite read-only connection, without
  daemon IPC, record decoding, provider access, credentials, or database writes.
  `doctor` reports CLI and daemon protocol versions, Git, the pinned provider
  and protocol, selected sandbox and image identity where discoverable,
  credential mode, and provider/backend capabilities.
  `session plan --output <path>` now writes a schema-versioned, digest-bound,
  owner-only saved plan and prints the exact `session start --plan <path>`
  handoff. Plan and start use the same resolver and deterministic identities.
  Start reconstructs the exact planned request, re-inspects the source before
  allocation, and rejects drift in every material request or resolution field
  with a field-specific error. Saved plans are regular files, limited to 1 MiB,
  created exclusively with mode `0600`, and never overwrite an existing path.
  Planning output and saved-plan errors do not disclose task bodies or changed
  secret values.
  Explicit multi-repository sets now have read-only `workspace set list` and
  `workspace set show` commands over the authenticated local IPC protocol. The
  review view reports every named repository's input commit, resulting commit,
  and managed workspace ID without silently expanding an ordinary task into a
  set operation.
- Phase 4 is implemented for artifact export and the default apply path. Both
  session and workspace commands can export verified result artifacts. Apply is
  dry-run-first and creates a detached managed review worktree by default. The
  source checkout remains unchanged, the shared common-Git-directory boundary
  is reported, and review cleanup refuses edits whose tree differs from the
  captured result.
- Phase 5 is implemented for the guarded direct path. It requires
  `--target current-worktree`, `--write`, `--yes`, an exact control epoch, a
  clean target at the recorded base, and a request ID. It writes an owner-only
  per-path and index backup before patch application, verifies the final tree,
  retains the backup for seven days, and enters `needs_reconciliation` without
  reset, clean, stash, or automatic rollback when an interrupted write leaves
  evidence behind. Explicit reconciliation can either quarantine the workspace
  or restore a checksum-validated backup after proving the source has not
  changed since the interruption.
- The production manager runtime now has one deterministic path from an
  admitted child to an attached Podman or Apple container, including stable
  sandbox identity, copied workspace and credential mounts, cancellation,
  export, destruction, and runtime-quiescence evidence. Unattended Codex API
  credentials are resolved in the manager, issued through a short-lived
  session-bound broker lease, and passed to `codex login --with-api-key` only
  over stdin in a scrubbed environment. The resulting owner-only, bounded
  `CODEX_HOME` is mounted into the outer sandbox and is removed when the lease
  is revoked. Secret-like worker environment names remain denied. The runtime
  supervisor restarts admission, sandbox ownership, and scheduling together so
  no scheduler survives replacement of its runtime authority. Sandbox resource
  intent and ownership are persisted before creation when durable operation is
  enabled. On manager restart, Twelvgaige revokes the recorded authority,
  destroys the exact resource, releases admission, and removes the journal
  before scheduling resumes; sanitized backups exclude live sandbox records.
- Phase 6 remains qualification work. Unsupported Git features still fail
  before allocation. Git 2.39.0 is the enforced minimum. Ordinary SHA-1 and
  bare repositories, linked review worktrees, symlinks, binary changes, unusual
  filenames covered by fixtures, and explicit rejection of submodules, Git
  LFS, sparse checkout, shallow and partial clones, case collisions, nested
  repositories, filters, and SHA-256 object storage now have fixtures. A real
  2,000-file fixture with 8 MiB of deterministic binary data now qualifies
  inspection, ancestry-preserving capture, result capture, patch round-trip,
  manifest verification, memory, and disk amplification against explicit
  ceilings. It exposed and drove replacement of per-file Git processes with
  bounded object and index batches: on macOS arm64 with Git 2.55.0, source
  capture fell from 72.2 seconds to 2.2 seconds and result capture from 71.3
  seconds to 1.3 seconds. The full platform matrix and oldest-Git runs remain
  incomplete. The checksum-pinned Git 2.39.0 workspace suite now passes all 53
  selected fixtures plus the performance qualification on macOS arm64. Linux
  runs the same pinned source build in CI; that support claim remains pending
  until its retained evidence passes. Agent
  commits after the workspace baseline are now preserved in a self-contained,
  size-bounded Git bundle, verified before persistence, digest-bound in
  `ResultManifest.v2`, and exported beside the patch; v1 manifests remain
  readable under their original digest contract. `doctor` now reports
  actionable data-volume pressure without exposing its path, storage-admission
  failures point to read-only inventory commands, and retention status suggests
  a sweep only when verified workspaces have actually expired.
- The first-pass support bundle is implemented as a separate dry-run-first
  command. It exports only environment versions, configured profile names, and
  daemon availability/transport; persisted metadata excludes its own absolute
  destination. Source, workspaces, task text, transcripts, credentials,
  endpoint tokens, databases, audit payloads, artifacts, patches, and absolute
  paths are explicitly excluded. The destination and files are owner-only,
  writes require `--write --yes`, and a repeated request ID verifies the exact
  manifest, file set, digests, sizes, types, and permissions before reporting a
  replay.
- Common-path discoverability and latency now have a public-command
  qualification rather than an internal-function benchmark. It verifies help
  contains plan/start/review and support-bundle paths, generates all three
  completion formats, runs JSON repository inspection and task validation,
  performs a no-mutation JSON session plan, and exercises the saved-plan
  handoff through the public dispatcher and result envelope. The retained local
  macOS arm64 run records 3 ms for help, 4–6 ms for completion generation, 10 ms
  for task validation, 269 ms for repository inspection, 280 ms for session
  planning, and 275 ms for the saved-plan handoff. The same qualification must
  retain independent macOS and Linux CI evidence before release.
- The first-pass hardening audit now has six explicit gates. Four are
  implemented locally: every public JSON and NDJSON response uses the shared
  versioned envelope; source reads and managed mutations are separated by
  mechanically enforced Git capability APIs; and managed Git mutations emit
  paired, durable intent and terminal audit records. The enumerated interruption
  matrix fails on missing, duplicate, unknown, invalid, or skipped cases and
  retains exact per-boundary outcomes. Result capture also uses an
  isolated object directory so a read or preview cannot add objects to the
  source repository. The evidence-derived support matrix is now enforced by the
  release gate: a locally qualified claim must name a passing retained evidence
  file, while pending and not-advertised states remain explicit. Retained Linux,
  fish-parser and real authenticated attached-run evidence remain
  pending. Existing component coverage must not be used to mark those gates
  complete.
- Previous-release migration now has a retained, fail-closed qualification.
  Fixtures produced by the tagged `v0.0.3` release cover both SQLite and file
  stores, completed records, and an interrupted write with an unresolved tool
  intent. Current code upgrades the decoded snapshot schema, migrates legacy
  audit events into a verifiable chain, keeps completed work readable, and
  moves the interrupted write to `awaiting_reconciliation` instead of retrying
  it. A fixed result-manifest v1 vector also proves that its original canonical
  payload and digest are unchanged. `make migration-qualify` records the
  fixture provenance, exact artifact digests, and each outcome; macOS and Linux
  CI retain separate evidence.
- The local engineering gates are green after the saved-plan work. `make check`
  passes formatting, warnings-as-errors compilation, Credo, Sobelow, the full
  default test suite (1,284 passing, 44 excluded), and the Phase 0 performance
  gate. `make typecheck` passes without Dialyzer warnings or suppressions. The
  configured coverage gate also passes at 76.1% aggregate coverage against a
  75% floor; the Codex
  authentication-profile and executor critical modules are at 100% and 95.5%,
  respectively. These figures establish the local regression baseline, but do
  not substitute for platform, migration, shell-parser, or authenticated live
  qualification.
- The deterministic-invocation contract is qualified locally. The fixed
  configuration precedence and non-secret
  per-setting provenance are implemented in profile resolution, task and CLI
  overrides, planning, persisted start requests, and human output. Public
  command paths, authority classes, daemon requirements, completion, and the
  initial compatibility aliases now share a typed command model. The model
  declares every documented option type, default, conflict, and output schema;
  help and completion derive from that model. Dispatch now runs the model's
  typed validation before any command-specific parser, including every enum,
  integer, duration, timestamp, environment-name, and digest option, required
  option, and declared constraint. Established error phrases remain compatible.
  The retained public qualification exercises every semantic option contract,
  the complete default inventory, and every completion candidate. It also covers
  configuration provenance and fail-closed missing-daemon behavior across the
  main command classes. Client timeout reports an unknown durable disposition
  and request-ID lookup instead of claiming daemon failure. First-interrupt
  cancellation and second-interrupt detachment have state-machine tests. The
  packaged release launcher passes a real PTY qualification on local macOS for
  signal forwarding, exit-status propagation, child reaping, and temporary-file
  cleanup. Public saved-plan fixtures now prove exact request reconstruction,
  plan/start identity parity, owner-only persistence, no-mutation planning, task
  redaction, and independent drift rejection for every request and resolution
  field. Shell completion now asks the typed model for candidates at runtime;
  retained public qualification checks every command path, option, enum, global
  placement, and declared conflict instead of sampling a hand-maintained
  subset. Generated bash and zsh scripts pass their local parsers. The native
  Mix release, escript launcher, and macOS Burrito executable each pass the same
  real Ollama-backed package E2E. That gate exposed and fixed a release-only
  omission of the OTP `inets` and `ssl` applications. Remaining work is retained
  fish-parser evidence and the advertised platform matrix. Existing component
  tests count only where they exercise those shared public contracts.

- The release matrix now includes the full attached-session lifecycle for both
  Podman and Apple containers as required evidence, in addition to direct
  provider/backend fixtures. It verifies attached stdio, outer-sandbox
  authority, copied rather than source-mounted credentials, complete workspace
  repatriation, runtime quiescence, and exact cleanup. Missing attached evidence
  fails closed instead of allowing the release qualification to pass. The live
  runs require explicit authorization because they copy local Codex login state
  into an ephemeral credential directory and enable unrestricted provider
  networking for a controlled fixture. That authorization has not been granted
  in the current qualification run, so both attached checks remain open. The
  release gate also consumes the retained developer-CLI, 178-case lifecycle,
  previous-release migration, minimum-Git workspace, and packaged-interrupt
  records directly. Each record is validated against its complete contract;
  a top-level passing label is not sufficient. `make release-qualification`
  regenerates the locally runnable records and all three packaged-executable
  E2E fixtures before evaluating the aggregate report. The current report has
  18 passing checks and exactly the two missing attached-session failures.

The core workflow is implemented; the remaining work is release qualification.
The immediate gates are retained fault-matrix evidence on every advertised
platform, explicitly authorized live qualification of the real authenticated
delegated-session path inside both selected outer sandboxes, and the Phase 6
platform matrix. In particular, retained Linux, fish-parser, and authenticated
attached Podman and Apple-container evidence are still pending. The
production wiring and deterministic component fixtures prove the intended
boundary and cleanup sequence, but they do not replace a live run that starts,
authenticates, supervises, cancels, and finalizes Codex through that boundary.
Features remain fail-closed until those fixtures pass on a named platform and
Git version.

## Purpose

Make delegated coding sessions feel natural from a developer's terminal while
keeping Git operations recoverable and workspace boundaries explicit.

The common path should be short:

```bash
twelvgaige session plan task.md
twelvgaige session start task.md --follow
twelvgaige session review <session-id>
```

When something goes wrong, the CLI should say which repository, commit,
workspace, sandbox, and artifact it used, then provide a safe next command. A
developer should not need to inspect the application-data directory or reverse
engineer a detached Git state.

## Scope

This plan covers:

- CLI command shape, output, errors, discovery, and shell completion.
- Repository preflight and source-state selection.
- Isolated execution snapshots and linked worktrees for human review.
- Durable workspace identity, inspection, recovery, retention, and cleanup.
- Correct capture of committed, staged, unstaged, untracked, and binary changes.
- Patch, commit, bundle, artifact, and verification handoff.
- Explicit, reviewable application of completed work.

This plan does not add providers or agent runtimes. It stays within Codex,
OpenAI, OpenCode, and Ollama. It also does not make Twelvgaige a Git hosting
service or permit automatic merge, push, force-push, or branch deletion.

It also does not fetch missing objects, install Git extensions, run repository
hooks, or evaluate arbitrary repository configuration during source capture.

## First-pass release invariants

These are cross-cutting requirements, not later polish. Each one needs a test
through the same public command and runtime path that developers will use.

### One production execution path

- The session controller must launch the delegated process inside the selected
  Podman or Apple container boundary. Starting the provider process on the host
  and creating a separate container does not satisfy the sandbox contract.
- Authentication material must enter through the credential broker, remain
  outside the source snapshot, and be revoked or removed when the session ends.
- API-key authentication materializes an isolated per-session `CODEX_HOME` by
  invoking the supported Codex stdin login flow from a scrubbed manager
  process. The raw key must never appear in argv, the launch manifest, worker
  environment, source, result artifacts, routine errors, or logs. The worker
  receives only the copied credential home and non-secret lease identity.
- A locally materialized API key is not a per-request enforcement proxy. The
  manager still enforces session runtime and declared budgets, and provider
  project limits remain useful, but hard model, destination, or token checks on
  every provider request require a configured gateway credential profile.
- Interactive auto-approval flags may relax provider prompts only within the
  authority already granted to the Twelvgaige session. They cannot widen host
  mounts, credentials, network policy, budgets, or cleanup authority.
- Readiness, cancellation, timeout, process-tree quiescence, result capture,
  and cleanup must all be driven by the same supervised runtime handle.
- Mock adapters and direct backend qualification remain useful unit and
  component tests, but cannot satisfy the release gate for a supported session
  profile.

### Stable automation contract

- Every command that changes state accepts a caller-supplied request ID and is
  safe to retry after a timeout or lost response.
- `--format json` writes one versioned result envelope to stdout. Progress,
  warnings, and diagnostics go to stderr. NDJSON streams use a terminal record
  that states the final disposition.
- Non-interactive commands never prompt. Missing authority, ambiguous IDs,
  dirty input, and destructive effects return a typed error with a safe next
  command.
- Exit codes distinguish invalid input, policy denial, conflict or drift,
  unavailable runtime, failed delegated work, failed verification, and
  internal failure.
- Human output may improve without breaking automation; field removal or a
  semantic change requires a new schema version.

### Deterministic invocation and control-plane behavior

- Define the command tree, option types, defaults, conflicts, authority level,
  and machine-output schema once. Parsing, help, completion, examples, and
  compatibility tests must derive from or validate against that model so they
  cannot drift independently.
- Configuration precedence is, from lowest to highest: built-in defaults, user
  profile, repository profile, task document, then explicit CLI flags. A value
  may widen authority only when the highest-precedence source expresses that
  authority directly; merging lists must not accidentally turn two restricted
  inputs into a broader union.
- The plan and `--verbose` output identify the source of every material setting,
  including repository, source mode, write paths, sandbox, network policy,
  authentication profile reference, budget, timeout, and apply target. Secret
  values are never printed.
- Environment variables are limited to documented process-level concerns such
  as config/runtime locations and credential injection. They must not silently
  override task authority, write paths, network policy, sandbox selection, or
  Git target state.
- Read-only commands that can operate from local inputs, including help,
  completion, task validation, repository inspection, and session planning, do
  not require or start the daemon. A command that needs the daemon reports its
  unavailable state and an exact start or status command; it never creates a
  hidden background process as a side effect of parsing or inspection.
- A client timeout does not imply that a mutating daemon operation stopped.
  Timeout output includes the request ID and an exact lookup or retry command.
  Repeating that request ID observes the original operation rather than
  creating a replacement.
- The first interrupt requests the normal cancellation protocol and continues
  to show bounded shutdown progress. A second interrupt may detach the client,
  but it does not claim that the sandbox or delegated process has stopped. The
  terminal result identifies the still-running or recoverable operation and
  gives a status command.
- Human output may use color and terminal width, but it does not invoke a pager
  in non-interactive use. JSON and NDJSON are independent of terminal width,
  color settings, locale, and whether stdout is a TTY.
- Unknown commands and flags fail rather than being prefix-matched. A renamed
  command or flag keeps an explicit compatibility alias for a documented
  transition window, warns only on stderr, and names the release in which the
  alias will be removed.

### First-pass developer workflow contract

The first release also fixes the shape of the everyday workflow. These rules
prevent later safety work from making the CLI unpredictable or forcing scripts
to depend on internal storage details.

- **Plan and start use the same resolver.** `session plan` and `session start`
  consume the same typed request and configuration resolver. A successful plan
  prints its digest, source token, resolved repository, selected profile, and a
  copyable start command. Start either accepts that saved plan unchanged or
  reports the exact field that drifted; it does not silently re-plan with new
  defaults.
- **Every response carries usable context.** Human and machine output identify
  the selected repository, profile, session, workspace, request, and operation
  when they exist. List commands are repository-scoped by default, and an
  explicit `--all-repos` is required to cross that boundary. A developer never
  has to inspect the application-data directory to discover the active object.
- **Recovery is operation-centered.** A mutating command prints its request ID
  before or with the first progress record. `operation show <request-id>` works
  after a client timeout, interrupt, daemon restart, or lost terminal and
  returns the durable disposition plus one exact next command. `resume`,
  `retry`, `reconcile`, and `clean` remain distinct actions; none is inferred
  from a generic `start` retry.
- **Managed Git names cannot collide with developer names.** Internal refs,
  temporary directories, review-worktree paths, and optional generated branch
  names derive from the durable workspace identity rather than task text or the
  current branch. Creation uses exclusive semantics, records the final name,
  and fails safely on an existing unowned target. The default review worktree
  remains detached, so a successful session does not create a branch.
- **The packaged executable is the tested interface.** Release qualification
  invokes the installed launcher and daemon protocol, not only Elixir command
  modules. It covers spaces and non-ASCII characters in repository and task
  paths, stdin and non-TTY execution, stdout/stderr separation, exit-status
  propagation, first and second interrupts, child-process cleanup, and
  temporary-file cleanup. Platform-specific launchers may differ internally,
  but supported platforms expose the same documented command behavior.

### Ownership, concurrency, and cancellation

- A single user may run concurrent sessions, but only one mutating operation
  may own a workspace at a time. Repository-scoped writes use the validated
  common Git directory as the lock identity.
- Admission records the controlling process, operation ID, request ID, control
  epoch, and resource reservation before an external side effect begins.
- `Ctrl-C`, daemon shutdown, provider exit, sandbox failure, and deadline expiry
  converge on the same cancellation protocol: stop new work, terminate the
  delegated process tree, prove quiescence, capture what remains, and persist a
  recoverable terminal state.
- A second interrupt may shorten waiting, but it must not skip evidence capture
  or exact-target cleanup without recording that the result is incomplete.

### Compatibility and capability discovery

- `twelvgaige doctor` and session planning report the CLI, daemon protocol,
  Git, provider, sandbox backend, image digest, and credential-mode versions
  that will actually be used.
- The daemon rejects an incompatible CLI protocol before mutation. Backend and
  provider capabilities are discovered and saved in the plan rather than
  inferred from an executable name.
- A saved plan is bound to these capabilities. Start refuses drift in policy,
  image, source token, authentication mode, or sandbox backend unless the user
  creates a new plan.
- Resume supports only the pinned current provider version and the immediately
  previous version during the documented transition window.

### Privacy and diagnosability

- Routine logs contain identifiers and digests, not prompts, source contents,
  patches, credentials, raw provider environments, or task-file bodies.
- Human and JSON errors include the failed phase, stable error code, affected
  resource IDs, whether retry is safe, and an exact inspection or recovery
  command.
- `--verbose` exposes decisions and timing without exposing secrets.
  Security-sensitive raw artifacts require a separate explicit command and
  retain their audit entry.
- A support bundle is allowlist-based, redacted by default, and inspectable
  before export.

### Bounded local resource use

- Planning estimates source, workspace, result, verification, and backup disk
  demand. Admission reserves finalization headroom and fails before allocation
  when the bound cannot be met.
- Concurrency, CPU, memory, process count, file count, output bytes, event
  backlog, and wall-clock time have profile-defined defaults and hard ceilings.
- Backpressure must slow or stop provider event ingestion without dropping
  lifecycle, policy, or terminal events.
- Cleanup and retention operate on exact recorded resource IDs. They never
  discover deletion targets through broad globs or an untrusted task path.

### First-pass release proof

A release candidate must preserve evidence for one end-to-end run on each
advertised sandbox backend that covers plan, authentication, sandbox creation,
delegated execution, event streaming, cancellation, quiescence, result capture,
independent verification, export, review, and cleanup. The proof must also show
that the source common Git directory was never mounted, provider credentials
were absent from verification, no managed runtime resource remained, and a
repeated request ID caused no duplicate side effect.

### First-pass qualification contract

Qualification must distinguish a feature that compiles from a feature that is
supported. Each evidence record names the operating system and architecture,
Git version, CLI and daemon protocol versions, provider artifact and protocol,
sandbox backend and version, image digest, credential mode, source mode, and
apply mode. A missing field or an unexecuted case is `unqualified`, not an
implicit pass.

The first release matrix is intentionally narrow:

| Platform | CLI contract | Git source and result fixtures | Sandbox execution |
| --- | --- | --- | --- |
| macOS arm64 | Required | Required | Podman required; Apple containers opt-in and separately qualified |
| Linux x86-64 | Required | Required | Not advertised by this plan |

Git 2.39.0 is the minimum supported version. CI must exercise the minimum on
macOS and Linux before release in addition to the pinned current version. A
newer local run may provide useful evidence but does not prove the minimum.
Each generated bash and zsh completion script must pass its shell's syntax
check; fish must do the same when fish completion is shipped for that release.
Dynamic completion remains offline and read-only.

The large-repository qualification fixture must contain at least 2,000 regular
files, unusual but valid path names, an executable, symlinks where supported,
and at least 8 MiB of deterministic binary content. It measures repository
inspection, ancestry-preserving source capture, controlled edit/rename/delete
and binary result capture, and manifest verification. The evidence records
wall-clock time, peak or bounded process memory, input bytes, managed bytes,
file counts, and disk amplification.

Initial release ceilings are deliberately generous failure bounds, not
performance promises:

- repository inspection completes within 10 seconds;
- source capture completes within 60 seconds;
- result capture and manifest verification each complete within 30 seconds;
- measured process-memory growth remains below 512 MiB; and
- managed disk use remains below four times the measured source bytes, with
  finalization reserve accounted separately.

CI runs the qualification on macOS arm64 and Linux x86-64, retains the versioned
JSON evidence as a build artifact, and fails on a missing measurement, exceeded
ceiling, source mutation, result mismatch, or leaked managed resource. Local
evidence is written under `qualification/evidence/workspace/` and must not
contain repository contents, task text, credentials, or absolute source paths.
Threshold evaluation has deterministic unit tests; the generated repository is
still required because injected measurements alone cannot qualify the real Git
and filesystem path.

The release gate remains closed until the restart fault matrix, authenticated
attached-session proof, supported-backend cleanup proof, minimum-Git runs, and
large-repository qualification all pass. Any override is an explicit
unsupported user choice and never changes the published support matrix.

### First-pass hardening gates

The first release should settle the boundaries that become expensive to change
after developers begin scripting against the CLI. These are release gates, not
follow-up polish:

1. **One versioned machine-output envelope.** Every non-streaming
   `--format json` response uses the same top-level envelope for success and
   failure. It identifies the envelope schema and version, command, disposition,
   and result or typed error. Request and resolved resource IDs are present when
   applicable. NDJSON uses a versioned event envelope and exactly one terminal
   record. Existing command payloads remain nested without semantic changes;
   removing, renaming, or reinterpreting a field requires an explicit schema
   version change. Golden tests cover representative success, dry-run,
   rejection, conflict, unavailable, and internal-error output.
2. **Capability-scoped Git access.** The typed Git adapter exposes separate
   `SourceRead` and `ManagedWorkspace` interfaces in code, not only in
   documentation. `SourceRead` has no mutating entry points. A
   `ManagedWorkspace` operation requires a validated canonical root, durable
   workspace identity, active lease, and control epoch. CLI modules and session
   orchestration cannot invoke the unscoped process runner directly.
3. **Complete mutation audit.** Every Git command that can change a managed
   index, worktree, ref, or worktree registration emits a structured intent and
   completion or failure event bound to its durable operation, request ID,
   workspace ID, lease, control epoch, sanitized argument class, and resulting
   tree or state evidence. The event is persisted before the operation is
   reported complete. Audit records never contain credentials, repository
   contents, task text, patches, or credential-bearing URLs.
4. **Systematic interruption proof.** Maintain an enumerated fault matrix for
   create, capture, finalize, export, review apply, direct apply, reconcile,
   retention cleanup, and sandbox-resource cleanup. Inject termination before
   and after every durable phase transition and externally visible side effect.
   Each case proves one of three explicit outcomes: safe idempotent resume,
   checksum-validated compensation, or `needs_reconciliation` with preserved
   evidence and an exact recovery command. A source-file list or a few selected
   crash tests is not sufficient qualification.
5. **Evidence-backed support claims.** A platform, Git version, shell, sandbox
   backend, credential mode, or delegated-session path is supported only when a
   retained, versioned evidence record identifies the exact versions and proves
   cleanup. CI configuration alone is not evidence. Local evidence may qualify
   a named local combination but cannot stand in for a missing CI platform run.
   The published platform matrix is generated or checked against the retained
   evidence so it cannot silently overstate support.
6. **Backward-compatible rollout and recovery.** Schema migrations, legacy
   workspace records, interrupted operations, and immediately previous pinned
   provider sessions have explicit read, resume, export, or conservative
   reconciliation behavior. Upgrade tests begin from persisted fixtures from
   the prior supported release. No migration silently recalculates a digest,
   deletes a workspace, changes source-selection semantics, or widens authority.

The authenticated attached-session proof requires real user-selected
credentials and provider egress, so it is an explicit release qualification
step rather than an ordinary unit-test dependency. If that authority is not
available, the build may pass deterministic tests but the delegated-session
profile remains unqualified.

## Decision Status and System Boundaries

This document uses three decision labels:

- **Accepted:** an existing product constraint or a decision required to begin
  implementation.
- **Proposed:** the recommended design, subject to fixture-backed validation.
- **Open:** a product choice that can materially change the interface.

The initial architecture has four distinct locations. They must not be
collapsed into one path merely to make the CLI simpler:

| Location | Purpose | May the delegated agent write it? | Shares source Git metadata? |
|---|---|---:|---:|
| Source repository | Developer-owned input | No | Yes, by definition |
| Managed execution workspace | Reproducible agent input and output | Within declared write paths | No |
| Sandbox filesystem | Runtime enforcement boundary | Within sandbox policy | No |
| Managed review worktree | Human inspection and deliberate application | Human-controlled | Yes |

Accepted boundaries:

- A sandboxed delegated agent executes only in a private, ancestry-preserving
  snapshot. Podman or Apple containers enforce runtime isolation; OTP owns
  orchestration, lifecycle, leases, and policy state but is not a filesystem or
  kernel sandbox.
- A linked worktree is initially a review and application surface, not an agent
  execution transport. Its `.git` indirection reaches the source repository's
  common Git directory, which is incompatible with the default container mount
  contract and weakens isolation if that directory is mounted.
- Source materialization and output authority are separate. The workspace may
  contain the complete admitted source while the sandbox permits writes only to
  declared paths.
- The source repository is never a hidden application target. Export and apply
  are explicit post-session operations.

The existing `bind_worktree` transport is therefore legacy and experimental.
Container admission must reject it unless a future profile is separately
qualified; it must never silently mount the source common Git directory or
fall back from private-snapshot execution.

### Single-user threat model

The initial product is single-user software. Its security claims rely on these
trust boundaries:

- The local user, Twelvgaige CLI, daemon, and configured operating-system
  account are trusted.
- Delegated agents, generated commands, repository hooks, build scripts, test
  scripts, task-file content, and repository configuration are untrusted input.
- Provider credentials, source credentials, sandbox control credentials, and
  signing keys are never part of a workspace or result artifact.
- OTP provides supervision, process ownership, leases, timeouts, and durable
  recovery. It does not provide a filesystem, network, process, or kernel
  security boundary.
- Podman or Apple containers provide the qualified runtime boundary. A runtime
  that cannot enforce the selected filesystem, process, and network contract
  fails admission; it never falls back to unsandboxed execution.
- The host operating system and the user's account are trusted. Isolation
  between mutually hostile local users, remote daemon access, and multi-tenant
  scheduling are out of scope.

The source repository is developer-owned but may still contain unsafe scripts
or configuration. Read-only inspection must not execute them. Build and test
commands execute only inside the selected sandbox under the same network and
credential restrictions as other repository-controlled code.

## Desired Developer Experience

### First run

```bash
cd my-project
twelvgaige init --auth-profile codex-service
twelvgaige doctor
twelvgaige task validate task.md
twelvgaige session plan task.md
twelvgaige session start task.md --follow
```

The CLI discovers the repository root and project profile. `session plan`
prints the resolved base commit, source-state policy, workspace transport,
write paths, network policy, sandbox, authentication-profile reference, budget,
and expected result artifacts. It does not create a workspace or contact the
daemon.

For automation that needs an exact handoff between planning and starting:

```bash
twelvgaige session plan task.md --output plan.json
twelvgaige session start --plan plan.json --follow
```

The saved plan includes a schema version, `plan_digest`, and
`source_state_token`. Starting from it fails if the task, profile, repository,
policy, or source state has drifted. A normal `session start task.md` performs a
fresh just-in-time plan and the same server-side revalidation.

### While work is running

```bash
twelvgaige session show <session-id>
twelvgaige session watch <session-id>
twelvgaige workspace show <workspace-id>
twelvgaige workspace diff <workspace-id>
```

Human output should put the useful state first. JSON output remains stable and
complete for scripts. While an unattended session is active, inspection goes
through manager-backed `show`, `status`, and `diff` commands. The CLI does not
present the live path as a read-only boundary that the operating system cannot
actually enforce for the same local user.

### Reviewing and applying a result

```bash
twelvgaige session review <session-id>
twelvgaige session export <session-id> --output ./review/session-id
twelvgaige session apply <session-id> --check
twelvgaige session apply <session-id> --write --yes
```

`session apply` is always a separate, explicit operation. Without `--write`, it
is a dry run. It checks the target repository identity, exact base commit,
working-tree state, allowed paths, artifact digest, and patch applicability.
It never merges or pushes.

## Baseline Before This Plan

The implementation started with several useful foundations:

- `session start`, `session plan`, `session watch`, `session review`, and
  bounded retry commands.
- Project and user developer profiles.
- Stable session, child, and workspace identifiers.
- `copy_snapshot` as the unattended default.
- Interactive-only admission for `bind_worktree`.
- One writer lease per writable workspace.
- Cross-repository workspace sets and commit provenance.
- A separate integration workspace and no automatic merge.
- Podman and Apple container boundaries that do not require mounting the source
  repository into an unattended worker.

The following baseline gaps motivated the phases below. They describe the state
before this plan was implemented; the implementation
checkpoint at the beginning of this document is authoritative for current
status.

### Correctness gaps

1. `copy_snapshot` uses `git archive` at the resolved commit. It does not carry
   staged, unstaged, or untracked developer changes.
2. A snapshot is initialized as a new repository with a synthetic root commit.
   It records the source commit as metadata but does not preserve source
   ancestry for ordinary Git operations.
3. `allowed_paths` currently limits archive contents. Write authority and source
   materialization are different concerns; a partial repository can omit build
   files or dependencies needed for verification.
4. Finalization runs `git diff --binary HEAD`. That captures unstaged changes,
   but it misses changes the agent committed and does not include untracked
   files.
5. Individual workspaces are held in the workspace manager's memory. Workspace
   sets have durable provenance, but the ordinary workspace inventory is not a
   complete durable lifecycle record.
6. `Workspace.Manager.finalize/2` is not visibly connected to the normal manager
   executor path. A successful delegated session therefore needs an audited,
   end-to-end finalization contract rather than relying on adapter events alone.
7. `git worktree remove --force` can discard work. There is no public cleanup
   contract that requires result capture and a clean-state check first.

### Developer-experience gaps

- There is no `workspace` CLI command family.
- Markdown and YAML task files were supported only through `--task-file`; the
  baseline CLI did not accept them positionally for `session plan` or
  `session start`.
- Repository preflight does not explain dirty files, ignored files, submodules,
  Git LFS, sparse checkout, linked-worktree state, or the selected source mode.
- Session output does not consistently show workspace path, input commit,
  result commit, patch digest, or the next safe command.
- Errors are technically precise but often lack a concrete remediation command.
- IDs are stable but long, and commands do not have a documented unambiguous
  prefix rule.
- Cleanup, retention, export, and recovery are mostly operational concepts
  rather than developer-facing workflows.
- There is no shell completion contract for commands, flags, profiles, sessions,
  or workspace IDs.

## Design Principles

1. **Never surprise the source repository.** Snapshot mode must not change the
   source worktree, index, stash, refs, hooks, config, or remotes.
2. **Name the source state.** A session must record whether it started from a
   commit, the index, or an explicit working-tree overlay.
3. **Keep source capture separate from write authority.** The worker may need a
   complete repository to build while retaining permission to modify only
   declared paths.
4. **Preserve one exact base.** Every patch, commit, bundle, verification result,
   retry, and apply operation binds to the same source repository identity and
   base commit.
5. **Capture the result tree, not just `git diff HEAD`.** Agent commits and
   uncommitted files are both valid outcomes.
6. **Make destructive operations explicit.** Cleanup and application require a
   dry run or confirmation. Merge and push remain outside automatic session
   completion.
7. **Treat linked worktrees as a convenience boundary.** They are useful for an
   interactive reviewer, but they share Git metadata and are not an agent
   execution or unattended isolation boundary in the initial contract.
8. **Prefer recoverable artifacts.** Capture and verify the patch or bundle
   before releasing the writer lease or deleting a workspace.
9. **Keep human and machine interfaces aligned.** Human output is concise; JSON
   exposes the same state through a versioned schema.
10. **Revalidate at the authority boundary.** A plan is explanatory, not a
    reservation. Session start must confirm that the repository and source
    state still match before allocating a writable workspace.
11. **Prefer honest recovery over impossible atomicity.** Multi-file Git
    application cannot be guaranteed atomic across interruption. Use isolated
    review worktrees by default and journal any explicitly requested direct
    application.

## Recommended Decisions

### Source-state modes

Add an explicit source mode to profiles, task files, plans, and session records:

| Mode | Input | Recommended use |
|---|---|---|
| `committed` | Exact resolved commit | Default for unattended sessions and CI |
| `staged` | Base commit plus the current index | Reviewable local work prepared by the developer |
| `working-tree` | Base commit plus staged, tracked, and explicitly admitted untracked changes | Interactive local development |

Recommendations:

- Default unattended sessions to `committed`.
- If the repository is dirty, fail with an explanation and show
  `--source staged` and `--source working-tree`; do not silently ignore changes.
- Never create or apply a stash automatically.
- Never commit the developer's source worktree automatically.
- Include untracked files only with `--include-untracked` or matching declared
  include paths. Exclude ignored files by default.
- Require an additional explicit flag for ignored files and show a credential
  exposure warning before capture.
- Capture `staged` mode through a temporary index and stable tree object; never
  refresh or write the developer's index.
- Bound working-tree capture by file count, total bytes, and individual-file
  size. Record every omitted path and fail if a required path is omitted.
- Preserve file type and executable mode. Reject unsafe symlinks, nested
  repositories, and unsupported special files during planning.

Example:

```bash
twelvgaige session plan task.md --source working-tree --include-untracked
```

### Snapshot implementation

Keep `copy_snapshot` as the user-facing unattended transport, but replace the
synthetic-root implementation with an isolated Git repository that preserves
the exact source commit and ancestry.

The initial implementation should favor correctness over disk optimization:

1. Resolve and record the repository's common directory, worktree root, object
   format, base ref, and base commit.
2. Create a private repository under the managed workspace root without
   hardlinks, alternates, or writable shared Git metadata.
3. Check out the exact base commit in detached state.
4. Apply the admitted staged or working-tree overlay inside the private copy.
5. Disable hooks and ambient credential helpers for workspace Git commands.
6. Record an input manifest and digest after overlay application.
7. Copy the private workspace into the sandbox; do not mount the original
   repository or its `.git` directory.

`allowed_paths` constrains writes and result admission. It must not be reused as
a source-copy filter. The snapshot contains the complete admitted source except
for explicit sensitive-path exclusions. A result outside `allowed_paths` is a
policy failure: preserve it as quarantined evidence, report it, and do not
silently omit it from finalization.

Source capture is a checked transaction rather than a single `git archive`:

1. Inspect the repository and calculate a `source_state_token` from repository
   identity, HEAD, index state, selected overlay metadata, and relevant Git
   feature flags.
2. Capture through the source-read Git adapter with index refresh,
   hooks, filters, pagers, editors, prompts, and maintenance disabled.
3. Inspect again before accepting the capture. If the token changed, discard
   the incomplete private copy and retry once or fail with `source_changed`.
4. Build the input manifest and verify the materialized tree before allocating
   the writer lease.

The first release rejects repositories that require custom clean, smudge, or
process filters, including Git LFS. Checkout-based capture can execute those
programs and may contact the network or expose credentials. These features can
be qualified later with an explicit adapter and tests.

Do not optimize with shared object stores until tests prove they are read-only,
recoverable after source cleanup, and safe across repository ownership
boundaries.

### Managed review worktrees

Create a linked worktree only after result capture, as an optional human review
surface:

```bash
twelvgaige session apply <session-id> --write --yes
```

The CLI must explain that this mode shares the source repository's common Git
directory. It creates a detached worktree by default, verifies the artifact
against the recorded base, then materializes the result there without changing
the developer's current worktree or index. Creating a named branch is a
separate explicit option.

Before cleanup, Twelvgaige must:

- confirm that the path and common Git directory match the durable record;
- reject deletion when human edits have not been exported or explicitly
  discarded;
- use `git worktree remove` only for the exact registered path;
- inspect stale registrations under a repository-scoped lock;
- never delete a Git lock file or run broad cleanup automatically.

Executing an agent directly in a linked worktree is deferred. It requires a
separate design proving how the sandbox can use Git without receiving writable
access to the source common directory. It is not an undocumented escape hatch
for container or source-capture failures.

### Result capture

Finalization begins with a writer-quiescence barrier. Twelvgaige first stops new
provider and tool calls, asks the runtime to terminate, enforces the bounded
termination deadline, stops the complete process tree or container, and proves
that no delegated writer remains. It then transfers the lease to the finalizer
under a new control epoch. If the runtime cannot prove quiescence, the workspace
is quarantined and must not be captured as a stable result.

Finalization should construct one result tree from:

- commits created after the workspace base;
- staged changes;
- unstaged changes;
- admitted untracked files;
- deletions, renames, executable-bit changes, symlinks allowed by policy, and
  binary files.

The result model records both `source_base_commit` and
`workspace_baseline_commit`. They are normally identical in the new snapshot
format, but the distinction is required to finalize legacy synthetic-root
snapshots correctly. Finalization builds a temporary result index/tree so that
committed, staged, unstaged, and untracked state is represented exactly once.

It should then produce:

- a binary-safe patch from the exact base tree to the result tree;
- an optional commit series and Git bundle when the workspace contains useful
  commits;
- a changed-file manifest with modes, sizes, and digests;
- test and verification artifacts;
- the base commit, result-tree digest, result commit if present, and workspace
  status;
- a machine-readable application report.

Artifact-integrity verification applies the patch in a fresh isolated checkout
of the recorded base and compares the resulting tree digest. It does not run
repository code. Test verification is a separate operation in a new sandbox
with no provider credentials and restricted network access by default. A patch
can therefore be integrity-verified even when tests fail or cannot run. A
no-change session returns an explicit no-change result rather than an empty,
ambiguous patch.

Successful, failed, cancelled, timed-out, and exhausted-repair sessions all run
best-effort capture. Capture failure never changes a failed run into success;
it changes the workspace disposition to recoverable or quarantined and blocks
automatic deletion. Session success is impossible until the no-change marker
or verified result manifest is durably stored.

Do not overload one status with several meanings. Persist and display these
dimensions independently:

- agent execution: completed, failed, cancelled, timed out, or interrupted;
- result capture: complete, partial, failed, or no change;
- artifact integrity: verified, failed, or not attempted;
- test verification: passed, failed, timed out, or not run;
- policy compliance: compliant or rejected with evidence;
- workspace disposition: reviewable, retained, quarantined, reconciling, or
  deleted.

The human summary leads with the combined outcome, while JSON exposes every
dimension. Useful captured work remains reviewable when agent execution or
tests fail, but policy-rejected work cannot be applied.

### Workspace lifecycle

Persist every workspace, not only workspace-set provenance.

```text
creating → ready → leased → running → stopping → quiesced → finalizing
     └──────────────── failure/restart ───────────────────→ quarantined
finalizing → reviewable → retained
reviewable/retained → deleting → deleted
```

Each durable record should include:

- workspace and owning session IDs;
- canonical source repository identity;
- source mode, base ref, and base commit;
- input overlay manifest and digest;
- transport and managed path;
- sandbox identity and policy revision;
- writer lease and control epoch;
- runtime process/container identity and quiescence evidence;
- result commit, result-tree digest, patch and bundle artifact references;
- dirty and capture status;
- created, finalized, retained-until, quarantined, and deleted timestamps.

A restart reconciles the durable record with the managed directory and Git
state. Missing paths, unexpected Git common directories, identity drift, or
uncaptured changes move the workspace to `quarantined`; they are never silently
deleted or recreated.

Workspace admission reserves enough disk for the execution copy, result
artifact, and integrity-verification checkout before the agent starts. Enforce
per-workspace and total managed-storage limits, keep a finalization reserve, and
reject admission when available capacity cannot preserve a recoverable result.
Disk pressure may shorten future admissions but must not trigger deletion of an
active, uncaptured, quarantined, or retained workspace.

Managed roots, workspaces, temporary files, operation journals, and artifacts
use owner-only permissions from creation rather than relying on a later chmod.
Creation and cleanup walk validated paths without following symlinks and refuse
hard-linked or replaced targets when identity no longer matches the durable
record. Temporary files stay under the managed root or destination filesystem;
they are not placed in a shared predictable directory.

Source and result artifacts may contain credentials even when provider secrets
are excluded. Do not print file contents, patches, task text, repository URLs,
or raw command environments in routine logs, telemetry, completion, or error
messages. Retention deletion means removal from Twelvgaige's managed storage,
not a promise of physical secure erasure on copy-on-write filesystems or SSDs.

### Versioned data contracts

Define these schemas before adding more CLI commands. JSON fields are additive
within a schema version; a semantic change requires a new version.

| Contract | Required identity and evidence |
|---|---|
| `RepositoryInspection.v1` | Canonical root, common directory, local and logical repository identities, object format, HEAD, proposed base, dirtiness, feature flags, warnings, and `source_state_token` |
| `SourceManifest.v1` | Repository logical identity, base commit, source mode, index/tree identity, overlay entries with modes and digests, exclusions, limits, and manifest digest |
| `WorkspaceRecord.v2` | Workspace/session IDs, state and revision, source-manifest digest, transport, canonical managed path, lease/epoch, sandbox identity, workspace baseline, result references, retention, and reconciliation reason |
| `ResultManifest.v2` | Input and result digests, source base and workspace baseline, changed paths, patch and optional verified commit-bundle identity, verification, out-of-policy evidence, and explicit `no_change`; v1 remains readable without bundle fields |
| `ApplyReport.v1` | Target identity, checked preconditions, dry-run outcome, authorization, backup/journal references, final tree verification, and reconciliation state |

Repository identity has two forms:

- Local identity binds operations to the canonical worktree and common-directory
  filesystem identities on this machine.
- Logical identity binds portable artifacts to object format, base commit, and
  an optional sanitized remote fingerprint. It never stores remote credentials
  or credential-bearing URLs.

### Canonical encoding and digest contract

Portable digests must not depend on Elixir map order, JSON encoder behavior,
host paths, timestamps, locale, or display escaping. Define one canonical byte
encoding for each versioned contract before persisting its first digest:

- Use RFC 8785 JSON Canonicalization Scheme. Contract schemas allow integers
  only within JSON's interoperable exact range and do not use floating-point
  values. Unicode strings retain their original scalar sequence; Twelvgaige does
  not silently apply NFC or another normalization. Fields omitted by the schema
  are absent rather than serialized as implementation-specific null values.
- Represent repository paths by their raw bytes using unpadded base64url plus an
  optional escaped display value. Digest and ordering use the raw bytes; display
  text is never authoritative. This preserves Git paths that are not valid
  UTF-8.
- Sort manifest path entries by unsigned raw path bytes. Include file type,
  executable mode, symlink target bytes, content digest, and deletion state.
- Exclude transient local paths, timestamps, progress, and human messages from
  portable digests unless the contract explicitly makes them part of identity.
- Use SHA-256 initially and domain-separate every digest as
  `twelvgaige\0<contract>\0<version>\0<canonical-bytes>`. The digest field itself
  is omitted while calculating the digest.
- Store the algorithm, contract name, and version next to every digest. A future
  algorithm change creates a new digest version; it never reinterprets stored
  values.

Add cross-language golden vectors for empty manifests, binary paths, Unicode,
symlinks, executable files, large integer limits, and field-order changes. The
human-facing JSON may be pretty-printed, but verification always rebuilds the
canonical bytes from the typed contract.

### Non-negotiable invariants

| Invariant | Enforcement point |
|---|---|
| Snapshot capture does not mutate source HEAD, refs, index, stash, config, hooks, files, or worktree registrations | Source adapter and integration fixtures |
| A plan cannot authorize a changed source state | Start-time token revalidation |
| Complete admitted source is independent of allowed output paths | Snapshot builder and sandbox policy |
| At most one writer owns a workspace | Durable lease and control epoch |
| Finalization starts only after the delegated writer is proven stopped | Runtime quiescence barrier |
| Terminal success has a verified result or explicit no-change marker | Session finalization gate |
| No workspace with uncaptured work is deleted | Cleanup preconditions |
| Apply, merge, push, and branch creation never follow implicitly from session success | CLI authority checks |
| Unexpected output is retained as evidence, not hidden | Result finalization and quarantine |

### Failure and recovery contract

| Failure | Required outcome |
|---|---|
| Source changes during capture | Reject or retry once; do not admit a mixed snapshot |
| Crash while creating a private copy | Reconcile `creating`; remove only a validated incomplete managed path |
| Finalization or artifact persistence fails | Preserve workspace and enter `quarantined` or recoverable failure |
| Result violates allowed paths | Preserve complete evidence, report policy failure, block apply |
| Review-worktree apply conflicts | Leave the source worktree unchanged and retain the review worktree |
| Explicit direct apply is interrupted | Mark `needs_reconciliation`; show journal and recovery commands |
| Cleanup observes path or identity drift | Refuse deletion and quarantine the record |

### Durable operation and idempotency protocol

Every operation that creates, mutates, applies, reconciles, or deletes durable
state uses the same write-ahead protocol:

1. Persist an operation record containing its operation ID, caller-supplied
   idempotency key, kind, target identities, expected revisions, intent digest,
   and initial phase before the first side effect.
2. Perform one bounded side effect against canonical validated paths and record
   its evidence before advancing to the next phase.
3. Write artifacts to a temporary file on the destination filesystem, set
   owner-only permissions, flush the file, atomically rename it, flush the
   containing directory where supported, and then publish its durable reference.
4. Mark the operation complete only after postconditions and digests pass.
5. On restart, resume an idempotent step, compensate when that is proven safe,
   or enter `needs_reconciliation`. Never infer completion from a directory or
   artifact existing by itself.

The same idempotency key with the same intent returns the original operation and
result. Reuse with different intent is a conflict. Retried `session start`,
`session apply`, `workspace clean`, and `workspace reconcile` requests must not
create duplicate sessions, workspaces, worktrees, or writes. Operation records
outlive the maximum client retry window and are included in audit output.

## Proposed CLI Contract

### Consistent global behavior

Support these options consistently where they apply:

```text
--format human|json
--no-color
--quiet
--verbose
--profile <name>
--repo <path>
--yes
```

Rules:

- Accept a task file positionally for `task validate`, `session plan`, and
  `session start`. Keep `--task-file` as a compatible spelling during a
  deprecation window.
- Discover the repository root from the task file or current directory, then
  print the selected root in plan output.
- Treat a plan as inspectable intent, not reserved authority. `session start`
  re-resolves repository identity and the source token before capture; a saved
  plan must also match its `plan_digest`.
- Generate an idempotency key for every mutating request and print it in verbose
  and JSON output. Accept an explicit `--request-id` for scripts. A connection
  timeout should tell the developer how to look up or safely retry that request,
  not suggest starting a second session blindly.
- Let commands accept a full ID or an unambiguous prefix. Reject zero or
  multiple matches and list the candidates.
- Use a common error envelope with `reason`, `message`, `context`, and
  `remediation` fields.
- Map new repository, workspace, conflict, policy, timeout, unavailable, and
  internal errors through the existing `Twelvgaige.CLI.ExitCode` contract.
  Scripts must not need to parse prose or receive a generic exit code because a
  new reason was forgotten.
- Print destructive impact before asking for confirmation. `--yes` confirms the
  displayed operation; it does not expand authority.
- Commands that can mutate Git or delete a workspace default to a preview.
  `--write` performs the displayed action; `--yes` only suppresses the
  confirmation. Do not mix `--apply`, `--write`, and `--dry-run` spellings for
  the same authority transition.
- Keep stdout for results and stderr for progress and diagnostics so JSON output
  remains pipe-safe.

### Repository commands

```bash
twelvgaige repo inspect [path]
twelvgaige repo status [path]
```

`repo inspect` reports:

- canonical root and Git common directory;
- current branch or detached state;
- HEAD and proposed base commit;
- clean, staged, unstaged, untracked, and ignored counts;
- linked worktrees;
- submodules, Git LFS, sparse checkout, shallow history, and object format;
- source modes that are safe for this repository;
- warnings and exact remediation commands.

`repo status` is the compact script-friendly subset.

### Repository context and selectors

Repository selection must be deterministic and visible. Use this precedence:

1. explicit `--repo`;
2. repository declared in a structured task file, resolved relative to that
   file;
3. nearest Git root containing the task file;
4. nearest Git root containing the current directory.

If no candidate exists, fail before daemon discovery. If explicit inputs point
to different repositories, show both canonical paths and require the developer
to resolve the conflict. Never choose based on the daemon's working directory.

Session and workspace lists default to the selected repository, with
`--all-repos` as an explicit expansion. Add `--last` for commands where a single
session is required; it means the newest matching session in the selected
repository and profile, not the newest global record. Do not add fuzzy names or
implicit branch matching. Human output always prints the resolved full ID, and
JSON includes both the selector and resolved identity.

Task-relative paths such as allowed paths and artifact inputs resolve against
the selected repository, not the caller's current directory. Plan output shows
their normalized repository-relative form and rejects traversal before
contacting the daemon.

### Workspace commands

```bash
twelvgaige workspace list [--status reviewable]
twelvgaige workspace show <workspace-id>
twelvgaige workspace path <workspace-id>
twelvgaige workspace status <workspace-id>
twelvgaige workspace diff <workspace-id> [--stat|--name-only]
twelvgaige workspace export <workspace-id> --output <directory>
twelvgaige workspace retain <workspace-id> --for 7d
twelvgaige workspace clean <workspace-id> [--write --yes]
twelvgaige workspace reconcile [--write --yes]
```

For a reviewable or retained workspace, `workspace path` prints one path and no
decoration, making this usable:

```bash
cd "$(twelvgaige workspace path <workspace-id>)"
```

It refuses a running unattended workspace. Same-user filesystem permissions
cannot make a printed local path read-only, so the active-session interface is
`workspace show/status/diff`. A future debugging escape hatch requires a
separate design for audit, result invalidation, and takeover.

`workspace clean` refuses active, leased, unfinalized, dirty-but-uncaptured, or
quarantined workspaces. The destructive form requires `--write --yes` or an
interactive confirmation. It reports whether a retained patch or bundle can
recover the work.

### Session output

`session start` should return:

```text
Session:       sess_...
Plan:          mgr_...
Workspace:     ws_...
Source:        /path/to/repo @ <base-commit> (committed)
Sandbox:       podman / coding_restricted:podman
Write paths:   lib, test
Status:        running
Next:          twelvgaige session watch sess_...
```

On completion:

```text
Status:        reviewable
Result:        4 files changed, 2 tests passed
Patch:         artifact_... (sha256:...)
Workspace:     ws_... retained until 2026-08-17T...
Review:        twelvgaige session review sess_...
Dry-run apply: twelvgaige session apply sess_... --check
```

`session review` should lead with the outcome, verification, changed files, and
open questions. Provider events and low-level lifecycle data remain available
under `--verbose` or JSON.

### Shell completion

Add generated completion for `zsh`, `bash`, and `fish`:

```bash
twelvgaige completion zsh
twelvgaige completion bash
twelvgaige completion fish
```

Complete command names, flags, profile names, task files, session IDs, workspace
IDs, and safe enum values. Completion must not contact providers or expose
credential material.

## Git Safety Contract

All Twelvgaige-owned Git commands should run through one typed adapter with:

- argument arrays rather than shell strings;
- a pinned minimum supported Git version;
- bounded output and timeout;
- `LC_ALL=C` for parseable output where porcelain v2 or `-z` is unavailable;
- repository and workspace path validation before every mutating command;
- `core.hooksPath` disabled for managed workspaces;
- no inherited credential helper for local snapshot operations;
- no global or system Git configuration writes;
- no automatic stash, reset, clean, checkout of the source worktree, branch
  deletion, merge, rebase, push, or force-push;
- structured redaction for URLs and command failures;
- an audit event for every workspace-mutating Git operation.

Expose two capability-scoped interfaces over that adapter:

- `SourceRead` may inspect and copy from the developer repository but has no
  mutating operations.
- `ManagedWorkspace` may mutate only a canonical registered workspace and must
  match its durable identity and lease.

The raw command runner is private to the adapter. The public interfaces are
separate modules or opaque capabilities whose exported functions make the
authority difference mechanically reviewable. Tests must prove that source
callers cannot obtain a mutating operation and that a stale lease, control
epoch, path identity, or workspace identity is rejected before Git starts.

Source reads use a neutral environment: `GIT_OPTIONAL_LOCKS=0`, no pager,
editor, terminal prompt, credential helper, hooks, automatic maintenance, or
garbage collection; `core.fsmonitor` is disabled. Do not inherit repository
filters or external diff commands during capture. Use an isolated Git config
and application data directory while passing only reviewed settings needed for
object-format compatibility.

Private copies must not use hardlinks, alternates, or reference repositories.
They must remain readable after the source repository is removed. Every command
has an operation-specific timeout and output limit; exceeding either produces a
typed error without including secrets or unbounded process output.

Snapshot reads do not take a long-lived source lock. They prove stability with
the pre/post source token. Operations that add or remove managed review
worktrees use a repository-scoped lock keyed by the validated common directory.
Twelvgaige may diagnose an existing Git lock but never deletes it automatically
or waits indefinitely.

Prefer porcelain v2 with NUL-delimited paths. Do not parse human-oriented Git
output. Treat filenames as arbitrary bytes where the platform permits and never
construct paths by splitting on whitespace.

## Repository Compatibility

The first supported contract should cover ordinary non-bare SHA-1 repositories
with:

- clean or explicitly captured dirty state;
- branches or detached HEAD;
- renames, binary files, executable modes, and deletions;
- nested directories and multiple linked worktrees.

Admit these only after explicit detection and tests:

- submodules;
- Git LFS;
- sparse checkout;
- shallow or partial clones;
- case-colliding paths;
- repositories with symlinks;
- bare repositories;
- nested repositories.

Unsupported repository features should fail during `repo inspect` or `session
plan`, before workspace allocation.

### Initial qualified release slice

The first shippable slice is intentionally smaller than the full compatibility
target:

- local, non-bare SHA-1 repository;
- clean `committed` source mode;
- private `copy_snapshot` execution only;
- no submodules, Git LFS, sparse checkout, shallow/partial clone, nested
  repository, or custom content filters;
- complete result capture for commits, staged/unstaged changes, admitted
  untracked files, binary files, renames, deletions, executable modes, and
  qualified symlinks;
- durable workspace recovery plus export and human review;
- no direct application into the developer's current worktree.

This slice is useful on its own and creates the fixtures needed to add staged
and working-tree inputs safely. A feature is advertised only after its admission
check, fixture, sandbox test, result round trip, and recovery path all pass.

## Phased Delivery

```text
Phase 0: result correctness
    ↓
Phase 1: repository preflight and source capture
    ↓
Phase 2: durable workspace lifecycle
    ↓
Phase 3: developer-facing CLI
    ↓
Phase 4: export and review worktrees
    ↓
Phase 5: explicit direct apply
    ↓
Phase 6: compatibility and polish
```

Phase numbering expresses dependency, not a requirement to hide finished work.
Read-only CLI commands may land as soon as their durable schema exists, but no
command may expose a state that restart cannot recover. Each subphase begins
with failing fixtures and ends with a schema, migration path, operator-facing
error, and end-to-end recovery test. A later phase cannot compensate for a
missing earlier integrity gate.

### Implementation seams

Keep the change localized around existing ownership boundaries:

| Area | Primary implementation seam | Planned responsibility |
|---|---|---|
| Git execution | `Twelvgaige.Workspace.Git` | Typed `SourceRead` and `ManagedWorkspace` operations, neutral environment, parsing, limits |
| Workspace lifecycle | `Twelvgaige.Workspace.Manager` | Durable operations, idempotency, state transitions, leases, reconciliation, finalization, cleanup |
| Session terminal paths | `Twelvgaige.Manager.Executor` | Stop and prove writer quiescence, invoke capture for every terminal outcome, and gate success |
| Session planning/start | `Twelvgaige.Manager.SessionStart` | Repository inspection, source token, plan digest, start-time revalidation |
| CLI | `Twelvgaige.CLI.Dispatcher`, `Twelvgaige.CLI.Usage`, command modules | Consistent grammar, human output, JSON envelopes, remediation, completion |
| Artifacts and persistence | Artifact store and durable store migrations | Canonical manifests and digests, patch/bundle references, operation records, workspace records, apply journals |

CLI command modules must not invoke raw Git or infer workspace state from the
filesystem. They request typed operations from the owning service and render
the returned contract.

### Phase 0 — Correct result capture

Objective: ensure current sessions cannot lose committed or untracked work.

Work:

- **0A — Contract and red fixtures:** define `ResultManifest.v1`, distinguish
  source base from workspace baseline, define canonical digest vectors and the
  independent outcome dimensions, and add tests demonstrating loss of committed
  and untracked agent work.
- **0B — Tree capture:** build the result through a temporary index, include all
  admitted result forms, verify a binary-safe patch in a fresh checkout, and
  run repository tests only in a separate credential-free sandbox.
- **0C — Lifecycle gate:** connect capture to success, failure, cancellation,
  timeout, and repair exhaustion; stop and prove the delegated writer is gone;
  persist the manifest before terminal success; and quarantine unrecoverable
  finalization.

Exit criteria:

- Agent-created commits appear in the handoff.
- An untracked file appears in the patch and manifest when policy admits it.
- Applying the artifact to a fresh checkout of the recorded base reproduces the
  exact result-tree digest.
- Cancellation and failure retain recoverable partial work.
- Finalization cannot overlap an active delegated writer.
- Integrity verification and test verification are reported independently.
- No completion path reports success without either a verified result artifact
  or an explicit no-change result.

### Phase 1 — Repository preflight and source capture

Objective: make the session input explicit and reproducible.

Work:

- **1A — Inspection and committed capture:** add `repo inspect`, the source-read
  adapter, stable source tokens, and private ancestry-preserving snapshots.
- **1B — Dirty overlays:** add `staged` and `working-tree` modes through a
  temporary index and bounded explicit overlay capture.
- Capture overlays without changing source index, files, stash, config, refs,
  worktree registrations, or background maintenance state.
- Separate full repository materialization from write-path policy.
- Replace synthetic snapshot history with a private ancestry-preserving Git
  repository.
- Record input manifests and digests.
- Encode manifests with the canonical path and digest contract and prove them
  against golden vectors.
- Detect unsupported Git features before admission.
- Revalidate saved and just-in-time plans at session start.

Exit criteria:

- A dirty repository never enters a committed-only session silently.
- Source capture leaves source Git status byte-for-byte equivalent before and
  after planning and workspace creation.
- Two captures of the same commit and overlay produce the same input digest.
- A restricted write-path session can still build using read-only files outside
  those paths.
- A plan/start source race fails with `source_changed`, never a mixed input.

### Phase 2 — Durable workspace lifecycle

Objective: make every workspace inspectable and recoverable after restart.

Work:

- Persist individual workspace records and transitions.
- Add the write-ahead operation and idempotency protocol for creation,
  finalization, reconciliation, application, and cleanup.
- Recover writer leases and reconcile directories after manager restart.
- Add capture, retention, quarantine, and cleanup states.
- Bind workspaces to session, source, sandbox, policy, and artifact identity.
- Add bounded retention and disk-usage accounting.
- Reserve execution, result, and verification capacity before admission and
  retain protected finalization capacity under disk pressure.
- Create managed paths and artifacts with owner-only, symlink-safe handling.
- Make cleanup exact-target, dry-run-first, and artifact-aware.
- Add a durable `needs_reconciliation` disposition for interrupted mutations.
- Bind every managed Git mutation audit event to the durable operation,
  request ID, workspace identity, lease, and control epoch, and persist its
  terminal evidence before reporting operation completion.
- Define and execute the enumerated lifecycle fault matrix rather than relying
  on representative interruption tests.

Exit criteria:

- Restart preserves workspace and writer identity.
- Missing or drifted state quarantines instead of recreating or deleting work.
- Cleanup cannot remove an active or uncaptured workspace.
- Every deleted workspace has a durable deletion event and recovery statement.
- Killing the daemon after any recorded side effect resumes safely or produces
  an actionable `needs_reconciliation` state.
- Insufficient disk is rejected before execution, not discovered after work is
  ready to capture.

### Phase 3 — Developer-facing CLI

Objective: expose the lifecycle without requiring internal knowledge.

Work:

- Add positional task-file support.
- Add `workspace list/show/path/status/diff`.
- Improve `session start`, `show`, `watch`, and `review` output.
- Add unambiguous ID prefixes.
- Add repository-scoped lists and `--last` resolution.
- Make task, repository, and relative-path precedence visible in plan output.
- Add structured remediation to errors.
- Add request IDs and retry-safe status lookup for mutating commands.
- Make `session plan` and `session start` share one typed resolver. Emit the
  plan digest, source token, and a copyable start command, and name the exact
  drift when start rejects a saved plan.
- Add operation lookup by request ID as the durable recovery entry point after
  timeout, interruption, daemon restart, or terminal loss.
- Display agent, capture, integrity, test, policy, and workspace outcomes
  without collapsing them into one status.
- Standardize global flags, stdout/stderr behavior, color, quiet, and verbose
  modes.
- Standardize successful and failed JSON output on one versioned top-level
  envelope, with a versioned terminal record for NDJSON streams.
- Establish one typed command specification and validate parser behavior, help,
  completion, examples, mutability, and output contracts against it.
- Implement and display the fixed configuration precedence and per-setting
  provenance without exposing credential values.
- Keep locally answerable read-only commands daemon-independent and make daemon
  requirements explicit for stateful commands.
- Standardize client timeout, first-interrupt cancellation, second-interrupt
  detachment, TTY, locale, and pager behavior.
- Add an explicit alias and deprecation registry with removal versions; reject
  implicit command and flag abbreviations.
- Add zsh, bash, and fish completion.

Exit criteria:

- A new developer can initialize, plan, start, watch, review, and locate a
  workspace from CLI help alone.
- Every common Git or workspace rejection includes a safe next command.
- JSON schemas remain backward compatible or have an explicit version change.
- Every JSON-producing command passes shared-envelope golden tests; scripts do
  not need command-specific logic to find disposition, result, or error data.
- Retrying a timed-out mutating command with the same request ID returns the
  original operation and never duplicates its side effects.
- Completion performs no network or credential operations.
- Help, completion, and parser fixtures agree on every public command, option,
  conflict, default, and authority transition.
- The same invocation resolves the same effective plan regardless of current
  directory, locale, terminal width, or TTY state once its repository and
  configuration inputs are fixed.
- A missing daemon cannot turn a read-only command into a mutation, and a
  stateful command reports how to start or inspect the daemon without silently
  starting it.
- Client timeout and both interrupt paths retain a request ID and a truthful
  operation disposition.
- A public-command fixture proves plan/start resolution parity and rejects each
  independently changed material setting with field-specific drift output.
- Human and JSON fixtures prove that repository, profile, request, operation,
  session, and workspace identities are present whenever the command has
  resolved them.

### Phase 4 — Export and managed review worktrees

Objective: make completed work easy to export and inspect without modifying the
developer's current worktree.

Work:

- Add `session export` and `workspace export`.
- Add `session apply --check` and guarded `--write --yes`.
- Reuse digest-bound patch verification where possible.
- Verify target repository identity, base, current dirtiness, paths, patch
  digest, and result-tree digest.
- Apply to a new managed review worktree by default, isolating conflicts from
  the developer's current worktree.
- Detect common-directory and linked-worktree conflicts, create detached review
  worktrees, and label the shared-metadata boundary.
- Derive internal refs, temporary paths, and optional generated branch names
  from durable workspace identity; create them exclusively and reject an
  existing target that is not owned by the same operation.
- Add exact-target cleanup, dirty-state refusal, and stale-registration
  reconciliation under a repository-scoped lock.
- Record the human-authorized apply operation.

Exit criteria:

- Dry-run apply never changes the target.
- Default write apply either produces a verified review worktree or leaves the
  source worktree unchanged.
- A dirty or drifted target is rejected with recovery instructions.
- Creating and removing a managed review worktree does not change source HEAD,
  index, files, stash, branches, or remotes.
- Dirty uncaptured review edits prevent cleanup.
- No command merges or pushes automatically.
- Task text and the developer's current branch cannot cause an internal ref,
  review path, or generated branch-name collision.

### Phase 5 — Explicit direct application

Objective: optionally apply a verified result to a developer-selected worktree
with honest interruption recovery.

Work:

- Add an explicit `--target current-worktree`; never select it by default.
- Require exact repository identity, expected base/tree, clean target, verified
  artifact digest, allowed paths, and a fresh applicability check.
- Create a recoverable backup and durable operation journal before the first
  write.
- Record each write stage, verify the final tree, and remove the backup only
  after the retention period.
- On interruption or unexpected drift, stop and enter `needs_reconciliation`
  with evidence and exact recovery commands.

Exit criteria:

- Direct apply requires both `--target current-worktree` and `--write`; `--yes`
  only suppresses confirmation.
- A successful apply reproduces the result-tree digest.
- An interrupted apply becomes `needs_reconciliation`; the CLI never claims
  transaction-level atomicity across filesystem or process failure.
- Conflict or drift does not trigger reset, clean, stash, merge, or checkout.
- Recovery is fixture-tested for interruption before, during, and after writes.

### Phase 6 — Compatibility and polish

Objective: broaden Git compatibility only where the safety contract can be
proven.

Work:

- Finish the capability split between source reads and managed Git mutations,
  including compile-time API boundaries and stale-authority tests.
- Complete the mutation-audit coverage map and the lifecycle interruption
  matrix for every durable operation and side-effect boundary.
- Qualify submodules, Git LFS, sparse checkout, shallow clones, SHA-256 objects,
  custom filters, symlinks, and case-sensitive path behavior.
- Improve multi-repository workspace-set commands and review output.
- Add performance budgets for large repositories and binary changes.
- Add disk-pressure warnings and retention suggestions.
- Measure command discoverability and common-path latency.
- Retain minimum-Git, platform, shell-parser, sandbox, and authenticated
  delegated-session evidence, and validate the published support matrix against
  those records.
- Qualify the packaged executable rather than only in-process command modules,
  including signal forwarding, exit-status propagation, non-TTY behavior,
  unusual repository and task paths, and exact temporary-file and child-process
  cleanup.
- Exercise upgrade fixtures from the previous supported persisted schemas and
  provider version.

Exit criteria:

- Each advertised repository feature has fixtures and end-to-end tests.
- Large-repository behavior has measured time, memory, and disk bounds.
- Unsupported features continue to fail before workspace allocation.
- Every fault-matrix case has a retained outcome and no case is silently
  skipped on an advertised platform.
- Every published support claim resolves to retained qualification evidence.
- Every advertised platform passes the packaged-CLI contract; an in-process
  test cannot substitute for launcher, signal, or cleanup evidence.
- Previous-release persisted fixtures can be read, exported, resumed where
  supported, or conservatively reconciled without silent mutation.

## Test Strategy

### Unit and property tests

- Exact Git argument vectors and environment isolation.
- Porcelain-v2 and NUL-delimited status parsing.
- Path traversal, strange filenames, invalid UTF-8 where supported, symlinks,
  and case collisions.
- Source-overlay manifest determinism.
- Canonical manifest golden vectors, raw-byte path ordering, digest domain
  separation, and hash-version migration.
- Source-state and plan-digest stability and drift detection.
- Workspace state-machine transitions and cleanup preconditions.
- Operation-journal replay, idempotency conflicts, and repeated request IDs.
- Result-manifest completeness and policy-violation quarantine.
- Independent agent, capture, integrity, test, policy, and disposition outcomes.
- CLI option precedence, ID prefix resolution, JSON schema, exit codes, and
  remediation text.
- Configuration-precedence tables covering defaults, user and repository
  profiles, task documents, explicit flags, list replacement, and attempted
  authority widening. Golden plan fixtures assert the provenance of each
  material value while proving that secrets are absent.
- Command-model consistency tests that fail when parsing, help, completion,
  examples, mutability metadata, or machine-output declarations disagree.
- TTY and non-TTY output, locale and width independence, stdout/stderr
  separation, unknown-option rejection, and alias/deprecation warnings.
- Missing-daemon behavior for every command family, including proof that local
  read-only commands neither connect to nor start the daemon.
- Client timeout, first interrupt, and second interrupt tests that reconnect by
  request ID and prove no duplicate mutation or false quiescence claim.
- Shared JSON and NDJSON envelope golden vectors for success and every stable
  error class.
- Capability-boundary tests proving `SourceRead` cannot mutate and
  `ManagedWorkspace` rejects stale or mismatched authority before process
  execution.
- Mutation-audit completeness tests that compare the managed Git operation
  registry with emitted intent and terminal event classes.
- Prior-release persisted-record and canonical-digest migration fixtures.

### Real Git integration fixtures

Create disposable repositories that cover:

- clean committed work;
- staged, unstaged, untracked, and ignored files;
- agent commits plus remaining dirty work;
- binary files, renames, deletions, and executable-bit changes;
- detached HEAD and multiple linked worktrees;
- crash during capture, finalization, export, apply, and cleanup;
- daemon termination before and after every durable-operation phase boundary;
- generated fault-matrix coverage that fails when a durable phase or external
  side effect lacks both pre-boundary and post-boundary interruption cases;
- repeated start, apply, clean, and reconcile requests after simulated client
  timeouts;
- attempted finalization while the delegated process tree is still writing;
- runtime termination that cannot prove writer quiescence;
- disk exhaustion before admission and during artifact persistence;
- symlink replacement, hard-link substitution, and permission checks under the
  managed root;
- source repository removal after snapshot creation;
- source mutation between plan, capture start, and capture completion;
- hostile or surprising Git configuration: hooks, credential helpers,
  filesystem monitors, maintenance, filters, external diff, pager, and editor;
- linked-worktree `.git` indirection and a negative container-admission test;
- interrupted direct apply and durable reconciliation;
- patch round-trip into a fresh clone;
- concurrent sessions from one repository and from several repositories.

Tests must compare source HEAD, refs, index bytes, files, config, stash list,
worktree list, and object reachability before and after each operation. Where
filesystem behavior permits, also compare index metadata to catch an accidental
refresh. Tests must prove that a private copy remains usable after its source is
renamed or removed.

### Sandbox and end-to-end tests

- Run the same source and result fixtures through Podman and Apple containers.
- Prove the original repository and Git common directory are not mounted in
  snapshot mode.
- Prove write-path policy prevents changes outside admitted paths even though
  the full source tree is available for reads.
- Prove out-of-policy output is captured as quarantined evidence and cannot be
  applied.
- Prove finalization begins only after the container and its complete process
  tree have stopped.
- Run integrity reconstruction without executing repository code, then run test
  verification in a fresh sandbox without provider credentials.
- Prove that test code cannot read provider credentials or use network access
  beyond the verification policy.
- Cancel and restart during active Git operations, then reconcile safely.
- Export and apply the resulting artifact outside the sandbox.
- Run one real authenticated attached Codex session through each advertised
  sandbox profile using explicitly authorized test credentials and egress; mock
  authentication does not satisfy this release proof.

## Observability and Audit

Add events for:

- repository inspection and selected source mode;
- plan digest, source-state token validation, and drift rejection;
- source capture start, completion, digest, and rejection;
- workspace creation, lease, finalization, quarantine, retention, and deletion;
- Git commands that mutate a managed workspace;
- result-tree capture and artifact verification;
- writer stop request, forced termination, quiescence proof, and lease transfer;
- storage reservation, pressure rejection, and finalization reserve use;
- idempotent request receipt, replay, conflict, and completion;
- integrity verification and test verification as separate outcomes;
- apply dry run, authorization, completion, conflict, and rollback;
- reconciliation entry, recovery action, and resolution.

Metrics should use low-cardinality labels such as transport, source mode,
status, and failure class. Repository paths, session IDs, workspace IDs, commit
IDs, and filenames belong in access-controlled events, not metric labels.

## Migration and Compatibility

- Keep existing `--task-file`, `--repo`, and `--base-ref` flags while adding
  positional task files and source/workspace options.
- Add schema versions to repository inspection, workspace records, result
  manifests, and apply reports.
- Version canonical encodings and digest algorithms independently. Existing
  digests retain their original interpretation and are never silently
  recalculated under new rules.
- Introduce operation records before moving lifecycle side effects to the new
  protocol. Legacy in-flight state is reconciled conservatively and never
  guessed complete.
- Mark existing synthetic-root snapshots as `legacy_snapshot_v1`. They may be
  inspected and exported but should not be silently reinterpreted as
  ancestry-preserving snapshots.
- Do not automatically clean old workspaces during migration. Reconcile them,
  show their recoverability, and require an explicit cleanup operation.
- Keep current JSON fields where possible; add richer nested objects before
  removing flat fields in a future major CLI version.
- Gate releases with fixtures generated by the previous tagged version. The
  fixture set must cover every supported persistence backend, completed and
  interrupted records, legacy audit-chain migration, and the previous
  canonical-digest contract. Qualification must reopen migrated state and prove
  its recovery disposition after another restart.

## Success Measures

- One command starts a task file from a clean repository.
- Planning identifies dirty or unsupported repository state before allocation.
- Starting revalidates the plan and refuses repository or policy drift.
- Snapshot mode makes zero observable changes to the source repository.
- Every terminal session returns a verified patch, verified bundle, or explicit
  no-change result.
- Every workspace can be found, inspected, exported, retained, or safely
  cleaned by ID.
- Restart and cancellation do not lose captured or uncaptured developer work.
- Finalization never races an active delegated writer.
- Retrying a timed-out mutating request does not duplicate work or Git changes.
- Artifact integrity and test outcomes remain independently visible.
- Admission preserves enough disk to capture or quarantine the result.
- Managed source and result data is owner-only and absent from routine logs.
- Common CLI failures include a safe remediation command.
- Effective configuration is deterministic and every material setting has a
  visible, non-secret provenance.
- Help, completion, examples, and parsing describe the same public command
  surface.
- Read-only local commands work while the daemon is stopped and never start it
  implicitly.
- A timeout or interrupt never causes a duplicate operation or falsely reports
  that delegated work has stopped.
- The default local workflow requires no direct navigation into application
  support directories.
- A containerized session never receives the source repository's common Git
  directory.

## Decision Follow-ups

The first pass now resolves the interface-affecting choices where the safety
contract is proven. Items tied to release environments or measured operating
limits remain open:

1. **Accepted for the first pass:** a dirty repository fails until the developer
   selects `staged` or `working-tree`. Non-interactive execution never guesses.
   A future terminal prompt may present the exact choices but must compile to
   the same explicit request.
2. **Accepted:** `working-tree` does not imply untracked input. The developer
   must pass `--include-untracked`; ignored files additionally require
   `--include-ignored` and are never included by default.
3. **Accepted and implemented:** finalized workspaces and direct-apply backups
   use a seven-day default, independently configurable from 30-day artifacts
   and 90-day audit records. Automatic workspace expiry uses the same durable,
   journaled cleanup path. The retained 178-case lifecycle matrix covers every
   enumerated before-and-after boundary without skipped cases on local macOS.
4. **Accepted and implemented:** never rewrite agent commits automatically. The
   verified base-to-result patch remains authoritative for the result tree.
   When the delegated session creates commits after the workspace baseline, a
   self-contained, size-bounded Git bundle preserves that commit series. The
   bundle is verified before persistence, digest-bound in `ResultManifest.v2`,
   and exported for human review; it is never merged automatically.
5. **Accepted, Linux qualification pending:** require Git 2.39.0 and
   porcelain v2 with no human-output parsing fallback. Repository inspection
   rejects older versions before reading source state. A checksum-pinned source
   build passes the selected workspace and CLI fixture suite plus the large-repo
   qualification on macOS arm64. CI runs the identical build on Linux; its
   retained evidence must pass before release.
6. **Accepted:** multi-repository workspace sets remain explicit. No task is
   silently expanded into a multi-repository operation.
7. **Accepted and published:** keep the contracts platform-neutral and publish
   `qualification/platform-matrix.json` for CLI, Git workspace, and sandbox
   support. The matrix distinguishes local evidence, retained CI evidence,
   opt-in support, pending qualification, and features that are not advertised.
8. **Accepted for the first release:** file-count, per-file, patch, and
   aggregate-byte limits are enforced. The large-repository gate adds explicit
   time, memory, and disk-amplification ceilings and has deterministic threshold
   tests plus real Git evidence. An override remains an unsupported user choice
   and cannot alter the published support matrix.
9. **Accepted:** all non-streaming machine output converges on one versioned
   top-level result envelope; NDJSON uses the corresponding versioned event and
   terminal-record contract. Adoption preserves current payload semantics under
   the nested result object and uses an explicit version transition rather than
   silently changing existing script behavior.
10. **Accepted:** the source/managed Git authority split is enforced by public
    API shape. The raw runner remains private, and managed mutation requires
    durable workspace identity plus a live lease and control epoch.
11. **Accepted:** managed Git mutation audit is complete at the command boundary,
    not inferred only from a surrounding workspace operation. Intent and
    terminal evidence are both durable and use sanitized operation classes.
12. **Accepted:** release qualification uses an enumerated lifecycle fault
    matrix with termination before and after every durable phase and external
    side effect. A missing case fails qualification.
13. **Accepted:** support claims are evidence-derived. Workflow configuration,
    a newer Git run, or a mock sandbox/provider test cannot substitute for the
    named minimum-version, platform, backend, shell, or authenticated-path
    evidence.
14. **Accepted and implemented:** the previous supported release is a migration
    fixture. Tagged `v0.0.3` SQLite and file-store artifacts prove that completed
    records remain readable and an unresolved write is conservatively
    reconciled. A fixed result-manifest v1 vector preserves its digest meaning.
    The gate is configured on macOS and Linux CI; retained passing evidence is
    required before release.
15. **Accepted:** invocation is deterministic. Built-in defaults, user profile,
    repository profile, task document, and explicit CLI flags form one fixed
    precedence order. Plans report non-secret value provenance, list merging
    cannot widen authority, and environment variables do not silently replace
    task or CLI policy.
16. **Accepted:** CLI discovery has no hidden control-plane side effects. Local
    read-only commands do not start the daemon; stateful commands report an
    unavailable daemon with an exact remediation command. Client timeouts and
    interrupts preserve the request identity and distinguish cancellation from
    detachment.
17. **Accepted:** the public command model is singular and testable. Parser,
    help, completion, examples, mutability metadata, and machine-output
    contracts must agree. Unknown abbreviations fail, while intentional aliases
    have a documented deprecation and removal version.

## First Iteration

Start with Phase 0A through 0C and Phase 1A only:

1. Add real Git fixtures that prove the current committed-change and untracked
   file loss.
2. Define all five versioned contracts, the workspace state transitions, and
   typed failure classes before freezing CLI JSON. Include canonical digest
   vectors and independent outcome fields.
3. Add durable operation records and request-id idempotency before creating new
   workspace mutation paths.
4. Implement the runtime quiescence barrier, base-to-result-tree capture, and
   patch round-trip verification.
5. Run test verification separately in a credential-free sandbox.
6. Connect finalization to every normal and abnormal session lifecycle path.
7. Add storage reservation, owner-only managed paths, and symlink-safe artifact
   publication.
8. Add `repo inspect` as a read-only command using the new Git adapter.
9. Add start-time source-token revalidation and the plan/capture race fixture.
10. Qualify the initial release slice before enabling staged or working-tree
   input.

This sequence fixes result integrity before adding convenience commands that
would otherwise make an incomplete workspace model easier to invoke.
