output "bucket_names" {
  description = "Raw, curated and ops bucket names."
  value       = module.storage.bucket_names
}

output "kms_key_alias" {
  description = "Alias of the lake KMS key."
  value       = module.storage.kms_key_alias
}

output "glue_job_name" {
  description = "Name of the incremental orders Glue job."
  value       = module.orders_job.job_name
}

output "iceberg_table" {
  description = "Spark name of the curated orders table."
  value       = module.orders_job.target_table
}

output "athena_workgroup" {
  description = "Athena workgroup for ad-hoc and data quality queries."
  value       = module.athena.workgroup_name
}

output "state_machine_arn" {
  description = "Start an execution of this state machine to run the pipeline."
  value       = module.orchestration.state_machine_arn
}

output "alerts_topic_arn" {
  description = "SNS topic for failure alerts."
  value       = module.orchestration.alerts_topic_arn
}
