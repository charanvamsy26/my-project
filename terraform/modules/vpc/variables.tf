variable "name" {
  description = "Base name for the VPC and all child resources (e.g. eks-gitops-platform-dev)."
  type        = string
}

variable "cidr_block" {
  description = "Primary IPv4 CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = <<-EOT
    Availability zones to spread subnets across. Pass exactly the zones you want
    (this module is built for 3). The environment computes these from a data
    source so we never hardcode AZ ids.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2 && length(var.azs) <= 3
    error_message = "Provide 2 or 3 AZs; the platform is designed for 3-AZ HA."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDRs for the public subnets, one per AZ (same length/order as azs)."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDRs for the private subnets, one per AZ (same length/order as azs)."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = <<-EOT
    When true, create ONE NAT gateway shared by all private subnets (cheaper, a
    single AZ failure takes out egress — fine for dev). When false, create one NAT
    per AZ for high availability (prod).
  EOT
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs to CloudWatch Logs (recommended in prod)."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention for the VPC flow log group."
  type        = number
  default     = 90
}

variable "eks_cluster_name" {
  description = <<-EOT
    EKS cluster name this VPC serves. Used for the Kubernetes subnet discovery
    tags (kubernetes.io/cluster/<name>) so the AWS LB Controller and Karpenter
    can find subnets. Leave empty to omit the cluster-specific tags.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags merged onto every resource in the module."
  type        = map(string)
  default     = {}
}
