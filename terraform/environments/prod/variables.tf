variable "aws_region" {
  description = "AWS region for the prod environment."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name for naming/tagging."
  type        = string
  default     = "eks-gitops-platform"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "CIDR block for the prod VPC (kept distinct from dev to allow peering)."
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (one per AZ)."
  type        = list(string)
  default     = ["10.1.0.0/20", "10.1.16.0/20", "10.1.32.0/20"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs (one per AZ)."
  type        = list(string)
  default     = ["10.1.64.0/20", "10.1.80.0/20", "10.1.96.0/20"]
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.30"
}

variable "endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the EKS public API endpoint. PROD SHOULD NOT use
    0.0.0.0/0 — set this to your VPN/office egress ranges in terraform.tfvars.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "Instance types for the default managed node group."
  type        = list(string)
  default     = ["m5.xlarge"]
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
  default     = 3
}

variable "node_min_size" {
  description = "Minimum node count (one per AZ for HA)."
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 9
}

variable "rds_instance_class" {
  description = "Aurora instance class for prod."
  type        = string
  default     = "db.r6g.large"
}

variable "rds_instance_count" {
  description = "Aurora instance count for prod (2 = writer + reader, multi-AZ)."
  type        = number
  default     = 2
}

variable "rds_database_name" {
  description = "Initial database name."
  type        = string
  default     = "demo"
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Pinned AWS LB Controller Helm chart version."
  type        = string
  default     = "1.8.1"
}

variable "metrics_server_chart_version" {
  description = "Pinned metrics-server Helm chart version."
  type        = string
  default     = "3.12.1"
}
