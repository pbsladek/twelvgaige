# Design And Implementation Records

These documents serve different purposes. Use current contracts for expected
behavior and implementation records for the reasoning and qualification history
behind it. Command examples in older plans may describe the implementation
stage in which they were written; `twelvgaige --help` is authoritative for the
installed CLI.

## Current Contracts

- [Implementation spec](spec.md): normative workflow, runtime, provider, tool,
  persistence, API, security, and testing contract.
- [Delegated-agent control plane](delegated-agent-control-plane-design.md):
  implemented single-user delegated-session, sandbox, authentication, egress,
  manager, and operations design.
- [Release checklist](release-checklist.md): current local single-node release
  gates and no-go criteria.
- [Programmatic shell RFC](programmatic-shell-rfc.md): accepted gating policy;
  no programmatic shell runtime is enabled.
- [Patch-apply RFC](patch-apply-rfc.md): accepted design for digest-bound,
  human-approved authoring patches.

## Security Records

- [Security hardening plan](security-plan.md): detailed control inventory and
  remaining review work. The operator-facing [security guide](../security.md)
  is the concise current posture.
- [Cryptography, TLS, and encryption plan](crypto-tls-encryption-plan.md):
  implemented controls, platform qualification notes, and explicitly deferred
  encryption work.

## Implementation And Qualification Records

- [Authoring completion](authoring-completion-plan.md)
- [Developer CLI, Git, and workspace plan](developer-cli-git-workspace-plan.md)
- [K3d Git and HTTP live tests](k3d-git-http-live-test-plan.md)
- [Live E2E](live-e2e-implementation-plan.md)
- [Shell formats](shell-formats-plan.md)
- [Shot authoring and management](shot-authoring-management-plan.md)
- [Testing, coverage, and E2E](testing-coverage-e2e-plan.md)

Most implementation work in these records is complete. Any remaining external
qualification or repository-setting step is stated in the individual document.

## Historical Direction

- [Initial project plan and review](plan.md): original direction that preceded
  the normative implementation spec. Where the two conflict, the spec wins.
