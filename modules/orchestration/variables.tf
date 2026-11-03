variable "name_prefix" {
  description = "Prefix for resource names, usually \"<project>-<environment>\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 4-32 characters of lowercase letters, digits and hyphens, start with a letter and not end with a hyphen."
  }
}

variable "pipeline_name" {
  description = "Logical pipeline name; the state machine is named \"<name_prefix>-<pipeline_name>\"."
  type        = string
  default     = "orders-pipeline"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,40}$", var.pipeline_name))
    error_message = "pipeline_name must be 3-41 characters of lowercase letters, digits and hyphens."
  }
}

variable "glue_job_name" {
  description = "Name of the Glue job the state machine runs."
  type        = string
}

variable "athena_workgroup_name" {
  description = "Athena workgroup used for the data quality query."
  type        = string
}

variable "database_name" {
  description = "Glue database the data quality query runs against."
  type        = string
}

variable "dq_query" {
  description = <<-EOT
    Athena SQL that returns exactly one row with a single column named
    failed_rows (the number of rows that break a rule). Zero passes; anything
    else sends an alert and fails the execution.
  EOT
  type        = string

  validation {
    condition     = can(regex("(?i)\\bfailed_rows\\b", var.dq_query))
    error_message = "dq_query must return a column named failed_rows."
  }
}

variable "curated_bucket_name" {
  description = "Curated bucket. Athena reads table data with the state machine's credentials, so the role needs read access to the warehouse prefix."
  type        = string
}

variable "warehouse_prefix" {
  description = "Iceberg warehouse prefix inside the curated bucket."
  type        = string
  default     = "warehouse"
}

variable "ops_bucket_name" {
  description = "Ops bucket that holds Athena query results under athena-results/."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the lake KMS key (decrypts data, encrypts query results, the SNS topic and the log group)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "alert_email_addresses" {
  description = "Email addresses subscribed to failure alerts. Each address must confirm the subscription. Leave empty to subscribe later (for example a chat webhook)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alert_email_addresses : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "Every alert_email_addresses entry must look like an email address."
  }
}

variable "glue_retry_max_attempts" {
  description = "Retries for transient Glue service errors (throttling, concurrency limit, internal errors). Job failures caused by data are never retried."
  type        = number
  default     = 2

  validation {
    condition     = var.glue_retry_max_attempts >= 0 && var.glue_retry_max_attempts <= 5
    error_message = "glue_retry_max_attempts must be between 0 and 5."
  }
}

variable "log_retention_days" {
  description = "Retention for the state machine's CloudWatch log group."
  type        = number
  default     = 365

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention value CloudWatch Logs accepts."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
