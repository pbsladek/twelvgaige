# Workflow Shell Examples

These are runnable, no-network shell examples for local smoke testing and format
review. The YAML, JSON, and TOML files describe the same workflow and agent, so
they should normalize to the same canonical shell document and compile to the
same pattern.

## Validate

```bash
twelvgaige shell validate docs/traphouse/workflows/simple.yaml
twelvgaige shell validate docs/traphouse/workflows/simple.json
twelvgaige shell validate docs/traphouse/workflows/simple.toml
twelvgaige shell validate docs/traphouse/workflows/safety.yaml
twelvgaige shell validate docs/traphouse/workflows/shell_authoring_review_readonly.yaml
```

## Normalize

```bash
twelvgaige shell normalize docs/traphouse/workflows/simple.yaml
twelvgaige shell normalize docs/traphouse/workflows/simple.json --format yaml
twelvgaige shell normalize docs/traphouse/workflows/simple.toml --format json
twelvgaige shell fmt docs/traphouse/workflows/simple.yaml --check
twelvgaige shell doctor docs/traphouse/workflows/simple.yaml
twelvgaige shell review docs/traphouse/workflows/simple.yaml --by human:reviewer
```

## Convert

```bash
twelvgaige shell convert docs/traphouse/workflows/simple.yaml --to toml
twelvgaige shell convert docs/traphouse/workflows/simple.toml --to json
```

## Run

The workflow uses the `mock` provider and auto-discovers agents from
`docs/traphouse/workflows/agents/`, so it does not call a live LLM:

```bash
twelvgaige round run docs/traphouse/workflows/simple.yaml
twelvgaige round run docs/traphouse/workflows/simple.json
twelvgaige round run docs/traphouse/workflows/simple.toml
twelvgaige round run docs/traphouse/workflows/safety.yaml --approve-safety
twelvgaige round run docs/traphouse/workflows/shell_authoring_review_readonly.yaml
```

## Authoring Review

`shell_authoring_review_readonly.yaml` demonstrates SAM5's read-only authoring
tools. Its agents are mock agents with access to shell validation, graph, lint,
inventory, impact, normalize, diff, catalog-read, and patch-plan tools. The
workflow is safe to run locally because no tool writes files.

## Drafting

`shell draft` can turn local notes into a candidate shell without executing it.
The default mock provider is offline and deterministic; hosted providers require
`--allow-remote` and receive redacted source text.

```bash
twelvgaige shell draft --from incident-notes.md
twelvgaige shell draft --from incident-notes.md --output docs/traphouse/workflows/incident-draft.yaml --write
```

For an existing workflow or collection, use hosted authoring review to produce a
read-only patch plan. Hosted providers require explicit consent:

```bash
twelvgaige shell author review docs/traphouse --root docs/traphouse
twelvgaige shell author review docs/traphouse --root docs/traphouse --provider openai --model gpt-4.1 --allow-remote
```

The command prints provider/model disclosure, source/redacted byte counts,
exposed read-only authoring tools, and a digest-bound patch plan. It does not
apply changes.

Structured patch artifacts can be inspected, verified, rehearsed, and then
applied with an explicit approval:

```bash
twelvgaige shell patch inspect patch.json
twelvgaige shell patch verify patch.json --root docs/traphouse --approval approval.json
twelvgaige shell patch apply patch.json --root docs/traphouse
twelvgaige shell patch apply patch.json --root docs/traphouse --approval approval.json --write
```

Verification checks path policy, current file digests, proposed content digests,
candidate shell validity, strict workflow lint, and optional approval binding.
`shell patch apply` without `--write` is a dry-run rehearsal that returns the
verify report with `changed: false`. `shell patch apply --write` requires a
matching human approval, writes through atomic sibling temp files, and verifies
the final target digest after each replacement. The write path also reruns
declared safe validation commands and includes a local tamper-evident audit
checkpoint in JSON output.

## Shot Libraries

Repo-local shot templates live in `docs/traphouse/shots/`. They are authoring
inputs copied into workflow shells; runtime rounds do not load templates.

```bash
twelvgaige shot library list --library-path docs/traphouse/shots
twelvgaige shot library show platform/review.summary --library-path docs/traphouse/shots
twelvgaige shot library verify --root docs/traphouse
twelvgaige shot library outdated docs/traphouse --root docs/traphouse
```

Repo-local scaffolds live in `docs/traphouse/scaffolds/`. They expand into
ordinary workflow shells and use the same `twelvgaige-library.lock` file as shot
templates.

```bash
twelvgaige shell scaffold list --root docs/traphouse
twelvgaige shell scaffold show platform/release-readiness --root docs/traphouse
twelvgaige shell new release-check --scaffold platform/release-readiness --root docs/traphouse
twelvgaige shell scaffold verify --root docs/traphouse
```

## Format Guidance

- YAML is easiest for hand-authored operator shells.
- JSON is best for generated shells and CI review.
- TOML is compact for developer-local shells with simple nested structure.
- Programmatic shells are intentionally disabled until the sandbox requirements
  in `docs/design/programmatic-shell-rfc.md` are implemented and tested.
