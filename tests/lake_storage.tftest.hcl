# Unit tests for modules/lake_storage. The AWS provider is mocked, so these
# run offline with no credentials; they prove configuration logic only.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" } # AWS documentation placeholder
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }

  # Give the key a well-formed ARN so policies that embed it are realistic.
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:eu-west-1:111122223333:key/00000000-1111-2222-3333-444444444444"
      key_id = "00000000-1111-2222-3333-444444444444"
    }
  }
}

variables {
  name_prefix   = "orderlake-test"
  bucket_suffix = "abc123"
}

run "buckets_follow_naming_convention" {
  command = plan

  module {
    source = "./modules/lake_storage"
  }

  assert {
    condition = (
      aws_s3_bucket.this["raw"].bucket == "orderlake-test-raw-abc123" &&
      aws_s3_bucket.this["curated"].bucket == "orderlake-test-curated-abc123" &&
      aws_s3_bucket.this["ops"].bucket == "orderlake-test-ops-abc123"
    )
    error_message = "Bucket names must be <name_prefix>-<layer>-<suffix>."
  }

  assert {
    condition     = alltrue([for b in aws_s3_bucket.this : length(b.bucket) <= 63])
    error_message = "S3 bucket names must be at most 63 characters."
  }

  assert {
    condition     = aws_kms_alias.lake.name == "alias/orderlake-test-lake"
    error_message = "KMS alias must be alias/<name_prefix>-lake."
  }

  assert {
    condition     = alltrue([for b in aws_s3_bucket.this : b.tags["module"] == "lake_storage" && contains(keys(b.tags), "layer")])
    error_message = "Buckets must carry the module and layer tags."
  }
}

run "suffix_is_optional" {
  command = plan

  module {
    source = "./modules/lake_storage"
  }

  variables {
    bucket_suffix = ""
  }

  assert {
    condition     = aws_s3_bucket.this["raw"].bucket == "orderlake-test-raw"
    error_message = "An empty suffix must not leave a trailing hyphen."
  }
}

run "kms_key_is_customer_managed_with_rotation" {
  command = plan

  module {
    source = "./modules/lake_storage"
  }

  assert {
    condition     = aws_kms_key.lake.enable_key_rotation == true
    error_message = "Automatic key rotation must be enabled."
  }

  assert {
    condition     = aws_kms_key.lake.deletion_window_in_days == 30
    error_message = "Default deletion window should be the maximum (30 days)."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_kms_key.lake.policy).Statement :
      s.Principal != "*" && try(s.Principal.AWS, "") != "*"
    ])
    error_message = "The key policy must not grant access to a wildcard principal."
  }
}

run "every_bucket_is_encrypted_with_the_cmk" {
  command = apply # mocked apply: needed so the key ARN is known

  module {
    source = "./modules/lake_storage"
  }

  assert {
    condition = alltrue([
      for cfg in aws_s3_bucket_server_side_encryption_configuration.this :
      one(one(cfg.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    ])
    error_message = "Every bucket must default to SSE-KMS."
  }

  assert {
    condition = alltrue([
      for cfg in aws_s3_bucket_server_side_encryption_configuration.this :
      one(one(cfg.rule).apply_server_side_encryption_by_default).kms_master_key_id == aws_kms_key.lake.arn
    ])
    error_message = "Every bucket must use the module's customer-managed key."
  }

  assert {
    condition     = alltrue([for cfg in aws_s3_bucket_server_side_encryption_configuration.this : one(cfg.rule).bucket_key_enabled])
    error_message = "S3 Bucket Keys should be enabled to limit KMS request costs."
  }
}

run "buckets_are_private_versioned_and_acl_free" {
  command = plan

  module {
    source = "./modules/lake_storage"
  }

  assert {
    condition = alltrue([
      for p in aws_s3_bucket_public_access_block.this :
      p.block_public_acls && p.block_public_policy && p.ignore_public_acls && p.restrict_public_buckets
    ])
    error_message = "All four public access block settings must be on for every bucket."
  }

  assert {
    condition     = alltrue([for v in aws_s3_bucket_versioning.this : one(v.versioning_configuration).status == "Enabled"])
    error_message = "Versioning must be enabled on every bucket."
  }

  assert {
    condition     = alltrue([for o in aws_s3_bucket_ownership_controls.this : one(o.rule).object_ownership == "BucketOwnerEnforced"])
    error_message = "ACLs must be disabled (BucketOwnerEnforced)."
  }
}

run "bucket_policies_enforce_tls_and_kms" {
  command = apply

  module {
    source = "./modules/lake_storage"
  }

  assert {
    condition = alltrue([
      for p in aws_s3_bucket_policy.this : anytrue([
        for s in jsondecode(p.policy).Statement :
        s.Effect == "Deny" && s.Action == "s3:*" && s.Condition.Bool["aws:SecureTransport"] == "false"
      ])
    ])
    error_message = "Every bucket policy must deny requests that are not over TLS."
  }

  assert {
    condition = alltrue([
      for p in aws_s3_bucket_policy.this : anytrue([
        for s in jsondecode(p.policy).Statement :
        s.Effect == "Deny" && s.Action == "s3:PutObject" &&
        try(s.Condition.StringNotEqualsIfExists["s3:x-amz-server-side-encryption"], "") == "aws:kms"
      ])
    ])
    error_message = "Every bucket policy must deny puts that request non-KMS encryption."
  }

  assert {
    condition = alltrue([
      for p in aws_s3_bucket_policy.this : anytrue([
        for s in jsondecode(p.policy).Statement :
        s.Effect == "Deny" && s.Action == "s3:PutObject" &&
        try(s.Condition.StringNotEqualsIfExists["s3:x-amz-server-side-encryption-aws-kms-key-id"], "") == aws_kms_key.lake.arn
      ])
    ])
    error_message = "Every bucket policy must deny puts that use a different KMS key."
  }
}

run "lifecycle_rules_match_each_layer" {
  command = plan

  module {
    source = "./modules/lake_storage"
  }

  assert {
    condition = alltrue([
      for lc in aws_s3_bucket_lifecycle_configuration.this :
      contains([for r in lc.rule : r.id], "abort-incomplete-multipart-uploads") &&
      contains([for r in lc.rule : r.id], "expire-noncurrent-versions")
    ])
    error_message = "Every bucket must abort stale multipart uploads and expire noncurrent versions."
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_lifecycle_configuration.this["raw"].rule :
      r.id == "raw-tiering" && one(r.transition).storage_class == "STANDARD_IA"
    ])
    error_message = "Raw data must tier to Standard-IA."
  }

  assert {
    condition     = alltrue([for r in aws_s3_bucket_lifecycle_configuration.this["curated"].rule : length(r.expiration) == 0])
    error_message = "Curated (Iceberg) objects must never be expired by S3 lifecycle rules."
  }
}

run "rejects_invalid_name_prefix" {
  command = plan

  module {
    source = "./modules/lake_storage"
  }

  variables {
    name_prefix = "Order_Lake"
  }

  expect_failures = [var.name_prefix]
}

run "rejects_too_early_ia_transition" {
  command = plan

  module {
    source = "./modules/lake_storage"
  }

  variables {
    raw_transition_to_ia_days = 7
  }

  expect_failures = [var.raw_transition_to_ia_days]
}
