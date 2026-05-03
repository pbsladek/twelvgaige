# AWS RDS Maintenance Window Commander

This drill prepares a database maintenance window by reading approved AWS/RDS
exports, migration notes, recent incidents, and rollback plans. It produces a
go/no-go packet and pauses before any operational action.

## Why It Is Interesting

Database maintenance crosses teams: app owners, DBAs, support, and incident
commanders. Agents can summarize different evidence lanes, while Twelvgaige
ensures the maintenance recommendation is built only after all prerequisites
complete.

## Workflow Shape

```yaml
kind: workflow
id: aws_rds_maintenance_window_commander
version: 1.0.0
shots:
  - id: read_rds_inventory
    kind: slug
    agent: rds_reader
    tools: [shell_read]
    prompt: |
      Read approved RDS instance and cluster exports. Extract engine versions,
      pending maintenance, backup status, multi-AZ, replica lag, and storage
      pressure. Do not recommend action yet.

  - id: read_change_plan
    kind: slug
    agent: change_plan_reviewer
    tools: [shell_read]
    prompt: |
      Read the approved maintenance plan, migration notes, and rollback plan.
      Extract prerequisites, expected downtime, owner approvals, and rollback
      triggers.

  - id: read_recent_health
    kind: slug
    agent: incident_reader
    tools: [shell_read, http_get]
    prompt: |
      Read approved incident summaries and health dashboards. Extract recent
      database or application instability that should affect go/no-go.

  - id: maintenance_decision
    kind: slug
    agent: dba_commander
    depends_on:
      - read_rds_inventory
      - read_change_plan
      - read_recent_health
    prompt: |
      Produce a maintenance go/no-go packet with blockers, risk level,
      rollback readiness, monitoring checks, and exact human approvals needed.

  - id: dba_gate
    kind: safety
    depends_on: [maintenance_decision]
    description: "DBA approval before any maintenance execution round"
```

## Example Evidence Exports

```bash
aws rds describe-db-instances > evidence/rds-instances.json
aws rds describe-db-clusters > evidence/rds-clusters.json
aws rds describe-pending-maintenance-actions > evidence/rds-maintenance.json
aws cloudwatch describe-alarms --alarm-name-prefix prod-rds \
  > evidence/rds-alarms.json
```

## CLI Flow

```bash
twelvgaige round run workflows/aws_rds_maintenance_window_commander.yaml \
  --input '{
    "rds_instances":"evidence/rds-instances.json",
    "rds_clusters":"evidence/rds-clusters.json",
    "pending_maintenance":"evidence/rds-maintenance.json",
    "change_plan":"changes/rds-maintenance-2026-05.md",
    "rollback_plan":"changes/rds-rollback.md"
  }' \
  --detach
```

## Future Native AWS Tools

- `aws_rds_describe_db_instances`
- `aws_rds_describe_pending_maintenance_actions`
- `aws_cloudwatch_describe_alarms`
- `aws_cloudtrail_lookup_events`

Execution tools should be separate from this drill and require a safety shot,
idempotency keys where possible, and explicit account/region/runtime policy.

## Chokes

- This is a planning and evidence drill, not an execution drill.
- Do not let the model choose an AWS account or region.
- Require backup freshness and rollback evidence before any go recommendation.
- Store the audit export with the change ticket.
