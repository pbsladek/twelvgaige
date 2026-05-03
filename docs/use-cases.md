# Use Cases

Twelvgaige is most useful when an agent workflow needs to run like operational
software instead of a chat session: bounded, inspectable, restartable, and
guarded by policy.

## Kubernetes Incident Triage

Pattern:

1. Collect pod status, events, resource usage, and bounded logs.
2. Ask an analysis agent for likely causes and confidence.
3. Pause on a safety shot if remediation is risky.
4. Apply a narrow approved action.
5. Verify recovery and write an audit trail.

Why Twelvgaige helps:

- `kubectl_*` tools are structured and safety-classified.
- Tool output is bounded before it re-enters model context.
- Approval is a workflow node, not a model suggestion.
- Watch and audit streams give operators a live view and a record.

See [Kubernetes Incident Response](traphouse/drills/kubernetes-incident-response.md).

## Release Readiness Review

Pattern:

1. Read release notes, changed files, test output, and deployment plan.
2. Summarize risk areas.
3. Produce a structured readiness decision.
4. Require a human gate before tagging or deploying.

Why Twelvgaige helps:

- The model can summarize messy project state.
- CI can consume JSON output and deterministic exit codes.
- A failed or halted round is visible to scripts without parsing prose.

See [Release Readiness](traphouse/drills/release-readiness.md).

## Repository Maintenance

Pattern:

1. Inspect selected files.
2. Draft a small change plan.
3. Run tests through a controlled workflow.
4. Optionally create a narrow commit.

Why Twelvgaige helps:

- `shell_read` and Git tools keep file access bounded.
- `git_commit` is explicit and destructive, so it belongs behind safety policy.
- Audit records capture what the agent inspected and attempted.

See [Repository Maintenance](traphouse/drills/repo-maintenance.md).

## Local LLM Triage With Ollama

Pattern:

1. Use local Ollama for logs, reports, or internal text.
2. Keep data on the machine.
3. Apply the same workflow semantics as cloud providers.

Why Twelvgaige helps:

- Provider IDs are explicit, so model names do not silently switch backends.
- The same shell can be moved from `ollama` to a cloud provider later.
- Laptop resource profiles prevent local LLM calls from overwhelming the host.

See [Local Ollama Analysis](traphouse/drills/local-ollama-analysis.md).

## Terraform Plan Review

Pattern:

1. Read a generated Terraform plan JSON.
2. Summarize adds, changes, replacements, destroys, and IAM/network exposure.
3. Classify blast radius.
4. Require a safety shot before any apply-oriented workflow.

Why Twelvgaige helps:

- The round stays read-only.
- The analysis can be attached to CI or PR review as JSON.
- Apply is kept out of the reviewer loadout.

See [Terraform Plan Review](traphouse/drills/terraform-plan-review.md).

## Database Migration Guardrail

Pattern:

1. Read migration files.
2. Identify lock, rewrite, rollback, and data-risk concerns.
3. Produce a preflight checklist.
4. Require DBA or owner safety approval before deploy.

Why Twelvgaige helps:

- Migration review stays deterministic and auditable.
- Human approval is explicit.
- No SQL execution is needed in the review round.

See [Database Migration Guardrail](traphouse/drills/database-migration-guardrail.md).

## Security Patch Triage

Pattern:

1. Read advisory output or approved advisory URLs.
2. Map vulnerable packages to services and owners.
3. Prioritize emergency versus scheduled patch work.
4. Gate patch execution behind a safety shot.

Why Twelvgaige helps:

- Alerts become structured triage instead of free-form chat.
- Network fetches can be allowlisted.
- Patch actions can live in a separate, guarded round.

See [Security Patch Triage](traphouse/drills/security-patch-triage.md).

## Cloud Cost Patrol

Pattern:

1. Read cost exports on a schedule.
2. Compare spend by service, account, owner, and tag.
3. Identify anomalies and missing ownership data.
4. Require review before posting or paging.

Why Twelvgaige helps:

- Breech can run scheduled rounds with laptop-safe resource profiles.
- Large exports stay bounded by retained-byte and tool-output chokes.
- The model suggests follow-up, not cloud changes.

See [Cloud Cost Patrol](traphouse/drills/cloud-cost-patrol.md).

## SLO Error Budget Watch

Pattern:

1. Read approved SLO snapshots or alert artifacts.
2. Summarize burn rate and likely reliability risk.
3. Produce an operator update.
4. Use a safety shot before notification tools.

Why Twelvgaige helps:

- Watch/audit streams give SREs live context.
- Notification remains a controlled workflow step.
- The LLM cannot decide paging policy.

See [SLO Error Budget Watch](traphouse/drills/slo-error-budget-watch.md).

## Incident Postmortem Draft

Pattern:

1. Read incident timeline, alerts, deploy notes, and impact evidence.
2. Draft a blameless postmortem.
3. Mark uncertain claims separately from facts.
4. Require incident-lead review before sharing.

Why Twelvgaige helps:

- Evidence collection is bounded and auditable.
- Sensitive conclusions stay behind safety review.
- The output shape can be consistent across incidents.

See [Incident Postmortem Draft](traphouse/drills/incident-postmortem-draft.md).

## Scheduled Operational Reports

Pattern:

1. Breech runs a workflow every interval or UTC cron schedule.
2. The workflow collects infrastructure state.
3. An agent writes a bounded summary.
4. Operators inspect watch/audit records when something looks wrong.

Why Twelvgaige helps:

- Scheduled jobs run through the same Breech control plane as manual rounds.
- Durable state keeps history available after terminal rounds.
- Resource profiles keep scheduled work from fighting interactive work.

## Guarded Remediation

Pattern:

1. Read-only inspection round gathers facts.
2. Analysis round recommends action.
3. Safety shot pauses for approval.
4. Write-capable shot executes only narrow tools.
5. Verification shot confirms the effect.

Why Twelvgaige helps:

- Read and write capabilities can be split across different shots and agents.
- Retry policy can differ for read-only, idempotent, and destructive actions.
- Ambiguous crash windows become reconciliation events instead of silent retries.

## What Not To Use It For

Twelvgaige is not trying to be a general chat assistant or an autonomous shell.
Avoid workflows where:

- the model needs unrestricted shell command authority,
- the desired behavior is an open-ended conversation,
- the state can live only in the prompt,
- safety decisions are delegated to the model.

Those constraints are deliberate. They keep the tool useful for unattended or
semi-attended infrastructure workflows.
