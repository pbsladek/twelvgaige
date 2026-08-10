# Twelvgaige Usage

Twelvgaige runs deterministic agent workflows from the CLI. Elixir/OTP owns the control flow, retries, resource limits, safety gates, and persistence; LLMs only produce bounded shot outputs.

For broader documentation, start at [`README.md`](README.md). For scenario
drills, see the traphouse rack at
[`docs/traphouse/drills/readme.md`](docs/traphouse/drills/readme.md).
Provider credentials and endpoint policy are covered in
[`docs/secrets-and-providers.md`](docs/secrets-and-providers.md).
JSON and TOML authoring examples are covered in
[`docs/shell-formats.md`](docs/shell-formats.md).

## Core Terms

- **Shell**: a workflow or agent definition file. YAML, JSON, and TOML are
  implemented authoring formats.
- **Round**: one execution of a workflow shell.
- **Shot**: one step inside a round.
- **Safety shot**: a human approval checkpoint.
- **Breech**: the local daemon that owns detached rounds, round history, watch events, audit events, and safety decisions.

## Build And Help

From source:

```bash
mise install # optional, uses .mise.toml
mix deps.get
mix escript.build
./twelvgaige --help
./twelvgaige version
```

Use `./twelvgaige` in the examples below when running from the repo.

Common development and CI targets are controlled by the Makefile:

```bash
make doctor
make check
make coverage
make e2e-cli
make ci
make e2e
make package
make release-smoke
make package-burrito-smoke BURRITO_TARGET=linux
```

`make check` is the fast local gate. `make coverage` enforces the offline
coverage threshold. `make e2e-cli` runs the core CLI contract through the built
escript. `make ci` runs dependency fetch, formatter and warnings-as-errors
checks, Credo, Sobelow, the locked-dependency audit, normal and persistence
tests, and the Phase 0 performance gate. GitHub Actions also runs
`make authoring-check`, coverage, package smoke, and remote e2e jobs. See
[`docs/ci.md`](docs/ci.md) for the full CI and branch-protection checklist.

For repeatable failure artifacts that can be shared in review, run:

```bash
make e2e-artifacts
```

This keeps per-suite transcripts and stdout/stderr under `artifacts/e2e`.

Run Dialyzer locally when working through ElixirLS type warnings:

```bash
make typecheck
```

This uses Dialyxir over the normal app build. It is intentionally separate from
`make ci` because it is slower, but it is part of the local release gate.

For a native Elixir release bundle:

```bash
make release
_build/prod/rel/twelvgaige_native/bin/twelvgaige version
```

The release tarball is `_build/prod/twelvgaige_native-<version>.tar.gz`. It includes
ERTS and is specific to the OS/architecture where it was built. Inside the
release, use `bin/twelvgaige` for normal CLI commands and
`bin/twelvgaige_native` for Mix release lifecycle commands such as `start`,
`remote`, and `stop`.

For a Burrito single-file executable:

```bash
make burrito BURRITO_TARGET=macos_silicon
./burrito_out/twelvgaige_macos_silicon version
```

Choose the target for the machine you are publishing to: `macos_silicon`,
`linux`, `linux_arm64`, or `windows`. Burrito needs Zig
`0.15.2` and `xz` to build; Windows targets also need `7z` or `7zz`. The output
is `burrito_out/twelvgaige_<target>` or `burrito_out/twelvgaige_<target>.exe`.
Run it like the normal CLI:

```bash
./burrito_out/twelvgaige_macos_silicon shell validate docs/traphouse/workflows/simple.yaml
./burrito_out/twelvgaige_macos_silicon round run docs/traphouse/workflows/simple.yaml
```

If your local OTP patch release is newer than the Burrito ERTS archive mirror,
point Burrito at the host ERTS explicitly for host-target builds:

```bash
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" \
BURRITO_CUSTOM_ERTS_MACOS_SILICON="$(elixir -e 'IO.puts(:code.root_dir())')" \
make package-burrito-smoke BURRITO_TARGET=macos_silicon
```

The target-specific variables are `BURRITO_CUSTOM_ERTS_MACOS_SILICON`,
`BURRITO_CUSTOM_ERTS_LINUX`,
`BURRITO_CUSTOM_ERTS_LINUX_ARM64`, and `BURRITO_CUSTOM_ERTS_WINDOWS`.
`BURRITO_CUSTOM_ERTS` applies to every target. Only use a custom ERTS that
matches the target OS and architecture. On macOS with newer SDKs, Homebrew's
patched `zig@0.15` has proven more reliable than the upstream Zig binary.

GitHub workflows live in `.github/workflows`:

- `ci.yml`: formatting, compilation, static/security analysis, dependency
  audit, normal and persistence tests, authoring checks, and coverage.
- `build.yml`: smoke-builds escript, Mix release artifacts, and Burrito
  executables. Burrito runs as a multi-platform matrix for `linux`,
  `linux_arm64`, `windows`, and `macos_silicon`.
- `release.yml`: publishes tag/manual release artifacts. Burrito binaries are
  the primary multi-platform release artifacts.

Reusable actions are pinned to full commit SHAs. Keep workflow logic thin; add
commands to the Makefile first.

## Scaffold A Workflow

Use `shell new` to generate a valid starter workflow instead of building every
shot by hand:

```bash
twelvgaige shell new incident --scaffold inspect-analyze-gate-fix-verify
twelvgaige shell new demo --scaffold single-shot --format json
twelvgaige shell new release-check --scaffold platform/release-readiness --root docs/traphouse
```

By default the generated workflow is printed to stdout. To write it to a
traphouse, pass `--write --output`:

```bash
twelvgaige shell new incident \
  --scaffold inspect-analyze-gate-fix-verify \
  --output traphouse/workflows/incident.yaml \
  --write
```

Scaffolds may include companion agent shells, which are written next to the
workflow under `workflows/agents/`. Existing files are protected unless
`--force` is provided. Generated workflows start with draft lifecycle metadata and a
`generated_by` provenance record that names the scaffold source. After
generation, run `shell lint --strict` before committing changes:

```bash
twelvgaige shell lint traphouse/workflows/incident.yaml --strict
```

Lint also checks resource-profile fit, including clamped profile requests and
shots that ask for more iterations than the effective local profile recommends.
Path-based lint discovers nearby agent shells and checks shot tool use against
agent allow/deny policy. In-memory generated candidates skip agent discovery
until they are written into a traphouse.

Scaffolds can also come from a traphouse-local scaffold library:

```bash
twelvgaige shell scaffold list --root docs/traphouse
twelvgaige shell scaffold show platform/release-readiness --root docs/traphouse
twelvgaige shell scaffold verify --root docs/traphouse
twelvgaige shell scaffold update --root docs/traphouse
twelvgaige shell scaffold outdated docs/traphouse --root docs/traphouse
```

Scaffold and shot-template lock entries live together in
`traphouse/twelvgaige-library.lock`. CI should run scaffold and shot library
verification without `--write-lock`; update the lock only after reviewing source
changes.

Use `shell author review` when you want a provider-assisted, read-only patch
plan for a workflow or traphouse collection:

```bash
twelvgaige shell author review traphouse/workflows/incident.yaml
twelvgaige shell author review traphouse --format json
twelvgaige shell author review traphouse --provider openai --model gpt-4.1 --allow-remote
```

Hosted providers require `--allow-remote`. The command prints the provider,
model, source paths, source byte count, redacted byte count, exposed read-only
authoring tools, and patch-plan digest. It does not write files or apply
patches directly; controlled patch application is handled by the patch commands
below.

Patch artifacts are handled in inspect, verify, dry-run apply, and guarded
write steps:

```bash
twelvgaige shell patch inspect patch.json
twelvgaige shell patch inspect patch.json --root traphouse --format json
twelvgaige shell patch verify patch.json --root traphouse
twelvgaige shell patch verify patch.json --root traphouse --approval approval.json
twelvgaige shell patch apply patch.json --root traphouse
twelvgaige shell patch apply patch.json --root traphouse --approval approval.json --write
```

`inspect` parses JSON patch artifacts and checks the canonical patch digest.
`verify` additionally requires a traphouse root, rejects unsafe paths and file
kinds, verifies current and proposed digests, validates approval binding when
provided, and preflights candidate shell validation/lint. `apply` without
`--write` runs the same verification as a dry run and reports `changed: false`.
`apply --write` requires `--approval`, writes through atomic sibling temp files,
re-reads each target to verify the final digest, reruns declared safe validation
commands such as `shell validate` and `shell lint`, and includes a local
tamper-evident audit checkpoint in the JSON report.

Use `shell admit` when CI or a scheduler needs a hard lifecycle gate:

```bash
twelvgaige shell admit traphouse/workflows/incident.yaml --policy approved
twelvgaige shell admit traphouse/workflows/incident.yaml --policy scheduled --format json
```

`approved` requires lifecycle `approved` or `scheduled` plus a current
digest-bound approval record. `scheduled` requires lifecycle `scheduled`.
Manual `round run` does not require admission unless `--admission` is supplied;
scheduled jobs pass the scheduled policy to the daemon path.

Use lifecycle maintenance commands when replacing or archiving workflows:

```bash
twelvgaige shell deprecate traphouse/workflows/old-incident.yaml \
  --by human:owner \
  --reason "replaced by incident-v2" \
  --write

twelvgaige shell retire traphouse/workflows/old-incident.yaml \
  --by human:owner \
  --reason "kept for audit only" \
  --write
```

Deprecation clears current approval/review bindings so stale approvals are not
mistaken for active authorization. Strict lint treats deprecated workflows as
warnings and retired workflows as error-level findings.

Use raw metadata maintenance for labels that do not require digest-bound
approval:

```bash
twelvgaige shell metadata set traphouse/workflows/incident.yaml --owner platform
twelvgaige shell metadata set traphouse/workflows/incident.yaml --lifecycle reviewed --write
twelvgaige shell metadata clear traphouse/workflows/incident.yaml --review --approval
```

`shell metadata set --lifecycle approved` only changes the label. It does not
create a current approval binding; use `shell approve` when admission policy
must trust the workflow.

Use bulk refactors for repository-wide maintenance. Bulk commands dry-run by
default and require both `--write` and `--yes` before mutating workflow files:

```bash
twelvgaige shell bulk replace-agent traphouse old_inspector new_inspector --root traphouse
twelvgaige shell bulk replace-agent traphouse old_inspector new_inspector --root traphouse --write --yes
twelvgaige shell bulk replace-tool traphouse kubectl_get kubectl_describe --root traphouse
twelvgaige shell bulk replace-tool traphouse kubectl_get kubectl_describe --root traphouse --write --yes
```

Each candidate workflow is rewritten with the same single-file refactor logic
and must pass contextual lint with discovered agent shells before it is written.
Failures are reported per file instead of being hidden.

## Draft From Notes

Use `shell draft` when you have a ticket, incident note, or rough prompt and
want a first workflow shell to review:

```bash
twelvgaige shell draft --from incident-notes.md
twelvgaige shell draft --from incident-notes.md --format toml
twelvgaige shell draft --from incident-notes.md \
  --output traphouse/workflows/incident-draft.yaml \
  --write
```

The command never runs the generated workflow. It reads bounded source text,
redacts secret-shaped values, asks the configured provider for a candidate, then
parses, validates, and strict-lints the shell before emitting it. The hosted
OpenAI provider requires explicit `--allow-remote`:

```bash
twelvgaige shell draft --from incident-notes.md \
  --provider openai \
  --model gpt-4.1 \
  --allow-remote
```

The default provider is `ollama`, which is treated as local and does not require
`--allow-remote`.

## A Minimal Workflow

The repo includes the same minimal workflow as YAML, JSON, and TOML under
`docs/traphouse/workflows/`. The YAML shape is:

```yaml
kind: workflow
id: simple
name: Simple Format Demo
version: 1.0.0
shots:
  - id: first
    kind: slug
    agent: local_agent
    prompt: first prompt
  - id: second
    kind: slug
    agent: local_agent
    depends_on:
      - first
    prompt: second prompt
```

See [`docs/shell-formats.md`](docs/shell-formats.md) for JSON and TOML versions,
nested policy examples, and conversion commands.

The adjacent local agent lives at `docs/traphouse/workflows/agents/local_agent.yaml`:

```yaml
kind: agent
id: local_agent
name: Local Ollama Agent
version: 1.0.0
provider: ollama
model: llama3.2
system_prompt: Run the local shot.
```

Agent shells in an `agents/` directory next to the workflow are discovered
automatically for trusted local roots. For shells stored elsewhere, pass one or
more explicit paths:

```bash
twelvgaige round run docs/traphouse/workflows/simple.yaml --agent-shell docs/traphouse/workflows/agents/local_agent.yaml
```

When testing a workflow from an unreviewed repository, disable adjacent agent
discovery and pass only reviewed agent shells:

```bash
twelvgaige round run ./downloaded/workflow.yaml --untrusted-root --agent-shell ./reviewed-agents/local_agent.yaml
twelvgaige round run ./downloaded/workflow.yaml --no-agent-discovery --agent-shell ./reviewed-agents/local_agent.yaml
```

`--untrusted-root` keeps explicit `--agent-shell` paths working but blocks
workflow-relative auto-discovery unless a privileged API caller opts back in.

Validate it:

```bash
twelvgaige shell validate docs/traphouse/workflows/simple.yaml
twelvgaige shell validate docs/traphouse/workflows/simple.yaml --format json
twelvgaige shell fmt docs/traphouse/workflows/simple.yaml --check
twelvgaige shell fmt docs/traphouse/workflows/simple.yaml
twelvgaige shell graph docs/traphouse/workflows/simple.yaml --root docs/traphouse
twelvgaige shell graph docs/traphouse/workflows/simple.yaml --root docs/traphouse --format json
twelvgaige shell graph docs/traphouse/workflows/simple.yaml --root docs/traphouse --format mermaid
twelvgaige shell lint docs/traphouse/workflows/simple.yaml
twelvgaige shell lint docs/traphouse --root docs/traphouse --format json
twelvgaige shell admit docs/traphouse/workflows/simple.yaml --policy manual
twelvgaige shell admit docs/traphouse/workflows/simple.yaml --policy approved --format json
twelvgaige shell doctor docs/traphouse/workflows/simple.yaml
twelvgaige shell doctor docs/traphouse/workflows/simple.yaml --format json
twelvgaige shell review docs/traphouse/workflows/simple.yaml --by human:reviewer
twelvgaige shell approve docs/traphouse/workflows/simple.yaml --by human:approver --scope dev
twelvgaige shell deprecate docs/traphouse/workflows/simple.yaml --by human:owner --reason "replaced"
twelvgaige shell retire docs/traphouse/workflows/simple.yaml --by human:owner --reason "audit only"
twelvgaige shell inventory docs/traphouse --root docs/traphouse
twelvgaige shell inventory docs/traphouse --root docs/traphouse --format json
twelvgaige shell inventory docs/traphouse --root docs/traphouse --output docs/traphouse/inventory/inventory.json
twelvgaige shell impact docs/traphouse --root docs/traphouse --tool kubectl_apply --format json
twelvgaige shell impact docs/traphouse --root docs/traphouse --agent local_agent
twelvgaige shell impact docs/traphouse --root docs/traphouse --tool kubectl_apply --output docs/traphouse/inventory/impact-kubectl-apply.json
twelvgaige shell reload docs/traphouse --format json
twelvgaige shell list --format json
twelvgaige shell show simple
```

Run the read-only authoring review example when you want agents to inspect a
workflow shell without changing files:

```bash
twelvgaige shell validate docs/traphouse/workflows/shell_authoring_review_readonly.yaml
twelvgaige round run docs/traphouse/workflows/shell_authoring_review_readonly.yaml
```

That workflow grants local Ollama agents access to read-only tools for shell
validation, graphing, linting, inventory, impact analysis, normalization, diff
review, tool catalog lookup, and patch-plan drafting. Patch plans are advisory
artifacts; this phase does not write edits back to disk.

## Refactor Shots

Add a manual slug shot:

```bash
twelvgaige shot add traphouse/workflows/incident.yaml verify_recovery \
  --kind slug \
  --agent k8s_inspector \
  --depends-on apply_remediation \
  --tool kubectl_get \
  --prompt "Verify that the service recovered."
```

Add a human safety shot:

```bash
twelvgaige shot add traphouse/workflows/incident.yaml approve_remediation \
  --kind safety \
  --before apply_remediation
```

Both commands dry-run by default. Add `--write` after reviewing the diff.

Split one slug shot into a chain of draft child shots:

```bash
twelvgaige shot split traphouse/workflows/incident.yaml analyze_root_cause \
  --into identify_cause,summarize_cause

twelvgaige shot split traphouse/workflows/incident.yaml analyze_root_cause \
  --into identify_cause,summarize_cause \
  --write
```

The first child inherits the original dependencies, later children depend on
the previous child, and existing dependents are rewired to the final child.
Supported condition references to the original shot are also rewritten to the
final child. The new child prompts are marked as drafts so they can be refined
before review or approval.

Merge a linear chain of slug shots back into one draft shot:

```bash
twelvgaige shot merge traphouse/workflows/incident.yaml identify_cause summarize_cause \
  --id analyze_root_cause

twelvgaige shot merge traphouse/workflows/incident.yaml identify_cause summarize_cause \
  --id analyze_root_cause \
  --write
```

The source shots must use the same agent and form a dependency chain in the
order provided. The merged shot keeps upstream dependencies, unions source
tools, combines prompts with source headings, and rewires downstream
dependencies and supported condition references to the merged shot.

To insert a safety gate and update the target shot's dependency edge in one
step, use `shot gate`:

```bash
twelvgaige shot gate traphouse/workflows/incident.yaml apply_remediation --id approve_remediation
twelvgaige shot gate traphouse/workflows/incident.yaml apply_remediation --id approve_remediation --write
```

The gate inherits the target's previous dependencies, and the target is rewired
to depend on the new safety shot.

Set or replace a shot output schema from a JSON schema file:

```bash
twelvgaige shot schema set traphouse/workflows/incident.yaml analyze_root_cause schemas/root-cause.json
twelvgaige shot schema set traphouse/workflows/incident.yaml analyze_root_cause schemas/root-cause.json --write
```

Replace an agent across every matching shot in one workflow:

```bash
twelvgaige shot replace-agent traphouse/workflows/incident.yaml old_inspector new_inspector
twelvgaige shot replace-agent traphouse/workflows/incident.yaml old_inspector new_inspector --write
```

The replacement agent must be discoverable through the workflow's adjacent
`agents/` directory, and the candidate workflow must pass contextual lint before
it is printed or written.

Replace a tool across every matching shot in one workflow:

```bash
twelvgaige shot replace-tool traphouse/workflows/incident.yaml kubectl_get http_get
twelvgaige shot replace-tool traphouse/workflows/incident.yaml kubectl_get http_get --write
```

The replacement tool must be known to the tool registry, and every affected
shot must still satisfy its agent's tool allowlist after the rewrite.

List built-in and local shot templates:

```bash
twelvgaige shot library list
twelvgaige shot library list --library-path docs/traphouse/shots
twelvgaige shot library show builtin/analysis.slug
twelvgaige shot library show platform/review.summary --library-path docs/traphouse/shots
twelvgaige shot library verify --root docs/traphouse
twelvgaige shot library update --root docs/traphouse
twelvgaige shot library outdated docs/traphouse --root docs/traphouse
```

Insert a copied template as an ordinary shot with source metadata:

```bash
twelvgaige shot add traphouse/workflows/incident.yaml summarize \
  --template platform/review.summary \
  --depends-on verify_recovery \
  --library-path docs/traphouse/shots
```

Template insertion is still dry-run by default. Use `--write` only after
reviewing the generated diff.

After reviewing local template changes, update the lockfile deliberately:

```bash
twelvgaige shot library verify --root docs/traphouse --write-lock
```

CI should run `shot library verify` without `--write-lock`; digest mismatches
fail instead of silently using changed templates.

After reviewing intentional local template changes, update the lockfile with an
explicit write:

```bash
twelvgaige shot library update --root docs/traphouse
twelvgaige shot library update --root docs/traphouse --write-lock
```

The dry run prints the canonical lockfile diff. `--write-lock` refreshes the
lock entries after review.

To find workflow shots copied from templates that have since changed, run:

```bash
twelvgaige shot library outdated docs/traphouse --root docs/traphouse
twelvgaige shot library outdated docs/traphouse --root docs/traphouse --format json
```

This compares each copied shot's recorded template digest against the current
library template digest. It does not rewrite workflows; use `shot add --template`
or normal shot refactors after reviewing the report.

Use `shot rename` for the first write-capable authoring refactor. It is dry-run
by default and prints a canonical diff:

```bash
twelvgaige shot rename traphouse/workflows/incident.yaml gather_cluster_state inspect_cluster_state
```

Apply the rewrite only after reviewing the diff:

```bash
twelvgaige shot rename traphouse/workflows/incident.yaml gather_cluster_state inspect_cluster_state --write
```

The command updates `depends_on` edges and supported condition references,
normalizes legacy `steps.<shot>` condition roots to `shots.<shot>`, writes
atomically, and validates the workflow after writing.

Reorder shots in the document without changing execution dependencies:

```bash
twelvgaige shot move traphouse/workflows/incident.yaml verify_recovery --before notify_team
twelvgaige shot move traphouse/workflows/incident.yaml verify_recovery --before notify_team --write
```

`shot move` is for readability and authoring organization. It does not add,
remove, or infer `depends_on` edges.

Remove a leaf shot the same way:

```bash
twelvgaige shot remove traphouse/workflows/incident.yaml notify_team
twelvgaige shot remove traphouse/workflows/incident.yaml notify_team --write
```

If the shot has dependents, removal is blocked unless the cascade is explicit
and confirmed:

```bash
twelvgaige shot remove traphouse/workflows/incident.yaml gather_cluster_state --cascade --yes
twelvgaige shot remove traphouse/workflows/incident.yaml gather_cluster_state --cascade --yes --write
```

Cascade removal deletes the selected shot plus transitive dependent shots. It
still refuses condition references that would remain in the workflow.

Normalize or convert shells when reviewing generated definitions or moving
between YAML, JSON, and TOML:

```bash
twelvgaige shell normalize docs/traphouse/workflows/simple.yaml
twelvgaige shell normalize docs/traphouse/workflows/simple.toml --format json
twelvgaige shell convert docs/traphouse/workflows/simple.yaml --to toml --output docs/traphouse/workflows/simple.toml
twelvgaige shell convert docs/traphouse/workflows/simple.toml --to yaml
```

Run it in the foreground:

```bash
twelvgaige round run docs/traphouse/workflows/simple.yaml
```

Input defaults to `{}`. When a workflow needs data, input can be inline JSON, a
JSON file, or stdin:

```bash
twelvgaige round run docs/traphouse/workflows/simple.yaml --input '{"cluster":"dev"}'
twelvgaige round run docs/traphouse/workflows/simple.yaml --input input.json
cat input.json | twelvgaige round run docs/traphouse/workflows/simple.yaml --input -
```

Use JSON output for scripts:

```bash
twelvgaige round run docs/traphouse/workflows/simple.yaml --format json
```

## Foreground Safety Flow

A safety shot pauses the round for approval.

```yaml
kind: workflow
id: safety_simple
version: 1.0.0
shots:
  - id: approval
    kind: safety
    description: "Review before continuing"
  - id: after
    kind: slug
    agent: local_agent
    depends_on: [approval]
    prompt: "run after approval"
```

Run and auto-approve local safety shots:

```bash
twelvgaige round run docs/traphouse/workflows/safety.yaml --approve-safety
```

Without `--approve-safety`, the foreground run returns an awaiting-safety snapshot. Use the daemon flow when you want to approve later from another command.

## Daemon Flow

The daemon is used for detached rounds, inspection, watch, audit, cancellation, and external safety approval.

When the daemon is started with configured shell cache paths, workflow IDs can be used instead of file paths. Foreground runs still use explicit workflow paths.

```elixir
config :twelvgaige, :shell_paths, ["./workflows"]
```

Serve it in one terminal:

```bash
twelvgaige daemon serve
```

Use a durable SQLite store:

```bash
TWELVGAIGE_STORE_SQLITE=/tmp/twelvgaige.sqlite3 twelvgaige daemon serve
```

Then use another terminal for CLI commands:

```bash
twelvgaige status
twelvgaige daemon paths
```

Submit a detached round:

```bash
twelvgaige round run docs/traphouse/workflows/simple.yaml --detach
```

Inspect rounds:

```bash
twelvgaige round list
twelvgaige round list --status running
twelvgaige round show <round-id>
twelvgaige round show <round-id> --format json
```

Stop the daemon:

```bash
twelvgaige daemon stop
```

## Single-User Operations Plane

The unattended operations plane is opt-in. It adds delegated-session control,
sandbox health and reconciliation, encrypted artifact storage, retention,
operational audit, backup, and release checks to the local daemon:

```bash
export TWELVGAIGE_OPERATIONS_ENABLED=1
export TWELVGAIGE_PODMAN_MACHINE=twelvgaige
twelvgaige daemon serve
```

It supports one trusted local OS user. Podman is the default sandbox backend.
Apple containers are an explicit macOS backend and must be qualified on the
host before use. OTP supervises sessions and container processes, but the
selected container backend supplies the filesystem, process, credential, and
network isolation boundary.

The checked-in sandbox onboarding is for macOS. After installing Podman,
prepare and verify a new development host in one command:

```bash
make sandbox-setup
# equivalent while running from the source checkout:
twelvgaige sandbox setup --backend podman
```

The command is idempotent: it leaves an existing dedicated machine's resource
configuration unchanged, starts it when necessary, builds the pinned worker,
and verifies the actual mount and backend contract. Use `sandbox setup --check`
for a read-only health check. Add `--qualify-image` when onboarding should also
produce signed supply-chain and vulnerability evidence.

The machine uses the dedicated `twelvgaige` name by default, with 4 CPUs, 6 GiB
of memory, a 64 GiB virtual disk, rootless operation, and one narrow mount for
the Twelvgaige application-data directory. Override those values through the
`TWELVGAIGE_PODMAN_MACHINE`, `TWELVGAIGE_PODMAN_CPUS`,
`TWELVGAIGE_PODMAN_MEMORY_MIB`, `TWELVGAIGE_PODMAN_DISK_GIB`, and
`TWELVGAIGE_DATA_ROOT` Make variables before creation. The create target leaves
an existing machine unchanged; the health target verifies the actual mount and
connection contract.

Image build proves local execution. Supply-chain and live security
qualification remain separate, more expensive gates:

```bash
make podman-worker-qualify-image
make podman-live-qualify
```

Apple-container admission remains explicit. On a supported host, run
`make sandbox-setup TWELVGAIGE_SANDBOX_BACKEND=apple-container` or
`twelvgaige sandbox setup --backend apple-container` from the source checkout.
The command verifies the
signed CLI, starts its service, builds and exports the pinned OCI worker through
the dedicated Podman builder, imports it, and verifies backend health. Run
`make apple-container-live-qualify` for the separate live security gate.
The complete two-backend, egress, and operations evidence matrix is evaluated
by `make release-qualification`; it is a release gate, not a first-run setup
command.

Inspect the operations plane from another terminal:

```bash
twelvgaige operations dashboard
twelvgaige sandbox health
twelvgaige session list
twelvgaige operations retention status
twelvgaige operations release check
```

The session commands start, list, inspect, attach to, take over, or revoke
sessions created through the delegated-session manager and integration API.
The manager path is available as a standalone `session start` CLI command.

Initialize a repository once instead of repeating authority flags for every
task:

```bash
twelvgaige init --auth-profile codex-service
twelvgaige doctor
```

`init` writes `.twelvgaige/config.yaml` and an example YAML task. The project
file contains profile references and policy, never credential values. User
defaults can live in `$XDG_CONFIG_HOME/twelvgaige/config.yaml` (normally
`~/.config/twelvgaige/config.yaml`). Project values override user values, task
files override the selected profile, and explicit CLI flags win over both.

`doctor` checks the project profile, Codex executable, and selected sandbox.
Use `doctor --fix` to create missing project files and run sandbox onboarding.
That flag authorizes local configuration changes and may create or start the
dedicated container backend; it cannot invent or repair authentication.

Validate a task and preview the compiled authority without contacting the
daemon or reserving work:

```bash
twelvgaige task validate .twelvgaige/tasks/example.yaml
twelvgaige session plan --task-file .twelvgaige/tasks/example.yaml
```

`task validate` resolves the profile, task file, and CLI overrides. `session
plan` also resolves the Git base commit and compiles the exact manager envelope,
but doesn't create a session, workspace, credential lease, or sandbox.

```bash
twelvgaige session start \
  --task "Fix the failing tests and return a verified patch" \
  --profile local-dev \
  --auth-profile codex-service \
  --repo . \
  --sandbox podman \
  --budget-tokens 80000
```

The task can also come from Markdown:

```bash
twelvgaige session start \
  --task-file task.md \
  --auth-profile codex-service
```

Markdown is passed as the complete objective. A YAML task file can define the
structured request:

```yaml
version: 1
task: Fix the failing tests and return a verified patch.
repository: .
base_ref: main
auth_profile: codex-service
sandbox: podman
network: broker-only
allowed_paths: [lib, test]
write: true
timeout: 45m
budget:
  tokens: 80000
  cost_micros: 25000000
  time_ms: 2700000
  tool_calls: 1000
```

YAML repository paths are relative to the task file. Explicit CLI flags
override file values, including `--task`. Unknown YAML fields, duplicate aliases
such as both `task` and `objective`, and unrestricted networking without
`allow_unrestricted_network: true` or `--unrestricted-network` are rejected.

The auth profile must be present in the configured manager executor. Unattended
starts require a brokered service profile; no host login is copied into the
worker. The command returns stable plan, child, and session IDs immediately and
fails closed if the manager, auth profile, sandbox, or pinned runtime is not
available. `--unrestricted-network` is the explicit opt-in for unrestricted
egress; the default is broker-only.

Add `--follow` when the calling terminal should wait for the durable terminal
state. The same event-backed view is available later, and review never applies
or merges the result:

```bash
twelvgaige session start --task-file task.yaml --profile local-dev --follow
twelvgaige session watch <session-id>
twelvgaige session review <session-id>
```

If a terminal session needs another attempt, retry it under the original
repository, sandbox, network, path, credential-profile, timeout, and budget
boundary:

```bash
twelvgaige session retry <session-id>
twelvgaige session retry <session-id> --repair
```

Normal retries are capped at three. A repair adds the prior failure to the
objective and is capped at one attempt. The reservation is durable and atomic,
so concurrent callers cannot bypass those limits. Neither command expands
authority, merges a commit, or applies an artifact automatically.

`sandbox reconcile` is a dry run unless
`--apply` is supplied; destroying orphaned sandboxes also requires
`--destroy-orphans`.

The default application-data directory is
`~/Library/Application Support/Twelvgaige` on macOS,
`%LOCALAPPDATA%\Twelvgaige` on Windows, and
`$XDG_DATA_HOME/twelvgaige` or `~/.local/share/twelvgaige` on Linux. Override it
with `TWELVGAIGE_DATA_ROOT`.

## Watch And Audit

Watch committed round events:

```bash
twelvgaige round watch <round-id>
twelvgaige round watch <round-id> --format ndjson
twelvgaige round watch <round-id> --after-seq 10 --follow --timeout-ms 30000
twelvgaige round watch <round-id> --follow --until-terminal --format ndjson
```

`--follow` writes each committed event batch as it arrives. `--until-terminal` keeps advancing the cursor until the round reaches a terminal state, a timeout bound is hit, or the configured event limit is reached.

Read the audit trail:

```bash
twelvgaige round audit <round-id>
twelvgaige round audit <round-id> --format json
twelvgaige round audit <round-id> --format ndjson --after-seq 20 --limit 100
twelvgaige round audit <round-id> --format checkpoint
twelvgaige round audit <round-id> --format checkpoint --sign-hmac-env TWELVGAIGE_AUDIT_HMAC_KEY
twelvgaige audit verify checkpoint.json
twelvgaige audit verify signed-checkpoint.json --hmac-env TWELVGAIGE_AUDIT_HMAC_KEY
twelvgaige audit verify checkpoint.json --format json
```

Use watch for operational progress. Use audit when you need durable evidence of
state transitions, tool attempts, safety decisions, and recovery events.
`--format checkpoint` emits a SHA-256 hash-chain export so saved audit evidence
can be checked for mutation later. `audit verify` verifies a saved checkpoint
file or `-` for stdin; it detects post-export mutation, deletion, and reordered
records, but it does not make the live local store tamper-proof. Optional
`--sign-hmac-env` adds an HMAC-SHA-256 signature block to the checkpoint export;
`audit verify --hmac-env` verifies both the hash chain and that signature. HMAC
signing is shared-secret verification, not public signing.

## Safety Approval In The Daemon

When a detached round pauses on a safety shot:

```bash
twelvgaige round show <round-id>
twelvgaige round approve <round-id> --shot approval --reason "reviewed"
```

Rejecting halts or fails the round according to the workflow policy:

```bash
twelvgaige round reject <round-id> --shot approval --reason "too risky"
```

Cancel a round:

```bash
twelvgaige round cancel <round-id> --reason "operator stopped it"
```

## Common Use Cases

### Local Workflow Development

Use foreground runs while editing workflow shells:

```bash
twelvgaige shell validate docs/traphouse/workflows/simple.yaml
twelvgaige round run docs/traphouse/workflows/simple.yaml --format json
```

This is the fastest loop. No daemon is required.

### CI Or Automation

Use JSON output and deterministic exit codes:

```bash
twelvgaige round run ci/check.yaml --input ci-input.json --format json
```

The command exits non-zero for failed, halted, timed out, invalid, or unavailable runs.

### Long-Running Laptop Work

Use the daemon when a round may run longer than one terminal session:

```bash
twelvgaige daemon serve
twelvgaige round run workflows/report.yaml --input input.json --detach
twelvgaige round watch <round-id> --follow --until-terminal
```

The daemon keeps the round observable and applies local resource limits so multiple rounds do not overwhelm a laptop.

Use `--profile minimal|laptop|workstation|server` to choose local resource
budgets for a run. `laptop` is the default; `minimal` is best for battery or CI.

```bash
twelvgaige round run workflows/report.yaml --input input.json --profile minimal
TWELVGAIGE_PROFILE=workstation twelvgaige daemon serve
```

Scheduled daemon jobs can use fixed intervals or a portable five-field UTC cron expression in application config:

```elixir
config :twelvgaige, :scheduler_jobs, [
  %{id: "report_5m", workflow: "workflows/report.yaml", input: %{}, interval_ms: 300_000},
  %{id: "weekday_0900", workflow: "workflows/report.yaml", input: %{}, cron: "0 9 * * 1-5"}
]
```

### Human-Gated Operations

Use safety shots before any sensitive step:

```bash
twelvgaige round run workflows/remediate.yaml --input incident.json --detach
twelvgaige round show <round-id>
twelvgaige round approve <round-id> --shot approval --reason "approved by on-call"
```

This keeps approval outside the LLM. The model cannot bypass the checkpoint.

### Read-Only Infrastructure Inspection

Use read-only workflows for cluster, HTTP, shell-read, or Git inspection:

```bash
twelvgaige round run workflows/k8s_inspect.yaml --input '{"namespace":"default"}' --detach
twelvgaige round audit <round-id>
```

The useful pattern is: collect state, summarize it, validate structured output, then require safety approval before any later write-oriented workflow.

### Local Kubernetes Smoke

Live Kubernetes tests are opt-in. Prefer a disposable k3d cluster:

```bash
make e2e-live-local K3D_LIVE=1
```

That target creates a temporary k3d cluster, runs read-only Kubernetes tool
tests, RBAC denial checks, real `http_get`/`http_post` rounds against a
port-forwarded in-cluster fixture, a GitOps commit/apply round, Git destructive
safety denial, guarded remediation, daemon restart/resume, and fanout/fan-in
inspection. The harness deletes the cluster on exit. Normal tests must not
require a live cluster.

HTTP tools require trusted runtime policy. For local/private endpoints, pass the
policy in environment, not in workflow or model output:

```bash
TWELVGAIGE_HTTP_ALLOWED_HOSTS=127.0.0.1 \
TWELVGAIGE_HTTP_ALLOW_PRIVATE_HOSTS=1 \
twelvgaige round run workflows/http_check.yaml
```

## Output Formats

Most commands support human output by default and JSON for automation:

```bash
twelvgaige status --format json
twelvgaige round list --format json
twelvgaige round show <round-id> --format json
```

Event streams also support NDJSON:

```bash
twelvgaige round watch <round-id> --format ndjson
twelvgaige round audit <round-id> --format ndjson
```

If the optional HTTP listener is enabled with `:twelvgaige, :http_listener`, it
can push round events over chunked SSE or NDJSON:

```elixir
config :twelvgaige, :http_listener,
  ip: {127, 0, 0, 1},
  port: 4567,
  bearer_token: System.fetch_env!("TWELVGAIGE_HTTP_TOKEN")
```

```bash
curl -N -H "authorization: Bearer $TWELVGAIGE_HTTP_TOKEN" \
  "http://127.0.0.1:4567/api/v1/rounds/<round-id>/events?stream=true&format=sse&until_terminal=true"
curl -N -H "authorization: Bearer $TWELVGAIGE_HTTP_TOKEN" \
  "http://127.0.0.1:4567/api/v1/rounds/<round-id>/events?stream=true&format=ndjson&after_seq=10"
```

## Daemon Discovery

By default, CLI commands discover the local Breech endpoint file. You can inspect paths with:

```bash
twelvgaige daemon paths
```

Default IPC is a Unix socket on macOS/Linux and authenticated loopback TCP on Windows. Windows named-pipe addresses can be encoded and discovered, and the IPC protocol is tested through injected pipe transports; `--transport npipe` is still an explicit platform-verification path until native Windows pipe listener I/O is validated.

Useful overrides:

```bash
twelvgaige daemon serve --transport tcp --runtime-dir /tmp/twelvgaige
twelvgaige daemon serve --transport unix --endpoint /tmp/twelvgaige/endpoint.json
twelvgaige daemon paths --transport npipe
TWELVGAIGE_BREECH_ENDPOINT=/tmp/twelvgaige/endpoint.json twelvgaige status
TWELVGAIGE_BREECH_ADDR=tcp://127.0.0.1:4567 twelvgaige status
TWELVGAIGE_BREECH_ADDR=npipe:////./pipe/twelvgaige-<user-hash>-breech twelvgaige status
```

Use `crypto status` to see what protection is actually active:

```bash
twelvgaige crypto status
twelvgaige crypto status --format json
twelvgaige crypto sqlcipher-spike --format json
TWELVGAIGE_SQLCIPHER_SPIKE_KEY=test \
  twelvgaige crypto sqlcipher-spike --path /tmp/twelvgaige-sqlcipher-spike.db
```

The default file and SQLite stores are not encrypted by Twelvgaige. Use OS or
volume encryption for laptop at-rest protection, and use
`sensitive_retention: :summary` for high-sensitivity local runs. A separate
fail-closed SQLCipher store is available only with a SQLCipher-enabled driver.
Remote HTTP serving must use a
trusted TLS/mTLS proxy today; native TLS/mTLS is reported as unsupported until
the listener implements it. `crypto sqlcipher-spike` is a feasibility probe:
it detects whether the currently packaged SQLite driver was built against
SQLCipher. Passing a key through `TWELVGAIGE_SQLCIPHER_SPIKE_KEY` lets the probe
run migrations and reopen an encrypted test database when SQLCipher is present;
on normal bundled SQLite it reports `unavailable` and does not create an
encrypted-store claim.

For a deliberate local SQLCipher-linked driver spike, install SQLCipher and run:

```bash
make sqlcipher-env SQLCIPHER_PREFIX=/path/to/sqlcipher
make sqlcipher-spike-system SQLCIPHER_PREFIX=/path/to/sqlcipher
make sqlcipher-store-system SQLCIPHER_PREFIX=/path/to/sqlcipher
make sqlcipher-escript-smoke-system SQLCIPHER_PREFIX=/path/to/sqlcipher
make burrito-sqlcipher-smoke-system SQLCIPHER_PREFIX=/path/to/sqlcipher BURRITO_TARGET=macos_silicon
```

Those targets rebuild `exqlite` against system SQLCipher and are intentionally
opt-in. `sqlcipher-store-system` runs the excluded live store contract and raw
canary scan. `sqlcipher-escript-smoke-system` and
`burrito-sqlcipher-smoke-system` exercise the CLI path end to end: create a
plaintext SQLite store, back it up, migrate it to SQLCipher, open the encrypted
store, back it up, restore it, and reopen the restored encrypted store. They are
not part of the default build or release flow.

The operations plane uses platform key storage for its master key. A general
key-manager behaviour and platform backends also provide a stable contract for
tests, CI, and future integrations, but the optional SQLCipher store currently
accepts a key directly or through a named environment variable rather than
resolving it through those backends. Key management is not exposed as a general
CLI. The test backend and explicit env/file backends support tests, CI, and
headless operation. Env/file key backends require
`allow_insecure_key_backend?: true` and are reported by `crypto status` as not
OS-protected. The macOS keychain backend wraps `/usr/bin/security` generic
password items and is reported as OS-protected. Verify real login-Keychain
behavior with `make keychain-smoke-macos KEYCHAIN_LIVE=1`; normal tests exclude
that live tag and do not touch the user's Keychain. The Windows key backend is
DPAPI-protected files through a PowerShell wrapper. It is user-profile bound and
unit-tested with an injected runner; live Windows release verification remains
pending. The Linux key backend uses FreeDesktop Secret Service through
`secret-tool`. It is intended for desktop Linux with a user D-Bus session and
an unlocked collection, not WSL, containers, or headless servers. Use explicit
env/file key backends for headless Linux only when the insecure-backend
acceptance flag is set.

Backup and rotation rules are defined ahead of encrypted-store defaults:
encrypted backup is the default policy, redacted export is non-restorable, and
plaintext export must be explicitly allowed. Key rotation starts with DEK
rewrap: Twelvgaige can rotate the envelope around a store data key without
re-encrypting database pages.

The first encrypted SQLite slice is fail-closed. Set
`TWELVGAIGE_STORE_SQLCIPHER=/path/to/store.db` and
`TWELVGAIGE_STORE_SQLCIPHER_KEY=<key>` to select `Store.SQLiteEncrypted`. The
store probes `PRAGMA cipher_version` before creating the target file. On the
normal bundled SQLite driver it reports `:sqlcipher_unavailable` and does not
create an encrypted-store claim. Use `make sqlcipher-spike-system` to rebuild
the local driver against SQLCipher before testing the encrypted store path. Use
`make sqlcipher-store-system` for the opt-in live store contract and raw canary
scan once the system SQLCipher build is available.

SQLite backup/restore is exposed through the CLI:

```bash
# Plaintext SQLite backup requires explicit consent because the output is plaintext.
TWELVGAIGE_STORE_SQLITE=/path/to/store.db \
  twelvgaige store backup /path/to/backup.db --allow-plaintext-export

# SQLCipher-backed stores use the same command and keep the backup encrypted.
TWELVGAIGE_STORE_SQLCIPHER=/path/to/store.db \
TWELVGAIGE_STORE_SQLCIPHER_KEY=<key> \
  twelvgaige store backup /path/to/encrypted-backup.db

# Restore is offline: write a database file, then point the runtime at it.
twelvgaige store restore /path/to/backup.db /path/to/restored.db
twelvgaige store restore /path/to/backup.db /path/to/restored.db --replace

# Migrate an offline plaintext SQLite store to SQLCipher.
TWELVGAIGE_STORE_SQLCIPHER_KEY=<key> \
  twelvgaige store migrate-sqlcipher \
    --source /path/to/plain.db \
    --destination /path/to/encrypted.db \
    --key-env TWELVGAIGE_STORE_SQLCIPHER_KEY

# Rewrap a DEK envelope after rotating key material.
TWELVGAIGE_OLD_STORE_KEK=<old-key> \
TWELVGAIGE_NEW_STORE_KEK=<new-key> \
  twelvgaige store rewrap-envelope /path/to/store-envelope.json \
    --backup /path/to/store-envelope.backup.json \
    --old-key-env TWELVGAIGE_OLD_STORE_KEK \
    --new-key-env TWELVGAIGE_NEW_STORE_KEK
```

Migration is offline and non-destructive: the source is left in place, the
destination must not already exist unless `--replace` is supplied, and the
command fails before creating the destination when the loaded SQLite driver is
not SQLCipher-backed.

Envelope rewrap is also offline and requires a backup path. It rotates only the
DEK envelope metadata and wrapped DEK bytes; it does not re-encrypt existing
SQLCipher database pages. Full database rekey is a later, higher-risk phase.

## Release Checklist

Before publishing, use [`release-checklist.md`](docs/design/release-checklist.md). It tracks
required gates, packaging smoke checks, resource-profile measurements, security
checks, and no-go criteria.

## Command Reference

This section is a compact snapshot. `twelvgaige --help` is authoritative for
the installed executable.

```bash
twelvgaige --help
twelvgaige version
twelvgaige status [--format human|json]
twelvgaige crypto status [--format human|json]
twelvgaige crypto sqlcipher-spike [--path <path>] [--key-env <env>] [--format human|json]
twelvgaige store backup <destination-path> [--allow-plaintext-export] [--format human|json]
twelvgaige store restore <source-path> <destination-path> [--replace] [--format human|json]
twelvgaige store migrate-sqlcipher --source <plaintext.db> --destination <encrypted.db> --key-env <env> [--replace] [--format human|json]
twelvgaige store rewrap-envelope <envelope.json> --backup <backup.json> --old-key-env <env> --new-key-env <env> [--format human|json]

twelvgaige daemon serve [--transport unix|tcp|npipe] [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
twelvgaige daemon stop [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
twelvgaige daemon paths [--transport unix|tcp|npipe] [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
twelvgaige daemon token rotate [--runtime-dir <path>] [--endpoint <path>] [--format human|json]

twelvgaige session list [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
twelvgaige session show <session-id> [--format human|json]
twelvgaige session attach <session-id> [--format human|json]
twelvgaige session takeover <session-id> --expected-epoch <epoch> [--format human|json]
twelvgaige session revoke <session-id> [--format human|json]
twelvgaige sandbox health [--format human|json]
twelvgaige sandbox reconcile [--apply] [--destroy-orphans] [--format human|json]
twelvgaige operations dashboard [--format human|json]
twelvgaige operations audit status [--format human|json]
twelvgaige operations audit checkpoint [--format human|json]
twelvgaige operations audit export <path> [--format human|json]
twelvgaige operations store stats [--format human|json]
twelvgaige operations store backup <path> [--format human|json]
twelvgaige operations store restore <backup-path> <destination-path> [--format human|json]
twelvgaige operations retention status [--format human|json]
twelvgaige operations retention run [--format human|json]
twelvgaige operations artifact inventory [--format human|json]
twelvgaige operations artifact rotate [--format human|json]
twelvgaige operations release check [--format human|json]

twelvgaige shell validate <path> [--format human|json]
twelvgaige shell new <id> [--scaffold single-shot|inspect-analyze-gate-fix-verify] [--scaffold-path <path>] [--format yaml|json|toml] [--output <path>] [--write] [--force] [--root <path>]
twelvgaige shell scaffold list [--format human|json] [--root <path>] [--scaffold-path <path>]
twelvgaige shell scaffold show <scaffold-id> [--format human|json] [--root <path>] [--scaffold-path <path>]
twelvgaige shell scaffold verify [--write-lock] [--lockfile <path>] [--format human|json] [--root <path>] [--scaffold-path <path>]
twelvgaige shell scaffold update [--write-lock] [--lockfile <path>] [--format human|json] [--root <path>] [--scaffold-path <path>]
twelvgaige shell scaffold outdated <path> [--format human|json] [--root <path>] [--scaffold-path <path>]
twelvgaige shell author review <path> [--provider ollama|openai] [--model <model>] [--allow-remote] [--max-input-bytes <bytes>] [--format human|json] [--root <path>]
twelvgaige shell patch inspect <patch-file> [--root <path>] [--format human|json]
twelvgaige shell patch verify <patch-file> [--approval <approval-file>] --root <path> [--format human|json]
twelvgaige shell patch apply <patch-file> [--approval <approval-file>] --root <path> [--write] [--format human|json]
twelvgaige shell draft --from <file|-> [--provider ollama|openai] [--model <model>] [--allow-remote] [--max-input-bytes <bytes>] [--format yaml|json|toml] [--output <path> --write] [--force] [--root <path>]
twelvgaige shell normalize <path> [--format json|yaml|toml]
twelvgaige shell convert <path> --to json|yaml|toml [--output <path>]
twelvgaige shell fmt <path> [--check|--write] [--format human|json] [--root <path>]
twelvgaige shell graph <path> [--format text|json|mermaid] [--root <path>]
twelvgaige shell lint <path> [--strict] [--format human|json] [--root <path>]
twelvgaige shell admit <path> [--policy manual|approved|scheduled|none] [--format human|json] [--root <path>]
twelvgaige shell doctor <path> [--strict] [--format human|json] [--root <path>]
twelvgaige shell inventory <dir> [--format human|json] [--root <path>] [--output <path>] [--force]
twelvgaige shell impact <dir> (--agent <id>|--tool <name>|--template <id>) [--format human|json] [--root <path>] [--output <path>] [--force]
twelvgaige shell reload [path ...] [--format human|json]
twelvgaige shell list [--kind workflow|agent|all] [--format human|json]
twelvgaige shell show <shell-id> [--kind workflow|agent] [--format human|json]
twelvgaige shell review <path> --by <actor> [--scope <scope>] [--evidence-hash <sha256:...>] [--write] [--format human|json] [--root <path>]
twelvgaige shell approve <path> --by <actor> --scope <scope> [--expires-at <timestamp>] [--evidence-hash <sha256:...>] [--write] [--format human|json] [--root <path>]
twelvgaige shell deprecate <path> --by <actor> --reason <text> [--write] [--format human|json] [--root <path>]
twelvgaige shell retire <path> --by <actor> --reason <text> [--write] [--format human|json] [--root <path>]
twelvgaige shell metadata set <path> [--owner <owner>] [--lifecycle draft|reviewed|approved|scheduled|deprecated|retired] [--write] [--format human|json] [--root <path>]
twelvgaige shell metadata clear <path> [--review] [--approval] [--write] [--format human|json] [--root <path>]
twelvgaige shell bulk replace-agent <path> <old-agent-id> <new-agent-id> [--write --yes] [--format human|json] [--root <path>] [--output <path>] [--force]
twelvgaige shell bulk replace-tool <path> <old-tool-name> <new-tool-name> [--write --yes] [--format human|json] [--root <path>] [--output <path>] [--force]
twelvgaige shot library list [--format human|json] [--root <path>] [--library-path <path>]
twelvgaige shot library show <template-id> [--format human|json] [--root <path>] [--library-path <path>]
twelvgaige shot library verify [--write-lock] [--lockfile <path>] [--format human|json] [--root <path>] [--library-path <path>]
twelvgaige shot library update [--write-lock] [--lockfile <path>] [--format human|json] [--root <path>] [--library-path <path>]
twelvgaige shot library outdated <path> [--format human|json] [--root <path>] [--library-path <path>]
twelvgaige shot add <workflow-shell-path> <shot-id> --kind slug|safety [--agent <agent-id>] [--prompt <text>] [--description <text>] [--depends-on <id,id>] [--tool <name>] [--before <target-shot-id>|--after <target-shot-id>] [--write] [--format human|json] [--root <path>]
twelvgaige shot add <workflow-shell-path> <shot-id> --template <template-id> [--depends-on <id,id>] [--before <target-shot-id>|--after <target-shot-id>] [--write] [--format human|json] [--root <path>] [--library-path <path>]
twelvgaige shot split <workflow-shell-path> <shot-id> --into <child-id,child-id,...> [--write] [--format human|json] [--root <path>]
twelvgaige shot merge <workflow-shell-path> <source-shot-id> <source-shot-id> [more-source-shot-ids...] --id <merged-shot-id> [--write] [--format human|json] [--root <path>]
twelvgaige shot gate <workflow-shell-path> <target-shot-id> --id <gate-shot-id> [--description <text>] [--prompt <text>] [--write] [--format human|json] [--root <path>]
twelvgaige shot schema set <workflow-shell-path> <shot-id> <schema-json-path> [--write] [--format human|json] [--root <path>]
twelvgaige shot replace-agent <workflow-shell-path> <old-agent-id> <new-agent-id> [--write] [--format human|json] [--root <path>]
twelvgaige shot replace-tool <workflow-shell-path> <old-tool-name> <new-tool-name> [--write] [--format human|json] [--root <path>]
twelvgaige shot rename <workflow-shell-path> <old-shot-id> <new-shot-id> [--write] [--format human|json] [--root <path>]
twelvgaige shot move <workflow-shell-path> <shot-id> (--before <target-shot-id>|--after <target-shot-id>) [--write] [--format human|json] [--root <path>]
twelvgaige shot remove <workflow-shell-path> <shot-id> [--cascade --yes] [--write] [--format human|json] [--root <path>]

twelvgaige round run <workflow-shell-path-or-id> [--input <json-or-path>] [--agent-shell <path>] [--no-agent-discovery] [--untrusted-root] [--profile minimal|laptop|workstation|server] [--admission none|approved|scheduled] [--format human|json] [--approve-safety] [--detach]
twelvgaige round list [--format human|json] [--status <status>]
twelvgaige round show <round-id> [--format human|json]
twelvgaige round watch <round-id> [--format human|ndjson] [--after-seq <seq>] [--limit <count>] [--follow] [--until-terminal] [--timeout-ms <ms>]
twelvgaige round audit <round-id> [--format human|json|ndjson|checkpoint] [--after-seq <seq>] [--limit <count>] [--sign-hmac-env <env>]
twelvgaige audit verify <checkpoint-path|-> [--hmac-env <env>] [--format human|json]
twelvgaige round approve <round-id> --shot <safety-shot-id> [--reason <text>] [--format human|json]
twelvgaige round reject <round-id> --shot <safety-shot-id> [--reason <text>] [--format human|json]
twelvgaige round cancel <round-id> [--reason <text>] [--format human|json]
```
