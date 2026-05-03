# Repository Maintenance

This drill shows how to use Twelvgaige for bounded repository work without
turning the agent into an unrestricted shell.

## What It Enables

- Ask an agent to inspect selected files.
- Produce a small maintenance plan.
- Run a review shot before any write-capable operation.
- Optionally create a narrow commit with explicit files.

## Workflow Shape

```yaml
kind: workflow
id: repo_maintenance
version: 1.0.0
shots:
  - id: inspect
    kind: slug
    agent: repo_reader
    tools:
      - shell_read
    prompt: |
      Read the files listed in the round input. Summarize the issue, affected
      modules, and a minimal change plan.

  - id: review_plan
    kind: safety
    depends_on: [inspect]
    description: "Human review before any write or commit operation"

  - id: commit_notes
    kind: slug
    agent: repo_maintainer
    depends_on: [review_plan]
    tools:
      - git_commit
    prompt: |
      If the approved change has already been made, create a commit for exactly
      the approved files and message. Do not stage unrelated files.
```

## Example Input

```json
{
  "files": [
    "lib/twelvgaige/round/server.ex",
    "test/twelvgaige/round/server_test.exs"
  ],
  "goal": "Review resource cleanup around cancelled shots.",
  "commit_message": "Tighten cancelled-shot resource cleanup"
}
```

## CLI Flow

```bash
twelvgaige round run workflows/repo_maintenance.yaml \
  --input repo-input.json \
  --detach

twelvgaige round show <round-id>
twelvgaige round audit <round-id>
twelvgaige round approve <round-id> --shot review_plan --reason "plan accepted"
```

## Safety Notes

- Prefer `shell_read` for inspection.
- Keep `git_commit` behind a safety shot.
- Do not model arbitrary `git` or shell commands as free-form text.
- Use explicit file lists and bounded output.
