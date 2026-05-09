# Live E2E Implementation Plan

Live E2E proves integration boundaries that the normal offline suite must not
touch: disposable Kubernetes clusters, hosted LLM providers, SQLCipher-linked
SQLite, and OS key storage. These checks are intentionally opt-in because they
need local infrastructure, credentials, platform-specific services, or slower
setup.

## Goals

- Keep ordinary pull requests deterministic, offline, and credential-free.
- Make each live suite explicit about opt-in environment variables.
- Capture enough logs and diagnostics to reproduce failures locally.
- Protect credentialed suites with GitHub environments and manual approval.
- Keep live jobs out of required branch protection.

## Suites

| Suite | Trigger | Environment | Purpose |
| --- | --- | --- | --- |
| k3d | weekly schedule or manual | none | Build a disposable Kubernetes cluster and run `:k8s_live` tests. |
| providers | manual only | `live-providers` | Call selected live Anthropic/OpenAI/Gemini/Ollama providers. |
| sqlcipher | manual only | `live-sqlcipher` | Rebuild SQLite driver against SQLCipher and run encrypted-store tests. |
| keychain | manual only | `live-keychain` | Verify macOS Keychain backend creates, rotates, and deletes test keys. |

## Phases

### Phase L0 - Workflow Wiring

- Add `.github/workflows/live-e2e.yml`.
- Add `make e2e-k3d`, `make e2e-provider-live`,
  `make e2e-sqlcipher-live`, and `make keychain-smoke-macos`.
- Require explicit opt-in env vars in Make targets and ExUnit tags.
- Pin all reusable GitHub Actions to full commit SHAs.

Status: implemented.

### Phase L1 - Artifacts And Diagnostics

- Root live artifacts under a deterministic per-job directory.
- Always upload live artifacts, even when the command exits successfully.
- Capture k3d cluster diagnostics on failure.
- Capture provider, SQLCipher, and keychain test logs without printing secrets.

Status: implemented.

### Phase L2 - Protected Environments

- Use `live-providers`, `live-sqlcipher`, and `live-keychain` GitHub
  environments for credentialed/manual jobs.
- Configure the environments in GitHub repository settings with manual approval
  where credentials or cost exposure matter.
- Keep scheduled k3d uncredentialed.

Status: implemented in workflow; repository environment settings must be
configured in GitHub.

### Phase L3 - Confirmation And Promotion

- Run each manual suite once from GitHub Actions.
- Record provider/model combinations that pass reliably.
- Keep live suites non-required unless a future release process explicitly
  needs a manual live-health gate.
- If a live suite flakes, fix it or quarantine it behind a narrower manual
  option; do not add blind retries.

Status: pending remote manual confirmation.

## Local Commands

Set up a repeatable local toolchain where possible:

```bash
mise install
make doctor
make doctor-live
```

Run all offline e2e suites and keep artifacts:

```bash
make e2e-artifacts
```

Run explicitly enabled live suites through the aggregate target:

```bash
make e2e-live-local K3D_LIVE=1
make e2e-live-local PROVIDER_LIVE=1 PROVIDER_LIVE_PROVIDERS=openai
make e2e-live-local SQLCIPHER_LIVE=1 SQLCIPHER_PREFIX=/usr
make e2e-live-local KEYCHAIN_LIVE=1
```

Or run individual suites:

```bash
make e2e-k3d K3D_LIVE=1
make e2e-provider-live PROVIDER_LIVE=1 PROVIDER_LIVE_PROVIDERS=openai
make e2e-sqlcipher-live SQLCIPHER_PREFIX=/usr
make keychain-smoke-macos KEYCHAIN_LIVE=1
```

Provider-live commands require provider-specific key/model environment
variables. SQLCipher requires a SQLCipher-linked SQLite build. Keychain requires
macOS.

## Done Criteria

- Each live job has a bounded timeout.
- Each live job uploads logs or diagnostics.
- Credentialed jobs use protected GitHub environments.
- Normal PR checks do not require live credentials.
- Local setup has a pinned-tool hint and a doctor command.
- Manual live jobs have been confirmed in GitHub Actions.
