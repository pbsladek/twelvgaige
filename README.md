# Twelvgaige

[![CI](https://github.com/pbsladek/twelvgaige/actions/workflows/ci.yml/badge.svg)](https://github.com/pbsladek/twelvgaige/actions/workflows/ci.yml)
[![Build](https://github.com/pbsladek/twelvgaige/actions/workflows/build.yml/badge.svg)](https://github.com/pbsladek/twelvgaige/actions/workflows/build.yml)
[![Release](https://github.com/pbsladek/twelvgaige/actions/workflows/release.yml/badge.svg)](https://github.com/pbsladek/twelvgaige/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Twelvgaige runs auditable AI-agent workflows from the command line. Define a
workflow as a set of shots, give each shot an agent and allowed tools, then run
it locally with retries, safety gates, resource limits, persistence, and audit
trails handled by Elixir/OTP.

The project is pre-release and currently targets a single trusted OS user on one
machine. Workflow agents can use local Ollama models or the OpenAI API. The
optional unattended operations plane supplies durable control, credentials,
sandbox inventory, retention, and audit for delegated Codex sessions in
isolated containers. Delegated-session creation is available through both the
manager/integration API and the `session start` CLI command. Twelvgaige is
not a multi-user or distributed service.

`session start` accepts an inline objective, a Markdown task document, or a
closed-schema YAML task request. Explicit command-line options override values
from a task file.

## Why

LLMs are useful at reading messy context, forming hypotheses, writing summaries,
and choosing from a narrow set of tools. They are much less reliable as the
thing that owns retries, ordering, safety, resource limits, and recovery. When
that control flow lives in prompts, a workflow is hard to replay, hard to audit,
and easy to lose when the process crashes.

Twelvgaige moves that control flow into Elixir/OTP. A round is compiled into a
deterministic workflow graph. Shots run only when their dependencies are ready.
Write-capable tools require explicit safety policy. Every transition can be
stored, watched, retried, or exported for audit. The model still does the useful
language work, but the runtime decides what is allowed to happen next.

That makes Twelvgaige a better fit for operational workflows than chat-style
assistants: Kubernetes triage, guarded remediation, release checks, CI/CD
investigations, Git maintenance, local runbooks, and repeatable analysis using
OpenAI or Ollama.

## Install

Twelvgaige currently requires Erlang/OTP and Elixir. The versions used by the
repository are pinned in `.mise.toml`. From source:

```bash
mise install # optional, uses .mise.toml
mix deps.get
mix escript.build
./twelvgaige version
```

Run a credential-free CLI smoke test:

```bash
make escript-smoke
```

Run the main local validation gates:

```bash
make doctor
make check
make coverage
make e2e-cli
```

Build release artifacts:

```bash
make release
make burrito BURRITO_TARGET=linux
```

`make release` builds the native Mix release for the current OS and
architecture. Burrito builds single-file executables for release targets.
Released binaries are produced by the GitHub release workflow. See
[Release flow](docs/release.md) for checksum and GitHub artifact attestation
verification.

## Usage

The bundled examples use Ollama with the `llama3.2` model. Start Ollama and make
that model available before running a round. Validation and normalization do
not call a model.

```bash
ollama pull llama3.2
```

Validate a shell:

```bash
./twelvgaige shell validate docs/traphouse/workflows/simple.yaml
```

Run a round:

```bash
./twelvgaige round run docs/traphouse/workflows/simple.yaml
```

Use JSON or TOML shells too:

```bash
./twelvgaige shell validate docs/traphouse/workflows/simple.json
./twelvgaige shell validate docs/traphouse/workflows/simple.toml
```

Serve the local daemon in one terminal:

```bash
./twelvgaige daemon serve
```

Then inspect it from another terminal:

```bash
./twelvgaige status
```

Enable the single-user unattended operations plane before starting the daemon.
Podman is the default sandbox backend; Apple containers are available as an
explicit macOS backend after local qualification:

```bash
export TWELVGAIGE_OPERATIONS_ENABLED=1
export TWELVGAIGE_PODMAN_MACHINE=twelvgaige
./twelvgaige daemon serve
```

On a new macOS development host, `make sandbox-setup` creates and verifies the
dedicated Podman machine and builds the pinned worker image. The equivalent CLI
from the source checkout is `twelvgaige sandbox setup --backend podman`.
Backend options and the separate qualification gates are in
[Usage](USAGE.md#single-user-operations-plane).

For a delegated coding project, create a checked-in local profile and example
task, check the host, and inspect the exact authority before starting work:

```bash
./twelvgaige init --auth-profile codex-service
./twelvgaige doctor
./twelvgaige task validate .twelvgaige/tasks/example.yaml
./twelvgaige session plan --task-file .twelvgaige/tasks/example.yaml
./twelvgaige session start --task-file .twelvgaige/tasks/example.yaml --follow
```

`doctor --fix` creates missing project configuration and sets up the selected
sandbox. It doesn't create credentials. See the
[single-user operations guide](USAGE.md#single-user-operations-plane) for
profiles, review, and bounded retry commands.

This uses the per-user application-data directory, the platform credential
store for the operations master key, 30-day raw/artifact retention, and 90-day
security/audit retention. Override the data directory with
`TWELVGAIGE_DATA_ROOT`; use
`TWELVGAIGE_AUDIT_CHECKPOINT_EXTERNAL_PATH` for a second append-only audit
checkpoint destination.

Provider credentials come from environment variables or trusted runtime config:

```bash
export TWELVGAIGE_OPENAI_API_KEY=...
export TWELVGAIGE_OPENAI_API=responses
```

The bundled `simple` workflow uses local Ollama, so it runs without a hosted
LLM key once the configured model is available. See
[Secrets and providers](docs/secrets-and-providers.md) for OpenAI and Ollama
setup.

## Docs

- [Documentation index](docs/readme.md)
- [Usage](USAGE.md)
- [Core concepts](docs/concepts.md)
- [Authoring workflows](docs/authoring.md)
- [Scaffolds](docs/scaffolds.md)
- [Patch artifacts](docs/patches.md)
- [Shell formats](docs/shell-formats.md)
- [Secrets and providers](docs/secrets-and-providers.md)
- [Security](docs/security.md)
- [Use cases](docs/use-cases.md)
- [CI and local validation](docs/ci.md)
- [Release flow](docs/release.md)
- [Design and implementation records](docs/design/readme.md)
- [Design spec](docs/design/spec.md)
- [Release checklist](docs/design/release-checklist.md)

## License

MIT. See [LICENSE](LICENSE).
