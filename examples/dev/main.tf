# Wires every module into one small, deployable dev stack.
# No backend is configured: for a real environment add an S3 backend with
# state locking (see docs/deploy.md). Credentials come from the standard AWS
# provider chain (environment, SSO profile, ...), never from this repository.

provider "aws" {
  region = var.aws_region

  # Tags every taggable resource consistently; modules add a "module" tag.
  default_tags {
    tags = local.tags
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"

  tags = {
    project     = var.project
    environment = var.environment
    managed_by  = "terraform"
    repository  = "aws-glue-iceberg-terraform"
  }

  database_name = "${var.project}_${var.environment}"

  # Iceberg schema of the curated orders table. Must match ORDERS_COLUMNS in
  # glue/orders_incremental.py; a unit test reads both and compares them.
  orders_columns = [
    { name = "order_id", type = "string", comment = "Business key from the source system." },
    { name = "customer_id", type = "string", comment = "Pseudonymous customer identifier." },
    { name = "order_status", type = "string", comment = "placed, paid, shipped, delivered, cancelled or returned." },
    { name = "order_total", type = "decimal(12,2)", comment = "Order value in the order currency." },
    { name = "currency", type = "string", comment = "ISO 4217 code." },
    { name = "order_ts", type = "timestamp", comment = "When the order was placed (UTC)." },
    { name = "updated_at", type = "timestamp", comment = "Last change in the source; newest version wins in MERGE." },
    { name = "ingest_date", type = "date", comment = "Raw partition the row was last loaded from." },
  ]

  # One number is easier to alert on than a result set. Each term counts rows
  # that break one rule; the duplicate check scans the whole table, which is
  # fine at dev scale (add a date filter for large tables).
  dq_query = <<-SQL
    SELECT
        count_if(order_id IS NULL)
      + count_if(order_total < 0)
      + count_if(order_status NOT IN ('placed', 'paid', 'shipped', 'delivered', 'cancelled', 'returned'))
      + (count(*) - count(DISTINCT order_id)) AS failed_rows
    FROM ${local.database_name}.orders
  SQL
}

module "storage" {
  source = "../../modules/lake_storage"

  name_prefix   = local.name_prefix
  bucket_suffix = var.bucket_suffix
  force_destroy = var.force_destroy
}

module "catalog" {
  source = "../../modules/glue_catalog"

  database_name       = local.database_name
  curated_bucket_name = module.storage.bucket_names["curated"]

  iceberg_tables = {
    orders = {
      description = "Latest version of every order, merged incrementally from raw/orders."
      columns     = local.orders_columns
    }
  }
}

module "athena" {
  source = "../../modules/athena"

  name_prefix         = local.name_prefix
  results_bucket_name = module.storage.bucket_names["ops"]
  kms_key_arn         = module.storage.kms_key_arn
  force_destroy       = var.force_destroy
}

module "orders_job" {
  source = "../../modules/glue_job"

  name_prefix         = local.name_prefix
  job_name            = "orders-incremental"
  script_path         = "${path.module}/../../glue/orders_incremental.py"
  glue_version        = var.glue_version
  raw_bucket_name     = module.storage.bucket_names["raw"]
  raw_prefix          = "orders"
  curated_bucket_name = module.storage.bucket_names["curated"]
  ops_bucket_name     = module.storage.bucket_names["ops"]
  kms_key_arn         = module.storage.kms_key_arn
  database_name       = module.catalog.database_name
  table_name          = "orders"
}

module "orchestration" {
  source = "../../modules/orchestration"

  name_prefix           = local.name_prefix
  glue_job_name         = module.orders_job.job_name
  athena_workgroup_name = module.athena.workgroup_name
  database_name         = module.catalog.database_name
  dq_query              = local.dq_query
  curated_bucket_name   = module.storage.bucket_names["curated"]
  ops_bucket_name       = module.storage.bucket_names["ops"]
  kms_key_arn           = module.storage.kms_key_arn
  alert_email_addresses = var.alert_email_addresses
}
