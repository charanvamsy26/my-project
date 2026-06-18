###############################################################################
# Core EKS managed add-ons
#
# These four are the cluster's baseline: networking (vpc-cni), service DNS
# (coredns), kube proxying (kube-proxy), and block storage (ebs-csi). Using
# EKS *managed* add-ons (vs self-managed manifests) gives us version lifecycle
# and conflict resolution for free.
###############################################################################

# Networking must come up before anything else schedules.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.this.name
  addon_name    = "vpc-cni"
  addon_version = lookup(var.addon_versions, "vpc-cni", null)

  # OVERWRITE: reconcile back to our managed config if something drifts.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = lookup(var.addon_versions, "kube-proxy", null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags
}

# CoreDNS needs nodes to schedule onto, so wait for at least one node group.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = lookup(var.addon_versions, "coredns", null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = lookup(var.addon_versions, "aws-ebs-csi-driver", null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Prefer IRSA for the CSI controller; falls back to the node role if empty.
  service_account_role_arn = var.ebs_csi_irsa_role_arn != "" ? var.ebs_csi_irsa_role_arn : null

  tags = var.tags

  depends_on = [aws_eks_node_group.this]
}
