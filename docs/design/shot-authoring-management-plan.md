# Shot Authoring And Management Plan

Twelvgaige workflow shells are intentionally explicit: every shot has a clear
agent, dependencies, tools, chokes, safety requirements, and output shape. That
is good for auditability and production behavior, but it can become tedious to
author and maintain by hand as workflows grow.

This plan designs ergonomic tooling for creating, evolving, reviewing, and
reusing shots without weakening the core rule: generated or assisted authoring
must still compile into the same declarative shell IR and deterministic runtime
semantics.

## Goals

- Make common workflow shells fast to scaffold.
- Make multi-shot workflows easier to grow and refactor over time.
- Keep generated shells reviewable in plain YAML, JSON, or TOML.
- Provide local, no-daemon authoring tools that work on laptops.
- Support LLM-assisted shell generation while treating generated output as
  untrusted until validated.
- Make shot libraries and reusable scaffolds possible without introducing hidden
  runtime behavior.
- Help developers understand the workflow graph, safety gates, tools, and
  provider usage before a round runs.

## Non-Goals

- Do not let an LLM directly mutate a loaded daemon workflow without producing a
  reviewable file diff.
- Do not add runtime macros that change control flow after validation.
- Do not make YAML, JSON, TOML, or future Starlark shells mean different things.
- Do not embed secrets in generated shells.
- Do not replace explicit safety shots with prompt instructions.
- Do not make the daemon depend on a remote model for authoring.
- Do not preserve YAML comments or original hand formatting in the first edit
  implementation; early mutating commands may rewrite canonical documents.
- Do not implement LLM-assisted drafting for sensitive source artifacts until
  input redaction, size limits, and explicit remote-provider consent exist.
- Do not implement libraries or cross-repository discovery until the trust,
  checksum, and provenance model is explicit.
- Do not implement split, merge, or `doctor --apply` before graph, lint, and
  minimal scaffolding prove useful.

## Problem Statement

Current authoring is precise but manual:

- Developers must remember the required shell shape.
- Shot IDs, dependency edges, policies, tools, and output schemas are easy to
  drift.
- Repeated scaffolds such as "inspect -> analyze -> safety -> remediate ->
  verify" are rewritten in each shell.
- Renaming a shot requires careful updates to `depends_on`, conditions, tests,
  docs, and examples.
- The CLI validates shell syntax, but it does not yet help explain, visualize,
  or evolve the shell.
- LLM-assisted generation can be useful, but raw model output needs strict
  validation and review before use.

The design target is a developer workflow closer to:

```bash
twelvgaige shell new k8s-incident --scaffold inspect-analyze-gate-fix-verify
twelvgaige shot add docs/traphouse/workflows/k8s-incident.yaml verify_recovery --after remediate
twelvgaige shell graph docs/traphouse/workflows/k8s-incident.yaml
twelvgaige shell lint docs/traphouse/workflows/k8s-incident.yaml
twelvgaige shell explain docs/traphouse/workflows/k8s-incident.yaml
```

The file remains ordinary shell data. The tooling just makes the boring parts
harder to get wrong.

## Authoring Model

There are four layers:

| Layer | Purpose | Runtime Semantics |
| --- | --- | --- |
| Shell IR | Canonical normalized workflow or agent shell | Yes |
| Scaffolds | Declarative blueprints that expand into shell IR | No, authoring only |
| Shot library | Reusable shot templates and agent/tool presets | No, authoring only |
| Assistants | Optional LLM/local generators that propose shell diffs | No, authoring only |

Only the Shell IR is executed. Scaffolds, libraries, and assistants are
authoring inputs. Their output must pass the same loader, normalization,
compiler, safety, and resource checks as a hand-written shell.

## Proposed CLI Surface

### Scaffold Workflow Shells

```bash
twelvgaige shell new <id> [--scaffold <scaffold-id>] [--output <path>] [--format yaml|json|toml]
twelvgaige shell new k8s-incident --scaffold inspect-analyze-gate-fix-verify --output docs/traphouse/workflows/k8s-incident.yaml
```

Behavior:

- Creates a valid workflow shell with stable IDs and placeholders.
- For runnable local examples, creates or references companion mock agent shells
  under an adjacent `agents/` directory. Workflow shells themselves only
  reference agents; provider configuration lives in agent shells.
- Adds safety shots for write-capable scaffolds.
- Defaults to printing the generated document or diff. File writes require
  `--write`; replacing an existing file additionally requires `--force`.

### Add, Move, Rename, And Remove Shots

```bash
twelvgaige shot add <shell-path> <shot-id> --kind slug --agent <agent-id> [--after <shot-id>]
twelvgaige shot rename <shell-path> <old-id> <new-id>
twelvgaige shot move <shell-path> <shot-id> --after <dependency-id>
twelvgaige shot remove <shell-path> <shot-id>
```

Behavior:

- Maintains `depends_on` references.
- Refuses destructive edits that orphan dependent shots unless `--cascade` is
  supplied.
- Defaults to dry-run/diff output. File writes require `--write` and use atomic
  replacement.
- Canonicalizes the shell document in early phases and may drop YAML comments.
- Runs validation after each edit.
- Emits a summary of changed edges and safety implications.
- Refuses to rename shots referenced by condition strings until condition
  parsing and AST rewrites are implemented.

### Inspect And Explain Shells

```bash
twelvgaige shell graph <shell-path> [--format text|dot|json]
twelvgaige shell explain <shell-path>
twelvgaige shell lint <shell-path> [--strict]
twelvgaige shell doctor <shell-path>
```

Behavior:

- `graph` shows DAG edges, parallel groups, and safety gates.
- `explain` produces a human-readable operational summary.
- `lint` catches maintainability smells before runtime validation.
- `doctor` proposes concrete edits but does not write files in early phases.
  Later `--apply` support must still follow the diff, `--write`, atomic-write,
  and validation rules for all mutating commands.

### Generate From Intent

```bash
twelvgaige shell draft --from prompt.txt --output workflow.yaml --provider openai
twelvgaige shell draft --from incident.md --scaffold k8s-triage --dry-run
```

Behavior:

- Optional. Uses configured providers through the existing provider system.
- Always emits a candidate file or diff, never directly runs it.
- Candidate shells are marked with generated metadata.
- Candidate shells must pass strict validation before use.
- Generated tools are restricted to known tool IDs; unknown tools are comments
  or validation errors.
- Remote providers require explicit `--allow-remote` when input is read from a
  file or stdin. Draft input is size-bounded and passed through the configured
  redactor before leaving the machine.

### Manage Local Shot Libraries

```bash
twelvgaige shot library list
twelvgaige shot library show k8s.inspect
twelvgaige shot library add ./my-shot.yaml
twelvgaige shell new deploy-check --scaffold release.gate
```

Behavior:

- Libraries are local files loaded only from explicit trusted paths.
- Built-in libraries ship with Twelvgaige examples.
- Team libraries can be versioned in repositories.
- Library entries are authoring templates, not runtime imports.
- Non-built-in libraries require explicit `--library-path` or repo-local
  opt-in. User-local libraries must not silently affect repository output.

## Scaffold Design

Scaffolds are named authoring blueprints. They expand to ordinary workflow shell
data.

Example scaffold:

```yaml
kind: scaffold
id: inspect-analyze-gate-fix-verify
version: 1.0.0
description: "Read state, analyze it, require approval, apply fix, verify"
inputs:
  domain:
    type: string
    default: infrastructure
shots:
  - id: inspect
    kind: slug
    agent: "{{ domain }}_inspector"
    tools: []
  - id: analyze
    kind: slug
    agent: "{{ domain }}_analyst"
    depends_on: [inspect]
  - id: approval
    kind: safety
    depends_on: [analyze]
  - id: remediate
    kind: slug
    agent: "{{ domain }}_operator"
    depends_on: [approval]
  - id: verify
    kind: slug
    agent: "{{ domain }}_inspector"
    depends_on: [remediate]
```

Scaffold expansion rules:

- Expansion happens only in CLI authoring commands.
- Expanded output has no scaffold dependency at runtime.
- Templates support a small value-substitution language, not arbitrary code.
- Scaffold inputs are typed and validated.
- Scaffold output is normalized and compiled immediately.
- Generated metadata records the scaffold ID, scaffold version, input values,
  source content hash, expansion hash, and Twelvgaige version. This metadata is
  non-runtime provenance and can be used for later drift checks.
- Scaffolds may compose only through explicit authoring-time extension points.
  Composition must define parameter propagation, ID namespacing, collision
  behavior, and optional stages before nested scaffolds are implemented.

Initial built-in scaffolds:

| Scaffold | Purpose |
| --- | --- |
| `single-shot` | One agent shot for simple analysis. |
| `inspect-analyze` | Read-only triage with a structured output. |
| `inspect-analyze-gate-fix-verify` | Common infrastructure remediation flow. |
| `ci-review-gate` | CI result collection, risk analysis, safety gate, summary. |
| `git-pr-review` | Diff collection, risk review, optional merge gate. |
| `k8s-triage` | Kubernetes read-only incident triage. |
| `aws-review` | Cloud inventory/read-only analysis scaffold. |
| `release-readiness` | Release checklist, CI summary, and approval gate. |
| `terraform-review` | Plan review, risk classification, and apply gate. |
| `database-migration-guardrail` | Migration review, rollback evidence, and safety gate. |
| `security-patch-triage` | Patch impact analysis and deployment readiness. |
| `audit-evidence-lockbox` | Evidence collection and immutable audit summary. |

## Shot Template Design

A shot template is a reusable authoring unit:

```yaml
kind: shot_template
id: k8s.collect_namespace_state
version: 1.0.0
shot:
  kind: slug
  agent: k8s_inspector
  tools:
    - kubectl_get
    - kubectl_describe
    - kubectl_logs
  timeout_ms: 120000
  retry:
    max_attempts: 2
  output_schema:
    type: object
    required: [summary, risks]
    properties:
      summary:
        type: string
      risks:
        type: array
```

Template rules:

- A template cannot define secrets.
- A template cannot bypass compiler safety checks.
- A template can declare required agents and tools.
- A template can include docs, examples, and test input fixtures.
- When inserted, the resulting shot is copied into the workflow shell.
- Generated metadata records the template ID, version, source path, source
  content hash, and insertion command. Template output is copied, not linked.
- Later maintenance commands can compare copied shots against the source
  template, but runtime execution never imports templates dynamically.

## Metadata For Maintainability

Add optional authoring metadata that has no runtime effect:

```yaml
metadata:
  owner: platform
  tags: [kubernetes, incident]
  lifecycle: draft
  generated_by:
    tool: twelvgaige
    command: shell new
    version: 0.0.1
    source:
      kind: scaffold
      id: inspect-analyze-gate-fix-verify
      version: 1.0.0
      hash: sha256:...
  maintainers:
    - platform-oncall
```

Shot-level metadata:

```yaml
shots:
  - id: analyze_root_cause
    kind: slug
    agent: incident_analyst
    metadata:
      purpose: "Turn raw evidence into a root-cause hypothesis"
      owner: sre
      last_reviewed: "2026-05-03"
```

Rules:

- Metadata is preserved by normalize/convert commands.
- Metadata is allowlisted and size-bounded. Unknown metadata keys are rejected
  until a specific extension namespace is designed.
- Manifest provenance stores metadata hashes and selected safe fields, not
  arbitrary free-form metadata bodies.
- Metadata values pass through the same redaction rules used for logs and audit
  payloads.
- Metadata must not affect readiness, retry, safety, resource limits, or output.
- SAM0 must add metadata fields to the workflow and shot schema, structs, and
  document encoding before any command relies on metadata preservation.

Lifecycle values:

| Lifecycle | Meaning |
| --- | --- |
| `draft` | Work in progress; not suitable for unattended runs. |
| `reviewed` | Human reviewed, but not approved for scheduled or production use. |
| `approved` | Approved for the declared scope and safety policy. |
| `scheduled` | Approved and expected to run unattended or on a trigger. |
| `deprecated` | Still loadable, but should not be used for new rounds. |
| `retired` | Kept for history; should fail strict lint if referenced. |

Future lifecycle commands:

```bash
twelvgaige shell review <shell-path> --by <actor>
twelvgaige shell approve <shell-path> --scope prod --by <actor>
twelvgaige shell deprecate <shell-path> --reason <text>
```

## Lint Rules

Initial lints:

- Shot ID is too generic: `step1`, `run`, `fix`, `do_it`.
- Shot has write-capable tools without a direct safety dependency.
- Shot uses too many tools for its stated purpose.
- Agent and shot tool allowlists do not intersect.
- Prompt references a dependency output that does not exist.
- Dependency chain is deeper than needed and prevents safe parallelism.
- Multiple shots duplicate the same prompt/tools/schema shape.
- Output schema is missing for LLM-backed shots.
- Retry policy is missing on network-heavy read shots.
- Timeout is missing or larger than the active resource profile recommends.
- Workflow has no owner metadata.
- Generated metadata is present but the shell has not been reviewed.

`--strict` lints should be suitable for CI.

Lint classes:

| Class | Inputs | Examples |
| --- | --- | --- |
| Workflow-only | Workflow shell only | Graph shape, generic IDs, missing owner, lifecycle state. |
| Contextual | Workflow plus agents/tools/profile | Tool allowlist intersection, unsafe tools, provider/resource profile checks. |
| Collection | Directory or repository | Duplicate IDs, owner inventory, stale review dates, template drift. |

Contextual lints must reuse compiler and tool-safety helpers instead of
duplicating safety logic. When required context is missing, lint output should
report `unknown` or `skipped`, not guess.

## Refactoring Operations

The authoring tool should support common maintenance edits:

| Operation | Example | Notes |
| --- | --- | --- |
| Rename shot | `shot rename shell.yaml old new` | Updates dependencies and conditions. |
| Extract safety gate | `shot gate shell.yaml remediate --id approval` | Inserts safety dependency before write shot. |
| Split shot | `shot split shell.yaml analyze --into classify,explain` | Creates draft shots and preserves dependencies. |
| Merge shots | `shot merge shell.yaml collect_logs collect_events --id inspect` | Requires compatible agents/tools. |
| Replace agent | `shot replace-agent shell.yaml old_agent new_agent` | Dry-run impact report first. |
| Replace tool | `shot replace-tool shell.yaml old_tool new_tool` | Revalidates tool safety and allowlists. |
| Update schema | `shot schema set shell.yaml analyze schema.json` | Validates output schema shape. |
| Bulk metadata | `shell metadata set docs/traphouse --owner platform` | Collection-scale operation. |
| Convert format | existing `shell convert` | Preserve metadata; comments are best effort only. |
| Sort shots | `shell fmt shell.yaml` | Stable ordering by DAG groups. |

Format preservation is easiest for JSON/TOML and harder for YAML comments. The
first implementation can rewrite canonical YAML and document that comments may
not be preserved until a comment-preserving YAML library is adopted.

All refactoring commands are diff-first. Mutating commands require `--write`,
write via temporary file plus atomic rename, and validate the rewritten shell
before replacement. Dangerous operations such as `--cascade` must print the
exact removed shots and edges and require `--yes` in non-interactive contexts.

Condition rewrites are deferred until Twelvgaige has a condition parser that can
round-trip an AST. Before that exists, `shot rename` must refuse to modify a
shell when any condition string references the old shot ID.

## Assisted Generation Safety

LLM-assisted generation is useful only if it is constrained:

- Sensitive source artifacts are out of scope until redaction and explicit
  remote-provider consent are implemented.
- The model receives the shell schema, allowed tools, known agents, and selected
  scaffolds.
- Input is capped by bytes and summarized locally where possible before any
  remote call.
- The model returns JSON matching a draft schema.
- Draft output is parsed as untrusted input.
- Unknown fields are rejected unless explicitly allowed as metadata.
- Unknown tool IDs are rejected.
- Unsafe tool use requires generated safety shots.
- The CLI prints a diff and validation report.
- The CLI never runs generated shells automatically.

Recommended flow:

```text
prompt or source artifact
  -> provider draft response
  -> strict JSON parse
  -> shell normalization
  -> compiler validation
  -> lint report
  -> write candidate file or diff
  -> human review
  -> normal round run
```

## Storage And Discovery

Suggested local paths:

```text
docs/traphouse/
  scaffolds/
  shots/
  workflows/
  agents/

~/.config/twelvgaige/
  scaffolds/
  shots/
```

Discovery order:

1. Explicit `--library-path`.
2. Built-in templates shipped with the binary.
3. Repository-local `docs/traphouse/scaffolds` and `docs/traphouse/shots` when
   repo-local libraries are enabled.
4. User-local config directory only when explicitly enabled.

Conflicts are errors unless a command chooses a fully qualified ID.

Trust rules:

- Non-built-in libraries are never implicit in CI.
- Library entries are identified by namespace, ID, version, and content hash.
- Generated metadata records the library source and hash.
- A future `library verify` command should check a lockfile of expected hashes.
- A future `shell library outdated` command should report copied shots whose
  source template changed.

## Collection-Scale Management

Large teams maintain shell collections, not just single files. Collection
commands should be first-class rather than late polish:

```bash
twelvgaige shell inventory docs/traphouse --format json
twelvgaige shell impact docs/traphouse --agent k8s_inspector
twelvgaige shell impact docs/traphouse --tool kubectl_apply
twelvgaige shell impact docs/traphouse --template k8s.collect_namespace_state
```

Inventory should report workflow IDs, versions, lifecycle, owners, agents,
providers, tools, safety gates, write-capable shots, schedules, and scaffold or
template provenance.

## Variants And Overlays

Teams often need dev/staging/prod variants, read-only versus write-capable
variants, and provider/resource-profile variants. Variants are authoring-only:
they compile into ordinary explicit shells.

Design constraints:

- Variant expansion is not runtime behavior.
- Expanded shells are committed or reviewed as ordinary shell files.
- Lint can compare variants and report unintended differences.
- Safety policy differences between environments must be explicit.

## Safety Gate Policy Metadata

Graph placement is necessary but not enough for operational safety. Safety shots
may include authoring metadata for:

- approver role or team,
- required evidence packet,
- two-person approval,
- maintenance window,
- emergency override policy,
- approval expiry,
- downstream write shots covered by the approval.

This metadata does not replace runtime safety checks. It gives lint, review, and
documentation tools a consistent place to inspect human policy.

## Testing Strategy

Unit tests:

- Scaffold input validation.
- Scaffold expansion into canonical maps.
- Shot insert/rename/remove graph rewrites.
- Lint rules as pure functions.
- Format-stable generated output for JSON and TOML.

CLI tests:

- `shell new` creates valid shells.
- `shot add` updates dependencies and validates.
- `shot rename` updates dependencies when no unsafe condition rewrite is needed.
- `shell graph --format json` is deterministic.
- `shell draft --dry-run` does not write files.

Integration tests:

- Generated shells run with mock agents.
- Built-in scaffolds run against `docs/traphouse` examples.
- CI strict lint catches unsafe write tools without safety gates.

Property tests:

- Rename never leaves stale dependency references when no unsafe condition
  rewrite is needed.
- Remove without cascade never leaves invalid graphs.
- Scaffold expansion never produces cyclic graphs.
- Format conversion after generation preserves normalized shell semantics.

## Implementation Phases

### Phase SAM0 - Design And Shell Contract Review

Status: design.

- Confirm terminology and command names.
- Add canonical metadata fields to the spec.
- Add metadata fields to workflow/shot schemas, structs, parser validation, and
  `Shell.Document.to_map/1`.
- Define metadata allowlists, size limits, redaction, and manifest provenance
  behavior.
- Decide whether commands live under `shell`, `shot`, or both.
- Decide the first built-in scaffolds.
- Keep libraries, LLM drafting, `doctor --apply`, split, and merge out of early
  phases.

Acceptance:

- This plan is reviewed and updated.
- `spec.md` states that authoring helpers do not alter runtime semantics.
- Metadata survives normalize/convert round trips without affecting execution.

### Phase SAM1 - Graph Foundation

- Add pure graph inspection helpers over `Shell.Workflow`.
- Add `shell graph --format json|text`.
- Keep this phase read-only.

Acceptance:

- Existing shells can be explained as DAG groups.
- `shell graph --format json` is deterministic.
- No metadata, file rewrite, provider discovery, or runtime behavior changes are
  required.

### Phase SAM2 - Lint Foundation

- Add lint rule data structures.
- Add workflow-only lints.
- Add contextual lint plumbing for agents, tools, and profile without requiring
  every contextual lint immediately.
- Add `shell lint`.

Acceptance:

- Workflow-only lint works with just a workflow shell path.
- Contextual lint reports skipped checks when agent/tool/profile context is
  absent.
- Safety diagnostics reuse compiler/tool-safety helpers.

### Phase SAM3 - Scaffolding

- Add built-in scaffold structs or static scaffold files.
- Add `shell new`.
- Support YAML first, then JSON/TOML output through existing normalizers.
- Add examples under `docs/traphouse/scaffolds`.

Acceptance:

- `shell new simple --scaffold single-shot` creates a runnable mock workflow.
- `shell new incident --scaffold inspect-analyze-gate-fix-verify` creates a
  valid workflow with a safety shot.
- Runnable local scaffolds either create companion mock agent shells or document
  required adjacent agents.

### Phase SAM4 - Collection Inventory

- Add `shell inventory <dir>`.
- Add `shell impact <dir> --agent/--tool/--template`.
- Add collection lint output suitable for CI.

Acceptance:

- Teams can audit owners, lifecycle, tools, agents, providers, and safety gates
  across a repository.
- Impact reports are deterministic JSON.

### Phase SAM5 - Shot Refactoring Commands

- Add `shot add`, `shot rename`, `shot move`, and `shot remove`.
- Use canonical rewrites only.
- Require dry-run/diff by default and `--write` for mutation.
- Refuse condition rewrites until condition AST support exists.

Acceptance:

- Renaming a shot updates dependencies when safe.
- Renaming refuses shells with matching condition references.
- Removing a shot with dependents fails unless `--cascade --yes` is supplied.
- Every successful edit leaves a shell that validates.

### Phase SAM6 - Libraries

- Add local shot template discovery.
- Add `shot library list/show`.
- Add template insertion through `shot add --template`.
- Add repository-local example libraries.
- Add lockfile/hash verification design before implicit repo-local use.

Acceptance:

- Built-in templates can be listed offline.
- Team-local templates can be loaded from `docs/traphouse/shots`.
- Inserted templates compile to ordinary shell shots.
- Generated metadata records template source and hash.

### Phase SAM7 - Assisted Drafting

- Add `shell draft --from <file|->`.
- Use existing provider config and resource limits.
- Require strict validation and lint after draft.
- Emit candidate file or diff only.
- Require `--allow-remote` for hosted providers and run redaction before remote
  calls.

Acceptance:

- Mock provider tests cover draft generation.
- Unknown tools and unsafe write shots are rejected or safety-gated.
- Generated shells are never executed by the draft command.

### Phase SAM8 - Maintenance And CI Ergonomics

- Add `shell doctor`.
- Add `shell fmt` for canonical ordering.
- Add CI-friendly lint output.
- Add docs for maintaining large shell collections.

Acceptance:

- A repository can run `twelvgaige shell lint docs/traphouse --strict`.
- Developers can safely review generated and refactored shell diffs.

## Open Questions

- Should the primary term for reusable templates be `scaffold`, `wad`, `loadout`,
  or something else?
- Should `shot` be a top-level CLI namespace, or should all commands stay under
  `shell`?
- When, if ever, is comment-preserving YAML editing worth the dependency and
  complexity cost?
- Should scaffolds be plain shell-like YAML or a separate `kind: scaffold`
  document?
- Should generated metadata include the exact prompt hash used for assisted
  drafting?
- Should `shell graph` support Mermaid output for docs?
- How much lint should be warning-only versus compile-blocking?
- Should `shell draft` require `--write` to write files, defaulting to stdout?

## Recommended First Slice

Start with non-LLM tooling:

1. `shell graph`.

This gives immediate ergonomic value, stays deterministic, and creates the
foundation needed for lint, scaffolding, refactoring, inventory, and assisted
generation without touching file rewriting, metadata schemas, provider
discovery, or runtime behavior.
