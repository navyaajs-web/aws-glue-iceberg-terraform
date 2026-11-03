# Deploying `examples/dev` (optional)

Everything in CI runs without AWS. This page is for trying the stack in **your own** AWS account.
A deploy creates billable resources. Tear it down when you are done.

## 1. Prerequisites

- Terraform 1.9 or newer (CI uses 1.17.1) and the AWS CLI v2.
- An AWS account you control, ideally a sandbox account in an AWS Organization.
- Short-lived credentials from IAM Identity Center (SSO):
  ```bash
  aws sso login --profile your-sso-profile
  export AWS_PROFILE=your-sso-profile
  ```
  Do not create long-lived access keys for this. Do not put credentials in `.env`, `*.tfvars` or the repository.
- The deploying principal needs to manage S3, KMS, IAM roles, Glue, Athena, Step Functions, SNS and CloudWatch Logs.
  Use a sandbox admin role, or a scoped deployment role in shared accounts.

## 2. Configure

```bash
cd examples/dev
cp terraform.tfvars.example terraform.tfvars   # git-ignored
# Set bucket_suffix to your own random value, for example: openssl rand -hex 3
# Optionally add alert_email_addresses = ["you@example.com"]
```

**State.** The example has no backend, so state stays in a local `terraform.tfstate` (git-ignored).
For anything shared, add an S3 backend with encryption and native locking:

```hcl
terraform {
  backend "s3" {
    bucket       = "<your-state-bucket>"
    key          = "aws-glue-iceberg-terraform/dev.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

The state holds resource ARNs and the rendered IAM policies, but no secrets. Restrict who can read the state bucket anyway.

## 3. Deploy

```bash
terraform init
terraform plan -out tfplan
terraform apply tfplan
```

If you added email addresses, confirm the SNS subscription email. Until you do, no alerts are delivered.

## 4. Land synthetic data and run the pipeline

The job expects JSON lines under `orders/ingest_date=YYYY-MM-DD/` in the raw bucket. This snippet writes a tiny synthetic file:

```bash
RAW_BUCKET=$(terraform output -json bucket_names | jq -r .raw)
KEY_ARN=$(aws kms describe-key --key-id "$(terraform output -raw kms_key_alias)" --query KeyMetadata.Arn --output text)

cat > /tmp/orders.json <<'EOF'
{"order_id":"o-1001","customer_id":"c-001","status":"placed","total_amount":"42.50","currency":"eur","order_ts":"2026-03-01T08:00:00Z","updated_at":"2026-03-01T08:00:00Z"}
{"order_id":"o-1002","customer_id":"c-002","status":"paid","total_amount":"19.99","currency":"eur","order_ts":"2026-03-01T09:30:00Z","updated_at":"2026-03-01T09:31:00Z"}
EOF

# Uploads may rely on the bucket's default SSE-KMS or name the lake key explicitly.
# The bucket policy rejects SSE-S3 and any other KMS key.
aws s3 cp /tmp/orders.json "s3://$RAW_BUCKET/orders/ingest_date=2026-03-01/part-0000.json" \
  --sse aws:kms --sse-kms-key-id "$KEY_ARN"

aws stepfunctions start-execution --state-machine-arn "$(terraform output -raw state_machine_arn)"
```

Follow the execution in the Step Functions console. When it succeeds, query the table in the
`orderlake-dev-analytics` Athena workgroup:

```sql
SELECT order_status, count(*) AS orders, sum(order_total) AS value
FROM orderlake_dev.orders
GROUP BY order_status;
```

Land a second partition with a newer `updated_at` for `o-1001` and run the state machine again. The row is updated in place, not duplicated.

To run the pipeline on a schedule, add an EventBridge Scheduler schedule that targets the state machine. It is left out here so a dev stack never runs, and never costs money, by itself.

## 5. Cost notes (approximate, check current AWS pricing for your region)

| Resource | What drives cost | Typical dev cost |
|---|---|---|
| Glue job | DPU-hours. 2 x G.1X workers for a few minutes per run, 1-minute minimum | A few cents per run |
| KMS key | Monthly fee per customer-managed key, plus requests (S3 Bucket Keys keep requests low) | About 1 USD per month |
| S3 | Storage and requests. Versioning keeps noncurrent versions for 30 days | Cents |
| Athena | Bytes scanned, with a 10 MB minimum per query. The workgroup caps each query at 10 GB | Cents |
| Step Functions | State transitions (Standard workflow) | Negligible |
| CloudWatch Logs | Ingestion and storage. The state machine log group keeps logs for 365 days | Cents |

## 6. Security notes

- **Encryption.** All buckets, Athena results, the SNS topic, the state machine and its log group use one customer-managed key with yearly rotation. Glue temp files and Glue logs use the same key through a Glue security configuration.
- **Bucket policies.** Non-TLS requests are denied. Puts that ask for SSE-S3, another KMS key, or `aws:kms` without a key id are denied. Puts without encryption headers get the bucket default, which is the lake key. ACLs are disabled and all public access is blocked.
- **Least privilege.** The Glue role can read only `raw/orders/*`, write only `curated/warehouse/*` and its own temp prefix, use only the lake key, and update only its target table. The state machine can start only its own job and publish only to its own topic. `terraform test` asserts these scopes.
- **Not included.** These are deliberate gaps for a dev stack. Add them for production:
  - S3 server access logs or CloudTrail S3 data events.
  - Cross-region replication.
  - Lake Formation permissions.
  - VPC endpoints for Glue.
  - A permissions boundary for the roles.
  - The documented Checkov skips (see `.checkov.yaml`).
- **Iceberg maintenance.** Schedule `CALL glue_catalog.system.expire_snapshots(...)` and `rewrite_data_files` (compaction). Without them, the table keeps old snapshots and small files.

## 7. Tear down

```bash
terraform destroy
```

`force_destroy = true` in the dev example lets Terraform delete non-empty buckets. The KMS key is scheduled for deletion after a 30-day waiting period. You can cancel the deletion during that window.
