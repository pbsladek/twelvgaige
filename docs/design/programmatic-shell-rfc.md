# Programmatic Shell Authoring RFC

Status: accepted as a gating policy. No programmatic shell runtime is enabled.

Twelvgaige supports declarative YAML, JSON, and TOML shells. Programmatic shells
would let developers generate a shell map from code, but that expands the trust
boundary. This RFC defines the conditions required before any `.star`,
`.cue`, or similar authoring path can be implemented.

## Decision

Do not execute arbitrary Elixir, JavaScript, Python, shell, Lua, or template code
from workflow repositories.

Programmatic authoring may be considered only if the candidate language can be
run as a deterministic, bounded generator whose only output is a plain
declarative shell map. The generated map must then pass the same validation and
compiler path used by YAML, JSON, and TOML.

## Candidate Order

1. Starlark

   Preferred candidate because it is designed for deterministic configuration
   generation and has no ambient host access by default in well-designed
   runtimes.

2. CUE

   Useful for schema-driven configuration and validation. It should be treated
   as a possible authoring or conversion layer only if the implementation can be
   embedded or invoked without granting untrusted files host access.

Rejected by default:

- Elixir DSLs, because they execute BEAM code in the host VM.
- JavaScript or TypeScript, because they add a large runtime and broad host API
  surface unless heavily sandboxed.
- Python or shell templates, because host access is the default behavior.
- Lua, because embedding still requires a carefully constrained capability
  model and does not add enough value over Starlark for this use case.

## Required Sandbox Properties

A programmatic shell runtime must prove all of these before it can be enabled:

- no filesystem reads or writes,
- no network access,
- no subprocess execution,
- no environment variable access,
- no wall-clock or random access unless explicitly injected as deterministic
  test data,
- no dynamic imports except an approved Twelvgaige prelude,
- bounded CPU or instruction count,
- bounded memory and generated document size,
- deterministic output for the same source and inputs,
- clear errors for timeout, memory, unsupported import, and denied capability,
- disabled by default in the daemon, CLI, and shell cache.

## Loader Contract

The generated value must be equivalent to a decoded YAML/JSON/TOML document:

```text
programmatic source
  -> sandboxed evaluator
  -> ordinary map with string keys
  -> shell normalization
  -> workflow or agent struct
  -> compiler validation
  -> compiled pattern
```

The programmatic runtime may not:

- choose the next shot,
- execute tools,
- call LLM providers,
- read secrets,
- inspect host state,
- alter retry, safety, resource, persistence, provider, or tool semantics.

## Required Manifest Metadata

Rounds started from generated shells must persist:

- source path,
- source format,
- source content hash,
- generated normalized shell hash,
- evaluator name and version,
- evaluator options,
- prelude version,
- generated shell ID and version.

## Required Tests

Before enabling any implementation:

- denied filesystem read test,
- denied filesystem write test,
- denied environment read test,
- denied network test,
- denied subprocess test,
- denied dynamic import test,
- infinite-loop or instruction-budget test,
- generated-document size-limit test,
- deterministic output test,
- malformed generated map test,
- daemon default-deny test,
- shell-cache default-deny test,
- explicit-enable positive test.

## CLI Shape If Accepted

Programmatic shells must stay opt-in:

```bash
twelvgaige shell validate generated.star --enable-programmatic-shells
twelvgaige shell normalize generated.star --enable-programmatic-shells
```

Daemon config must require an explicit runtime option. Environment variables
alone are not enough for remote or long-running daemon use.

## Current Product Rule

Until all required properties and tests exist, Twelvgaige intentionally supports
only declarative shell files: YAML, JSON, and TOML.
