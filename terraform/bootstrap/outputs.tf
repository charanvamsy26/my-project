output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform remote state. Use in each env's backend.tf."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the state bucket (useful for scoping IAM policies)."
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "DynamoDB table used for state locking. Use in each env's backend.tf."
  value       = aws_dynamodb_table.locks.id
}

output "account_id" {
  description = "AWS account id the backend was created in (also the bucket-name suffix)."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "Region the backend lives in."
  value       = var.aws_region
}
