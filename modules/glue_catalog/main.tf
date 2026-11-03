locals {
  tags = merge(var.tags, { "module" = "glue_catalog" })

  database_location = "s3://${var.curated_bucket_name}/${var.warehouse_prefix}/${var.database_name}.db"
}

resource "aws_glue_catalog_database" "this" {
  name         = var.database_name
  description  = var.description
  location_uri = local.database_location
  tags         = local.tags
}

# Registering the table through the Glue API (rather than letting the first job
# run create it) means the schema is reviewed in a pull request and Athena can
# query an empty table on day one. Schema *evolution* after creation is done
# with ALTER TABLE through Spark/Athena, so Terraform ignores column drift.
resource "aws_glue_catalog_table" "iceberg" {
  for_each = var.iceberg_tables

  name          = each.key
  database_name = aws_glue_catalog_database.this.name
  description   = each.value.description
  table_type    = "EXTERNAL_TABLE"

  open_table_format_input {
    iceberg_input {
      metadata_operation = "CREATE"
      # Format v2 is required for row-level MERGE/UPDATE/DELETE.
      version = "2"
    }
  }

  storage_descriptor {
    location = "${local.database_location}/${each.key}"

    dynamic "columns" {
      for_each = each.value.columns

      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Iceberg owns these after creation: every commit rewrites the metadata
      # pointer and evolved schemas show up here.
      parameters,
      storage_descriptor,
    ]
  }
}
