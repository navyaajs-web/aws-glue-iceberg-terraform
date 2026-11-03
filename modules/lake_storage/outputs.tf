output "bucket_names" {
  description = "Bucket names keyed by layer (raw, curated, ops)."
  value       = { for key, bucket in aws_s3_bucket.this : key => bucket.bucket }
}

output "bucket_arns" {
  description = "Bucket ARNs keyed by layer (raw, curated, ops)."
  value       = { for key, bucket in aws_s3_bucket.this : key => bucket.arn }
}

output "kms_key_arn" {
  description = "ARN of the customer-managed KMS key that encrypts the lake."
  value       = aws_kms_key.lake.arn
}

output "kms_key_alias" {
  description = "Alias of the lake KMS key."
  value       = aws_kms_alias.lake.name
}
