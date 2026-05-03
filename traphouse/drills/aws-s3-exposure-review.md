# AWS S3 Exposure Review

This drill reviews S3 bucket exposure from approved AWS exports and IaC diffs.
It flags public access, risky bucket policies, missing encryption, weak logging,
and unexpected cross-account grants without making changes.

## Why It Is Interesting

S3 exposure incidents usually come from policy details that are easy to miss:
`Principal: "*"`, public ACL compatibility, disabled block-public-access, broad
cross-account access, or buckets that drift from IaC. The drill makes those
checks repeatable and auditable.

## Workflow Shape

```yaml
kind: workflow
id: aws_s3_exposure_review
version: 1.0.0
shots:
  - id: read_bucket_inventory
    kind: slug
    agent: s3_inventory_reader
    tools: [shell_read]
    prompt: |
      Read approved S3 bucket inventory exports. Extract bucket names, regions,
      tags, encryption status, versioning, logging, and block public access
      status.

  - id: read_bucket_policies
    kind: slug
    agent: s3_policy_reviewer
    tools: [shell_read]
    prompt: |
      Read approved bucket policy and ACL exports. Identify public principals,
      cross-account grants, wildcard actions, insecure transport exceptions,
      and policy statements without conditions.

  - id: compare_iac
    kind: slug
    agent: iac_reader
    tools: [shell_read]
    prompt: |
      Read approved Terraform or CloudFormation diffs. Identify buckets whose
      desired policy differs from exported runtime evidence.

  - id: exposure_report
    kind: slug
    agent: cloud_security_reviewer
    depends_on:
      - read_bucket_inventory
      - read_bucket_policies
      - compare_iac
    prompt: |
      Produce a bucket exposure report. Group findings by urgent, scheduled,
      and informational. Include exact bucket names, evidence source, and owner
      tag when available. Do not recommend deleting buckets.

  - id: owner_gate
    kind: safety
    depends_on: [exposure_report]
    description: "Data owner approval before remediation tickets or policy change"
```

## Example Evidence Exports

```bash
aws s3api list-buckets > evidence/s3-buckets.json
aws s3control get-public-access-block --account-id "$ACCOUNT_ID" \
  > evidence/s3-account-public-access-block.json

for bucket in $(jq -r '.Buckets[].Name' evidence/s3-buckets.json); do
  aws s3api get-bucket-policy --bucket "$bucket" \
    > "evidence/s3-policy-$bucket.json" || true
  aws s3api get-public-access-block --bucket "$bucket" \
    > "evidence/s3-public-access-$bucket.json" || true
done
```

## CLI Flow

```bash
twelvgaige round run workflows/aws_s3_exposure_review.yaml \
  --input '{
    "account":"prod-data",
    "bucket_inventory":"evidence/s3-buckets.json",
    "policy_exports":"evidence/s3-policy-*.json",
    "public_access_exports":"evidence/s3-public-access-*.json",
    "iac_diff":"evidence/s3-iac.diff"
  }' \
  --format json
```

## Chokes

- Keep remediation outside this round.
- Use bucket and account allowlists for future native AWS tools.
- Do not read object contents; this drill reviews metadata and policy only.
- Treat bucket names and policy principals as sensitive in public reports.
