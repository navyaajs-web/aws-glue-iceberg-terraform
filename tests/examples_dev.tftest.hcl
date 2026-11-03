# Integration-style test: plans and (mock-)applies the whole examples/dev stack
# so the wiring between modules is checked, not just each module alone.

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
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:eu-west-1:111122223333:key/00000000-1111-2222-3333-444444444444"
      key_id = "00000000-1111-2222-3333-444444444444"
    }
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
  bucket_suffix = "abc123"
}

run "dev_stack_wires_modules_together" {
  command = apply

  module {
    source = "./examples/dev"
  }

  assert {
    condition = output.bucket_names == {
      raw     = "orderlake-dev-raw-abc123"
      curated = "orderlake-dev-curated-abc123"
      ops     = "orderlake-dev-ops-abc123"
    }
    error_message = "Dev bucket names must follow <project>-<env>-<layer>-<suffix>."
  }

  assert {
    condition     = output.glue_job_name == "orderlake-dev-orders-incremental"
    error_message = "Unexpected Glue job name."
  }

  assert {
    condition     = output.iceberg_table == "glue_catalog.orderlake_dev.orders"
    error_message = "The job must target the orders table in the dev database."
  }

  assert {
    condition     = output.athena_workgroup == "orderlake-dev-analytics"
    error_message = "Unexpected Athena workgroup name."
  }

  assert {
    condition = (
      module.catalog.table_locations["orders"] == "s3://orderlake-dev-curated-abc123/warehouse/orderlake_dev.db/orders"
    )
    error_message = "The Iceberg table must live under the curated warehouse prefix."
  }
}

run "rejects_invalid_environment" {
  command = plan

  module {
    source = "./examples/dev"
  }

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}
