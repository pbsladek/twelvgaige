# PR Risk And Merge Gate

This drill reviews a pull request as a deterministic multi-shot gate. It reads
diffs, test output, ownership files, migration notes, and release impact, then
pauses before any merge or commit-producing action.

## Why It Is Interesting

PR review is a natural agent use case, but the model should not own the merge.
Twelvgaige lets agents inspect and summarize while the workflow enforces gates,
tool limits, audit records, and human approval.

## Workflow Shape

```yaml
kind: workflow
id: pr_risk_and_merge_gate
version: 1.0.0
shots:
  - id: read_diff
    kind: slug
    agent: diff_reviewer
    tools: [shell_read]
    prompt: |
      Read the approved PR diff. Extract touched components, risky changes,
      deleted files, generated files, config changes, and migration changes.

  - id: read_test_evidence
    kind: slug
    agent: test_reviewer
    tools: [shell_read]
    prompt: |
      Read approved test summaries and CI logs. Extract pass/fail status,
      skipped tests, flaky reruns, slow jobs, and missing coverage signals.

  - id: read_ownership
    kind: slug
    agent: ownership_reviewer
    tools: [shell_read]
    prompt: |
      Read CODEOWNERS, service catalog, or ownership metadata. Identify required
      reviewers and components without owners.

  - id: merge_risk_decision
    kind: slug
    agent: merge_captain
    depends_on:
      - read_diff
      - read_test_evidence
      - read_ownership
    prompt: |
      Produce a merge-risk decision: block, hold, or ready. Include evidence,
      missing checks, required reviewers, rollback risk, and release notes impact.

  - id: merge_gate
    kind: safety
    depends_on: [merge_risk_decision]
    description: "Maintainer approval before merge, squash, or release tagging"
```

## CLI Flow

```bash
git diff main...HEAD > evidence/pr.diff
git diff --name-only main...HEAD > evidence/pr-files.txt

twelvgaige round run workflows/pr_risk_and_merge_gate.yaml \
  --input '{
    "diff":"evidence/pr.diff",
    "changed_files":"evidence/pr-files.txt",
    "test_summary":"artifacts/test-summary.json",
    "ci_log":"artifacts/ci-log.txt",
    "ownership_files":["CODEOWNERS","docs/services.md"]
  }' \
  --detach
```

Review:

```bash
twelvgaige round show <round-id>
twelvgaige round audit <round-id>
twelvgaige round approve <round-id> --shot merge_gate --reason "maintainer reviewed risk packet"
```

## Future Tools

- `github_pr_files`
- `github_pr_reviews`
- `github_check_runs`
- `github_merge_pr`

The merge tool should be a separate destructive tool with safety approval,
branch allowlists, required status checks, and actor audit.

## Chokes

- Keep the current drill read-only.
- Do not let a model infer approval from passing tests.
- If `git_commit` is used for generated follow-up changes, keep it in a later
  shot behind `merge_gate`.
- Treat CI logs and diffs as untrusted input.
