###############################################################################
# Outputs — consumed by operators and the GitOps/Kubernetes layer
###############################################################################

output "region" {
  description = "AWS region."
  value       = var.aws_region
}

output "account_id" {
  description = "AWS account id."
  value       = data.aws_caller_identity.current.account_id
}

# ---- Networking --------------------------------------------------------------

output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "VPC id."
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnet_ids
  description = "Private subnet ids."
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnet_ids
  description = "Public subnet ids."
}

# ---- EKS ---------------------------------------------------------------------

output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name."
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Kubernetes API endpoint."
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Cluster CA (base64)."
  sensitive   = true
}

output "oidc_provider_arn" {
  value       = module.eks.oidc_provider_arn
  description = "IAM OIDC provider ARN (IRSA)."
}

output "node_role_arn" {
  value       = module.eks.node_role_arn
  description = "Shared node IAM role ARN."
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

# ---- IRSA role ARNs (for ServiceAccount annotations in GitOps) ---------------

output "irsa_role_arns" {
  description = "Map of IRSA role ARNs for the platform service accounts."
  value = {
    aws_load_balancer_controller = module.lb_controller_irsa.role_arn
    external_dns                 = module.external_dns_irsa.role_arn
    ebs_csi                      = module.ebs_csi_irsa.role_arn
    karpenter                    = module.karpenter_irsa.role_arn
  }
}

# ---- Karpenter ---------------------------------------------------------------

output "karpenter_node_instance_profile_name" {
  value       = module.eks.karpenter_node_instance_profile_name
  description = "Instance profile for Karpenter-launched nodes."
}

output "karpenter_interruption_queue_name" {
  value       = module.eks.karpenter_interruption_queue_name
  description = "SQS queue for Karpenter interruption handling."
}

# ---- RDS ---------------------------------------------------------------------

output "rds_writer_endpoint" {
  value       = module.rds.writer_endpoint
  description = "Aurora writer endpoint."
}

output "rds_reader_endpoint" {
  value       = module.rds.reader_endpoint
  description = "Aurora reader endpoint."
}

output "rds_secret_arn" {
  value       = module.rds.secret_arn
  description = "Secrets Manager ARN holding DB credentials."
}
