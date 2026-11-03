data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  tags = merge(var.tags, { "module" = "orchestration" })

  state_machine_name = "${var.name_prefix}-${var.pipeline_name}"

  glue_job_arn         = "arn:${local.partition}:glue:${local.region}:${local.account_id}:job/${var.glue_job_name}"
  athena_workgroup_arn = "arn:${local.partition}:athena:${local.region}:${local.account_id}:workgroup/${var.athena_workgroup_name}"
  glue_arn_base        = "arn:${local.partition}:glue:${local.region}:${local.account_id}"
  curated_bucket_arn   = "arn:${local.partition}:s3:::${var.curated_bucket_name}"
  ops_bucket_arn       = "arn:${local.partition}:s3:::${var.ops_bucket_name}"
  athena_results       = "athena-results"
}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name              = "${local.state_machine_name}-alerts"
  kms_master_key_id = var.kms_key_arn
  tags              = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_email_addresses)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# ---------------------------------------------------------------------------
# State machine definition
#
#   RunGlueJob (sync) -> RunDataQualityQuery (sync) -> GetDataQualityResult
#     -> EvaluateDataQuality -> Succeeded | NotifyDataQualityFailure -> Fail
#   Any task error -> NotifyFailure -> Fail
#
# Retries cover throttling and transient service errors only. A Glue job that
# fails on its own (States.TaskFailed) goes straight to the alert, because
# re-running a job that failed on bad data just fails again, more expensively.
# ---------------------------------------------------------------------------
locals {
  catch_all = [{
    ErrorEquals = ["States.ALL"]
    ResultPath  = "$.error"
    Next        = "NotifyFailure"
  }]

  definition = {
    Comment = "Run ${var.glue_job_name}, then an Athena data quality query; alert on failure."
    StartAt = "RunGlueJob"
    States = {
      RunGlueJob = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::glue:startJobRun.sync"
        Parameters = {
          JobName = var.glue_job_name
        }
        ResultSelector = {
          "JobRunId.$"      = "$.Id"
          "JobRunState.$"   = "$.JobRunState"
          "ExecutionTime.$" = "$.ExecutionTime"
        }
        ResultPath = "$.glue"
        Retry = [{
          ErrorEquals = [
            "Glue.ConcurrentRunsExceededException",
            "Glue.InternalServiceException",
            "Glue.OperationTimeoutException",
            "Glue.ThrottlingException",
          ]
          IntervalSeconds = 60
          BackoffRate     = 2
          MaxAttempts     = var.glue_retry_max_attempts
          JitterStrategy  = "FULL"
        }]
        Catch = local.catch_all
        Next  = "RunDataQualityQuery"
      }

      RunDataQualityQuery = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::athena:startQueryExecution.sync"
        Parameters = {
          QueryString = var.dq_query
          WorkGroup   = var.athena_workgroup_name
          QueryExecutionContext = {
            Database = var.database_name
          }
        }
        ResultSelector = {
          "QueryExecutionId.$" = "$.QueryExecution.QueryExecutionId"
        }
        ResultPath = "$.dq_query"
        Retry = [{
          ErrorEquals     = ["Athena.TooManyRequestsException", "Athena.InternalServerException"]
          IntervalSeconds = 10
          BackoffRate     = 2
          MaxAttempts     = 3
          JitterStrategy  = "FULL"
        }]
        Catch = local.catch_all
        Next  = "GetDataQualityResult"
      }

      GetDataQualityResult = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::athena:getQueryResults"
        Parameters = {
          "QueryExecutionId.$" = "$.dq_query.QueryExecutionId"
          MaxResults           = 2
        }
        # Row 0 is the header row; row 1 holds the failed_rows value.
        ResultSelector = {
          "failed_rows.$" = "$.ResultSet.Rows[1].Data[0].VarCharValue"
        }
        ResultPath = "$.dq"
        Retry = [{
          ErrorEquals     = ["Athena.TooManyRequestsException", "Athena.InternalServerException"]
          IntervalSeconds = 5
          BackoffRate     = 2
          MaxAttempts     = 3
        }]
        Catch = local.catch_all
        Next  = "EvaluateDataQuality"
      }

      EvaluateDataQuality = {
        Type = "Choice"
        Choices = [{
          Variable     = "$.dq.failed_rows"
          StringEquals = "0"
          Next         = "Succeeded"
        }]
        Default = "NotifyDataQualityFailure"
      }

      NotifyDataQualityFailure = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.alerts.arn
          Subject     = "[${local.state_machine_name}] data quality check failed"
          "Message.$" = "States.Format('Data quality check failed: {} row(s) broke a rule after Glue run {}.', $.dq.failed_rows, $.glue.JobRunId)"
        }
        Retry = [{
          ErrorEquals     = ["SNS.ThrottledException", "SNS.InternalErrorException"]
          IntervalSeconds = 5
          MaxAttempts     = 3
        }]
        Next = "DataQualityFailed"
      }

      DataQualityFailed = {
        Type  = "Fail"
        Error = "DataQualityFailed"
        Cause = "The data quality query returned failed_rows > 0."
      }

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:${local.partition}:states:::sns:publish"
        Parameters = {
          TopicArn    = aws_sns_topic.alerts.arn
          Subject     = "[${local.state_machine_name}] pipeline step failed"
          "Message.$" = "States.JsonToString($.error)"
        }
        Retry = [{
          ErrorEquals     = ["SNS.ThrottledException", "SNS.InternalErrorException"]
          IntervalSeconds = 5
          MaxAttempts     = 3
        }]
        Next = "PipelineFailed"
      }

      PipelineFailed = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "A pipeline step failed; see the alert and the execution history."
      }

      Succeeded = {
        Type = "Succeed"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# IAM for the state machine
# ---------------------------------------------------------------------------
resource "aws_iam_role" "state_machine" {
  name = "${local.state_machine_name}-sfn"
  tags = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:states:${local.region}:${local.account_id}:stateMachine:${local.state_machine_name}" }
      }
    }]
  })
}

locals {
  state_machine_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunTheGlueJob"
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
        Resource = [local.glue_job_arn]
      },
      {
        Sid      = "RunAthenaQueries"
        Effect   = "Allow"
        Action   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults", "athena:StopQueryExecution", "athena:GetWorkGroup"]
        Resource = [local.athena_workgroup_arn]
      },
      {
        # Athena resolves tables with the caller's credentials.
        Sid    = "ReadCatalogForAthena"
        Effect = "Allow"
        Action = ["glue:GetDatabase", "glue:GetTable", "glue:GetTables", "glue:GetPartitions"]
        Resource = [
          "${local.glue_arn_base}:catalog",
          "${local.glue_arn_base}:database/${var.database_name}",
          "${local.glue_arn_base}:table/${var.database_name}/*",
        ]
      },
      {
        Sid      = "ReadWarehouseForAthena"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${local.curated_bucket_arn}/${var.warehouse_prefix}/*"]
      },
      {
        Sid       = "ListWarehouseForAthena"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = [local.curated_bucket_arn]
        Condition = { StringLike = { "s3:prefix" = ["${var.warehouse_prefix}/", "${var.warehouse_prefix}/*"] } }
      },
      {
        Sid      = "WriteAthenaResults"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = ["${local.ops_bucket_arn}/${local.athena_results}/*"]
      },
      {
        Sid      = "AthenaBucketMetadata"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [local.ops_bucket_arn, local.curated_bucket_arn]
      },
      {
        Sid      = "UseLakeKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [var.kms_key_arn]
      },
      {
        Sid      = "PublishAlerts"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = [aws_sns_topic.alerts.arn]
      },
      {
        # Log delivery and X-Ray APIs do not support resource-level
        # permissions; AWS documents "*" as the only valid resource here.
        Sid    = "DeliverLogsAndTraces"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups",
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = ["*"]
      },
    ]
  }
}

resource "aws_iam_role_policy" "state_machine" {
  name   = "${local.state_machine_name}-access"
  role   = aws_iam_role.state_machine.id
  policy = jsonencode(local.state_machine_policy)
}

resource "aws_cloudwatch_log_group" "state_machine" {
  # The /aws/vendedlogs/ prefix avoids the CloudWatch resource-policy size
  # limit that Step Functions log delivery otherwise runs into.
  name              = "/aws/vendedlogs/states/${local.state_machine_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = local.tags
}

resource "aws_sfn_state_machine" "this" {
  name       = local.state_machine_name
  type       = "STANDARD"
  role_arn   = aws_iam_role.state_machine.arn
  definition = jsonencode(local.definition)
  tags       = local.tags

  logging_configuration {
    log_destination = "${aws_cloudwatch_log_group.state_machine.arn}:*"
    level           = "ERROR"
    # Execution data can contain row counts and error payloads; keep it in the
    # execution history (IAM-protected) rather than copying it to logs.
    include_execution_data = false
  }

  tracing_configuration {
    enabled = true
  }

  encryption_configuration {
    type                              = "CUSTOMER_MANAGED_KMS_KEY"
    kms_key_id                        = var.kms_key_arn
    kms_data_key_reuse_period_seconds = 300
  }

  depends_on = [aws_iam_role_policy.state_machine]
}
