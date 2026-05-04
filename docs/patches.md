# Patch Artifacts

Patch artifacts are the boundary between agent-assisted authoring and file
mutation. Agents may propose `twelvgaige.patch.v1` JSON, but Twelvgaige verifies
the artifact and requires a human approval before any write.

Read-only inspection:

```bash
twelvgaige shell patch inspect patch.json
twelvgaige shell patch inspect patch.json --root traphouse --format json
```

Verification with current filesystem state and approval binding:

```bash
twelvgaige shell patch verify patch.json --root traphouse
twelvgaige shell patch verify patch.json --root traphouse --approval approval.json
```

Dry-run apply:

```bash
twelvgaige shell patch apply patch.json --root traphouse --approval approval.json
```

Guarded write:

```bash
twelvgaige shell patch apply patch.json --root traphouse --approval approval.json --write
```

Write mode refuses missing approvals, stale file digests, path traversal,
symlink traversal, unsupported file kinds, invalid candidate content, and denied
validation commands. Files are written through sibling temp files, then reread
to verify final digests. Declared safe validation commands, currently
`shell validate` and `shell lint`, run after write.

JSON apply reports include local audit events and a tamper-evident checkpoint:

```bash
twelvgaige shell patch apply patch.json \
  --root traphouse \
  --approval approval.json \
  --write \
  --format json
```

The checkpoint proves the exported apply report was not modified after capture.
It does not make the local filesystem or git working tree tamper-proof.
