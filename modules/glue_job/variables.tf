variable "name_prefix" {
  description = "Prefix for resource names, usually \"<project>-<environment>\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 4-32 characters of lowercase letters, digits and hyphens, start with a letter and not end with a hyphen."
  }
}

variable "job_name" {
  description = "Logical job name; the deployed Glue job is named \"<name_prefix>-<job_name>\"."
  type        = string
  default     = "orders-incremental"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,40}$", var.job_name))
    error_message = "job_name must be 3-41 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "script_path" {
  description = "Local path to the PySpark entrypoint uploaded to the ops bucket."
  type        = string

  validation {
    condition     = endswith(var.script_path, ".py")
    error_message = "script_path must point to a .py file."
  }
}

variable "raw_bucket_name" {
  description = "Raw bucket the job reads from."
  type        = string
}

variable "raw_prefix" {
  description = "Prefix in the raw bucket holding the source dataset, laid out as <raw_prefix>/ingest_date=YYYY-MM-DD/. The job role can read nothing else."
  type        = string
  default     = "orders"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_/-]*[a-z0-9]$", var.raw_prefix))
    error_message = "raw_prefix must be a relative S3 prefix without leading or trailing slashes."
  }
}

variable "curated_bucket_name" {
  description = "Curated bucket that holds the Iceberg warehouse."
  type        = string
}

variable "warehouse_prefix" {
  description = "Prefix in the curated bucket under which Iceberg tables live. The job role can write nothing else."
  type        = string
  default     = "warehouse"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_/-]*[a-z0-9]$", var.warehouse_prefix))
    error_message = "warehouse_prefix must be a relative S3 prefix without leading or trailing slashes."
  }
}

variable "ops_bucket_name" {
  description = "Ops bucket for the job script (scripts/) and Glue temporary files (glue-temp/)."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the customer-managed KMS key that encrypts the lake."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "database_name" {
  description = "Glue database that contains the target Iceberg table."
  type        = string
}

variable "table_name" {
  description = "Target Iceberg table name."
  type        = string
}

variable "glue_version" {
  description = "AWS Glue version. 4.0 (Spark 3.3, Iceberg 1.0) and 5.0 (Spark 3.5, Iceberg 1.7) both ship Iceberg via --datalake-formats."
  type        = string
  default     = "5.0"

  validation {
    condition     = contains(["4.0", "5.0"], var.glue_version)
    error_message = "glue_version must be \"4.0\" or \"5.0\"."
  }
}

variable "worker_type" {
  description = "Glue worker type."
  type        = string
  default     = "G.1X"

  validation {
    condition     = contains(["G.1X", "G.2X", "G.4X", "G.8X"], var.worker_type)
    error_message = "worker_type must be one of G.1X, G.2X, G.4X, G.8X."
  }
}

variable "number_of_workers" {
  description = "Maximum number of workers (auto scaling is enabled, so this is a ceiling)."
  type        = number
  default     = 2

  validation {
    condition     = var.number_of_workers >= 2 && var.number_of_workers <= 100
    error_message = "number_of_workers must be between 2 and 100."
  }
}

variable "timeout_minutes" {
  description = "Job timeout. Keep it tight: a stuck job holds the single concurrency slot and blocks the next run."
  type        = number
  default     = 60

  validation {
    condition     = var.timeout_minutes >= 5 && var.timeout_minutes <= 2880
    error_message = "timeout_minutes must be between 5 and 2880."
  }
}

variable "lookback_days" {
  description = "Partitions this many days before the high-water mark are re-read on every run to pick up late-arriving files. MERGE makes the re-read idempotent."
  type        = number
  default     = 1

  validation {
    condition     = var.lookback_days >= 0 && var.lookback_days <= 30
    error_message = "lookback_days must be between 0 and 30."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
