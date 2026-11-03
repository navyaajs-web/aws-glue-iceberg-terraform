locals {
  tags           = merge(var.tags, { "module" = "athena" })
  workgroup_name = "${var.name_prefix}-analytics"
}

resource "aws_athena_workgroup" "this" {
  name          = local.workgroup_name
  description   = "Queries over the ${var.name_prefix} lake; results are KMS-encrypted."
  state         = "ENABLED"
  force_destroy = var.force_destroy
  tags          = local.tags

  configuration {
    # Enforcing the workgroup configuration means a client cannot override the
    # output location or turn result encryption off.
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.bytes_scanned_cutoff_gb * 1024 * 1024 * 1024

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${var.results_bucket_name}/athena-results/${local.workgroup_name}/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }
  }
}
