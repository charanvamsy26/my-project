variable "aws_region" {
  description = "AWS region for the state backend resources."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used for naming and tagging."
  type        = string
  default     = "eks-gitops-platform"
}

variable "state_bucket_force_destroy" {
  description = <<-EOT
    Whether `terraform destroy` is allowed to delete a non-empty state bucket.
    Keep this FALSE in any real account so years of state history cannot be wiped
    by an accidental destroy. Set it true only for throwaway sandboxes.
  EOT
  type        = bool
  default     = false
}

variable "noncurrent_version_expiration_days" {
  description = "Days to retain non-current (overwritten) state object versions before expiry."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Extra tags merged onto every bootstrap resource."
  type        = map(string)
  default     = {}
}
