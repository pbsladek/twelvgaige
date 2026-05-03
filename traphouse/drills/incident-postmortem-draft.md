# Incident Postmortem Draft

This drill drafts a postmortem from existing evidence. It does not decide
accountability or final root cause; it assembles a first pass for humans.

## What It Enables

- Collect timeline notes, alert snapshots, deploy history, and chat exports.
- Draft impact, detection, response, contributing factors, and follow-ups.
- Keep sensitive conclusions behind a review shot.
- Produce a consistent post-incident artifact.

## Workflow Shape

```yaml
kind: workflow
id: incident_postmortem_draft
version: 1.0.0
shots:
  - id: collect_evidence
    kind: slug
    agent: postmortem_reader
    tools:
      - shell_read
    prompt: |
      Read incident evidence paths from round input. Extract only factual
      timeline entries, alerts, deploys, actions, and observed customer impact.

  - id: draft_postmortem
    kind: slug
    agent: postmortem_writer
    depends_on: [collect_evidence]
    prompt: |
      Draft a blameless postmortem. Mark uncertain claims clearly and list open
      questions separately from confirmed facts.

  - id: incident_lead_review
    kind: safety
    depends_on: [draft_postmortem]
    description: "Incident lead review before sharing draft"
```

## Example Input

```json
{
  "incident_id": "INC-2026-05-02",
  "evidence": [
    "incidents/INC-2026-05-02/timeline.md",
    "incidents/INC-2026-05-02/alerts.json",
    "incidents/INC-2026-05-02/deploys.md"
  ]
}
```

## CLI Flow

```bash
twelvgaige round run workflows/incident_postmortem_draft.yaml \
  --input incident-input.json \
  --format json
```

## Chokes

- Treat chat exports and customer impact notes as sensitive.
- Keep raw evidence bounded and redacted.
- Require incident-lead review before publishing the draft.

