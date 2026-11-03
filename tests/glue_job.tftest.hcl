# Unit tests for modules/glue_job: least-privilege IAM, Iceberg settings and
# incremental parameters. All inputs are literals, so the IAM policy is fully
# known at plan time and can be inspected without an apply.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
}

variables {
  name_prefix         = "orderlake-test"
  script_path         = "./glue/orders_incremental.py"
  raw_bucket_name     = "orderlake-test-raw-abc123"
  curated_bucket_name = "orderlake-test-curated-abc123"
  ops_bucket_name     = "orderlake-test-ops-abc123"
  kms_key_arn         = "arn:aws:kms:eu-west-1:111122223333:key/00000000-1111-2222-3333-444444444444"
  database_name       = "orderlake_test"
  table_name          = "orders"
}

run "job_role_has_no_wildcard_s3_or_kms_resources" {
  command = plan

  module {
    source = "./modules/glue_job"
  }

  # For every statement that grants any s3:* or kms:* action, no resource may
  # be "*" and no resource may be a bare "arn:aws:s3:::*"-style wildcard.
  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.job.policy).Statement : [
        for r in flatten([s.Resource]) : r != "*" && !startswith(r, "arn:aws:s3:::*")
      ] if anytrue([for a in flatten([s.Action]) : startswith(a, "s3:") || startswith(a, "kms:")])
    ]))
    error_message = "S3 and KMS permissions must name specific resources, never \"*\"."
  }

  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.job.policy).Statement : [
        for a in flatten([s.Action]) : a != "*" && a != "s3:*" && a != "kms:*" && a != "glue:*"
      ]
    ]))
    error_message = "No wildcard actions in the job policy."
  }
}

run "job_role_is_scoped_to_exact_prefixes_and_key" {
  command = plan

  module {
    source = "./modules/glue_job"
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.job.policy).Statement : s.Resource if s.Sid == "ReadRawPrefix"][0]
      == ["arn:aws:s3:::orderlake-test-raw-abc123/orders/*"]
    )
    error_message = "Raw read access must be limited to the raw_prefix."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.job.policy).Statement : s.Resource if s.Sid == "ReadWriteIcebergWarehouse"][0]
      == ["arn:aws:s3:::orderlake-test-curated-abc123/warehouse/*"]
    )
    error_message = "Write access must be limited to the Iceberg warehouse prefix."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.job.policy).Statement :
      !contains(flatten([s.Action]), "s3:PutObject") || alltrue([
        for r in flatten([s.Resource]) :
        startswith(r, "arn:aws:s3:::orderlake-test-curated-abc123/warehouse/") ||
        startswith(r, "arn:aws:s3:::orderlake-test-ops-abc123/glue-temp/")
      ])
    ])
    error_message = "The job may only write to the warehouse prefix and its own temp prefix (never to raw)."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.job.policy).Statement :
      s.Resource == ["arn:aws:kms:eu-west-1:111122223333:key/00000000-1111-2222-3333-444444444444"]
      if anytrue([for a in flatten([s.Action]) : startswith(a, "kms:")])
    ])
    error_message = "KMS permissions must target only the lake key."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.job.policy).Statement :
      try(length(s.Condition.StringLike["s3:prefix"]) > 0, false)
      if contains(flatten([s.Action]), "s3:ListBucket")
    ])
    error_message = "ListBucket must be constrained with an s3:prefix condition."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.job.policy).Statement : s.Resource if s.Sid == "IcebergCatalogCommit"][0]
      == [
        "arn:aws:glue:eu-west-1:111122223333:catalog",
        "arn:aws:glue:eu-west-1:111122223333:database/orderlake_test",
        "arn:aws:glue:eu-west-1:111122223333:table/orderlake_test/orders",
      ]
    )
    error_message = "Catalog permissions must be limited to the target database and table."
  }

  assert {
    condition     = jsondecode(aws_iam_role.job.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111122223333"
    error_message = "The trust policy must pin aws:SourceAccount (confused-deputy protection)."
  }
}

run "job_uses_iceberg_and_incremental_settings" {
  command = plan

  module {
    source = "./modules/glue_job"
  }

  assert {
    condition     = aws_glue_job.this.name == "orderlake-test-orders-incremental"
    error_message = "Job name must be <name_prefix>-<job_name>."
  }

  assert {
    condition     = aws_glue_job.this.glue_version == "5.0" && aws_glue_job.this.default_arguments["--datalake-formats"] == "iceberg"
    error_message = "The job must run on Glue 5.0 by default with the Iceberg data lake format."
  }

  assert {
    condition = alltrue([
      for fragment in [
        "spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
        "spark.sql.catalog.glue_catalog.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog",
        "spark.sql.catalog.glue_catalog.warehouse=s3://orderlake-test-curated-abc123/warehouse",
        "spark.sql.catalog.glue_catalog.s3.sse.type=kms",
      ] : strcontains(aws_glue_job.this.default_arguments["--conf"], fragment)
    ])
    error_message = "--conf must register the Iceberg Glue catalog with SSE-KMS writes."
  }

  assert {
    condition = (
      aws_glue_job.this.default_arguments["--raw_prefix"] == "orders" &&
      aws_glue_job.this.default_arguments["--target_table"] == "glue_catalog.orderlake_test.orders" &&
      aws_glue_job.this.default_arguments["--lookback_days"] == "1" &&
      aws_glue_job.this.default_arguments["--job-bookmark-option"] == "job-bookmark-disable"
    )
    error_message = "Incremental parameters must be passed to the job."
  }

  assert {
    condition     = one(aws_glue_job.this.execution_property).max_concurrent_runs == 1 && aws_glue_job.this.max_retries == 0
    error_message = "One run at a time (Iceberg commits) and no Glue-level retries (the orchestrator decides)."
  }

  assert {
    condition = (
      one(one(aws_glue_security_configuration.job.encryption_configuration).s3_encryption).s3_encryption_mode == "SSE-KMS" &&
      one(one(aws_glue_security_configuration.job.encryption_configuration).cloudwatch_encryption).cloudwatch_encryption_mode == "SSE-KMS"
    )
    error_message = "Glue temp files and logs must be KMS-encrypted."
  }

  assert {
    condition     = aws_s3_object.script.server_side_encryption == "aws:kms" && aws_s3_object.script.key == "scripts/orders-incremental.py"
    error_message = "The script must be uploaded under scripts/ with SSE-KMS."
  }
}

run "glue_4_is_supported" {
  command = plan

  module {
    source = "./modules/glue_job"
  }

  variables {
    glue_version  = "4.0"
    lookback_days = 3
  }

  assert {
    condition     = aws_glue_job.this.glue_version == "4.0" && aws_glue_job.this.default_arguments["--lookback_days"] == "3"
    error_message = "Glue 4.0 and a custom lookback must be accepted."
  }
}

run "rejects_unsupported_glue_version" {
  command = plan

  module {
    source = "./modules/glue_job"
  }

  variables {
    glue_version = "3.0"
  }

  expect_failures = [var.glue_version]
}

run "rejects_alias_instead_of_key_arn" {
  command = plan

  module {
    source = "./modules/glue_job"
  }

  variables {
    kms_key_arn = "alias/orderlake-test-lake"
  }

  expect_failures = [var.kms_key_arn]
}
