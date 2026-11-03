data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  tags = merge(var.tags, { "module" = "glue_job" })

  full_job_name = "${var.name_prefix}-${var.job_name}"
  script_key    = "scripts/${var.job_name}.py"
  temp_prefix   = "glue-temp/${var.job_name}"

  # ARNs are built from names (not taken from resource attributes) so the IAM
  # policy is fully known at plan time and reviewable in the plan output.
  raw_bucket_arn     = "arn:${local.partition}:s3:::${var.raw_bucket_name}"
  curated_bucket_arn = "arn:${local.partition}:s3:::${var.curated_bucket_name}"
  ops_bucket_arn     = "arn:${local.partition}:s3:::${var.ops_bucket_name}"

  glue_arn_base = "arn:${local.partition}:glue:${local.region}:${local.account_id}"
  logs_arn_base = "arn:${local.partition}:logs:${local.region}:${local.account_id}"

  warehouse_uri = "s3://${var.curated_bucket_name}/${var.warehouse_prefix}"
  target_table  = "glue_catalog.${var.database_name}.${var.table_name}"

  # Spark settings that register an Iceberg catalog named "glue_catalog" backed
  # by the Glue Data Catalog. Glue accepts several --conf pairs in one value by
  # chaining them with " --conf ". S3FileIO is told to send SSE-KMS headers
  # with the lake key so writes are explicit about their encryption.
  iceberg_spark_conf = join(" --conf ", [
    "spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
    "spark.sql.catalog.glue_catalog=org.apache.iceberg.spark.SparkCatalog",
    "spark.sql.catalog.glue_catalog.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog",
    "spark.sql.catalog.glue_catalog.io-impl=org.apache.iceberg.aws.s3.S3FileIO",
    "spark.sql.catalog.glue_catalog.warehouse=${local.warehouse_uri}",
    "spark.sql.catalog.glue_catalog.s3.sse.type=kms",
    "spark.sql.catalog.glue_catalog.s3.sse.key=${var.kms_key_arn}",
  ])

  default_arguments = {
    "--job-language"                     = "python"
    "--datalake-formats"                 = "iceberg"
    "--conf"                             = local.iceberg_spark_conf
    "--TempDir"                          = "s3://${var.ops_bucket_name}/${local.temp_prefix}/"
    "--enable-metrics"                   = "true"
    "--enable-observability-metrics"     = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-auto-scaling"              = "true"

    # Incrementality comes from a high-water mark read from the target table,
    # not from Glue job bookmarks: bookmarks only track DynamicFrame sources,
    # are invisible to Athena users and cannot be reset per partition. The
    # watermark approach is reproducible from the data alone.
    "--job-bookmark-option" = "job-bookmark-disable"
    "--raw_bucket"          = var.raw_bucket_name
    "--raw_prefix"          = var.raw_prefix
    "--target_table"        = local.target_table
    "--lookback_days"       = tostring(var.lookback_days)
  }
}

# ---------------------------------------------------------------------------
# Script upload
# ---------------------------------------------------------------------------
resource "aws_s3_object" "script" {
  bucket                 = var.ops_bucket_name
  key                    = local.script_key
  source                 = var.script_path
  source_hash            = filemd5(var.script_path)
  server_side_encryption = "aws:kms"
  kms_key_id             = var.kms_key_arn
  content_type           = "text/x-python"
  tags                   = local.tags
}

# ---------------------------------------------------------------------------
# IAM: one role per job, scoped to exact prefixes, one key and one table.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "job" {
  name                 = "${local.full_job_name}-glue"
  description          = "Execution role for the ${local.full_job_name} Glue job."
  max_session_duration = 3600
  tags                 = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
      # Confused-deputy protection: only Glue acting for this account.
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

locals {
  job_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRawPrefix"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${local.raw_bucket_arn}/${var.raw_prefix}/*"]
      },
      {
        Sid       = "ListRawPrefix"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = [local.raw_bucket_arn]
        Condition = { StringLike = { "s3:prefix" = ["${var.raw_prefix}/", "${var.raw_prefix}/*"] } }
      },
      {
        Sid      = "ReadWriteIcebergWarehouse"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = ["${local.curated_bucket_arn}/${var.warehouse_prefix}/*"]
      },
      {
        Sid       = "ListIcebergWarehouse"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = [local.curated_bucket_arn]
        Condition = { StringLike = { "s3:prefix" = ["${var.warehouse_prefix}/", "${var.warehouse_prefix}/*"] } }
      },
      {
        Sid      = "ReadJobScript"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${local.ops_bucket_arn}/${local.script_key}"]
      },
      {
        Sid      = "ReadWriteGlueTemp"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = ["${local.ops_bucket_arn}/${local.temp_prefix}/*"]
      },
      {
        Sid       = "ListGlueTemp"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = [local.ops_bucket_arn]
        Condition = { StringLike = { "s3:prefix" = ["${local.temp_prefix}/", "${local.temp_prefix}/*"] } }
      },
      {
        Sid      = "BucketLocation"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = [local.raw_bucket_arn, local.curated_bucket_arn, local.ops_bucket_arn]
      },
      {
        Sid      = "UseLakeKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [var.kms_key_arn]
      },
      {
        # Iceberg's GlueCatalog reads the table and commits by updating the
        # metadata pointer. No CreateTable/DeleteTable: Terraform owns those.
        Sid    = "IcebergCatalogCommit"
        Effect = "Allow"
        Action = ["glue:GetDatabase", "glue:GetTable", "glue:GetTables", "glue:UpdateTable"]
        Resource = [
          "${local.glue_arn_base}:catalog",
          "${local.glue_arn_base}:database/${var.database_name}",
          "${local.glue_arn_base}:table/${var.database_name}/${var.table_name}",
        ]
      },
      {
        Sid    = "WriteJobLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:AssociateKmsKey"]
        Resource = [
          "${local.logs_arn_base}:log-group:/aws-glue/*",
        ]
      },
      {
        # PutMetricData has no resource-level permissions; the namespace
        # condition is the only scoping AWS supports.
        Sid       = "PublishGlueMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = ["*"]
        Condition = { StringEquals = { "cloudwatch:namespace" = "Glue" } }
      },
    ]
  }
}

resource "aws_iam_role_policy" "job" {
  name   = "${local.full_job_name}-access"
  role   = aws_iam_role.job.id
  policy = jsonencode(local.job_policy)
}

# ---------------------------------------------------------------------------
# Encrypts what Glue itself writes: temp/shuffle files via EMRFS, CloudWatch
# logs and (if ever enabled) bookmarks, all with the lake key.
# ---------------------------------------------------------------------------
resource "aws_glue_security_configuration" "job" {
  name = "${local.full_job_name}-sec"

  encryption_configuration {
    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = var.kms_key_arn
    }

    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = var.kms_key_arn
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = var.kms_key_arn
    }
  }
}

resource "aws_glue_job" "this" {
  name                   = local.full_job_name
  description            = "Incrementally merges new ${var.raw_prefix} partitions into ${local.target_table}."
  role_arn               = aws_iam_role.job.arn
  glue_version           = var.glue_version
  worker_type            = var.worker_type
  number_of_workers      = var.number_of_workers
  timeout                = var.timeout_minutes
  execution_class        = "STANDARD"
  security_configuration = aws_glue_security_configuration.job.name

  # Retries belong to the orchestrator, which can tell transient failures from
  # data failures. Retrying inside Glue would double-run on bad data.
  max_retries = 0

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${var.ops_bucket_name}/${aws_s3_object.script.key}"
  }

  # Two concurrent MERGEs into one Iceberg table would conflict on commit;
  # a second start fails fast with ConcurrentRunsExceededException instead.
  execution_property {
    max_concurrent_runs = 1
  }

  default_arguments = local.default_arguments
  tags              = local.tags
}
