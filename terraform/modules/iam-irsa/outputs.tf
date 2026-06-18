output "role_arn" {
  description = "ARN of the IRSA role. Annotate the K8s ServiceAccount with this (eks.amazonaws.com/role-arn)."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the IRSA role."
  value       = aws_iam_role.this.name
}

output "role_unique_id" {
  description = "Stable unique id of the role."
  value       = aws_iam_role.this.unique_id
}
