# Audit Evidence Lockbox

This drill builds an evidence packet for compliance, customer assurance, or an
internal incident review. It collects approved logs and round history, redacts
sensitive fields, produces a concise evidence index, and pauses before export.

## Why It Shows The Power

Evidence gathering needs repeatability more than creativity. Twelvgaige can
turn messy operational records into a deterministic, auditable round where
agents summarize, but the workflow controls what gets read and when export is
approved.

## Workflow Shape

```yaml
kind: workflow
id: audit_evidence_lockbox
version: 1.0.0
shots:
  - id: collect_round_history
    kind: slug
    agent: audit_reader
    tools: [shell_read]
    prompt: |
      Read approved exported round watch/audit files. Extract round IDs, state
      transitions, safety decisions, actors, timestamps, and terminal status.

  - id: collect_operational_artifacts
    kind: slug
    agent: evidence_reader
    tools: [shell_read]
    prompt: |
      Read approved operational artifacts such as incident notes, change tickets,
      and SLO snapshots. Redact credentials, tokens, cookies, and customer data.

  - id: verify_live_context
    kind: slug
    agent: k8s_inspector
    tools: [kubectl_get, kubectl_events]
    prompt: |
      Inspect only approved namespaces for current workload status and recent
      events. Do not read secrets or logs unless the input explicitly approves.

  - id: build_evidence_index
    kind: slug
    agent: compliance_writer
    depends_on:
      - collect_round_history
      - collect_operational_artifacts
      - verify_live_context
    prompt: |
      Build an evidence index with source file, timestamp, claim supported,
      redaction notes, open gaps, and reviewer questions. Do not invent missing
      evidence.

  - id: export_gate
    kind: safety
    depends_on: [build_evidence_index]
    description: "Owner approval before sharing the evidence packet"

  - id: commit_packet
    kind: slug
    agent: repo_maintainer
    depends_on: [export_gate]
    tools: [git_commit]
    prompt: |
      If approved, commit only the explicitly prepared evidence index files from
      round input. Do not commit raw logs, raw audit exports, or secret-bearing
      artifacts.
```

## CLI Flow

Export raw round material first:

```bash
twelvgaige round watch <source-round-id> --format ndjson > evidence/watch.ndjson
twelvgaige round audit <source-round-id> --format ndjson > evidence/audit.ndjson
```

Build the lockbox packet:

```bash
twelvgaige round run workflows/audit_evidence_lockbox.yaml \
  --input '{
    "round_exports":["evidence/watch.ndjson","evidence/audit.ndjson"],
    "artifact_files":["incidents/summary.md","slo/payments-weekly.json"],
    "context":"prod-us-east",
    "namespace":"payments",
    "approved_commit_paths":["evidence/index.md"]
  }' \
  --detach
```

Review and approve:

```bash
twelvgaige round show <round-id>
twelvgaige round audit <round-id>
twelvgaige round approve <round-id> --shot export_gate --reason "approved redacted index only"
```

## Safety Notes

- Treat raw exports as sensitive until Pass 3 audit integrity and retention work
  is complete.
- Commit only redacted indexes, not raw logs.
- Keep file roots narrow and review `approved_commit_paths` before approval.
- Use this drill to test canary-secret redaction across docs, audit, and watch
  outputs.
