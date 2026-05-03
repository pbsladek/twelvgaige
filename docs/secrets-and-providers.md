# Secrets And LLM Providers

Twelvgaige keeps provider credentials out of workflow and agent shells. Shells
choose what should run. Trusted runtime configuration supplies the credentials
needed to call a provider.

## Credential Flow

An agent shell may select a provider and model:

```yaml
kind: agent
id: release_reviewer
version: 1.0.0
provider: openai
model: gpt-4.1
system_prompt: Review release evidence and return concise JSON.
```

That file must not contain an API key, bearer token, base URL, proxy setting, or
custom auth header. During a shot, Twelvgaige resolves provider config in this
order:

1. Explicit process options, used by tests and embedded callers.
2. Trusted Elixir application config under `:twelvgaige, :llm_providers`.
3. Environment variables visible to the running foreground command or Breech
   daemon process.

The resolved API key is used only by the provider adapter to build the outgoing
HTTP request. It is not inserted into prompts, shell data, round input, watch
events, metrics, or audit output.

## Provider Environment Variables

| Provider | Secret Variables | Endpoint Variables |
| --- | --- | --- |
| `openai` | `TWELVGAIGE_OPENAI_API_KEY`, then `OPENAI_API_KEY` | `TWELVGAIGE_OPENAI_BASE_URL` |
| `anthropic` | `TWELVGAIGE_ANTHROPIC_API_KEY`, then `ANTHROPIC_API_KEY` | `TWELVGAIGE_ANTHROPIC_BASE_URL` |
| `gemini` | `TWELVGAIGE_GEMINI_API_KEY`, `GEMINI_API_KEY`, then `GOOGLE_API_KEY` | `TWELVGAIGE_GEMINI_BASE_URL` |
| `ollama` | none by default | `TWELVGAIGE_OLLAMA_BASE_URL`, then `OLLAMA_HOST` |

The `TWELVGAIGE_*` variables let an operator give this tool scoped credentials
without affecting other OpenAI, Anthropic, or Google tooling in the same shell.
Provider-standard variables are supported because they are familiar and work
well in local development.

Endpoint overrides are trusted runtime config. Hosted providers must use HTTPS
by default, must not contain URL userinfo, and are denied if they target
loopback, private, or `.local` destinations unless an embedded caller explicitly
allows that policy exception. Ollama is the opposite: it may use HTTP, but it
must target loopback by default.

## OpenAI How-To

Set an OpenAI API key before starting the CLI or daemon:

```bash
export OPENAI_API_KEY='sk-...'
```

Or use a Twelvgaige-specific variable:

```bash
export TWELVGAIGE_OPENAI_API_KEY='sk-...'
```

Create an agent shell:

```yaml
kind: agent
id: openai_reviewer
version: 1.0.0
provider: openai
model: gpt-4.1
system_prompt: Return factual JSON. Do not decide workflow routing.
```

Run a workflow that references the agent:

```bash
twelvgaige round run workflows/release.yaml \
  --agent-shell agents/openai_reviewer.yaml \
  --input '{"release":"2026.05.02"}'
```

For daemon mode, the daemon must inherit the environment. If Breech was already
running before the variable was set, restart it:

```bash
twelvgaige daemon stop
OPENAI_API_KEY='sk-...' twelvgaige daemon serve
```

## Does This Use Codex Credentials?

No. The OpenAI provider calls the OpenAI API with an API key. It does not read a
Codex CLI login, browser session, ChatGPT session, or local Codex config.

Codex can help develop Twelvgaige, and Twelvgaige can call OpenAI models through
the OpenAI API, but those are separate credential paths. Do not copy Codex
session material into Twelvgaige. If a future integration treats Codex as a
separate local tool, it should be modeled as an explicit tool with its own
policy and audit boundary, not as hidden provider auth.

## Security Properties

- Workflow and agent shells are safe to commit only if they contain no secrets.
- Provider keys are held in process memory and sent only as provider HTTP auth
  headers.
- OpenAI uses `Authorization: Bearer ...`.
- Anthropic uses `x-api-key`.
- Gemini uses `x-goog-api-key`.
- Ollama uses no credential by default.
- Logs and provider response metadata redact common secret fields, auth headers,
  cookies, URL query secrets, tokens, passwords, and API keys.
- Metrics use provider/model/status labels and never include prompts, tool
  output, response bodies, or credentials.
- Audit records are sanitized before persistence, but prompts and tool outputs
  can still contain sensitive operational data. Do not put long-lived secrets
  into prompts, round input, shell files, tool output, or model responses.
- The daemon reads environment variables at runtime. Anyone who can inspect the
  process environment or memory may be able to see credentials.

## Runtime Config Example

Embedded callers may configure providers without environment variables:

```elixir
Application.put_env(:twelvgaige, :llm_providers,
  openai: [
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    base_url: "https://api.openai.com/v1/chat/completions"
  ]
)
```

Use application config only from trusted boot/runtime code. Do not load it from
workflow shells or unreviewed repository files.

## Secret Handling Rules

- Prefer short-lived or scoped provider keys where the provider supports them.
- Prefer `TWELVGAIGE_*` variables on shared workstations to avoid accidental
  reuse by other tools.
- Restart Breech after rotating a key.
- Keep live provider tests opt-in. Normal `mix test` uses mock providers and
  fake transports.
- Treat Kubernetes, cloud, Git, and shell credentials as tool credentials. They
  are not provider credentials and must be scoped by tool policy, local config,
  and safety shots.
