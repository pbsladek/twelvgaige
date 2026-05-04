# Scaffolds

Scaffolds are reusable workflow starters. They reduce copy/paste drift while
still producing ordinary workflow and agent shells that can be reviewed, linted,
and committed.

List and inspect available scaffolds:

```bash
twelvgaige shell scaffold list --root docs/traphouse
twelvgaige shell scaffold show platform/release-readiness --root docs/traphouse
```

Create a workflow from a scaffold:

```bash
twelvgaige shell new release-check \
  --scaffold platform/release-readiness \
  --root docs/traphouse \
  --output traphouse/workflows/release-check.yaml \
  --with-mock-agents \
  --write
```

Verify scaffold library drift:

```bash
twelvgaige shell scaffold verify --root docs/traphouse
twelvgaige shell scaffold outdated docs/traphouse --root docs/traphouse
```

Update the lockfile only after reviewing scaffold source changes:

```bash
twelvgaige shell scaffold update --root docs/traphouse
twelvgaige shell scaffold update --root docs/traphouse --write-lock
```

Scaffold and shot-template entries share
`traphouse/twelvgaige-library.lock`. CI should verify the lock without
`--write-lock`; humans should refresh it deliberately.
