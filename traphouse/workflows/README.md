# Workflow Shell Examples

These are runnable, no-network shell examples for local smoke testing and format
review. The YAML, JSON, and TOML files describe the same workflow and agent, so
they should normalize to the same canonical shell document and compile to the
same pattern.

## Validate

```bash
twelvgaige shell validate traphouse/workflows/simple.yaml
twelvgaige shell validate traphouse/workflows/simple.json
twelvgaige shell validate traphouse/workflows/simple.toml
```

## Normalize

```bash
twelvgaige shell normalize traphouse/workflows/simple.yaml
twelvgaige shell normalize traphouse/workflows/simple.json --format yaml
twelvgaige shell normalize traphouse/workflows/simple.toml --format json
```

## Convert

```bash
twelvgaige shell convert traphouse/workflows/simple.yaml --to toml
twelvgaige shell convert traphouse/workflows/simple.toml --to json
```

## Run

The workflow uses the `mock` provider and auto-discovers agents from
`traphouse/workflows/agents/`, so it does not call a live LLM:

```bash
twelvgaige round run traphouse/workflows/simple.yaml --input '{}'
twelvgaige round run traphouse/workflows/simple.json --input '{}'
twelvgaige round run traphouse/workflows/simple.toml --input '{}'
```

## Format Guidance

- YAML is easiest for hand-authored operator shells.
- JSON is best for generated shells and CI review.
- TOML is compact for developer-local shells with simple nested structure.
- Programmatic shells are intentionally disabled until the sandbox requirements
  in `docs/design/programmatic-shell-rfc.md` are implemented and tested.
