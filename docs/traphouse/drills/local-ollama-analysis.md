# Local Ollama Analysis

This drill uses Ollama for local analysis where data should stay on the
machine. The workflow semantics are the same as cloud providers: deterministic
shots, bounded inputs, resource profiles, and audit records.

## What It Enables

- Summarize local logs or reports without sending data to a cloud provider.
- Run repeatable analysis on a laptop.
- Keep provider selection explicit in the agent shell.
- Later swap the provider to Anthropic, OpenAI, or Gemini without changing the
  workflow DAG.

## Agent Shell

```yaml
kind: agent
id: local_analyst
version: 1.0.0
provider: ollama
model: llama3.1
system_prompt: |
  You analyze local diagnostic text. Stay factual, cite the input sections you
  used, and return concise operational findings.
```

## Workflow Shape

```yaml
kind: workflow
id: local_log_triage
version: 1.0.0
shots:
  - id: read_logs
    kind: slug
    agent: local_analyst
    tools:
      - shell_read
    prompt: |
      Read the log path from round input. Extract errors, timestamps, affected
      components, and suspected root cause. Do not recommend destructive action.

  - id: operator_review
    kind: safety
    depends_on: [read_logs]
    description: "Operator review of local analysis"
```

## CLI Flow

Use a conservative resource profile for local LLM work:

```bash
TWELVGAIGE_PROFILE=minimal twelvgaige round run workflows/local_log_triage.yaml \
  --input '{"path":"logs/service.log"}' \
  --agent-shell agents/local_analyst.yaml \
  --format json
```

Detached run:

```bash
TWELVGAIGE_PROFILE=minimal twelvgaige daemon serve
twelvgaige round run workflows/local_log_triage.yaml \
  --input '{"path":"logs/service.log"}' \
  --agent-shell agents/local_analyst.yaml \
  --detach
twelvgaige round watch <round-id> --follow --until-terminal
```

## Notes

- Ollama must be running and reachable by the configured provider transport.
- Keep local log reads bounded. Large logs should be chunked or prefiltered.
- The model may be local, but the workflow still needs safety and audit if it
  drives later operations.
