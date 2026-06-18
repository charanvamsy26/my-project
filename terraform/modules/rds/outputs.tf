output "cluster_identifier" {
  description = "Aurora cluster identifier."
  value       = aws_rds_cluster.this.cluster_identifier
}

output "cluster_arn" {
  description = "Aurora cluster ARN."
  value       = aws_rds_cluster.this.arn
}

output "writer_endpoint" {
  description = "Cluster (writer) endpoint — point write traffic here."
  value       = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint — load-balances across read replicas."
  value       = aws_rds_cluster.this.reader_endpoint
}

output "port" {
  description = "Database port."
  value       = aws_rds_cluster.this.port
}

output "database_name" {
  description = "Initial database name."
  value       = aws_rds_cluster.this.database_name
}

output "master_username" {
  description = "Master username (password lives in Secrets Manager)."
  value       = aws_rds_cluster.this.master_username
}

output "security_group_id" {
  description = "Security group fronting the database."
  value       = aws_security_group.this.id
}

output "secret_arn" {
  description = "Secrets Manager secret ARN holding the master credentials JSON."
  value       = aws_secretsmanager_secret.master.arn
}

output "secret_name" {
  description = "Secrets Manager secret name."
  value       = aws_secretsmanager_secret.master.name
}

output "kms_key_arn" {
  description = "KMS key used for storage + secret encryption."
  value       = aws_kms_key.this.arn
}
