variable "name_prefix" {
  description = "Prefix for every resource name, usually \"<project>-<environment>\" (lowercase letters, digits and hyphens)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 4-32 characters of lowercase letters, digits and hyphens, start with a letter and not end with a hyphen."
  }
}

variable "bucket_suffix" {
  description = "Optional suffix appended to bucket names to make them globally unique (for example a short random string). Leave empty to omit."
  type        = string
  default     = ""

  validation {
    condition     = var.bucket_suffix == "" || can(regex("^[a-z0-9]{3,12}$", var.bucket_suffix))
    error_message = "bucket_suffix must be empty or 3-12 lowercase letters/digits."
  }
}

variable "raw_transition_to_ia_days" {
  description = "Days after which raw objects move to S3 Standard-IA. Raw data is re-read rarely once it has been merged into the curated layer."
  type        = number
  default     = 30

  validation {
    condition     = var.raw_transition_to_ia_days >= 30
    error_message = "S3 requires objects to be at least 30 days old before transitioning to Standard-IA."
  }
}

variable "raw_expiration_days" {
  description = "Days after which raw objects are deleted. Set to 0 to keep raw data forever."
  type        = number
  default     = 400

  validation {
    condition     = var.raw_expiration_days == 0 || var.raw_expiration_days > 30
    error_message = "raw_expiration_days must be 0 (never expire) or greater than 30 (after the Standard-IA transition)."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep noncurrent object versions in every bucket. Versioning protects against accidental overwrites; this bounds its cost."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1
    error_message = "noncurrent_version_expiration_days must be at least 1."
  }
}

variable "ops_temp_expiration_days" {
  description = "Days to keep Glue temporary files and Athena query results in the ops bucket."
  type        = number
  default     = 14

  validation {
    condition     = var.ops_temp_expiration_days >= 1
    error_message = "ops_temp_expiration_days must be at least 1."
  }
}

variable "kms_deletion_window_days" {
  description = "Waiting period before a scheduled KMS key deletion takes effect."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "force_destroy" {
  description = "Allow Terraform to delete non-empty buckets. Only for throwaway dev stacks."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource in this module (merged with provider default_tags)."
  type        = map(string)
  default     = {}
}
