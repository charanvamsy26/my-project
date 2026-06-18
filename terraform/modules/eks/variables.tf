variable "cluster_name" {
  description = "EKS cluster name (e.g. my-project-dev)."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes control-plane version."
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  description = "VPC the cluster lives in."
  type        = string
}

variable "subnet_ids" {
  description = <<-EOT
    Subnets for the EKS control-plane ENIs and managed node group(s). Pass the
    PRIVATE subnets — nodes must not be publicly addressable.
  EOT
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Whether the API server endpoint is reachable from the internet."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the public API endpoint. Default is open; LOCK THIS
    DOWN to your office/VPN ranges in prod.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "endpoint_private_access" {
  description = "Whether the API server is reachable from within the VPC."
  type        = bool
  default     = true
}

variable "cluster_log_types" {
  description = <<-EOT
    Control-plane log types to ship to CloudWatch. Full set:
    api, audit, authenticator, controllerManager, scheduler.
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  description = "Retention for the control-plane CloudWatch log group."
  type        = number
  default     = 90
}

variable "node_groups" {
  description = <<-EOT
    Map of managed node groups. Key = node group name suffix. Each group is fully
    parameterized so environments can differ (instance types, scaling, capacity).
  EOT
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND") # ON_DEMAND | SPOT
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size      = optional(number, 50)
    ami_type       = optional(string, "AL2023_x86_64_STANDARD")
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string # NO_SCHEDULE | NO_EXECUTE | PREFER_NO_SCHEDULE
    })), [])
  }))
}

variable "enable_karpenter_prerequisites" {
  description = <<-EOT
    Create the Karpenter node IAM role/instance profile and the SQS interruption
    queue + EventBridge rules. The Karpenter controller (Helm) and its IRSA role
    are wired up in the GitOps/iam-irsa layer.
  EOT
  type        = bool
  default     = true
}

variable "enable_irsa" {
  description = "Create the IAM OIDC provider so IRSA roles can trust this cluster."
  type        = bool
  default     = true
}

variable "kms_deletion_window_days" {
  description = "Deletion window for the cluster-encryption KMS key."
  type        = number
  default     = 30
}

variable "ebs_csi_irsa_role_arn" {
  description = <<-EOT
    IRSA role ARN for the EBS CSI driver addon. Optional — if empty the addon runs
    with the node role (works, but IRSA is preferred). Wire the iam-irsa output here.
  EOT
  type        = string
  default     = ""
}

variable "addon_versions" {
  description = <<-EOT
    Optional explicit addon versions, keyed by addon name (vpc-cni, coredns,
    kube-proxy, aws-ebs-csi-driver). Leave a key out to let EKS pick the default
    compatible version for the cluster's Kubernetes version.
  EOT
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags merged onto every resource in the module."
  type        = map(string)
  default     = {}
}
