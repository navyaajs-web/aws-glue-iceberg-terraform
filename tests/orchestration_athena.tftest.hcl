# Unit tests for modules/orchestration and modules/athena.

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
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:eu-west-1:111122223333:orderlake-test-orders-pipeline-alerts" }
  }
  # The provider validates these ARNs, so random mock strings will not do.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock-role" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:eu-west-1:111122223333:log-group:/aws/vendedlogs/states/mock" }
  }
}

variables {
  name_prefix           = "orderlake-test"
  glue_job_name         = "orderlake-test-orders-incremental"
  athena_workgroup_name = "orderlake-test-analytics"
  database_name         = "orderlake_test"
  dq_query              = "SELECT count_if(order_id IS NULL) AS failed_rows FROM orders"
  curated_bucket_name   = "orderlake-test-curated-abc123"
  ops_bucket_name       = "orderlake-test-ops-abc123"
  kms_key_arn           = "arn:aws:kms:eu-west-1:111122223333:key/00000000-1111-2222-3333-444444444444"
  results_bucket_name   = "orderlake-test-ops-abc123"
}

run "state_machine_flow" {
  command = apply # mocked; the definition embeds the SNS topic ARN

  module {
    source = "./modules/orchestration"
  }

  assert {
    condition     = aws_sfn_state_machine.this.name == "orderlake-test-orders-pipeline"
    error_message = "State machine name must be <name_prefix>-<pipeline_name>."
  }

  assert {
    condition = (
      jsondecode(aws_sfn_state_machine.this.definition).StartAt == "RunGlueJob" &&
      jsondecode(aws_sfn_state_machine.this.definition).States.RunGlueJob.Resource == "arn:aws:states:::glue:startJobRun.sync" &&
      jsondecode(aws_sfn_state_machine.this.definition).States.RunGlueJob.Next == "RunDataQualityQuery"
    )
    error_message = "The pipeline must start by running the Glue job synchronously, then the DQ query."
  }

  assert {
    condition = (
      jsondecode(aws_sfn_state_machine.this.definition).States.RunDataQualityQuery.Resource == "arn:aws:states:::athena:startQueryExecution.sync" &&
      jsondecode(aws_sfn_state_machine.this.definition).States.RunDataQualityQuery.Parameters.WorkGroup == "orderlake-test-analytics"
    )
    error_message = "The DQ query must run synchronously in the module's Athena workgroup."
  }

  assert {
    condition = alltrue([
      for name in ["RunGlueJob", "RunDataQualityQuery", "GetDataQualityResult"] :
      jsondecode(aws_sfn_state_machine.this.definition).States[name].Catch[0].Next == "NotifyFailure" &&
      contains(jsondecode(aws_sfn_state_machine.this.definition).States[name].Catch[0].ErrorEquals, "States.ALL")
    ])
    error_message = "Every task must catch all errors and route them to the SNS alert."
  }

  assert {
    condition = alltrue([
      for name in ["RunGlueJob", "RunDataQualityQuery", "GetDataQualityResult"] :
      length(jsondecode(aws_sfn_state_machine.this.definition).States[name].Retry) > 0
    ])
    error_message = "Every task must retry transient errors."
  }

  assert {
    condition = !anytrue([
      for r in jsondecode(aws_sfn_state_machine.this.definition).States.RunGlueJob.Retry :
      contains(r.ErrorEquals, "States.ALL") || contains(r.ErrorEquals, "States.TaskFailed")
    ])
    error_message = "A Glue job that fails on its own must not be retried blindly."
  }

  assert {
    condition = (
      jsondecode(aws_sfn_state_machine.this.definition).States.NotifyFailure.Resource == "arn:aws:states:::sns:publish" &&
      jsondecode(aws_sfn_state_machine.this.definition).States.NotifyFailure.Parameters.TopicArn == aws_sns_topic.alerts.arn &&
      jsondecode(aws_sfn_state_machine.this.definition).States.NotifyFailure.Next == "PipelineFailed" &&
      jsondecode(aws_sfn_state_machine.this.definition).States.PipelineFailed.Type == "Fail"
    )
    error_message = "Failures must publish to the alerts topic and end in a Fail state."
  }

  assert {
    condition = (
      jsondecode(aws_sfn_state_machine.this.definition).States.EvaluateDataQuality.Choices[0].StringEquals == "0" &&
      jsondecode(aws_sfn_state_machine.this.definition).States.EvaluateDataQuality.Default == "NotifyDataQualityFailure"
    )
    error_message = "Only failed_rows = 0 may pass the data quality gate."
  }
}

run "state_machine_is_encrypted_logged_and_least_privilege" {
  command = apply

  module {
    source = "./modules/orchestration"
  }

  assert {
    condition     = aws_sns_topic.alerts.kms_master_key_id == var.kms_key_arn
    error_message = "The alerts topic must be encrypted with the lake key."
  }

  assert {
    condition     = aws_cloudwatch_log_group.state_machine.kms_key_id == var.kms_key_arn && aws_cloudwatch_log_group.state_machine.retention_in_days == 365
    error_message = "State machine logs must be KMS-encrypted with bounded retention."
  }

  assert {
    condition = (
      one(aws_sfn_state_machine.this.encryption_configuration).type == "CUSTOMER_MANAGED_KMS_KEY" &&
      one(aws_sfn_state_machine.this.tracing_configuration).enabled &&
      one(aws_sfn_state_machine.this.logging_configuration).include_execution_data == false
    )
    error_message = "Execution data must be CMK-encrypted, traced, and kept out of logs."
  }

  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.state_machine.policy).Statement : [
        for r in flatten([s.Resource]) : r != "*"
      ] if anytrue([for a in flatten([s.Action]) : startswith(a, "s3:") || startswith(a, "kms:") || startswith(a, "glue:Start") || startswith(a, "sns:")])
    ]))
    error_message = "S3, KMS, Glue job and SNS permissions must name specific resources."
  }

  assert {
    condition = (
      [for s in jsondecode(aws_iam_role_policy.state_machine.policy).Statement : s.Resource if s.Sid == "RunTheGlueJob"][0]
      == ["arn:aws:glue:eu-west-1:111122223333:job/orderlake-test-orders-incremental"]
    )
    error_message = "The state machine may only start its own Glue job."
  }
}

run "dq_query_must_return_failed_rows" {
  command = plan

  module {
    source = "./modules/orchestration"
  }

  variables {
    dq_query = "SELECT count(*) AS bad FROM orders"
  }

  expect_failures = [var.dq_query]
}

run "athena_workgroup_enforces_encrypted_results" {
  command = plan

  module {
    source = "./modules/athena"
  }

  assert {
    condition     = aws_athena_workgroup.this.name == "orderlake-test-analytics"
    error_message = "Workgroup name must be <name_prefix>-analytics."
  }

  assert {
    condition     = one(aws_athena_workgroup.this.configuration).enforce_workgroup_configuration == true
    error_message = "Clients must not be able to override the workgroup settings."
  }

  assert {
    condition = (
      one(one(one(aws_athena_workgroup.this.configuration).result_configuration).encryption_configuration).encryption_option == "SSE_KMS" &&
      one(one(one(aws_athena_workgroup.this.configuration).result_configuration).encryption_configuration).kms_key_arn == var.kms_key_arn
    )
    error_message = "Query results must be SSE-KMS encrypted with the lake key."
  }

  assert {
    condition     = one(one(aws_athena_workgroup.this.configuration).result_configuration).output_location == "s3://orderlake-test-ops-abc123/athena-results/orderlake-test-analytics/"
    error_message = "Results must land under athena-results/<workgroup>/ in the ops bucket."
  }

  assert {
    condition     = one(aws_athena_workgroup.this.configuration).bytes_scanned_cutoff_per_query == 10 * 1024 * 1024 * 1024
    error_message = "A per-query scan limit must be set as a cost guardrail."
  }
}
