# Cloud Cost Patrol

This drill reviews cost exports or approved billing API snapshots and turns
them into a bounded FinOps report. It is designed for scheduled Breech rounds.

## What It Enables

- Identify unusual spend by service, tag, team, or account.
- Compare current spend against budget and previous periods.
- Suggest owner follow-ups without making cloud changes.
- Run on a schedule without overwhelming a laptop.

## Workflow Shape

```yaml
kind: workflow
id: cloud_cost_patrol
version: 1.0.0
policy:
  resource_profile: minimal
shots:
  - id: read_cost_export
    kind: slug
    agent: cost_reader
    tools:
      - shell_read
    prompt: |
      Read the cost export from round input. Extract spend by service, account,
      environment, and owner tag. Note missing tags.

  - id: anomaly_review
    kind: slug
    agent: finops_reviewer
    depends_on: [read_cost_export]
    prompt: |
      Identify unusual increases, likely causes, and owner follow-ups. Do not
      recommend deleting resources without verification.

  - id: send_review_gate
    kind: safety
    depends_on: [anomaly_review]
    description: "FinOps review before posting or paging anyone"
```

## Scheduler Shape

```elixir
config :twelvgaige, :scheduler_jobs, [
  %{
    id: "cost_patrol_weekday",
    workflow: "workflows/cloud_cost_patrol.yaml",
    input: %{"cost_export" => "exports/daily-cost.json"},
    cron: "0 15 * * 1-5"
  }
]
```

## CLI Flow

```bash
TWELVGAIGE_PROFILE=minimal twelvgaige daemon serve
twelvgaige round list --status complete
twelvgaige round audit <round-id>
```

## Chokes

- Keep this read-only until cloud write tools have explicit safety policies.
- Require tag-owner mappings in input, not model guesses.
- Use retained-byte caps because cost exports can get large.

