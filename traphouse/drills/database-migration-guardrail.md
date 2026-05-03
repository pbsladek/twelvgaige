# Database Migration Guardrail

This drill reviews migration files before a deploy window. The round reads
DDL, identifies lock and rollback risk, then requires DBA or owner approval.

## What It Enables

- Review migration SQL or Ecto migration files.
- Identify table rewrites, long locks, missing indexes, and rollback gaps.
- Produce a preflight checklist for the deployment owner.
- Keep production execution outside the analysis shot.

## Workflow Shape

```yaml
kind: workflow
id: database_migration_guardrail
version: 1.0.0
shots:
  - id: inspect_migrations
    kind: slug
    agent: migration_reader
    tools:
      - shell_read
    prompt: |
      Read migration files from round input. Extract schema changes, data
      changes, indexes, constraints, and rollback behavior.

  - id: risk_check
    kind: slug
    agent: database_reviewer
    depends_on: [inspect_migrations]
    prompt: |
      Classify migration risk for online production deploys. Call out lock
      duration, table size assumptions, rollback plan, and required monitoring.

  - id: dba_safety
    kind: safety
    depends_on: [risk_check]
    description: "DBA or service owner approval before deploy"
```

## Example Input

```json
{
  "database": "payments-prod",
  "migration_files": [
    "priv/repo/migrations/20260501120000_add_payment_index.exs"
  ],
  "estimated_table_rows": {
    "payments": 20000000
  }
}
```

## CLI Flow

```bash
twelvgaige round run workflows/database_migration_guardrail.yaml \
  --input migration-input.json \
  --detach

twelvgaige round watch <round-id> --follow
twelvgaige round approve <round-id> --shot dba_safety --reason "reviewed with DBA"
```

## Chokes

- Do not run SQL from this drill.
- Treat missing rollback as a blocker for high-risk changes.
- Use JSON output in CI if the review must block a merge.

