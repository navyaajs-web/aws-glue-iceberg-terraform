output "database_name" {
  description = "Name of the Glue database."
  value       = aws_glue_catalog_database.this.name
}

output "warehouse_location" {
  description = "S3 URI of the Iceberg warehouse root used by the Spark catalog."
  value       = "s3://${var.curated_bucket_name}/${var.warehouse_prefix}"
}

output "table_names" {
  description = "Names of the registered Iceberg tables."
  value       = sort(keys(aws_glue_catalog_table.iceberg))
}

output "table_locations" {
  description = "S3 location of each Iceberg table, keyed by table name."
  value       = { for name, _ in var.iceberg_tables : name => "${local.database_location}/${name}" }
}
