# K3D Git And HTTP Live Test Plan

Status: implemented record. The current commands and CI policy are documented
in [`../ci.md`](../ci.md).

## Goal

Expand the k3d live suite so it validates real Git and HTTP tool behavior through
the CLI/round runtime, not only isolated unit transports.

## Scope

- `[x]` Keep HTTP network policy in runtime configuration, not LLM output.
- `[x]` Add a k3d HTTP fixture service with GET and POST endpoints.
- `[x]` Add a live `http_get` happy-path round.
- `[x]` Add a live `http_get` network-policy denial round.
- `[x]` Add a safety-gated live `http_post` round and verify side effects.
- `[x]` Strengthen GitOps assertions around commit contents and untracked files.
- `[x]` Add a live `git_commit` destructive-safety denial round.

## Runtime Policy

HTTP tools require explicit allowlisted hosts. The live harness opts in with:

- `TWELVGAIGE_HTTP_ALLOWED_HOSTS`
- `TWELVGAIGE_HTTP_ALLOW_PRIVATE_HOSTS`
- `TWELVGAIGE_HTTP_TIMEOUT_MS`

The k3d suite uses `kubectl port-forward` to expose the in-cluster HTTP fixture
on loopback. Private-host access is enabled only for the specific live test
processes that need it.

## Validation

- Positive HTTP rounds must finish `complete` and include real tool output from
  the default HTTP transport.
- Negative HTTP rounds must fail with `network_policy_denied`.
- GitOps rounds must commit only the intended manifest and leave generated
  workflow files untracked.
- Git safety-denial rounds must fail with `policy_denied` and must not create
  the denied commit.
