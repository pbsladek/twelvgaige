# Payment Degradation War Room

This drill coordinates a complex customer-facing degradation: collect symptoms,
inspect Kubernetes, compare recent release evidence, estimate business impact,
pause for command approval, then apply a narrow rollback or scale action.

## Why It Shows The Power

The useful part is not that an LLM can summarize logs. The useful part is that
several specialist agents can work in parallel while OTP keeps the order of
operations hard: observe, correlate, decide, approve, act, verify.

## Workflow Shape

```yaml
kind: workflow
id: payment_degradation_war_room
version: 1.0.0
policy:
  resource_profile: laptop
shots:
  - id: edge_symptoms
    kind: slug
    agent: edge_probe
    tools: [http_get]
    prompt: |
      Fetch approved health, readiness, and synthetic-check URLs. Extract
      status codes, error messages, and affected flows.

  - id: cluster_state
    kind: slug
    agent: k8s_inspector
    tools: [kubectl_get, kubectl_logs, kubectl_events]
    prompt: |
      Inspect payment workloads, pods, events, and bounded logs. Report only
      observed state and timestamps.

  - id: release_delta
    kind: slug
    agent: release_reader
    tools: [shell_read]
    prompt: |
      Read approved release notes, deployment manifests, and changelog files
      from round input. Extract changes that may affect payment flows.

  - id: impact_model
    kind: slug
    agent: incident_analyst
    depends_on: [edge_symptoms, cluster_state, release_delta]
    prompt: |
      Correlate evidence into root-cause hypotheses, customer impact, confidence,
      rollback risk, and the safest next action. Include exact evidence links.

  - id: operator_safety
    kind: safety
    depends_on: [impact_model]
    description: "Incident commander approval before rollback, restart, or scale"

  - id: narrow_action
    kind: slug
    agent: k8s_remediator
    depends_on: [operator_safety]
    tools: [kubectl_scale, kubectl_rollout_restart]
    prompt: |
      Execute only the approved action. If the approval does not name a specific
      deployment and action, refuse and report why.

  - id: recovery_verification
    kind: slug
    agent: verifier
    depends_on: [narrow_action]
    tools: [kubectl_get, kubectl_logs, http_get]
    prompt: |
      Verify customer-facing recovery and cluster stability. Report whether the
      action improved, worsened, or did not change the incident.
```

## CLI Flow

```bash
twelvgaige daemon serve

twelvgaige round run workflows/payment_degradation_war_room.yaml \
  --input '{
    "context":"prod-us-east",
    "namespace":"payments",
    "health_urls":["https://checkout.example.com/healthz"],
    "release_files":["releases/2026-05-02.md","deploy/payments.yaml"]
  }' \
  --detach

twelvgaige round show <round-id> --format json
twelvgaige round audit <round-id>
```

Approve with an exact action:

```bash
twelvgaige round approve <round-id> \
  --shot operator_safety \
  --reason "approved rollout restart for deployments/payments-api only"
```

## Safety Notes

- This drill deliberately excludes `kubectl_delete` and `kubectl_exec`.
- Runtime Kubernetes policy should restrict context, namespace, resource, and
  deployment name patterns.
- The action shot should fail closed if approval text is vague.
- Use NDJSON watch output to feed a status board without scraping prose.
