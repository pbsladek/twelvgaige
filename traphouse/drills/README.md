# Twelvgaige Traphouse Drills

The traphouse is the drill rack: practical round patterns, shell snippets,
loadout sketches, and CLI flows for Twelvgaige. Some snippets are intentionally
templates. Adjust providers, models, tool policies, namespaces, chokes, and
safety shots before running them against real systems.

## Drills

- [Kubernetes Incident Response](kubernetes-incident-response.md)
- [Multi-Cluster Failover Rehearsal](multi-cluster-failover-rehearsal.md)
- [Payment Degradation War Room](payment-degradation-war-room.md)
- [Credential Exposure Containment](credential-exposure-containment.md)
- [Supply Chain Provenance Sweep](supply-chain-provenance-sweep.md)
- [Audit Evidence Lockbox](audit-evidence-lockbox.md)
- [AWS IAM Permission Drift Sweep](aws-iam-permission-drift-sweep.md)
- [AWS S3 Exposure Review](aws-s3-exposure-review.md)
- [AWS RDS Maintenance Window Commander](aws-rds-maintenance-window-commander.md)
- [CI Flaky Test Sheriff](ci-flaky-test-sheriff.md)
- [PR Risk And Merge Gate](pr-risk-and-merge-gate.md)
- [Deployment Rollback Commander](deployment-rollback-commander.md)
- [Release Readiness](release-readiness.md)
- [Repository Maintenance](repo-maintenance.md)
- [Local Ollama Analysis](local-ollama-analysis.md)
- [Terraform Plan Review](terraform-plan-review.md)
- [Database Migration Guardrail](database-migration-guardrail.md)
- [Security Patch Triage](security-patch-triage.md)
- [Cloud Cost Patrol](cloud-cost-patrol.md)
- [SLO Error Budget Watch](slo-error-budget-watch.md)
- [Incident Postmortem Draft](incident-postmortem-draft.md)

## Running A Small Known-Good Fixture

For a quick local smoke test, use the runnable traphouse examples:

```bash
mix escript.build
./twelvgaige shell validate traphouse/workflows/simple.yaml
./twelvgaige shell validate traphouse/workflows/simple.json
./twelvgaige shell validate traphouse/workflows/simple.toml
./twelvgaige round run traphouse/workflows/simple.toml --input '{}'
```

Those shells use the `mock` provider, so they never call a live LLM.

## Traphouse Rules

Good Twelvgaige drills should:

- keep workflow routing deterministic,
- split read-only inspection from write-capable remediation,
- add safety shots before destructive tools,
- bound tool output before it reaches the LLM,
- use JSON output when another script will consume results,
- document which parts need live credentials or infrastructure.
