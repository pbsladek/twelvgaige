# Shell Authoring Formats Plan

Twelvgaige currently loads workflow and agent shells from YAML, JSON, and TOML.
Further format work must keep the control plane format-neutral: every authoring
format parses into the same normalized shell map, passes the same validation, and
compiles into the same pattern. No parser gets its own workflow semantics.

## Goals

- Support JSON workflow and agent shells for generated definitions, CI systems,
  and tools that already emit JSON.
- Add one low-friction human/developer format after JSON. TOML is the preferred
  declarative candidate because it is readable, strict, and common in developer
  tooling.
- Evaluate one programmatic authoring language for advanced teams that need to
  generate repeated shots without giving workflow files arbitrary host access.
  Starlark is the preferred candidate if a maintained, sandboxable
  implementation is viable.
- Preserve YAML compatibility and existing shell validation behavior.

## Non-Goals

- Do not add runtime workflow logic to JSON, TOML, or YAML.
- Do not allow arbitrary Elixir, JavaScript, Python, shell, or template
  execution from untrusted workflow files.
- Do not let authoring format choice affect retry, dependency, safety,
  resource, persistence, provider, or tool semantics.
- Do not create separate examples, docs, or APIs that imply YAML, JSON, and TOML
  are different products.

## Format Decisions

| Format | Status | Primary Use | File Extensions | Notes |
| --- | --- | --- | --- | --- |
| YAML | implemented | Hand-authored shells and examples | `.yaml`, `.yml` | Existing behavior stays compatible. |
| JSON | implemented | Generated shells, CI, strict interchange | `.json` | Uses RFC 8259 JSON and the existing normalized shell map. |
| TOML | implemented | Developer-friendly local config | `.toml` | Declarative only. Arrays-of-tables map to `shots`, tools, and agents. |
| Starlark | design spike | Safe programmatic shell generation | `.star`, `.twelv.star` | Optional and gated until sandboxing, limits, and implementation maturity are proven. |

If the Starlark spike fails, the fallback is to stop at YAML, JSON, and TOML
until a better sandboxed language exists. CUE may be evaluated as a conversion
tool, but relying on an external `cue` binary should be treated as trusted-local
authoring, not daemon-side untrusted parsing.

## Canonical Shell IR

All formats must produce this pipeline:

```text
source file
  -> format parser
  -> ordinary map with string keys
  -> existing shell normalization
  -> workflow or agent struct
  -> compiler validation
  -> compiled pattern
```

The canonical in-memory representation is the normalized map and the existing
`Twelvgaige.Shell.Workflow` or `Twelvgaige.Shell.Agent` struct. Persisted round
manifests should record:

- original source path,
- source format,
- source content hash,
- normalized shell hash,
- shell ID,
- shell version.

This gives auditability while keeping execution independent from authoring
syntax.

## Phase AF0 - Contract And Loader Audit

Goal: make the format boundary explicit before adding parsers.

- Document the canonical shell map contract in `spec.md`.
- Inventory current YAML-only assumptions in loader, tests, docs, examples, and
  shell-cache discovery.
- Decide whether parse errors share `:invalid_shell` or get
  `:invalid_shell_format` details while preserving CLI behavior.
- Add source-format fields to validation metadata where useful.

Acceptance:

- YAML tests still pass unchanged.
- Unsupported format errors remain clear and deterministic.
- `spec.md` states that authoring formats cannot alter runtime semantics.

## Phase AF1 - Parser Dispatch Refactor

Status: implemented for YAML and JSON.

Goal: split parsing from shell construction.

- Introduce a small parser behavior, for example
  `Twelvgaige.Shell.Format.parse/2`.
- Move YAML parsing behind `Twelvgaige.Shell.Format.YAML`.
- Keep `Twelvgaige.Shell.Loader` as the dispatcher and owner of public error
  shape.
- Make shell discovery use a configured list of supported extensions.
- Add equivalence helpers that compare normalized maps, not raw source text.

Acceptance:

- YAML workflow and agent fixtures load through the new dispatch path.
- Agent discovery still finds adjacent `agents/` files.
- Duplicate agent ID detection works across any extensions already supported.
- No round, compiler, provider, tool, or store behavior changes.

## Phase AF2 - JSON Shells

Status: implemented.

Goal: support JSON workflow and agent shells end to end.

- Parse `.json` shells with `Jason`.
- Require the top-level JSON value to be an object.
- Convert all keys through the same string-key normalization path used by YAML.
- Add JSON fixtures equivalent to the existing YAML workflow and agent fixtures.
- Update `shell validate`, `shell show`, `shell reload`, daemon cache loading,
  and adjacent agent discovery to accept `.json`.
- Update examples with at least one JSON workflow and one JSON agent.

Acceptance:

- `twelvgaige shell validate workflow.json` succeeds for valid JSON shells.
- A JSON workflow can reference JSON, YAML, or later TOML agent shells.
- Malformed JSON, array top-level JSON, and unsupported fields return classified
  shell errors.
- Canonical JSON output from `shell show --format json` is byte-stable enough for
  golden tests after key-order normalization.

## Phase AF3 - TOML Shells

Status: implemented.

Goal: add a readable developer format without adding logic.

- Use `toml_elixir` with `spec: :"1.0.0"`.
- Parse `.toml` workflow and agent shells into the same normalized map.
- Define exact TOML mapping rules:
  - scalar fields become ordinary string-key map entries,
  - `[[shots]]` maps to the workflow `shots` list,
  - `[policy]`, `[retry]`, `[choke]`, `[memory]`, and `[tools]` map to nested maps,
  - arrays remain arrays and do not get implicit splitting,
  - dotted keys are accepted only when the parser returns them as normal nested
    TOML objects.
- Avoid format-specific defaults. Defaults live in shell structs and compiler
  validation.
- Add examples for a compact local TOML workflow and agent pair.

Acceptance:

- TOML, YAML, and JSON variants of the same fixture normalize to the same shell
  map.
- TOML duplicate keys and invalid tables fail before validation.
- Mixed-format agent discovery works.
- No TOML-specific runtime behavior exists.

## Phase AF4 - Programmatic Shell Spike

Status: gating RFC accepted; no runtime is enabled.

Goal: decide whether a safe programmatic authoring language belongs in the
product.

Preferred candidate: Starlark.

RFC: [`programmatic-shell-rfc.md`](programmatic-shell-rfc.md).

Required properties:

- deterministic evaluation,
- no filesystem, network, environment, process, or clock access by default,
- bounded CPU/instruction count,
- bounded memory/output size,
- no dynamic imports except an approved prelude,
- output is a plain object that passes the same shell validation,
- disabled by default until the security review accepts the sandbox.

Implementation approach:

- Add an RFC before code.
- Evaluate library maturity, maintenance, license, and sandbox controls.
- If viable, add a gated loader path behind explicit config such as
  `enable_programmatic_shells?: true`.
- Treat failures as shell validation failures, not round execution failures.
- Store the generated normalized shell hash and source hash in manifests.

Acceptance:

- Sandbox tests prove denied filesystem, env, network, import, and subprocess
  access.
- Infinite loops and oversized generated shells terminate with bounded errors.
- Programmatic shells can only generate a declarative shell map.
- The daemon refuses programmatic shells unless explicitly enabled.

## Phase AF5 - Conversion, Docs, And Examples

Status: implemented for YAML, JSON, and TOML normalize/convert support,
runnable traphouse examples, and package smoke coverage.

Goal: make multiple formats easy to operate without fragmenting examples.

- Add `shell convert <path> --to json|yaml|toml --output <path>`.
- Add `shell normalize <path> --format json` as the canonical review output.
- Document when to choose YAML, JSON, TOML, or gated Starlark.
- Add traphouse examples in at least YAML and JSON, with TOML for one compact
  developer workflow.
- Add mixed-format smoke tests in CI and package smoke targets.

Acceptance:

- Conversion output validates immediately.
- Golden normalized output is stable across equivalent YAML, JSON, and TOML
  inputs.
- Package smoke validates, normalizes, converts, and runs YAML, JSON, and TOML
  traphouse shells through the real CLI.
- Documentation consistently describes “shells” as format-neutral definition
  files.

## Recommended Implementation Order

1. AF0, AF1, AF2, AF3, and the AF4 gating RFC are implemented.
2. AF5 normalize and convert support is implemented for YAML, JSON, and TOML.
3. Future work is examples and a separate sandbox implementation spike if
   programmatic shells become worth the risk.
