# Terraform Plan Review

This drill keeps infrastructure-as-code review deterministic: capture the
plan, analyze blast radius, pause on safety, then optionally hand off to a human
or a separate apply workflow.

## What It Enables

- Summarize a Terraform plan without letting the model run `apply`.
- Detect destructive changes, unmanaged drift, and risky provider operations.
- Produce a concise review that can be attached to a pull request.
- Keep the apply decision outside the LLM.

## Workflow Shape

```yaml
kind: workflow
id: terraform_plan_review
version: 1.0.0
shots:
  - id: read_plan
    kind: slug
    agent: iac_reader
    tools:
      - shell_read
    prompt: |
      Read the Terraform plan JSON path from round input. Extract resources to
      add, change, replace, and destroy. Report module path, provider, and risk.

  - id: blast_radius
    kind: slug
    agent: infra_reviewer
    depends_on: [read_plan]
    prompt: |
      Classify the plan by blast radius. Call out destructive or replacement
      actions, IAM changes, network exposure, and state movement.

  - id: apply_gate
    kind: safety
    depends_on: [blast_radius]
    description: "Infra owner approval before any apply-oriented round"
```

## CLI Flow

```bash
terraform plan -out=tfplan
terraform show -json tfplan > tfplan.json

twelvgaige round run workflows/terraform_plan_review.yaml \
  --input '{"plan_json":"tfplan.json","workspace":"prod"}' \
  --detach

twelvgaige round show <round-id>
twelvgaige round audit <round-id>
```

## Chokes

- Keep this drill read-only.
- Use `shell_read`, not free-form shell execution.
- Put any future `terraform_apply` tool in a separate loadout behind a safety
  shot and durable journaling.

