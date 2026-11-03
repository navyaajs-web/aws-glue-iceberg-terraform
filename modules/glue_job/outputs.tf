output "job_name" {
  description = "Name of the Glue job."
  value       = aws_glue_job.this.name
}

output "job_arn" {
  description = "ARN of the Glue job (built from its name so it is known at plan time)."
  value       = "${local.glue_arn_base}:job/${aws_glue_job.this.name}"
}

output "role_arn" {
  description = "ARN of the job execution role."
  value       = aws_iam_role.job.arn
}

output "role_name" {
  description = "Name of the job execution role."
  value       = aws_iam_role.job.name
}

output "script_s3_uri" {
  description = "S3 URI of the uploaded job script."
  value       = "s3://${var.ops_bucket_name}/${aws_s3_object.script.key}"
}

output "target_table" {
  description = "Fully qualified Spark name of the target table (catalog.database.table)."
  value       = local.target_table
}
