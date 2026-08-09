# Shell Formats

Twelvgaige shell files are format-neutral workflow or agent definitions. YAML,
JSON, and TOML all load into the same internal structs and have the same runtime
semantics. The format only changes how developers author the file.

Use the format that fits the source:

- YAML is compact for hand-written operational workflows.
- JSON is useful for generated shells, API-driven tooling, and strict diffing.
- TOML is readable for developers who prefer config-file style sections.

The canonical examples live in [`docs/traphouse/workflows`](traphouse/workflows).

## Commands

Validate any supported shell:

```bash
twelvgaige shell validate docs/traphouse/workflows/simple.json
twelvgaige shell validate docs/traphouse/workflows/simple.toml
```

Run any supported workflow shell:

```bash
twelvgaige round run docs/traphouse/workflows/simple.json
twelvgaige round run docs/traphouse/workflows/simple.toml
```

Normalize or convert between formats:

```bash
twelvgaige shell normalize docs/traphouse/workflows/simple.toml --format json
twelvgaige shell convert docs/traphouse/workflows/simple.yaml --to toml
twelvgaige shell convert docs/traphouse/workflows/simple.toml --to yaml
```

## JSON Workflow

JSON shells are best when another program writes the workflow. They avoid YAML
edge cases and preserve a strict object/list shape.

```json
{
  "kind": "workflow",
  "id": "simple",
  "name": "Simple Format Demo",
  "version": "1.0.0",
  "shots": [
    {
      "id": "first",
      "kind": "slug",
      "agent": "local_agent",
      "prompt": "first prompt"
    },
    {
      "id": "second",
      "kind": "slug",
      "agent": "local_agent",
      "depends_on": ["first"],
      "prompt": "second prompt"
    }
  ]
}
```

## JSON Agent

```json
{
  "kind": "agent",
  "id": "local_agent",
  "name": "Local Ollama Agent",
  "version": "1.0.0",
  "provider": "ollama",
  "model": "llama3.2",
  "system_prompt": "Run the local shot."
}
```

## TOML Workflow

TOML shells are useful when the workflow should read like a config file. Each
shot is represented with `[[shots]]`.

```toml
kind = "workflow"
id = "simple"
name = "Simple Format Demo"
version = "1.0.0"

[[shots]]
id = "first"
kind = "slug"
agent = "local_agent"
prompt = "first prompt"

[[shots]]
id = "second"
kind = "slug"
agent = "local_agent"
depends_on = ["first"]
prompt = "second prompt"
```

## TOML Agent

```toml
kind = "agent"
id = "local_agent"
name = "Local Ollama Agent"
version = "1.0.0"
provider = "ollama"
model = "llama3.2"
system_prompt = "Run the local shot."
```

## Nested Policy Example

Nested maps become TOML tables. This workflow sets a resource profile and a
shot choke policy:

```toml
kind = "workflow"
id = "guarded_review"
version = "1.0.0"

[policy]
resource_profile = "minimal"
on_shot_failure = "fail_round"
on_safety_reject = "halt_round"

[[shots]]
id = "review"
kind = "slug"
agent = "local_agent"
prompt = "Review the input and summarize risk."

[shots.choke]
max_iterations = 2
tool_safety = "read_only"
audit = "summary"
```

The equivalent JSON shape is:

```json
{
  "kind": "workflow",
  "id": "guarded_review",
  "version": "1.0.0",
  "policy": {
    "resource_profile": "minimal",
    "on_shot_failure": "fail_round",
    "on_safety_reject": "halt_round"
  },
  "shots": [
    {
      "id": "review",
      "kind": "slug",
      "agent": "local_agent",
      "prompt": "Review the input and summarize risk.",
      "choke": {
        "max_iterations": 2,
        "tool_safety": "read_only",
        "audit": "summary"
      }
    }
  ]
}
```

## Agent Discovery

Adjacent agent discovery works for all supported formats. Given a workflow at:

```text
workflows/review.toml
```

Twelvgaige will discover agents in:

```text
workflows/agents/*.yaml
workflows/agents/*.yml
workflows/agents/*.json
workflows/agents/*.toml
```

For untrusted repositories, disable discovery and pass reviewed agent shells
explicitly:

```bash
twelvgaige round run ./downloaded/workflow.json \
  --untrusted-root \
  --agent-shell ./reviewed-agents/local_agent.toml
```

## Rules

- `kind` must be `workflow` or `agent`.
- File extension controls parser selection: `.yaml`, `.yml`, `.json`, `.toml`.
- JSON and TOML do not add different runtime behavior.
- Secrets do not belong in any shell format. Use provider environment variables
  or trusted runtime config instead.
- Programmatic shell languages are intentionally not enabled. See
  [`programmatic-shell-rfc.md`](design/programmatic-shell-rfc.md).
