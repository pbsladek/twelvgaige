# Core Concepts

## Vocabulary

| Term | Meaning |
| --- | --- |
| Shell | Workflow or agent definition file. YAML, JSON, and TOML are implemented. |
| Round | One execution of a workflow shell. |
| Shot | One executable step inside a round. |
| Safety shot | A human or policy approval checkpoint. |
| Choke | A limit or policy on a shot, such as timeout, retry, token budget, or tool safety. |
| Breech | The local daemon that owns detached rounds, event replay, audit, and safety decisions. |

## Deterministic Control Plane

The LLM does not choose the workflow path. Twelvgaige compiles the workflow
shell into a DAG and Elixir decides:

- which shots are ready,
- which dependencies are complete,
- whether a retry is allowed,
- when a timeout fires,
- whether a safety gate must pause,
- whether persisted state is safe to advance.

LLM output is treated as data. It may influence later prompts through structured
outputs, but it does not get authority to route the round.

## Workflow Shells

A workflow shell declares shots. This example is shown in YAML:

```yaml
kind: workflow
id: simple
version: 1.0.0
shots:
  - id: first
    kind: slug
    agent: local_agent
    prompt: first prompt

  - id: second
    kind: slug
    agent: local_agent
    depends_on: [first]
    prompt: second prompt
```

The same shell can be authored as JSON or TOML. See
[Shell Formats](shell-formats.md) for examples and conversion commands.

Validate before running:

```bash
twelvgaige shell validate workflows/simple.yaml
```

## Agent Shells

Agent shells define provider, model, prompt, and policy defaults:

```yaml
kind: agent
id: local_agent
version: 1.0.0
provider: ollama
model: llama3.2
system_prompt: Keep responses short and factual.
```

Supported provider IDs are `openai` and `ollama`. Tests use an internal,
deterministic adapter that is not compiled into production builds. Live provider
credentials are runtime configuration, not shell fields; see
[Secrets And Providers](secrets-and-providers.md).

## Tools

Built-in tools are narrow, structured operations. They are not arbitrary shell
strings.

Current tool names:

- `kubectl_get`, `kubectl_describe`, `kubectl_logs`, `kubectl_events`
- `kubectl_apply`, `kubectl_delete`, `kubectl_rollout_restart`, `kubectl_scale`, `kubectl_exec`
- `http_get`, `http_post`
- `shell_read`
- `git_commit`
- `shell_validate`, `shell_graph`, `shell_lint`, `shell_inventory`,
  `shell_impact`, `shell_diff`, `shell_normalize`, `tool_catalog_read`, and
  `patch_plan` for read-only assisted authoring

Each tool declares safety level and input schema. A shot must explicitly allow
the tool and the active choke must allow the tool safety level.

## Safety

Safety shots are explicit workflow nodes. They pause the round until a human or
policy decision arrives:

```yaml
shots:
  - id: approval
    kind: safety
    description: "Review before continuing"

  - id: apply_change
    kind: slug
    agent: remediator
    depends_on: [approval]
    tools: [kubectl_apply]
    prompt: "Apply the approved remediation."
```

This keeps the approval boundary outside the model. The LLM cannot skip or
approve its own gate.

## Watch, Audit, And Logs

Twelvgaige separates operational signals:

- Watch events show round progress.
- Audit events are durable evidence of transitions, attempts, tool calls, and
  safety decisions.
- Metrics show runtime health and resource pressure.
- Logs are for operator diagnosis.

Use watch for live UX:

```bash
twelvgaige round watch <round-id> --follow --until-terminal
```

Use audit for evidence:

```bash
twelvgaige round audit <round-id> --format ndjson
```

## Persistence And Recovery

Foreground runs can use in-memory state. Daemon workflows can use durable file
or SQLite stores. SQLite is the local laptop-oriented durable path.

On restart, in-flight OS processes are gone. Twelvgaige reconciles durable state
instead of pretending old shot tasks still exist. Ambiguous side effects move to
manual reconciliation rather than being retried blindly.

## Delegated Agent Sessions

The optional single-user manager and operations APIs can delegate a bounded
coding task to Codex. The delegated runtime manages its own context, tools, and
native subagents inside an outer Podman or Apple container boundary. Twelvgaige
retains authority over admission, workspace isolation, credentials, network
access, budgets, approvals, cancellation, recovery, and result verification.
The current CLI manages registered sessions but does not provide a standalone
`session start` command.

Delegated sessions complement provider-native shots; they do not silently
replace them or act as a fallback. Podman is the default backend. Apple
containers are selected explicitly on qualified macOS hosts.
