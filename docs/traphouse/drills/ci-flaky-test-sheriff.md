# CI Flaky Test Sheriff

This drill turns repeated CI noise into an actionable flaky-test report. It
reads job logs, test reports, recent diffs, and historical failure summaries,
then separates product failures from infrastructure failures.

## Why It Is Interesting

CI logs are long, repetitive, and full of false leads. Twelvgaige can bound log
inputs, run focused analysis shots in parallel, and produce a deterministic
triage packet that a maintainer can trust.

## Workflow Shape

```yaml
kind: workflow
id: ci_flaky_test_sheriff
version: 1.0.0
policy:
  resource_profile: minimal
shots:
  - id: read_test_reports
    kind: slug
    agent: test_report_reader
    tools: [shell_read]
    prompt: |
      Read approved JUnit, ExUnit, pytest, or test-summary files. Extract failed
      test names, files, assertions, seeds, durations, and rerun outcomes.

  - id: read_ci_logs
    kind: slug
    agent: ci_log_reader
    tools: [shell_read]
    prompt: |
      Read bounded CI logs from round input. Extract infrastructure errors,
      dependency download failures, timeouts, resource pressure, and toolchain
      versions.

  - id: read_recent_diff
    kind: slug
    agent: diff_reviewer
    tools: [shell_read]
    prompt: |
      Read the approved diff or changed-files summary. Identify whether failed
      tests map to recently touched modules.

  - id: classify_flakes
    kind: slug
    agent: ci_sheriff
    depends_on:
      - read_test_reports
      - read_ci_logs
      - read_recent_diff
    prompt: |
      Classify each failure as likely product regression, flaky test, CI
      infrastructure, dependency outage, or unknown. Include confidence and the
      minimal next action.

  - id: maintainer_gate
    kind: safety
    depends_on: [classify_flakes]
    description: "Maintainer approval before opening or updating tracking issues"
```

## Example Inputs

```bash
mkdir -p evidence/ci
cp _build/test/lib/*/test-junit-report.xml evidence/ci/ || true
cp artifacts/ci-log.txt evidence/ci/
git diff --name-only main...HEAD > evidence/ci/changed-files.txt
git diff main...HEAD > evidence/ci/diff.patch
```

```bash
twelvgaige round run workflows/ci_flaky_test_sheriff.yaml \
  --input '{
    "test_reports":["evidence/ci/test-junit-report.xml"],
    "ci_logs":["evidence/ci/ci-log.txt"],
    "changed_files":"evidence/ci/changed-files.txt",
    "diff":"evidence/ci/diff.patch"
  }' \
  --format json
```

## Chokes

- Keep logs bounded; CI output can be enormous.
- Do not auto-quarantine tests without a safety shot.
- Keep future issue-comment or PR-comment tools behind approval.
- Prefer JSON output so CI can attach the report as an artifact.
