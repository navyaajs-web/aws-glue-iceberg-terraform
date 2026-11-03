variable "database_name" {
  description = "Glue Data Catalog database name. Glue and Athena lower-case identifiers, so only lowercase is accepted."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{1,62}$", var.database_name))
    error_message = "database_name must be 2-63 characters of lowercase letters, digits and underscores, starting with a letter."
  }
}

variable "description" {
  description = "Human-readable description of the database."
  type        = string
  default     = "Curated Iceberg tables managed by Terraform."
}

variable "curated_bucket_name" {
  description = "Name of the curated bucket that holds the Iceberg warehouse."
  type        = string
}

variable "warehouse_prefix" {
  description = "Key prefix inside the curated bucket under which Iceberg tables live (no leading or trailing slash)."
  type        = string
  default     = "warehouse"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_/-]*[a-z0-9]$", var.warehouse_prefix))
    error_message = "warehouse_prefix must be a relative S3 prefix without leading or trailing slashes."
  }
}

variable "iceberg_tables" {
  description = <<-EOT
    Iceberg tables to register, keyed by table name. Each table has a description
    and an ordered list of columns (name, Hive/Glue type, optional comment).
  EOT
  type = map(object({
    description = string
    columns = list(object({
      name    = string
      type    = string
      comment = optional(string, "")
    }))
  }))

  validation {
    condition     = alltrue([for name in keys(var.iceberg_tables) : can(regex("^[a-z][a-z0-9_]{1,62}$", name))])
    error_message = "Table names must be lowercase letters, digits and underscores, starting with a letter."
  }

  validation {
    condition     = alltrue([for t in values(var.iceberg_tables) : length(t.columns) > 0])
    error_message = "Every table needs at least one column."
  }
}

variable "tags" {
  description = "Tags applied to taggable resources in this module."
  type        = map(string)
  default     = {}
}
