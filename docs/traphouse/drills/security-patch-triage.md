# Security Patch Triage

This drill turns dependency or advisory noise into an auditable triage round.
It reads advisories and dependency metadata, ranks urgency, and prepares a
patch plan for humans to review.

## What It Enables

- Triage CVEs, Dependabot alerts, or package-audit output.
- Map vulnerable packages to services and owners.
- Separate emergency fixes from scheduled patch work.
- Keep patch application behind an explicit safety shot.

## Workflow Shape

```yaml
kind: workflow
id: security_patch_triage
version: 1.0.0
shots:
  - id: collect_alerts
    kind: slug
    agent: security_reader
    tools:
      - shell_read
      - http_get
    prompt: |
      Read advisory files or fetch approved advisory URLs from round input.
      Extract package, affected versions, fixed versions, severity, and exploit
      maturity. Do not modify files.

  - id: prioritize
    kind: slug
    agent: security_reviewer
    depends_on: [collect_alerts]
    prompt: |
      Rank alerts by exposure, exploitability, service criticality, and patch
      effort. Produce an owner-ready patch queue.

  - id: patch_gate
    kind: safety
    depends_on: [prioritize]
    description: "Security owner approval before patch work"
```

## CLI Flow

```bash
twelvgaige round run workflows/security_patch_triage.yaml \
  --input '{"advisory_file":"artifacts/audit.json","service":"api"}' \
  --format json
```

Detached:

```bash
twelvgaige daemon serve
twelvgaige round run workflows/security_patch_triage.yaml \
  --input security-input.json \
  --detach
twelvgaige round audit <round-id>
```

## Chokes

- Allow `http_get` only for trusted advisory hosts.
- Keep any package update tool in a later guarded round.
- Redact tokens and internal repository URLs from logs and audit output.

