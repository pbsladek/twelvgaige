# Authoring Workflows

Twelvgaige authoring commands help teams create and maintain workflow shells
without handing write authority to an agent. The normal flow is:

```bash
twelvgaige shell new incident --scaffold inspect-analyze-gate-fix-verify --format yaml
twelvgaige shell lint traphouse/workflows/incident.yaml --root traphouse --strict
twelvgaige shell author review traphouse/workflows/incident.yaml --root traphouse
twelvgaige shell patch verify patch.json --root traphouse --approval approval.json
twelvgaige shell patch apply patch.json --root traphouse --approval approval.json
```

`shell author review` is read-only. It can ask local Ollama or hosted OpenAI to
review shell structure and propose changes, but it does not edit files. OpenAI
requires `--allow-remote`. Tests use a deterministic adapter that is not
compiled into production builds.

Use single-shell refactors for precise edits:

```bash
twelvgaige shot rename traphouse/workflows/incident.yaml gather inspect --write
twelvgaige shot gate traphouse/workflows/incident.yaml apply_fix --id approve_fix --write
twelvgaige shot split traphouse/workflows/incident.yaml analyze --into classify,explain --write
twelvgaige shot merge traphouse/workflows/incident.yaml classify explain --id analyze --write
```

Use collection refactors for repository maintenance:

```bash
twelvgaige shell bulk replace-agent traphouse old_agent new_agent --root traphouse
twelvgaige shell bulk replace-tool traphouse kubectl_get http_get --root traphouse
```

Bulk commands dry-run by default. They require both `--write` and `--yes` before
mutating files.

Run the CI-oriented authoring gate locally:

```bash
make authoring-check
```

That target builds the CLI, copies `docs/traphouse` to a temporary directory,
runs strict lint, inventory, shot-library verification, scaffold verification,
read-only author review, and patch verify/apply dry-run. It builds the test
escript for this gate so author review uses the test-only deterministic adapter
and never requires Ollama or hosted credentials.
