# Unit tests for modules/glue_catalog.

mock_provider "aws" {}

variables {
  database_name       = "orderlake_test"
  curated_bucket_name = "orderlake-test-curated-abc123"
  iceberg_tables = {
    orders = {
      description = "Test table"
      columns = [
        { name = "order_id", type = "string" },
        { name = "updated_at", type = "timestamp" },
      ]
    }
  }
}

run "registers_iceberg_v2_table_in_the_warehouse" {
  command = plan

  module {
    source = "./modules/glue_catalog"
  }

  assert {
    condition     = aws_glue_catalog_database.this.location_uri == "s3://orderlake-test-curated-abc123/warehouse/orderlake_test.db"
    error_message = "The database must live under the warehouse prefix."
  }

  assert {
    condition = (
      one(one(aws_glue_catalog_table.iceberg["orders"].open_table_format_input).iceberg_input).metadata_operation == "CREATE" &&
      one(one(aws_glue_catalog_table.iceberg["orders"].open_table_format_input).iceberg_input).version == "2"
    )
    error_message = "Tables must be created as Iceberg format v2 (needed for MERGE)."
  }

  assert {
    condition     = one(aws_glue_catalog_table.iceberg["orders"].storage_descriptor).location == "s3://orderlake-test-curated-abc123/warehouse/orderlake_test.db/orders"
    error_message = "Table location must be <database location>/<table>."
  }

  assert {
    condition     = [for c in one(aws_glue_catalog_table.iceberg["orders"].storage_descriptor).columns : c.name] == ["order_id", "updated_at"]
    error_message = "Columns must be registered in the declared order."
  }
}

run "rejects_uppercase_database_name" {
  command = plan

  module {
    source = "./modules/glue_catalog"
  }

  variables {
    database_name = "OrderLake"
  }

  expect_failures = [var.database_name]
}
