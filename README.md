# Twelvgaige

[![CI](https://github.com/pbsladek/twelvgaige/actions/workflows/ci.yml/badge.svg)](https://github.com/pbsladek/twelvgaige/actions/workflows/ci.yml)
[![Build](https://github.com/pbsladek/twelvgaige/actions/workflows/build.yml/badge.svg)](https://github.com/pbsladek/twelvgaige/actions/workflows/build.yml)
[![Release](https://github.com/pbsladek/twelvgaige/actions/workflows/release.yml/badge.svg)](https://github.com/pbsladek/twelvgaige/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Twelvgaige runs reliable, auditable AI-agent workflows from the command line.
Define a workflow as a set of shots, give each shot an agent and allowed tools,
then run it locally with retries, safety gates, resource limits, persistence,
and audit trails handled by Elixir/OTP.

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
Anthropic, OpenAI, Gemini, Ollama, or mock providers.

## Install

From source:

```bash
mix deps.get
mix escript.build
./twelvgaige version
```

Run the local smoke flow:

```bash
make escript-smoke
```

Run the main local validation gates:

```bash
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

Provider credentials come from environment variables or trusted runtime config:

```bash
export TWELVGAIGE_OPENAI_API_KEY=...
```

The bundled `simple` workflow uses the mock provider, so it runs without a
hosted LLM key. See [Secrets and providers](docs/secrets-and-providers.md) for
Anthropic, OpenAI, Gemini, and Ollama setup.

## Docs

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
- [Design spec](docs/design/spec.md)
- [Shot authoring and management plan](docs/design/shot-authoring-management-plan.md)
- [Release checklist](docs/design/release-checklist.md)

## License

MIT. See [LICENSE](LICENSE).
