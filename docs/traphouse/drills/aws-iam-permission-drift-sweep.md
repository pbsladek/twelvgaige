# AWS IAM Permission Drift Sweep

This drill reviews IAM snapshots, policy diffs, and access findings to catch
privilege drift before it becomes an incident. It is intentionally read-only:
agents analyze exported evidence while Twelvgaige keeps the review deterministic.

## Why It Is Interesting

IAM reviews are noisy. A human needs the short list: new admin-like grants,
wildcard resources, public trust policies, stale roles, risky service-linked
permissions, and what changed since the last review. Twelvgaige can split that
work across specialist shots and keep an audit trail of exactly which exports
were reviewed.

## Workflow Shape

```yaml
kind: workflow
id: aws_iam_permission_drift_sweep
version: 1.0.0
policy:
  resource_profile: minimal
shots:
  - id: read_iam_inventory
    kind: slug
    agent: iam_inventory_reader
    tools: [shell_read]
    prompt: |
      Read the approved IAM inventory exports from round input. Extract roles,
      users, groups, attached policies, trust policies, last-used timestamps,
      and permission boundaries. Do not infer missing resources.

  - id: read_policy_diff
    kind: slug
    agent: policy_diff_reviewer
    tools: [shell_read]
    prompt: |
      Read the approved policy diff or IaC diff files. Identify newly added
      actions, wildcard resources, trust policy changes, and removed guardrails.

  - id: access_analyzer_review
    kind: slug
    agent: access_analyzer_reader
    tools: [shell_read]
    prompt: |
      Read approved IAM Access Analyzer or security finding exports. Extract
      external access, public access, cross-account trust, and unresolved status.

  - id: drift_decision
    kind: slug
    agent: cloud_security_reviewer
    depends_on:
      - read_iam_inventory
      - read_policy_diff
      - access_analyzer_review
    prompt: |
      Produce a permission drift decision with severity, affected principal,
      risky actions, blast radius, owner, and recommended next review. Do not
      propose deleting or changing policies in this round.

  - id: security_owner_gate
    kind: safety
    depends_on: [drift_decision]
    description: "Security owner approval before opening remediation work"
```

## Example Evidence Exports

```bash
aws iam get-account-authorization-details \
  --filter User Role Group LocalManagedPolicy \
  > evidence/iam-authz.json

aws accessanalyzer list-findings \
  --analyzer-arn "$ANALYZER_ARN" \
  > evidence/access-analyzer-findings.json

git diff main...HEAD -- infra/aws/iam > evidence/iam-iac.diff
```

## CLI Flow

```bash
twelvgaige round run workflows/aws_iam_permission_drift_sweep.yaml \
  --input '{
    "iam_inventory":"evidence/iam-authz.json",
    "access_findings":"evidence/access-analyzer-findings.json",
    "policy_diff":"evidence/iam-iac.diff",
    "account":"prod-security"
  }' \
  --detach

twelvgaige round watch <round-id> --follow --until-terminal
twelvgaige round audit <round-id> --format ndjson
```

## Future Native AWS Tools

This drill becomes stronger with read-only AWS tools such as:

- `aws_iam_get_account_authorization_details`
- `aws_access_analyzer_list_findings`
- `aws_organizations_describe_account`
- `aws_cloudtrail_lookup_events`

Those tools should require runtime account/region allowlists and never accept
arbitrary AWS CLI strings from model output.

## Chokes

- Keep this round read-only.
- Use exported JSON from a least-privilege audit role.
- Treat role names, account IDs, and policy ARNs as sensitive operational data.
- Open remediation as a separate guarded round after human review.
