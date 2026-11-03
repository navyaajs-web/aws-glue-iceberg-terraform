data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  tags = merge(var.tags, { "module" = "lake_storage" })

  # One entry per bucket. The key becomes part of the bucket name and is the
  # handle other modules use ("raw", "curated", "ops").
  buckets = {
    raw     = "Landing zone for source extracts; append-only, partitioned by ingest_date."
    curated = "Apache Iceberg tables written by Glue and read by Athena."
    ops     = "Glue scripts, Glue temporary files and Athena query results."
  }

  bucket_names = {
    for key in keys(local.buckets) :
    key => join("-", compact([var.name_prefix, key, var.bucket_suffix]))
  }

  # Lifecycle rules per bucket. Curated has no current-version expiration on
  # purpose: Iceberg tracks every data file in its metadata, so S3 must never
  # delete live files behind its back. Snapshot expiry is an Iceberg concern
  # (CALL system.expire_snapshots), not an S3 one.
  lifecycle_rules = {
    raw = [
      {
        id              = "raw-tiering"
        prefix          = ""
        transition_days = var.raw_transition_to_ia_days
        expiration_days = var.raw_expiration_days > 0 ? var.raw_expiration_days : null
      },
    ]
    curated = []
    ops = [
      {
        id              = "expire-glue-temp"
        prefix          = "glue-temp/"
        transition_days = null
        expiration_days = var.ops_temp_expiration_days
      },
      {
        id              = "expire-athena-results"
        prefix          = "athena-results/"
        transition_days = null
        expiration_days = var.ops_temp_expiration_days
      },
    ]
  }
}

# ---------------------------------------------------------------------------
# Customer-managed KMS key shared by the lake. One key keeps the IAM story
# simple (one ARN to scope); split per layer if different teams own them.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "lake" {
  description             = "${var.name_prefix} data lake encryption key"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = var.kms_deletion_window_days
  policy                  = jsonencode(local.kms_key_policy)
  tags                    = local.tags
}

resource "aws_kms_alias" "lake" {
  name          = "alias/${var.name_prefix}-lake"
  target_key_id = aws_kms_key.lake.key_id
}

locals {
  kms_key_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        # Delegates key access to IAM in this account. Without this statement
        # IAM policies (like the Glue job role's) could not grant key usage.
        # In a key policy "Resource": "*" means "this key".
        Sid       = "EnableIamPolicies"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # CloudWatch Logs encrypts Glue job logs and Step Functions logs with
        # this key. The encryption-context condition stops any other log group
        # from using it.
        Sid       = "AllowCloudWatchLogsForLakeLogGroups"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = [
              "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws-glue/*",
              "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/vendedlogs/states/${var.name_prefix}-*",
            ]
          }
        }
      },
    ]
  }
}

# ---------------------------------------------------------------------------
# Buckets
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket        = local.bucket_names[each.key]
  force_destroy = var.force_destroy

  tags = merge(local.tags, {
    "layer"   = each.key
    "purpose" = each.value
  })
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  # Disables ACLs entirely; access is governed only by IAM and bucket policy.
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.buckets

  bucket                  = aws_s3_bucket.this[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.lake.arn
    }

    # S3 Bucket Keys cut KMS request volume (and cost) by orders of magnitude
    # for Spark workloads that touch many small objects.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id

  # Rules shared by every bucket.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  # Bucket-specific rules.
  dynamic "rule" {
    for_each = local.lifecycle_rules[each.key]

    content {
      id     = rule.value.id
      status = "Enabled"

      filter {
        prefix = rule.value.prefix
      }

      dynamic "transition" {
        for_each = rule.value.transition_days == null ? [] : [rule.value.transition_days]

        content {
          days          = transition.value
          storage_class = "STANDARD_IA"
        }
      }

      dynamic "expiration" {
        for_each = rule.value.expiration_days == null ? [] : [rule.value.expiration_days]

        content {
          days = expiration.value
        }
      }
    }
  }

  # Lifecycle rules reference versions, so versioning must exist first.
  depends_on = [aws_s3_bucket_versioning.this]
}

# ---------------------------------------------------------------------------
# Bucket policies: TLS only, and no object may be written with anything other
# than SSE-KMS under *this* key.
#
# Puts that send no encryption headers are allowed on purpose: the bucket
# default (above) encrypts them with the lake key. That keeps AWS services
# which rely on bucket defaults (for example Glue CreateTable writing the first
# Iceberg metadata file) working. What is denied is any request that asks for
# something weaker or different: SSE-S3 (AES256), another KMS key, or
# "aws:kms" without a key id (which S3 would satisfy with the aws/s3 key).
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_policy" "this" {
  for_each = local.buckets

  bucket = aws_s3_bucket.this[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.this[each.key].arn, "${aws_s3_bucket.this[each.key].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyNonKmsEncryption"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.this[each.key].arn}/*"
        Condition = { StringNotEqualsIfExists = { "s3:x-amz-server-side-encryption" = "aws:kms" } }
      },
      {
        Sid       = "DenyOtherKmsKeys"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.this[each.key].arn}/*"
        Condition = { StringNotEqualsIfExists = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.lake.arn } }
      },
      {
        Sid       = "DenyKmsWithoutKeyId"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.this[each.key].arn}/*"
        Condition = {
          StringEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
          Null         = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = "true" }
        }
      },
    ]
  })

  # Applying a policy while the public access block is still being created can
  # fail with AccessDenied, so order them explicitly.
  depends_on = [aws_s3_bucket_public_access_block.this]
}
