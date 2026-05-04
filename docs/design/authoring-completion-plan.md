# Authoring Completion Plan

This plan tracks the remaining authoring-management work after the first
conservative implementation of `shell graph`, `shell lint`, `shell new`,
`shell draft`, `shell review`, `shell approve`, `shot add`, `shot rename`,
`shot move`, `shot remove`, `shot library`, inventory, impact, doctor, format,
and Mermaid graph output.

The goal is to finish the higher-risk authoring surface without weakening the
runtime model. Runtime shells must still compile to ordinary deterministic
workflows. Authoring helpers may generate, inspect, or rewrite shell files, but
they must not create hidden runtime imports, implicit provider calls, or
unreviewed file mutation.

## Principles

- Keep authoring separate from execution. Generated or rewritten shells are
  still parsed, validated, linted, and admitted through the same runtime path.
- Keep mutation explicit. Commands dry-run by default, print stable diffs, and
  require `--write` for file changes.
- Keep dangerous edits bounded. Bulk changes require root resolution,
  no-cross-root checks, precise impact summaries, and deterministic output.
- Keep provider use explicit. Hosted LLM authoring requires `--allow-remote`
  and a disclosure of provider, model, source paths, byte counts, and redaction.
- Keep local developer ergonomics strong. All phases must work without a daemon
  unless the feature explicitly needs a running round.
- Keep tests as the implementation contract. Every phase needs unit tests for
  pure rewrite logic, CLI tests for dry-run/write behavior, and integration
  tests only where real filesystem or runtime interaction is required.

## Current State

Implemented:

- Graph inspection with text, JSON, and Mermaid output.
- Workflow and contextual lint.
- Built-in scaffolds with provenance metadata.
- Review, approval, deprecation, retirement, and admission checks.
- Inventory and impact reports.
- Read-only agent-assisted authoring rounds with patch-plan artifacts.
- Conservative shot refactors: add, template add, rename, move, remove.
- Shot-template libraries, lockfiles, verification, update, and outdated
  reports.
- Initial `shell draft` with mock/local/hosted-provider consent.

Remaining:

- Dedicated write-capable `patch_apply` RFC and implementation.
- Broader scaffold library discovery, provenance, lockfiles, and drift reports.
- Hosted-provider authoring rounds beyond one-shot `shell draft`.
- Advanced refactors: split, merge, gate extraction, replace agent, replace
  tool, schema set, and bulk metadata.
- Condition parser and AST-backed condition rewrites.
- Collection-scale maintenance and CI polish around the above features.

## Phase Dependencies

```text
AC0 patch-apply RFC
  -> AC1 condition parser
      -> AC2 advanced single-shell refactors
          -> AC3 collection-scale refactors
  -> AC4 scaffold libraries and locks
      -> AC5 hosted authoring rounds
          -> AC6 controlled patch application
              -> AC7 CI, docs, and release hardening
```

`AC0` is design-only but required before any write-capable agent patching.
`AC1` unblocks safe condition rewrites. `AC2` and `AC3` expand manual
authoring. `AC4` finishes reusable source management. `AC5` lets agents propose
larger changes with hosted providers. `AC6` is the first phase that may apply
agent-produced patches. `AC7` makes the full surface maintainable in real
repositories.

## Phase AC0 - Patch Apply RFC

Status: complete. The RFC lives in `docs/design/patch-apply-rfc.md`.

Purpose: define the write-capable patch application model before implementing
any agent-driven file mutation.

Scope:

- Add `docs/design/patch-apply-rfc.md`.
- Define patch artifact format:
  - target root
  - allowed paths
  - original file digests
  - proposed file digests
  - unified diff or structured replacement records
  - generated-by metadata
  - validation commands to rerun after apply
- Define approval binding:
  - patch hash
  - approver
  - approval scope
  - expiration
  - evidence hash
- Define command shape:
  - `shell patch inspect <patch-file>`
  - `shell patch verify <patch-file>`
  - `shell patch apply <patch-file> --write --approval <approval-id>`
- Define refusal rules:
  - path outside root
  - symlink traversal
  - original digest mismatch
  - missing approval
  - expired approval
  - generated patch modifies unknown file type
  - post-apply validation or lint fails
- Define audit events for patch inspection, approval, apply, and failure.

Acceptance:

- RFC is reviewed before implementation.
- RFC includes threat model and failure modes.
- No write-capable agent patch command is implemented before this phase is
  accepted.
- Test plan is explicit enough to implement without revisiting the design.

## Phase AC1 - Condition Parser And AST Rewrites

Status: complete for the current grammar. The implementation extends
`Twelvgaige.Pattern.Condition` with deterministic rendering, reference
extraction, and authoring-only `steps.` alias normalization instead of creating
a second parser.

Purpose: safely support refactors when conditions reference shot outputs.

Scope:

- Extend the runtime condition parser for authoring use instead of creating a
  divergent `Twelvgaige.Shell.Condition` grammar.
- Parse condition strings into an AST with source-free normalized rendering.
- Support references such as:
  - `shots.analyze_root_cause.output.requires_human_approval`
  - `steps.analyze_root_cause.requires_human_approval`
  - bracket equivalents if already supported by examples/spec.
- Reject arbitrary code execution and unknown syntax.
- Add reference extraction:
  - referenced shot IDs
  - referenced output paths
- Add rewrite helpers:
  - rename shot references
  - detect references to removed shots
- Done: update `shot rename` to rewrite supported conditions instead of
  refusing.
- Keep `shot remove` conservative: refuse unless removed references are also
  removed by the edit or cascade plan.

Acceptance:

- Parser round-trips supported conditions deterministically.
- Unsupported condition syntax returns a clear lint/refactor error.
- `shot rename` updates dependency edges and condition references together.
- Existing refusal behavior remains for unsupported syntax.
- Tests cover YAML, JSON, and TOML workflows.

## Phase AC2 - Advanced Single-Shell Refactors

Status: complete. `shot gate`, `shot split`, `shot merge`, `shot schema set`,
`shot replace-agent`, and `shot replace-tool` are implemented as conservative
single-shell refactors.

Purpose: add the high-value manual refactors that operate on one workflow file.

Commands:

- `shot gate <shell> <target-shot-id> --id <gate-id> [--before|--after]`
- `shot split <shell> <shot-id> --into <id,id,...>`
- `shot merge <shell> <shot-id> <shot-id> [more...] --id <new-id>`
- `shot replace-agent <shell> <old-agent> <new-agent>`
- `shot replace-tool <shell> <old-tool> <new-tool>`
- `shot schema set <shell> <shot-id> <schema-file>`

Shared behavior:

- Dry-run by default.
- `--write` required for mutation.
- Atomic writes.
- Canonical diff output.
- Validation after rewrite.
- Strict lint after rewrite unless `--no-lint` is explicitly added later.
- JSON output includes changed shots, changed edges, safety implications, and
  validation/lint status.

Feature details:

- Done: `shot gate` inserts an unconditional safety shot before a target,
  moves the target's previous dependencies onto the gate, and rewires the
  target to depend on the gate.
- Done: `shot split` creates chained draft child shots, moves dependents to the
  final child, preserves original dependencies on the first child, rewrites
  supported condition references, and requires contextual lint before output or
  write.
- Done: `shot merge` replaces a linear chain of same-agent slug shots with one
  draft merged shot, unions tools, preserves upstream dependencies, rewires
  downstream dependencies and supported condition references, and requires
  contextual lint before output or write. Explicit override support is deferred
  until a safe policy surface exists.
- Done: `shot replace-agent` requires the replacement agent to be discovered
  from the workflow context and requires the candidate workflow to pass
  contextual lint before dry-run output or write.
- Done: `shot replace-tool` rewrites every matching shot tool reference and
  requires the candidate workflow to pass contextual lint, including tool
  registry checks and agent allowlist checks.
- Done: `shot schema set` loads a JSON schema from file, validates the supported
  schema subset, and inserts it into the target shot.

Acceptance:

- Each command has pure rewrite tests and CLI dry-run/write tests.
- Dangerous or ambiguous rewrites fail with actionable messages.
- Safety gate insertion is deterministic and documented.
- Agent/tool replacement never bypasses contextual lint.

## Phase AC3 - Collection-Scale Refactors

Status: complete. Single-file `shell metadata set`, `shell metadata clear`,
`shell bulk replace-agent`, and `shell bulk replace-tool` are implemented.

Purpose: support repository-wide maintenance without hidden mutation.

Commands:

- Done: `shell metadata set <path> --owner <owner>`
- Done: `shell metadata set <path> --lifecycle draft|reviewed|approved|scheduled|deprecated|retired`
- Done: `shell metadata clear <path> --review|--approval`
- Done: `shell bulk replace-agent <path> <old-agent> <new-agent>`
- Done: `shell bulk replace-tool <path> <old-tool> <new-tool>`

Scope:

- Operate on directories inside a resolved traphouse root.
- Reuse inventory to find candidates.
- Print a multi-file plan before any write.
- Require `--write` plus `--yes` for multi-file mutation.
- Skip invalid shells by default and report them; add `--fail-on-invalid` for CI.
- Write each file atomically.
- Produce a machine-readable report under optional `--output`.

Acceptance:

- Dry-run output lists exact files and changes.
- Multi-file writes are deterministic and recoverable file-by-file.
- Failure in one file does not silently corrupt others.
- CI can run collection refactors in dry-run mode and fail if changes are
  needed.

## Phase AC4 - Scaffold Libraries And Lockfiles

Status: complete for the current conservative command surface. Built-in and
repo-local scaffold discovery, `shell scaffold list/show`, `shell new
--scaffold-path`, scaffold lockfile verify/update, and scaffold drift reporting
are implemented. Scaffold and shot-template entries share
`twelvgaige-library.lock` without overwriting each other.

Purpose: finish reusable scaffold source management with the same integrity
story as shot templates.

Scope:

- Add `traphouse/scaffolds/` discovery through explicit `--scaffold-path`.
- Add `shell scaffold list`.
- Add `shell scaffold show <scaffold-id>`.
- Allow `shell new --scaffold <id> --scaffold-path <path>`.
- Add scaffold lockfile entries:
  - scaffold ID
  - version
  - source path
  - digest
  - generated files policy
- Add `shell scaffold verify`.
- Add `shell scaffold update --write-lock`.
- Add scaffold drift reporting for generated workflows when source metadata is
  present.

Acceptance:

- Built-in scaffolds continue to work offline.
- Repo-local scaffolds require explicit path or root-local opt-in.
- Lockfile mismatches fail verification.
- Generated workflows record scaffold source metadata and digest.
- Scaffold update has dry-run diff and explicit `--write-lock`.

## Phase AC5 - Hosted Authoring Rounds

Status: complete for the current read-only command surface. `shell author
review <path>` can use mock, local Ollama, or hosted providers with explicit
`--allow-remote` consent. It emits a disclosure and deterministic patch plan to
stdout and never writes files.

Purpose: expand from one-shot `shell draft` to controlled agent-assisted
authoring workflows with hosted providers.

Scope:

- Add explicit authoring round command or documented workflow pattern:
  - Done: `shell author review <path>`
  - `shell author draft --from <file>`
  - or preserve current workflow-round model and add example hosted loadouts.
- Require `--allow-remote` for hosted providers.
- Print disclosure before remote provider use:
  - provider
  - model
  - source paths
  - byte count before/after redaction
  - tools exposed to the authoring agents
  - output files, if any
- Done: Extend authoring review to produce structured patch plans with patch
  hashes.
- Done: Keep hosted authoring read-only until AC6.

Acceptance:

- Done: Hosted authoring cannot run without explicit remote consent.
- Done: Redaction summary is visible in human and JSON output.
- Done: Patch plans are deterministic JSON artifacts.
- Done: No hosted authoring command writes files in this phase.

## Phase AC6 - Controlled Patch Application

Status: complete for the current controlled replacement surface:
`shell patch inspect` and `shell patch verify` parse JSON patch artifacts,
compute canonical patch digests, verify path/kind policy, check current file
digests and candidate content digests, validate approval files when supplied,
and run candidate validation/lint preflight. `shell patch apply` exists as a
dry-run rehearsal that runs verification and reports `changed: false`.
`shell patch apply --write` requires a matching human approval, uses sibling
temp files plus atomic replacement, verifies each final target digest, reruns
declared safe validation commands, and includes local audit events plus a
tamper-evident checkpoint in the apply report.

Purpose: implement write-capable patch application using the accepted RFC.

Scope:

- Done: Implement patch artifact validation.
- Done: Implement patch approval binding for verify.
- Done: Implement `shell patch inspect`.
- Done: Implement `shell patch verify`.
- Done: Implement read-only `shell patch apply` dry run.
- Done: Implement `shell patch apply --write`.
- Done: Apply only inside resolved traphouse roots.
- Done: Use sibling temp files and atomic replacement.
- Done: Verify original digests before write.
- Done: Verify candidate digests after write.
- Done: Run validation, strict lint, and optional command hooks after write.
- Done: Emit local audit/checkpoint events in apply reports.

Acceptance:

- Patch application refuses stale file contents.
- Patch application refuses missing or stale approval.
- Symlink and path traversal tests pass.
- Post-apply validation failure leaves original files intact where feasible, or
  writes a clear partial-failure report if a multi-file apply cannot be rolled
  back safely.
- Agent-generated patches are never applied without human approval.

## Phase AC7 - CI, Docs, And Release Hardening

Status: complete for the current release-hardening surface. The Makefile now
has `authoring-check`, `authoring-drift`, and `authoring-docs`; CI has a
dedicated authoring job; focused docs live in `docs/authoring.md`,
`docs/scaffolds.md`, and `docs/patches.md`.

Purpose: make the completed authoring surface usable in real repositories.

Scope:

- Done: Add Makefile targets:
  - `make authoring-check`
  - `make authoring-drift`
  - `make authoring-docs`
- Done: Add GitHub workflow jobs for:
  - shell lint strict
  - inventory report
  - library verify
  - scaffold verify
  - patch verify, once AC6 exists
- Done: Update `USAGE.md`.
- Done: Add focused docs under `docs/`:
  - `docs/authoring.md`
  - `docs/scaffolds.md`
  - `docs/patches.md`
- Done: Add examples under `docs/traphouse/` for:
  - scaffold library
  - advanced refactors
  - hosted authoring review
  - patch plan and patch apply dry-run

Acceptance:

- A new developer can scaffold, lint, review, refactor, and verify a traphouse
  using documented commands only.
- CI examples are copy/pasteable.
- All docs use lowercase filenames.
- Release checklist includes authoring checks.

## Tracking Checklist

- [x] AC0 patch apply RFC.
- [x] AC1 condition parser and AST rewrites.
- [x] AC2 advanced single-shell refactors.
- [x] AC3 collection-scale refactors.
- [x] AC4 scaffold libraries and lockfiles.
- [x] AC5 hosted authoring rounds.
- [x] AC6 controlled patch application.
- [x] AC7 CI, docs, and release hardening.

## Suggested Execution Order

Start with AC0. It is the only phase that can prevent a bad security model for
write-capable agent changes. After AC0, AC1 and AC4 can proceed in parallel
because condition parsing and scaffold source management do not overlap much.
AC2 should follow AC1 so refactors can correctly handle conditions. AC5 should
follow AC4 so hosted authoring can reference both shot templates and scaffold
libraries. AC6 must wait for AC0 and AC5. AC7 should run continuously in small
updates, with a final pass after AC6.
