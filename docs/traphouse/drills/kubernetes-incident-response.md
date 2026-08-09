# Kubernetes Incident Response

This drill shows a guarded incident workflow: inspect first, analyze second,
pause for approval, apply only a narrow remediation, then verify.

## Why It Is Interesting

Kubernetes operations are exactly where agent workflows need a deterministic
control plane. The LLM can summarize events and logs, but Elixir should decide
dependencies, retries, timeouts, safety gates, and whether a write tool may run.

## Workflow Shape

```yaml
kind: workflow
id: k8s_incident_response
version: 1.0.0
shots:
  - id: gather_state
    kind: slug
    agent: k8s_inspector
    tools:
      - kubectl_get
      - kubectl_describe
      - kubectl_logs
      - kubectl_events
    prompt: |
      Collect pod status, recent namespace events, deployment state, and bounded
      logs for the namespace in the round input. Report facts only.

  - id: analyze
    kind: slug
    agent: incident_analyst
    depends_on: [gather_state]
    prompt: |
      Identify the likely root cause, confidence, blast radius, and recommended
      remediation. Do not apply changes.

  - id: approval
    kind: safety
    depends_on: [analyze]
    description: "On-call approval before remediation"

  - id: remediate
    kind: slug
    agent: k8s_remediator
    depends_on: [approval]
    tools:
      - kubectl_rollout_restart
      - kubectl_scale
      - kubectl_apply
    prompt: |
      Apply only the approved remediation from the analysis. Use the narrowest
      tool call possible.

  - id: verify
    kind: slug
    agent: k8s_inspector
    depends_on: [remediate]
    tools:
      - kubectl_get
      - kubectl_logs
      - kubectl_events
    prompt: |
      Verify whether the workload recovered and summarize remaining risk.
```

## Agent Sketches

```yaml
kind: agent
id: k8s_inspector
version: 1.0.0
provider: openai
model: gpt-5.2
system_prompt: |
  You inspect Kubernetes state. Prefer read-only tools. Do not recommend or
  apply changes unless the workflow prompt explicitly asks for recommendations.
```

```yaml
kind: agent
id: k8s_remediator
version: 1.0.0
provider: openai
model: gpt-5.2
system_prompt: |
  You apply only approved Kubernetes remediation. Never invent resources,
  namespaces, or commands. Prefer the least destructive supported tool.
```

## CLI Flow

Run against a disposable k3d cluster while developing:

```bash
k3d cluster create twelvgaige-smoke --servers 1 --agents 0 --wait
kubectl get nodes --context k3d-twelvgaige-smoke
```

Run detached:

```bash
TWELVGAIGE_STORE_SQLITE=/tmp/twelvgaige-k8s.sqlite3 twelvgaige daemon serve
twelvgaige round run workflows/k8s_incident_response.yaml \
  --input '{"cluster":"k3d-twelvgaige-smoke","namespace":"default"}' \
  --detach
```

Approve only after review:

```bash
twelvgaige round show <round-id>
twelvgaige round audit <round-id>
twelvgaige round approve <round-id> --shot approval --reason "approved by on-call"
twelvgaige round watch <round-id> --follow --until-terminal
```

## Safety Notes

- Keep `kubectl_exec` disabled unless the workflow is trusted and explicitly
  reviewed.
- Use read-only tools in the inspection and verification shots.
- Put every write-capable shot behind a safety shot.
- Treat ambiguous crashes after side effects as reconciliation work, not a
  reason to blindly retry.
