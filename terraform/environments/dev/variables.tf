variable "aws_region" {
  description = "AWS region for the dev environment."
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
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the dev VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (one per AZ)."
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs (one per AZ)."
  type        = list(string)
  default     = ["10.0.64.0/20", "10.0.80.0/20", "10.0.96.0/20"]
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.30"
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "Instance types for the default managed node group."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 4
}

variable "rds_instance_class" {
  description = "Aurora instance class for dev."
  type        = string
  default     = "db.t4g.medium"
}

variable "rds_instance_count" {
  description = "Aurora instance count for dev (1 = single writer)."
  type        = number
  default     = 1
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
