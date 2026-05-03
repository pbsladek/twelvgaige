# SLO Error Budget Watch

This drill turns SLO snapshots into an operator-readable round. It can be
scheduled or triggered by a webhook when burn rate crosses a threshold.

## What It Enables

- Summarize availability, latency, and error-budget burn.
- Separate noisy alerts from actionable reliability issues.
- Produce a concise status update for incident channels.
- Escalate through a safety shot before notifications.

## Workflow Shape

```yaml
kind: workflow
id: slo_error_budget_watch
version: 1.0.0
shots:
  - id: gather_slo_snapshot
    kind: slug
    agent: slo_reader
    tools:
      - http_get
      - shell_read
    prompt: |
      Read approved SLO snapshots from input. Extract objective, current value,
      burn rate, window, and linked alerts.

  - id: reliability_review
    kind: slug
    agent: sre_reviewer
    depends_on: [gather_slo_snapshot]
    prompt: |
      Explain whether the service is burning budget, likely causes, and what an
      operator should inspect next. Stay factual.

  - id: notify_gate
    kind: safety
    depends_on: [reliability_review]
    description: "SRE approval before sending a status update"
```

## CLI Flow

```bash
twelvgaige round run workflows/slo_error_budget_watch.yaml \
  --input '{"snapshot":"artifacts/slo.json","service":"checkout"}' \
  --detach

twelvgaige round watch <round-id> --follow --until-terminal
```

## Chokes

- Keep dashboard URLs allowlisted.
- Do not let the model decide whether to page people.
- Require a human safety shot before notification tools.

