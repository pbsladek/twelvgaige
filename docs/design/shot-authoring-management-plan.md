# Shot Authoring And Management Plan

Status: completed implementation record. Early sections describe the proposed
sequence at the time this plan was written. Current public examples use Ollama
or OpenAI; the deterministic LLM adapter is test-only and is not a supported
runtime provider. See [`../authoring.md`](../authoring.md) for current usage.

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
- Do not implement write-capable patch application until a dedicated
  `patch_apply` RFC defines canonical patch plans, digest-bound approval, path
  isolation, and audit behavior.

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
twelvgaige shot add traphouse/workflows/k8s-incident.yaml verify_recovery --after remediate
twelvgaige shell graph traphouse/workflows/k8s-incident.yaml
twelvgaige shell lint traphouse/workflows/k8s-incident.yaml
twelvgaige shell explain traphouse/workflows/k8s-incident.yaml
```

The file remains ordinary shell data. The tooling just makes the boring parts
harder to get wrong.

## Early Scope Boundary

The first implementation slice should stay narrow:

- SAM0a root/command contracts.
- SAM1 graph inspection.
- SAM2a workflow-only lint that does not depend on metadata or contextual
  agent/tool discovery.
- SAM3a local scaffolding with deterministic test agents and no provenance
  metadata until SAM0b exists.

The following are intentionally later work unless a phase explicitly depends on
them: metadata-bound lifecycle approval, variants, lifecycle mutation commands,
full lockfile updates, repo-wide shared agent loading, remote drafting,
write-capable patch application, condition AST rewriting, split/merge
refactors, and `doctor --apply`.

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

## Design Principles

The authoring system should optimize for long-term maintainability rather than
one-time generation.

- **Files remain the source of truth.** The daemon can load and run shells, but
  authoring state belongs in reviewed repository files.
- **Generation produces diffs.** Any generated or refactored shell should be
  reviewed like code before it is run in production.
- **No hidden imports at runtime.** Scaffolds, templates, overlays, and
  libraries expand into ordinary shell files. A future reader should not need a
  live library server to understand what will execute.
- **Bulk operations are first-class.** Teams manage collections of workflows,
  agents, tools, and policies. Single-file commands must have directory-level
  equivalents.
- **Safety is structural.** Write-capable flows require explicit graph-level
  safety shots and policy metadata, not prompt-only warnings.
- **Edits are reversible.** Mutating commands should support dry-run output,
  deterministic formatting, atomic writes, and small reviewable diffs.
- **LLM assistance is optional.** The deterministic local authoring tools must
  be useful without hosted provider credentials.
- **Hosted model use is explicit.** Any authoring command or authoring round
  that sends data to OpenAI must
  require `--allow-remote` and print a provider/data disclosure summary before
  transport.

## Developer Usage Flows

### Flow 1 - Understand An Existing Workflow

This is the safest first user experience because it is read-only:

```bash
twelvgaige shell validate traphouse/workflows/k8s-incident.yaml
twelvgaige shell graph traphouse/workflows/k8s-incident.yaml
twelvgaige shell graph traphouse/workflows/k8s-incident.yaml --format json
twelvgaige shell explain traphouse/workflows/k8s-incident.yaml
```

The CLI should answer:

- Which shots can run in parallel?
- Which shots are safety gates?
- Which shots can write to external systems?
- Which agents and tools are referenced?
- Which input keys and output schemas shape the workflow?
- What will block the workflow from compiling or running?

### Flow 2 - Create A New Workflow From A Scaffold

```bash
twelvgaige shell new k8s-incident \
  --scaffold inspect-analyze-gate-fix-verify \
  --format yaml \
  --output traphouse/workflows/k8s-incident.yaml \
  --write

twelvgaige shell lint traphouse/workflows/k8s-incident.yaml
twelvgaige round run traphouse/workflows/k8s-incident.yaml --input incident.json
```

Default behavior should print the candidate shell. Writing requires `--write`.
Scaffolds that bundle agents write those adjacent agent shells with the workflow:

```bash
twelvgaige shell new demo \
  --scaffold platform/release-readiness \
  --root docs/traphouse \
  --output docs/traphouse/workflows/demo.yaml \
  --write
```

### Flow 3 - Evolve A Workflow With Reviewable Diffs

```bash
twelvgaige shot add traphouse/workflows/k8s-incident.yaml verify_recovery \
  --template k8s.verify_recovery \
  --after remediate

twelvgaige shot rename traphouse/workflows/k8s-incident.yaml analyze analyze_root_cause
twelvgaige shell graph traphouse/workflows/k8s-incident.yaml
twelvgaige shell lint traphouse/workflows/k8s-incident.yaml --strict
```

The first run prints a diff and a validation report. The developer adds
`--write` only after the diff is acceptable.

### Flow 4 - Maintain A Repository Of Workflows

```bash
twelvgaige shell inventory traphouse --format json
twelvgaige shell lint traphouse --strict
twelvgaige shell impact traphouse --tool kubectl_apply
twelvgaige shell impact traphouse --agent k8s_inspector
```

This flow is for CI, platform teams, and code review. It should find stale
owners, deprecated shells, write-capable tools without safety policy metadata,
generated shells that were never reviewed, and workflows affected by a changed
agent or tool.

### Flow 5 - Draft From Intent

```bash
twelvgaige shell draft \
  --from incident-notes.md \
  --provider openai \
  --allow-remote \
  --output traphouse/workflows/k8s-triage-draft.yaml \
  --write
```

The draft command never runs a workflow. It emits a candidate shell to stdout by
default, or writes a candidate file only when `--output` and `--write` are both
present. Hosted providers always require explicit `--allow-remote`. Draft input
is byte-bounded and redacted before provider transport. Local Ollama does not
require that flag.

### Flow 6 - Use Twelvgaige To Improve Twelvgaige Shells

The authoring system should be able to use Twelvgaige itself. A shell authoring
round can inspect an existing traphouse, propose workflow edits, run lint, and
produce a patch for human review.

```bash
twelvgaige round run traphouse/workflows/shell-authoring-review-readonly.yaml \
  --input '{"path":"traphouse/workflows/k8s-incident.yaml"}'
```

The round might use agents such as:

- `shell_architect`: understands the workflow graph and desired operating flow.
- `shot_editor`: proposes concrete shot additions, removals, or rewrites.
- `safety_reviewer`: checks write-capable tools and safety gate policy.
- `schema_reviewer`: checks output schemas and dependency data flow.
- `docs_reviewer`: updates adjacent docs and usage notes.

Even when agents help, the output is still a candidate diff. The round does not
write files unless a human-approved safety shot permits a write-capable patch
tool, and the resulting shell must pass validation and lint.

### End-To-End Team Lifecycle

A realistic team flow should look like this:

```bash
# 1. Scaffold and write a draft file.
twelvgaige shell new prod-rollout-check \
  --scaffold release-readiness \
  --output traphouse/workflows/prod-rollout-check.yaml \
  --write

# 2. Review the candidate graph and lint findings.
twelvgaige shell graph traphouse/workflows/prod-rollout-check.yaml
twelvgaige shell lint traphouse/workflows/prod-rollout-check.yaml

# 3. Mark review/approval metadata.
twelvgaige shell review traphouse/workflows/prod-rollout-check.yaml --by platform-oncall
twelvgaige shell approve traphouse/workflows/prod-rollout-check.yaml --scope prod --by release-manager

# 4. CI checks the whole collection.
twelvgaige shell inventory traphouse --format json
twelvgaige shell lint traphouse --strict

# 5. A later agent or template change gets an impact report.
twelvgaige shell impact traphouse --agent release_analyst
twelvgaige shell impact traphouse --template release.readiness_gate
```

This flow makes the desired operating model explicit: scaffolding is quick,
review is file-based, approval is metadata, CI is collection-aware, and runtime
execution remains ordinary `round run` or daemon-triggered execution.

## Proposed CLI Surface

### Shared Command Contract

Authoring commands should follow one mutation contract so developers can trust
them in CI and code review:

- Read-only commands never write files.
- Mutating commands default to stdout diff or generated document output.
- `--output <path>` declares the intended destination, but does not write by
  itself.
- `--write` performs the write.
- `--dry-run` is accepted for clarity on mutating commands, but it is also the
  default. In JSON output, dry-run commands report `"write": false`.
- `--force` is required to overwrite an existing destination when the command
  would otherwise create a new file.
- Invalid `--format` values fail before reading or writing files.
- When `--format` is omitted, commands infer it from `--output` or the input
  path. If inference is impossible, YAML is the human-facing default and JSON is
  used only when `--format json` is explicit.
- JSON output includes `status`, `exit_code`, `errors`, and command-specific
  payload fields.
- Human output may be richer, but must not be the only place critical errors are
  reported.

Initial implementation modules should keep these contracts explicit:

| Module | Responsibility |
| --- | --- |
| `Twelvgaige.Shell.Graph` | Pure graph extraction, dependency groups, reverse edges, and graph JSON. |
| `Twelvgaige.Shell.Lint` | Pure and contextual lint rules with stable finding IDs. |
| `Twelvgaige.Authoring.Root` | Traphouse root resolution and no-cross-root guarantees. |
| `Twelvgaige.Authoring.Scaffold` | Scaffold expansion into ordinary shell maps. |
| `Twelvgaige.Authoring.Mutation` | Diff-first shell edits and validation orchestration. |
| `Twelvgaige.Authoring.AtomicWriter` | Sibling temp-file writes, cleanup, and replacement. |
| `Twelvgaige.Authoring.PatchPlan` | Structured patch-plan generation without file mutation. |

### Scaffold Workflow Shells

```bash
twelvgaige shell new <id> [--scaffold <scaffold-id>] [--output <path>] [--format yaml|json|toml]
twelvgaige shell new k8s-incident --scaffold inspect-analyze-gate-fix-verify --output traphouse/workflows/k8s-incident.yaml
```

Behavior:

- Creates a valid workflow shell with stable IDs and placeholders.
- For runnable local examples, creates or references companion Ollama agent shells
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
twelvgaige shell graph <shell-path> [--format text|json]
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
twelvgaige shell draft --from prompt.txt
twelvgaige shell draft --from incident.md --provider ollama --model llama3.1 --format toml
twelvgaige shell draft --from prompt.txt --provider openai --model gpt-4.1 --allow-remote
twelvgaige shell draft --from prompt.txt --output workflow.yaml --write
```

Behavior:

- Optional. Uses configured providers through the existing provider system.
- Defaults to the local Ollama provider; tests substitute a deterministic adapter.
- Always emits a candidate shell, never directly runs it.
- `--output` is accepted only with `--write`; stdout remains the default dry-run
  path.
- Hosted providers are blocked unless `--allow-remote` is present.
- Source text is redacted before it is sent to any provider.
- Candidate shells must parse, validate, and pass strict lint before emission.
- Write-capable shots without a direct safety dependency are rejected by lint.
- `patch_apply` remains deliberately out of scope until its dedicated RFC lands.
- Hosted providers always require explicit `--allow-remote`, regardless of
  input source. Draft input is size-bounded and passed through the configured
  redactor before leaving the machine.
- Before remote transport, the CLI prints a provider/data disclosure summary:
  provider, model, source paths or stdin, byte count after redaction, and
  whether generated output will include provenance metadata.

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
- SAM0b must add metadata fields to the workflow and shot schema, structs, and
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

Lifecycle transitions:

```text
draft -> reviewed -> approved -> scheduled
   |         |           |
   |         |           +-> deprecated -> retired
   |         +-> draft
   +-> retired
```

Rules:

- Generated or scaffolded shells start as `draft`.
- `reviewed` means a human has reviewed the shell content, but it is not
  automatically allowed for scheduled or production use.
- `approved` requires owner, scope, review timestamp, and safety policy metadata
  when write-capable tools are present.
- `scheduled` requires `approved` plus trigger/schedule metadata.
- `deprecated` shells remain loadable for replay or audit but strict lint warns
  when they are referenced by new automation.
- `retired` shells are retained for history and should fail strict lint if
  selected for new runs.
- `reviewed` and `approved` records must bind to the content that was reviewed:
  normalized workflow digest, referenced agent/loadout digests, approver,
  timestamp, approval scope, expiry when relevant, and evidence hash.
- Any workflow, agent, loadout, safety policy, or approved patch-plan change
  invalidates the bound review or approval. Strict lint should fail or downgrade
  the shell to `draft` until a new review is recorded.

Lifecycle metadata is authoring-only and does not change DAG execution
semantics. Runtime still validates the shell and enforces safety policies
independently. Separately, daemon, scheduler, and CI admission policy may require
`approved` or `scheduled` lifecycle metadata bound to the current digest for
production or unattended runs. Manual local runs should warn when approval is
missing instead of silently treating metadata as runtime control flow.

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
| Rename shot | `shot rename shell.yaml old new` | Updates dependencies; condition rewrites wait for AST support. |
| Extract safety gate | `shot gate shell.yaml remediate --id approval` | Inserts safety dependency before write shot. |
| Split shot | `shot split shell.yaml analyze --into classify,explain` | Creates draft shots and preserves dependencies. |
| Merge shots | `shot merge shell.yaml collect_logs collect_events --id inspect` | Requires compatible agents/tools. |
| Replace agent | `shot replace-agent shell.yaml old_agent new_agent` | Dry-run impact report first. |
| Replace tool | `shot replace-tool shell.yaml old_tool new_tool` | Revalidates tool safety and allowlists. |
| Update schema | `shot schema set shell.yaml analyze schema.json` | Validates output schema shape. |
| Bulk metadata | `shell metadata set traphouse --owner platform` | Collection-scale operation. |
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
- Hosted providers require explicit `--allow-remote` for every authoring
  command and authoring round, even when input is an inline prompt.
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

## Agent-Assisted Authoring Rounds

Twelvgaige should dogfood its own model: authoring assistance can be expressed
as ordinary workflow shells that operate on other shells. This gives us
parallel review agents, safety gates, resource limits, audit logs, and
repeatable authoring workflows without creating a separate hidden generator.

### Core Rule

Agent-assisted authoring is not a privileged path. It follows the same contract
as `shell draft`:

- It reads workflow, agent, scaffold, template, inventory, and lint data.
- It proposes normalized shell maps, diffs, or patch plans.
- It runs validation, graph inspection, and lint as tool calls.
- It cannot directly mutate files without an explicit write-capable tool and a
  safety shot.
- It never bypasses shell compile, tool-safety, metadata, or provenance rules.

### Authoring Agents

Recommended built-in authoring agents:

| Agent | Role | Default Tools |
| --- | --- | --- |
| `shell_architect` | Designs workflow shape, shot boundaries, and dependency flow. | `shell_validate`, `shell_graph`, `shell_lint` |
| `shot_editor` | Proposes concrete shot edits and templates. | `shell_validate`, `shell_graph`, `shell_diff` |
| `safety_reviewer` | Reviews write-capable shots, approval policy, and unsafe tool exposure. | `shell_lint`, `tool_catalog_read` |
| `schema_reviewer` | Reviews output schemas and dependency data contracts. | `shell_validate`, `shell_graph` |
| `collection_curator` | Reviews inventory, owners, stale lifecycle states, and impact reports. | `shell_inventory`, `shell_impact`, `shell_lint` |
| `docs_reviewer` | Proposes README/usage updates for changed workflows. | `shell_graph`, `shell_explain` |

These agents should default to read-only tools. A separate `patch_writer` agent
may exist, but it must sit behind a safety shot and use a narrow patch tool that
only writes approved paths.

### Authoring Tools

The agent-authoring workflow should use product APIs as tools rather than
private internals:

| Tool | Purpose | Safety |
| --- | --- | --- |
| `shell_validate` | Load and validate shell files. | read-only |
| `shell_graph` | Return deterministic graph JSON. | read-only |
| `shell_lint` | Return lint findings. | read-only |
| `shell_inventory` | Inventory a traphouse directory. | read-only |
| `shell_impact` | Find workflows affected by agent/tool/template changes. | read-only |
| `shell_diff` | Compare original and candidate normalized shells. | read-only |
| `shell_normalize` | Normalize candidate shell maps. | read-only |
| `tool_catalog_read` | Return known tools, safety levels, and write capability. | read-only |
| `patch_plan` | Build a structured patch plan without writing. | read-only |
| `patch_apply` | Apply an approved patch to allowed paths. | write-capable |

`patch_apply` must require:

- a dedicated `patch_apply` RFC before implementation,
- a structured patch plan emitted by `patch_plan`, not natural-language edit
  instructions,
- approval whose canonical patch-plan hash exactly matches the current
  patch-plan hash,
- base workflow/file digests that still match the files being changed,
- repository-root-relative normalized paths,
- rejection of absolute paths, `..`, symlinks, hardlinks, binary files, and
  paths outside the configured traphouse root,
- allowlisted file kinds and roots such as `traphouse/workflows/**/*.yaml`,
  `traphouse/workflows/**/*.json`, `traphouse/workflows/**/*.toml`, and
  explicitly configured docs paths,
- maximum changed files, hunks, bytes, and resulting file size,
- clean worktree by default, with an explicit dirty-worktree acknowledgment for
  local interactive use,
- atomic sibling temp-file writes with cleanup on validation or write failure,
- audit events containing patch-plan hash, before/after file digests, changed
  paths, approval actor, and approval scope.

`patch_apply` should only write. Post-write `shell_validate` and `shell_lint`
must be separate dependent shots so validation remains visible in the graph and
can fail independently.

### Example Read-Only Shell Authoring Round

```yaml
kind: workflow
id: shell_authoring_review_readonly
version: 1.0.0
input_schema:
  type: object
  required: [path]
  properties:
    path:
      type: string
shots:
  - id: inspect_graph
    kind: slug
    agent: shell_architect
    tools: [shell_validate, shell_graph]
    prompt: "Inspect the workflow graph and summarize structural issues."

  - id: lint_shell
    kind: slug
    agent: safety_reviewer
    tools: [shell_lint]
    prompt: "Run lint and classify findings by risk."

  - id: propose_patch
    kind: slug
    agent: shot_editor
    depends_on: [inspect_graph, lint_shell]
    tools: [patch_plan, shell_diff]
    prompt: "Propose the smallest reviewable patch plan."
```

This SAM5 round is read-only. It can produce a graph report, lint report, and
patch plan, but it cannot mutate files. Metadata can be added after SAM0b lands;
until then this example should remain loadable by the current shell schema.

### Later Apply Round

SAM8 can add a separate write-capable round after the `patch_apply` RFC is
accepted:

```yaml
kind: workflow
id: shell_authoring_apply
version: 1.0.0
input_schema:
  type: object
  required: [patch_plan_path, expected_patch_hash]
  properties:
    patch_plan_path:
      type: string
    expected_patch_hash:
      type: string
shots:
  - id: approve_patch
    kind: safety
    metadata:
      approver_role: maintainer
      required_evidence: [patch_plan_path, expected_patch_hash]

  - id: apply_patch
    kind: slug
    agent: patch_writer
    depends_on: [approve_patch]
    tools: [patch_apply]
    prompt: "Apply the approved patch only if the patch-plan hash matches."

  - id: validate_after_apply
    kind: slug
    agent: shell_architect
    depends_on: [apply_patch]
    tools: [shell_validate, shell_lint]
    prompt: "Rerun validation and lint after the write."
```

This is intentionally just another workflow. It can run locally with Ollama
agents, or against hosted OpenAI when the user opts in with
`--allow-remote`.

### Feedback Loop

Agent-assisted authoring should produce structured artifacts:

```text
read-only authoring run
  -> graph report
  -> lint report
  -> proposed patch plan
  -> human safety decision

later write-capable apply run
  -> approved patch-plan hash check
  -> applied patch, if approved
  -> post-write validation and lint report
```

Those artifacts can feed future inventory and lifecycle commands. Over time,
this lets Twelvgaige maintain its own traphouse without making the model the
control plane.

## Storage And Discovery

Repository storage should make workflow ownership and review obvious. The
authoring system should assume Git is the durable source of truth.

The recommended project-local workspace name is `traphouse/`. In this
repository, example material currently lives under `docs/traphouse/` because it
is product documentation. For a team using Twelvgaige in its own repository,
`traphouse/` should be the default root.

```text
traphouse/
  README.md
  workflows/
    README.md
    *.yaml
    agents/
      *.yaml
  agents/
    *.yaml
  scaffolds/
    README.md
    *.yaml
  shots/
    README.md
    *.yaml
  inventory/
    shell-inventory.json
    shell-impact-*.json
  twelvgaige-library.lock

~/.config/twelvgaige/traphouse/
  config.toml
  workflows/
  agents/
  scaffolds/
  shots/
  libraries/
```

Repository-local files:

| Path | Purpose | Committed |
| --- | --- | --- |
| `traphouse/workflows/` | Runnable workflow shells. | Yes |
| `traphouse/workflows/agents/` | Workflow-local agents for examples or tightly coupled workflows. | Yes |
| `traphouse/agents/` | Shared repository agents for future loader support and current authoring inventory. | Yes |
| `traphouse/scaffolds/` | Team-owned scaffold definitions. | Yes |
| `traphouse/shots/` | Team-owned shot templates. | Yes |
| `traphouse/twelvgaige-library.lock` | Hashes for trusted scaffold/template sources. | Yes |
| `traphouse/inventory/` | Optional generated inventory and impact reports. | Optional |

The daemon does not need scaffolds, shot templates, inventory reports, or
lockfiles to run a workflow. Those are authoring artifacts.

### Root Resolution

Commands that accept a traphouse collection must resolve exactly one root:

1. `--root <path>` wins.
2. If the current working directory contains `traphouse/`, use that root.
3. In this repository, docs and tests may pass `--root docs/traphouse` because
   shipped examples intentionally live under documentation.
4. User-local `~/.config/twelvgaige/traphouse` is used only with an explicit
   `--include-user` or equivalent opt-in.

There is no cross-root discovery. A command operating on `traphouse/` must not
silently merge files from `docs/traphouse/`, user-local config, or another
repository. CI must forbid user-local roots so generated output is reproducible.

The root resolver should emit a resolution manifest for inventory, lint, and
authoring rounds:

```json
{
  "root": "traphouse",
  "workflow_paths": ["traphouse/workflows/k8s-incident.yaml"],
  "agent_roots": ["traphouse/workflows/agents"],
  "library_roots": ["traphouse/scaffolds", "traphouse/shots"],
  "user_local_included": false
}
```

### Agent Resolution

Early runtime phases should match the current loader behavior before adding
global traphouse-wide agent discovery:

1. Workflow-adjacent agents under `<workflow-dir>/agents/`.
2. Explicit agent shell paths when a command supplies them.
3. Test fixture agents where the existing loader already
   supports them.

Shared `traphouse/agents/` is authoring and inventory-only until explicit loader
support is added. When that support lands, the resolver must define namespace
rules, duplicate handling, digest recording, and stable precedence. Duplicate
agent IDs across enabled roots should be hard errors unless a fully qualified
namespace is used.

The future full resolution manifest should include workflow path, workflow
digest, enabled agent roots in order, resolved agent digests, tool catalog
digest, provider/loadout digest, library lock digest, namespace decisions, and
duplicate or skipped entries.

Generated example agents should be deterministic and live under the workflow's
adjacent `agents/` directory unless the user supplies a different explicit
agent output root.

### Library Discovery Order

Template and scaffold discovery order:

1. Explicit `--library-path`.
2. Built-in templates shipped with the binary.
3. Repository-local `traphouse/scaffolds` and `traphouse/shots` when
   repo-local libraries are enabled.
4. User-local `~/.config/twelvgaige/traphouse` directory only when explicitly
   enabled.

Conflicts are errors unless a command chooses a fully qualified ID.

Trust rules:

- Non-built-in libraries are never implicit in CI.
- User-local libraries must not silently affect repository output.
- Library entries are identified by namespace, ID, version, and content hash.
- Generated metadata records the library source and hash.
- A future `library verify` command should check a lockfile of expected hashes.
- A future `shell library outdated` command should report copied shots whose
  source template changed.

### Library Lockfile

The lockfile records the exact content used by scaffolding and template
insertion:

```yaml
kind: library_lock
version: 1
entries:
  - kind: scaffold
    namespace: builtin
    id: inspect-analyze-gate-fix-verify
    version: 1.0.0
    digest: sha256:...
  - kind: shot_template
    namespace: team-platform
    id: k8s.collect_namespace_state
    version: 1.2.0
    source: traphouse/shots/k8s.collect_namespace_state.yaml
    digest: sha256:...
```

Rules:

- `shell new` and `shot add --template` record the source entry and digest in
  generated metadata.
- `library verify` checks that local files still match the lock.
- `library update` updates lock entries after human review.
- CI uses the lockfile and explicit repository paths, not user-local libraries.

### Runtime Manifest Provenance

Workflow shells may include authoring metadata, but persisted round manifests
should store only safe provenance:

```yaml
metadata:
  owner: platform
  lifecycle: approved
  source:
    repository: github.com/pbsladek/twelvgaige
    path: traphouse/workflows/k8s-incident.yaml
    digest: sha256:...
  generated_by:
    command: shell new
    scaffold:
      namespace: builtin
      id: inspect-analyze-gate-fix-verify
      version: 1.0.0
      digest: sha256:...
```

The runtime manifest should prefer digests and selected safe fields over full
free-form metadata. This keeps audit provenance useful without turning metadata
into an accidental secret store.

### Storage Rules

- Workflow shells are stable source files.
- Scaffolds and templates are copied into workflow shells during authoring.
- Generated metadata records source and digest, but runtime does not import the
  source again.
- Normalization preserves allowlisted metadata.
- File rewrite commands write to a temporary sibling file, validate it, then
  atomically replace the target.
- The authoring cache, if added later, is disposable and rebuildable from files.
- Generated inventory reports are derived data and should never be required to
  run a workflow.

## Collection-Scale Management

Large teams maintain shell collections, not just single files. Collection
commands should be first-class rather than late polish:

```bash
twelvgaige shell inventory traphouse --format json
twelvgaige shell impact traphouse --agent k8s_inspector
twelvgaige shell impact traphouse --tool kubectl_apply
twelvgaige shell impact traphouse --template k8s.collect_namespace_state
```

Inventory should report workflow IDs, versions, lifecycle, owners, freshness,
agents, providers, tools, safety gates, write-capable shots, schedules, triggers,
variants, scaffold/template provenance, agent/tool/provider digests, safety
coverage, approval digest validity, stale review age, template drift, orphaned
agents, orphaned templates, invalid partials, and duplicate IDs.

Findings need stable IDs so CI can baseline or route them:

```json
{
  "id": "approval.digest.stale",
  "severity": "error",
  "path": "traphouse/workflows/prod-rollout-check.yaml",
  "subject": "workflow:prod-rollout-check",
  "message": "approved digest does not match the normalized workflow digest"
}
```

## Command Output Contracts

Every authoring command should support human output and `--format json`.
Machine-readable output needs stable shapes because these commands are likely to
run in CI.

### Graph JSON

```json
{
  "status": "ok",
  "exit_code": 0,
  "errors": [],
  "workflow_id": "k8s_incident",
  "version": "1.0.0",
  "nodes": [
    {
      "id": "inspect",
      "kind": "slug",
      "agent": "k8s_inspector",
      "dependencies": [],
      "dependents": ["analyze"],
      "tools": ["kubectl_get"],
      "safety": false,
      "write_capable": false
    }
  ],
  "edges": [{"from": "inspect", "to": "analyze"}],
  "groups": [["inspect"], ["analyze"], ["approval"], ["remediate"], ["verify"]]
}
```

### Lint JSON

```json
{
  "path": "traphouse/workflows/k8s-incident.yaml",
  "status": "failed",
  "exit_code": 1,
  "errors": [],
  "findings": [
    {
      "id": "metadata.owner.missing",
      "severity": "warning",
      "class": "workflow",
      "message": "workflow metadata owner is missing",
      "location": {"shot_id": null}
    }
  ],
  "skipped": [
    {
      "id": "tools.safety.write_without_gate",
      "reason": "tool catalog unavailable"
    }
  ]
}
```

### Mutation Dry-Run JSON

```json
{
  "path": "traphouse/workflows/k8s-incident.yaml",
  "status": "ok",
  "exit_code": 0,
  "errors": [],
  "write": false,
  "valid": true,
  "summary": {
    "shots_added": ["verify"],
    "shots_removed": [],
    "edges_added": [{"from": "remediate", "to": "verify"}],
    "edges_removed": []
  },
  "diff": "--- old\n+++ new\n..."
}
```

Human output can be richer, but JSON output should stay boring and stable.

## Variants And Overlays

Teams often need dev/staging/prod variants, read-only versus write-capable
variants, and provider/resource-profile variants. Variants are authoring-only:
they compile into ordinary explicit shells.

Suggested storage:

```text
traphouse/
  workflows/
    incident-response.yaml
  variants/
    incident-response.dev.yaml
    incident-response.staging.yaml
    incident-response.prod.yaml
```

Possible authoring commands:

```bash
twelvgaige shell variant create traphouse/workflows/incident-response.yaml \
  --env prod \
  --output traphouse/variants/incident-response.prod.yaml

twelvgaige shell variant diff traphouse/variants/incident-response.dev.yaml \
  traphouse/variants/incident-response.prod.yaml
```

Design constraints:

- Variant expansion is not runtime behavior.
- Expanded shells are committed or reviewed as ordinary shell files.
- Lint can compare variants and report unintended differences.
- Safety policy differences between environments must be explicit.
- Production variants cannot silently inherit write-capable tools from a base
  shell without an explicit safety gate and approval metadata.
- Variant diffs should classify changes by graph, agent, provider, tool, safety,
  resource profile, input schema, and metadata.
- Variants record `base_path`, `base_digest`, `variant_kind`, overlay or patch
  digest, generator command, and Twelvgaige version.
- CI reports stale bases when `base_digest` no longer matches the referenced
  base shell.
- CI reports unauthorized deltas when a variant changes fields outside the
  allowed delta model for its `variant_kind`.

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

- Generated shells run with test-only deterministic agents in integration tests.
- Built-in scaffolds run against repository examples with `--root
  docs/traphouse`, and against project-local `traphouse` layouts in fixtures.
- CI strict lint catches unsafe write tools without safety gates.

Property tests:

- Rename never leaves stale dependency references when no unsafe condition
  rewrite is needed.
- Remove without cascade never leaves invalid graphs.
- Scaffold expansion never produces cyclic graphs.
- Format conversion after generation preserves normalized shell semantics.

## Implementation Phases

Phase dependencies:

```text
SAM0a command/root contracts
  -> SAM1 graph
      -> SAM2a workflow-only lint
      -> SAM3a local scaffolding without provenance metadata
      -> SAM0b metadata and approval binding
          -> SAM2b contextual, lifecycle, and approval lint
          -> SAM3b scaffold provenance metadata
          -> SAM4 inventory
              -> SAM5 read-only authoring rounds
                  -> SAM6 refactor
                      -> SAM7 libraries
                          -> SAM8 assisted draft and patch RFCs
                              -> SAM9 maintenance polish
```

The dependency direction is intentional. Graph inspection should land first
because it is read-only and exercises the same DAG analysis needed by lint,
scaffolding validation, refactoring, inventory, and future assisted generation.
Metadata binding is important but should not block the first useful lint and
scaffold slices; those early slices must simply avoid relying on metadata.

### Phase SAM0a - Command Contracts And Root Resolution

Status: implemented for the initial authoring command surface.

- Confirm terminology and command names.
- Decide whether commands live under `shell`, `shot`, or both.
- Decide the first built-in scaffolds.
- Define root resolution, no-cross-root discovery, user-local opt-in, and CI
  restrictions.
- Define the shared mutation contract: stdout by default, `--output` as intended
  path, `--write` for mutation, `--force` for overwrite, invalid `--format`
  failures, and stable JSON fields.
- Keep libraries, LLM drafting, `doctor --apply`, split, and merge out of early
  phases.

Acceptance:

- This plan is reviewed and updated.
- `spec.md` states that authoring helpers do not alter runtime semantics.
- CLI examples use `traphouse/` for team repositories and `--root
  docs/traphouse` only for this repository's examples/tests.
- The first implementation slice can land graph inspection without schema
  metadata changes.
- Command output contracts are documented before new authoring commands are
  added.

### Phase SAM1 - Graph Foundation

Status: implemented. SAM9 documentation polish adds Mermaid rendering for
copy/paste diagrams through `shell graph --format mermaid`.

- Add pure graph inspection helpers over `Shell.Workflow`.
- Add `shell graph --format json|text|mermaid`.
- Include shot IDs, dependencies, reverse dependencies, derived ready groups,
  kind, agent, tools, safety marker, and write-capable marker when known.
- Keep this phase read-only.

Acceptance:

- Existing shells can be explained as DAG groups.
- `shell graph --format json` is deterministic.
- Graph output for YAML, JSON, and TOML equivalents is semantically identical.
- No metadata, file rewrite, provider discovery, or runtime behavior changes are
  required.

### Phase SAM0b - Metadata Persistence And Approval Binding

Status: metadata persistence, canonical workflow subject digests, digest-bound
review/approval parsing, stale approval lint, `shell admit`, explicit
daemon/foreground admission policy, and scheduled-job admission defaults are
implemented.

- Add canonical metadata fields to the spec.
- Add metadata fields to workflow/shot schemas, structs, parser validation, and
  `Shell.Document.to_map/1`.
- Define metadata allowlists, size limits, redaction, and manifest provenance
  behavior.
- Add digest-bound review and approval records.
- Define execution admission policy for daemon, scheduler, and CI when
  production or unattended runs require approved/scheduled shells.

Acceptance:

- Metadata survives normalize/convert round trips without affecting execution.
- Existing workflow shells without metadata continue to load unchanged.
- Metadata is excluded from runtime DAG, retry, resource, and safety decisions by
  tests.
- `reviewed` and `approved` records bind to normalized workflow, agent, and
  loadout digests.
- Strict lint can detect stale approval digests.

### Phase SAM2 - Lint Foundation

Status: SAM2a implemented for workflow-only lint. SAM2b now includes lifecycle
metadata warnings, generated-draft warnings, stale/missing approval digest
errors, initial contextual agent/tool lint for path-based workflows, and
resource-profile warnings for clamped profiles or excessive shot iterations.

- Add lint rule data structures.
- Add SAM2a workflow-only lints.
- Add contextual lint plumbing for agents, tools, and profile without requiring
  every contextual lint immediately.
- Add SAM2b lifecycle, approval-digest, and contextual lints after SAM0b
  metadata exists.
- Add `shell lint`.
- Add directory lint support for workflow-only checks.

Acceptance:

- Workflow-only lint works with just a workflow shell path.
- Contextual lint reports skipped checks when agent/tool/profile context is
  absent.
- Safety diagnostics reuse compiler/tool-safety helpers.
- Strict lint returns a deterministic non-zero exit code only for configured
  error-level findings.

### Phase SAM3 - Scaffolding

Status: SAM3a implemented for built-in local scaffolds. SAM3b scaffold
provenance metadata is implemented for `shell new`; repo-local scaffold
libraries and shared lockfile provenance are implemented through
`shell scaffold list/show/verify/update/outdated`.

- Add built-in scaffold structs or static scaffold files.
- Add `shell new`.
- Support YAML first, then JSON/TOML output through existing normalizers.
- Add examples under this repository's `docs/traphouse/scaffolds` and document
  `traphouse/scaffolds` as the recommended location for user projects.
- Default to stdout. Require `--write` for filesystem changes.

Acceptance:

- `shell new simple --scaffold single-shot` creates a valid workflow.
- `shell new incident --scaffold inspect-analyze-gate-fix-verify` creates a
  valid workflow with a safety shot.
- Runnable local scaffolds either create companion Ollama agent shells or document
  required adjacent agents.
- Scaffold output validates immediately.
- Scaffold output includes provenance metadata only after SAM0b metadata support
  exists.
- Minimal `library verify` and lockfile write provenance exist before repo-local
  scaffolds/templates are enabled in CI.

### Phase SAM4 - Collection Inventory

Status: `shell inventory` and `shell impact` are implemented for deterministic
read-only workflow/agent/tool/provider/lifecycle summaries, invalid-shell
reporting, agent/tool/template impact queries, and optional JSON report writing
with `--output`.

- Add `shell inventory <dir>`.
- Add `shell impact <dir> --agent/--tool/--template`.
- Add collection lint output suitable for CI.
- Add optional report writing under `traphouse/inventory/`.

Acceptance:

- Teams can audit owners, lifecycle, tools, agents, providers, and safety gates
  across a repository.
- Impact reports are deterministic JSON.
- Inventory does not require daemon state.
- Inventory treats invalid shells as reportable findings rather than crashing
  the whole collection scan.

### Phase SAM5 - Read-Only Agent-Assisted Authoring

Status: implemented for local Ollama authoring. The read-only authoring tools,
catalog entries, safety classifications, example authoring agents, example review
shell, and an end-to-end review round fixture that emits graph, lint, and
patch-plan artifacts are implemented. Hosted-provider authoring remains blocked
until explicit `--allow-remote` consent and disclosure UX are added in a later
drafting phase.

- Add read-only authoring tools: `shell_validate`, `shell_graph`,
  `shell_lint`, `shell_inventory`, `shell_impact`, `shell_diff`,
  `shell_normalize`, `tool_catalog_read`, and `patch_plan`.
- Add catalog entries and safety classifications for those read-only tools before
  any authoring round references them.
- Add example `shell_authoring_review_readonly` workflow under this repository's
  `docs/traphouse/workflows`.
- Add example agents for shell architecture, safety review, schema review, and shot
  editing.
- Keep all tools read-only.

Acceptance:

- Twelvgaige can run a shell-authoring review round against an existing shell.
- The round emits graph, lint, and patch-plan artifacts.
- No files are modified by this phase.
- Hosted-provider use remains opt-in through normal provider configuration and
  explicit `--allow-remote`.

### Phase SAM6 - Shot Refactoring Commands

Status: implemented for the initial conservative command surface. `shot add`,
`shot rename`, `shot move`, and `shot remove` are implemented. They dry-run by
default, emit unified diffs, validate rewritten workflows before returning, and
use atomic writes when `--write` is supplied. Add supports manual slug and
safety shot insertion; template insertion remains in SAM7. Rename updates
dependency edges and refuses matching condition references. Move reorders the
canonical document only; it does not infer or change dependency edges. Remove
refuses dependent shots unless `--cascade --yes` is supplied, then removes
transitive dependents.

- Add `shot add`, `shot rename`, `shot move`, and `shot remove`.
- Use canonical rewrites only.
- Require dry-run/diff by default and `--write` for mutation.
- Refuse condition rewrites until condition AST support exists.
- Implement one command at a time, starting with `shot add --template` or
  `shot rename` over dependency edges only.

Acceptance:

- Renaming a shot updates dependencies when safe.
- Renaming refuses shells with matching condition references.
- Removing a shot with dependents fails unless `--cascade --yes` is supplied.
- Every successful edit leaves a shell that validates.
- Atomic writes are tested by failure injection or temp-file cleanup checks.

### Phase SAM7 - Libraries

Status: implemented for the initial conservative command surface. Built-in and
explicit/repo-local shot template discovery, `shot library list/show`, repo-local
example templates, `shot add --template` insertion, lockfile writing, and
`shot library verify/update/outdated` are implemented. Inserted templates are
copied into workflow shells as ordinary shots with generated source metadata and
source digests. CI should use `shot library verify` without `--write-lock`;
digest mismatches fail instead of silently using changed template content.
`shot library update` gives a reviewable lockfile diff and writes only with
`--write-lock`. Scaffold sources now use the same shared library lockfile
without overwriting shot-template entries.

- Add local shot template discovery.
- Add `shot library list/show`.
- Add template insertion through `shot add --template`.
- Add repository-local example libraries.
- Add lockfile/hash verification design before implicit repo-local use.
- Add `library verify` before enabling repo-local libraries in CI.

Acceptance:

- Built-in templates can be listed offline.
- Team-local templates can be loaded from `traphouse/shots`.
- Inserted templates compile to ordinary shell shots.
- Generated metadata records template source and hash.
- Lockfile mismatch produces a clear finding and does not silently use changed
  template content.

### Phase SAM8 - Assisted Drafting And Patch Application

Status: initial draft generation implemented; write-capable patch application is
still intentionally blocked pending a dedicated RFC.

- Implemented: `shell draft --from <file|->`.
- Implemented: existing provider config and resource limiter plumbing are used
  through `Twelvgaige.LLM.complete/4`.
- Implemented: strict validation and lint after draft.
- Implemented: candidate shell emission to stdout, or candidate file write with
  explicit `--output ... --write`.
- Implemented: `--allow-remote` is required for hosted providers and source text
  is redacted before provider transport.
- Deferred: write-capable `patch_apply` only after safety-shot approval, path
  allowlists, atomic writes, patch hashes, and the dedicated `patch_apply` RFC
  exist.

Acceptance:

- Done: the test-only deterministic provider covers draft generation.
- Done: unsafe write shots are rejected unless safety-gated.
- Done: generated shells are never executed by the draft command.
- Done: hosted-provider drafting is impossible without explicit `--allow-remote`.
- Done: draft input is size-bounded and redacted before provider transport.
- Agent-assisted patch application records patch hashes and reruns validation
  and lint after writing.
- `patch_plan` can land before `patch_apply`; write-capable application remains
  blocked until the RFC and hash-bound approval model are implemented.

### Phase SAM9 - Maintenance And CI Ergonomics

- Add `shell doctor`.
- Add `shell fmt` for canonical ordering.
- Add CI-friendly lint output.
- Add docs for maintaining large shell collections.
- Add lifecycle commands if the metadata model has proven useful.
- Add `library outdated` and template drift reports after lockfiles exist.

Status: initial `shell doctor`, `shell fmt`, `shell review`, `shell approve`,
`shell deprecate`, and `shell retire` implemented. They are daemon-free and
suitable for CI.
`shell doctor` turns graph and lint findings into repair-oriented
recommendations in human or JSON output. `shell fmt` canonicalizes one shell
file, supports `--check`, emits diffs by default, and uses atomic writes.
`shell review` and `shell approve` stamp digest-bound authoring metadata, emit
diffs by default, and write only with `--write`; approval requires
`metadata.owner` and explicit `--scope`. `shell deprecate` and `shell retire`
record a lifecycle reason and clear review/approval bindings. Strict lint warns
on deprecated workflows and fails retired workflows. `shot library outdated`
scans copied template source metadata in workflow shots and reports
digest/version drift without rewriting workflows.

Acceptance:

- A repository can run `twelvgaige shell lint traphouse --strict`.
- Done: developers can safely review generated and refactored shell diffs.
- Done: CI can produce inventory, impact, lint, and doctor artifacts without
  daemon startup.

## Decisions For First Pass

These decisions are resolved for the first implementation pass:

- Reusable workflow blueprints are called `scaffolds`. `loadout` remains
  reserved for provider/model/system-prompt resolution.
- `shot` is a top-level CLI namespace for shot lifecycle commands. Whole-shell
  commands stay under `shell`.
- Comment-preserving YAML editing is not a phase-one requirement. Canonical
  rewrites may drop comments until there is a clear library and UX need.
- Scaffolds are separate `kind: scaffold` documents. They are authoring inputs,
  not runtime shell imports.
- Assisted drafting metadata should include prompt/input digest, provider,
  model, redaction summary, and source byte count after SAM0b exists. It must
  not store raw prompt text by default.
- Mermaid output for `shell graph` is implemented as documentation polish after
  JSON and text.
- Lint rules have severities. `--strict` exits non-zero only for error-level
  findings, while warning-only findings remain review guidance unless promoted
  by policy.

## Recommended First Slice

Start with non-LLM tooling:

1. SAM0a root and command contracts.
2. `shell graph`.

This gives immediate ergonomic value, stays deterministic, and creates the
foundation needed for lint, scaffolding, refactoring, inventory, and assisted
generation without touching file rewriting, metadata schemas, provider
discovery, or runtime behavior.
