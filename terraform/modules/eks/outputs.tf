output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA cert for the cluster (for kubeconfig / providers)."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version of the control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Security group attached to the control plane."
  value       = aws_security_group.cluster.id
}

# The EKS-managed cluster security group (auto-created by EKS) — node/pod traffic.
output "cluster_primary_security_group_id" {
  description = "EKS-managed primary security group (node<->control-plane traffic)."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA (empty if IRSA disabled)."
  value       = try(aws_iam_openid_connect_provider.oidc[0].arn, "")
}

output "oidc_provider_url" {
  description = "OIDC issuer URL WITHOUT the https:// scheme (for IRSA trust policies)."
  value       = try(replace(aws_iam_openid_connect_provider.oidc[0].url, "https://", ""), "")
}

output "oidc_issuer_url" {
  description = "Full OIDC issuer URL (with https://)."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "node_role_arn" {
  description = "Shared IAM role ARN for worker nodes (managed groups + Karpenter)."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "Shared IAM role name for worker nodes."
  value       = aws_iam_role.node.name
}

output "kms_key_arn" {
  description = "KMS key ARN used for secret envelope encryption."
  value       = aws_kms_key.eks.arn
}

output "karpenter_node_instance_profile_name" {
  description = "Instance profile Karpenter assigns to launched nodes (empty if disabled)."
  value       = try(aws_iam_instance_profile.karpenter_node[0].name, "")
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue name Karpenter watches for interruptions (empty if disabled)."
  value       = try(aws_sqs_queue.karpenter[0].name, "")
}

output "karpenter_interruption_queue_arn" {
  description = "SQS queue ARN for the Karpenter IRSA policy (empty if disabled)."
  value       = try(aws_sqs_queue.karpenter[0].arn, "")
}
