variable "name_prefix" {
  description = "Prefix for resource names, usually \"<project>-<environment>\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 4-32 characters of lowercase letters, digits and hyphens, start with a letter and not end with a hyphen."
  }
}

variable "results_bucket_name" {
  description = "Bucket for query results; results are written under athena-results/<workgroup>/."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key used to encrypt query results."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-f0-9-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias)."
  }
}

variable "bytes_scanned_cutoff_gb" {
  description = "Per-query scan limit in GB. Athena bills per byte scanned, so this is a cost guardrail against accidental full scans."
  type        = number
  default     = 10

  validation {
    condition     = var.bytes_scanned_cutoff_gb >= 1
    error_message = "bytes_scanned_cutoff_gb must be at least 1 (Athena's minimum is 10 MB)."
  }
}

variable "force_destroy" {
  description = "Delete the workgroup even if it contains saved queries. Only for throwaway dev stacks."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
