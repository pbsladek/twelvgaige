# Shot Templates

Reusable authoring templates live here as `kind: shot_template` documents. They
are copied into workflow shells by `shot add --template`; runtime rounds do not
load templates dynamically.

```bash
twelvgaige shot library list --library-path docs/traphouse/shots
twelvgaige shot library show platform/review.summary --library-path docs/traphouse/shots
twelvgaige shot library verify --root docs/traphouse
twelvgaige shot add docs/traphouse/workflows/simple.yaml review \
  --template platform/review.summary \
  --library-path docs/traphouse/shots
```

After reviewing template edits, update `docs/traphouse/twelvgaige-library.lock`
with:

```bash
twelvgaige shot library verify --root docs/traphouse --write-lock
```
