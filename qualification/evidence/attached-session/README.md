# Attached-session qualification

This directory holds evidence for the production attached Codex lifecycle. A
direct provider/backend fixture is not a substitute: the attached proof must
start the controller, authenticate inside the selected outer sandbox, complete
a turn over stdio, repatriate the full workspace, prove runtime quiescence, and
destroy the exact sandbox resource.

The live fixtures use a controlled repository containing only a generated
`README.md`. They copy the selected local Codex `auth.json` into a temporary
owner-only credential directory, mount that copy into the sandbox, and enable
unrestricted provider networking for the duration of the qualification. The
credential directory and sandbox are removed afterward, and captured files are
scanned for credential values.

Because the run uses local login state and external networking, execute it only
after the user explicitly approves that combination:

```sh
make attached-session-podman-qualify
make attached-session-apple-qualify
```

Successful runs write `podman.json` and `apple-container.json`. The release
matrix fails closed while either file is absent, stale, unsuccessful, or
missing any required lifecycle/security field.
