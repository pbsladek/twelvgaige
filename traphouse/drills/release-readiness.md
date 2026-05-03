# Release Readiness

This drill uses agents as structured reviewers for a release candidate. It
does not let the model ship the release; it produces a bounded readiness report
and can pause on a safety gate before tagging or deployment.

## What It Enables

- Summarize test results, changed files, and release notes.
- Highlight risk areas for the release owner.
- Produce JSON output that CI can inspect.
- Keep final approval outside the LLM.

## Workflow Shape

```yaml
kind: workflow
id: release_readiness
version: 1.0.0
shots:
  - id: collect_release_context
    kind: slug
    agent: release_reader
    tools:
      - shell_read
    prompt: |
      Read the release notes, test summary, and deployment checklist paths from
      the round input. Extract relevant facts and missing data.

  - id: risk_review
    kind: slug
    agent: release_reviewer
    depends_on: [collect_release_context]
    prompt: |
      Produce a readiness review with blockers, non-blocking risks, rollback
      concerns, and a recommended go/no-go decision.

  - id: release_owner_approval
    kind: safety
    depends_on: [risk_review]
    description: "Release owner approval before publishing"
```

## Example Input

```json
{
  "release_notes": "CHANGELOG.md",
  "test_summary": "artifacts/test-summary.json",
  "deployment_checklist": "docs/deploy.md"
}
```

## CLI Flow

Foreground review:

```bash
twelvgaige round run workflows/release_readiness.yaml \
  --input release-input.json \
  --format json
```

Detached review with approval:

```bash
twelvgaige daemon serve
twelvgaige round run workflows/release_readiness.yaml --input release-input.json --detach
twelvgaige round watch <round-id> --follow
twelvgaige round approve <round-id> --shot release_owner_approval --reason "approved for rc"
```

## Useful Variations

- Add a `shell_read` shot for migration plans.
- Add `http_get` for internal release dashboards if network policy allows it.
- Add a final `git_commit` or tag-producing step only after safety and audit
  requirements are settled.
- Run this in CI with `--format json` and deterministic exit codes.
