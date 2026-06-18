variable "cluster_name" {
  description = "EKS cluster name (used by the LB controller chart and for tagging)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the cluster runs in (required by the AWS LB Controller)."
  type        = string
}

variable "aws_region" {
  description = "AWS region (passed to the LB controller chart)."
  type        = string
  default     = "us-east-1"
}

# ---- AWS Load Balancer Controller -------------------------------------------

variable "enable_aws_load_balancer_controller" {
  description = "Install the AWS Load Balancer Controller via Helm."
  type        = bool
  default     = true
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Pinned Helm chart version for the AWS LB Controller (no floating tags)."
  type        = string
  default     = "1.8.1"
}

variable "aws_load_balancer_controller_irsa_role_arn" {
  description = "IRSA role ARN for the LB controller service account (from iam-irsa)."
  type        = string
  default     = ""
}

variable "aws_load_balancer_controller_service_account" {
  description = "Service account name for the LB controller."
  type        = string
  default     = "aws-load-balancer-controller"
}

# ---- metrics-server ----------------------------------------------------------

variable "enable_metrics_server" {
  description = "Install metrics-server via Helm (powers `kubectl top` and HPA)."
  type        = bool
  default     = true
}

variable "metrics_server_chart_version" {
  description = "Pinned Helm chart version for metrics-server."
  type        = string
  default     = "3.12.1"
}

# ---- shared ------------------------------------------------------------------

variable "namespace" {
  description = "Namespace the add-ons are installed into."
  type        = string
  default     = "kube-system"
}

variable "tags" {
  description = "Tags (applied where the underlying chart/resources support them)."
  type        = map(string)
  default     = {}
}
