variable "name" {
  description = "Name of the IAM role to create (e.g. my-project-dev-aws-lb-controller)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider (from the eks module)."
  type        = string
}

variable "oidc_provider_url" {
  description = <<-EOT
    The OIDC provider URL WITHOUT the https:// scheme
    (e.g. oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539...). From the eks module.
  EOT
  type        = string
}

variable "namespace_service_accounts" {
  description = <<-EOT
    List of "<namespace>:<serviceaccount>" pairs allowed to assume this role.
    The trust policy is scoped to exactly these subjects (least privilege) — a
    pod in any other namespace/SA cannot assume the role.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.namespace_service_accounts) > 0
    error_message = "Provide at least one <namespace>:<serviceaccount> subject."
  }
}

variable "policy_arns" {
  description = "List of existing managed/customer policy ARNs to attach to the role."
  type        = list(string)
  default     = []
}

variable "inline_policy_json" {
  description = <<-EOT
    Optional inline policy document (JSON string). Use for least-privilege,
    purpose-built policies that don't exist as managed policies. Leave null to skip.
  EOT
  type        = string
  default     = null
}

variable "max_session_duration" {
  description = "Maximum role session duration in seconds."
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags applied to the role."
  type        = map(string)
  default     = {}
}
