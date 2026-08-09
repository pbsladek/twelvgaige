# Documentation

Twelvgaige is a pre-release, single-user local agent orchestrator. Start with
the operator guides below. The CLI's built-in help is the authoritative command
reference for the version you are running:

```bash
twelvgaige --help
```

## Use Twelvgaige

- [Usage](../USAGE.md): build, author, run, inspect, and recover workflows.
- [Core concepts](concepts.md): shells, rounds, shots, safety gates, chokes, and
  the Breech daemon.
- [Authoring workflows](authoring.md): scaffolds, refactors, reviews, and
  controlled patch application.
- [Shell formats](shell-formats.md): equivalent YAML, JSON, and TOML forms.
- [Scaffolds](scaffolds.md): built-in and repository-local workflow templates.
- [Patch artifacts](patches.md): inspect, approve, verify, and apply structured
  authoring changes.
- [Use cases](use-cases.md): operational workflow patterns and limits.

## Operate And Secure It

- [Secrets and providers](secrets-and-providers.md): OpenAI, Ollama, and the
  separate delegated Codex authentication path.
- [Security](security.md): current trust model, implemented controls, and known
  gaps.
- [CI and local validation](ci.md): normal, coverage, package, and opt-in live
  test gates.
- [Release flow](release.md): build artifacts, checksums, and attestations.

## Examples

The [traphouse](traphouse/readme.md) contains runnable Ollama workflows,
authoring fixtures, and operational drills. Validation and formatting commands
are offline; running an example round calls the configured local Ollama service.

## Design Records

The [design index](design/readme.md) separates current contracts from completed
implementation plans and historical decision records. Plans describe how a
feature was built; they are not a substitute for current CLI help or the
operator guides.
