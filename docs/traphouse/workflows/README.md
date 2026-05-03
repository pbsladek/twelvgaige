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
```

## Normalize

```bash
twelvgaige shell normalize docs/traphouse/workflows/simple.yaml
twelvgaige shell normalize docs/traphouse/workflows/simple.json --format yaml
twelvgaige shell normalize docs/traphouse/workflows/simple.toml --format json
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
```

## Format Guidance

- YAML is easiest for hand-authored operator shells.
- JSON is best for generated shells and CI review.
- TOML is compact for developer-local shells with simple nested structure.
- Programmatic shells are intentionally disabled until the sandbox requirements
  in `docs/design/programmatic-shell-rfc.md` are implemented and tested.
