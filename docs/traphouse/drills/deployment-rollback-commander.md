# Deployment Rollback Commander

This drill prepares and gates a rollback decision from CI/CD evidence. It reads
deployment logs, release notes, runtime health exports, and rollback procedure,
then pauses before any rollback-oriented action.

## Why It Is Interesting

Rollback decisions are time-sensitive and politically noisy. Twelvgaige can
force a sane order: collect evidence, correlate blast radius, compare rollback
risk, get approval, and only then run a narrow action or handoff.

## Workflow Shape

```yaml
kind: workflow
id: deployment_rollback_commander
version: 1.0.0
shots:
  - id: read_deployment_evidence
    kind: slug
    agent: deployment_reader
    tools: [shell_read, http_get]
    prompt: |
      Read approved deployment logs, pipeline summaries, and deployment
      dashboard URLs. Extract version, commit, environment, started/completed
      times, failed stages, and operator actions.

  - id: read_runtime_health
    kind: slug
    agent: runtime_health_reader
    tools: [shell_read, http_get]
    prompt: |
      Read approved runtime health exports and health URLs. Extract error rate,
      latency, saturation, failed synthetic checks, and affected regions.

  - id: read_rollback_plan
    kind: slug
    agent: rollback_plan_reviewer
    tools: [shell_read]
    prompt: |
      Read the approved rollback runbook and release notes. Extract exact
      rollback command owner, prerequisites, database compatibility, and abort
      criteria. Do not execute commands.

  - id: rollback_decision
    kind: slug
    agent: release_commander
    depends_on:
      - read_deployment_evidence
      - read_runtime_health
      - read_rollback_plan
    prompt: |
      Produce a rollback decision packet with go/no-go recommendation, customer
      impact, rollback risks, prerequisites, and exact human approvals needed.

  - id: rollback_gate
    kind: safety
    depends_on: [rollback_decision]
    description: "Release commander approval before rollback action"

  - id: verification_plan
    kind: slug
    agent: verifier
    depends_on: [rollback_gate]
    tools: [shell_read, http_get]
    prompt: |
      Build the post-rollback verification checklist from approved evidence.
      Do not claim rollback happened unless the input includes execution proof.
```

## CLI Flow

```bash
twelvgaige round run workflows/deployment_rollback_commander.yaml \
  --input '{
    "deployment_log":"artifacts/deploy-prod-2026-05-02.log",
    "pipeline_summary":"artifacts/pipeline-summary.json",
    "health_export":"artifacts/prod-health.json",
    "health_urls":["https://api.example.com/healthz"],
    "rollback_runbook":"docs/runbooks/rollback.md",
    "release_notes":"CHANGELOG.md"
  }' \
  --detach

twelvgaige round watch <round-id> --follow --until-terminal
```

Approve only after command review:

```bash
twelvgaige round approve <round-id> \
  --shot rollback_gate \
  --reason "release commander approved rollback handoff; execution remains external"
```

## Variations

- Add Kubernetes verification shots for workloads after rollback.
- Add a future CI/CD rollback tool only as a destructive, safety-gated shot.
- Add `git_commit` after approval to update incident notes or rollback packet.

## Chokes

- Keep rollback execution external until a narrow rollback tool exists.
- Do not parse free-form CI logs as commands.
- Require database compatibility evidence before recommending rollback.
- Export audit NDJSON into the incident ticket.
