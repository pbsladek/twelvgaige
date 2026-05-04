# Scaffold Library

Scaffolds are reusable workflow blueprints. They are authoring inputs only:
`shell new` expands a scaffold into an ordinary workflow shell, then the runtime
uses that generated workflow directly.

Useful commands:

```bash
twelvgaige shell scaffold list --root docs/traphouse
twelvgaige shell scaffold show platform/release-readiness --root docs/traphouse
twelvgaige shell new release-check --scaffold platform/release-readiness --root docs/traphouse
twelvgaige shell scaffold verify --root docs/traphouse
```

Use `shell scaffold update --write-lock --root <traphouse>` after reviewing a
scaffold change.
