variable "name" {
  description = "Base name for the Aurora cluster and related resources (e.g. eks-gitops-platform-dev)."
  type        = string
}

variable "vpc_id" {
  description = "VPC the database lives in."
  type        = string
}

variable "subnet_ids" {
  description = "PRIVATE subnet IDs for the DB subnet group (Aurora must not be public)."
  type        = list(string)
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version."
  type        = string
  default     = "16.4"
}

variable "database_name" {
  description = "Initial database name created in the cluster."
  type        = string
  default     = "demo"
}

variable "master_username" {
  description = "Master username. The password is generated and stored in Secrets Manager."
  type        = string
  default     = "dbadmin"
}

variable "instance_class" {
  description = "Instance class for cluster instances (e.g. db.t4g.medium for dev, db.r6g.large for prod)."
  type        = string
  default     = "db.t4g.medium"
}

variable "instance_count" {
  description = <<-EOT
    Number of cluster instances. 1 = single writer (dev). 2+ = writer + reader(s)
    spread across AZs for HA (prod).
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1
    error_message = "Need at least one instance (the writer)."
  }
}

variable "allowed_security_group_ids" {
  description = <<-EOT
    Security groups allowed to reach the DB on the Postgres port. Typically the
    EKS node / cluster security group(s) so only in-cluster workloads can connect.
  EOT
  type        = list(string)
  default     = []
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDRs allowed to reach the DB (use sparingly; prefer SG references)."
  type        = list(string)
  default     = []
}

variable "port" {
  description = "Database port."
  type        = number
  default     = 5432
}

variable "backup_retention_days" {
  description = "Automated backup retention in days."
  type        = number
  default     = 7
}

variable "preferred_backup_window" {
  description = "Daily backup window (UTC)."
  type        = string
  default     = "03:00-04:00"
}

variable "preferred_maintenance_window" {
  description = "Weekly maintenance window (UTC)."
  type        = string
  default     = "sun:04:30-sun:05:30"
}

variable "deletion_protection" {
  description = "Block accidental deletion. Should be TRUE in prod."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. TRUE for dev, FALSE for prod."
  type        = bool
  default     = true
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights on cluster instances."
  type        = bool
  default     = true
}

variable "monitoring_interval" {
  description = "Enhanced monitoring interval in seconds (0 disables). 60 is typical."
  type        = number
  default     = 60
}

variable "kms_deletion_window_days" {
  description = "Deletion window for the storage-encryption KMS key."
  type        = number
  default     = 30
}

variable "apply_immediately" {
  description = "Apply modifications immediately instead of during the maintenance window."
  type        = bool
  default     = false
}

variable "secret_recovery_window_days" {
  description = "Recovery window for the Secrets Manager secret on deletion (0 = force delete)."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags merged onto every resource in the module."
  type        = map(string)
  default     = {}
}
