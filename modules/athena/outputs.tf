output "workgroup_name" {
  description = "Name of the Athena workgroup."
  value       = aws_athena_workgroup.this.name
}

output "workgroup_arn" {
  description = "ARN of the Athena workgroup."
  value       = aws_athena_workgroup.this.arn
}

output "results_location" {
  description = "S3 URI where query results are written."
  value       = "s3://${var.results_bucket_name}/athena-results/${local.workgroup_name}/"
}
