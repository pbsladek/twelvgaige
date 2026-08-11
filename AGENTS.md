# Repository Instructions

## Supported Providers And Agent Runtimes

Twelvgaige supports only these provider and agent-runtime integrations:

- Codex
- OpenAI
- OpenCode
- Ollama

Do not suggest Claude or any other provider or agent runtime. Do not describe
unsupported integrations as planned features, candidates, alternatives, or
recommended future work. Keep implementation, documentation, examples, design
discussion, and product recommendations within the four integrations listed
above unless the user explicitly changes this policy.

## Supported Platforms

Twelvgaige supports only macOS and Linux. Windows is not supported and is not a
future target.

Do not add or suggest Windows builds, packages, CI jobs, runtime fallbacks,
filesystem or credential backends, IPC transports, documentation, examples, or
qualification work. Remove Windows-specific product code when encountered.
References that are part of a pinned upstream protocol schema, a vulnerability
advisory, or a security deny-list may remain when removing them would weaken
schema fidelity or platform-independent protection; those references do not
constitute Windows support.
