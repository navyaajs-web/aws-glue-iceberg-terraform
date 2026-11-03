variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must look like an AWS region code, for example eu-west-1."
  }
}

variable "project" {
  description = "Short project name used in every resource name."
  type        = string
  default     = "orderlake"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,15}$", var.project))
    error_message = "project must be 3-16 lowercase letters/digits, starting with a letter."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be dev, test or prod."
  }
}

variable "bucket_suffix" {
  description = "Short random string that makes bucket names globally unique, for example the output of `openssl rand -hex 3`."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.bucket_suffix))
    error_message = "bucket_suffix must be 3-12 lowercase letters/digits."
  }
}

variable "glue_version" {
  description = "AWS Glue version for the job (4.0 or 5.0)."
  type        = string
  default     = "5.0"
}

variable "alert_email_addresses" {
  description = "Email addresses that receive pipeline failure alerts."
  type        = list(string)
  default     = []
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to remove non-empty buckets. Convenient for a throwaway dev stack; keep false anywhere else."
  type        = bool
  default     = true
}
