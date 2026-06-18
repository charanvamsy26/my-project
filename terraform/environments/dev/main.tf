###############################################################################
# dev environment — root module
#
# Wires the reusable modules into a cost-optimized cluster:
#   * single NAT gateway
#   * smaller node group
#   * single-instance Aurora
# Naming follows my-project-dev throughout.
###############################################################################

locals {
  name = "${var.project}-${var.environment}" # my-project-dev

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Discover AZs from a data source rather than hardcoding us-east-1a/b/c.
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

###############################################################################
# Networking
###############################################################################

module "vpc" {
  source = "../../modules/vpc"

  name                 = local.name
  cidr_block           = var.vpc_cidr
  azs                  = local.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  single_nat_gateway = true # dev: one NAT to save ~$32/mo per extra AZ
  enable_flow_logs   = true
  eks_cluster_name   = local.name

  tags = local.tags
}

###############################################################################
# EKS cluster
###############################################################################

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # dev: a leaner log set keeps CloudWatch costs down.
  cluster_log_types = ["api", "audit"]

  node_groups = {
    default = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"
      desired_size   = var.node_desired_size
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      labels         = { role = "general" }
    }
  }

  enable_karpenter_prerequisites = true
  enable_irsa                    = true

  # Prefer IRSA for the EBS CSI driver.
  ebs_csi_irsa_role_arn = module.ebs_csi_irsa.role_arn

  tags = local.tags
}

###############################################################################
# IRSA roles (least privilege, one per workload)
###############################################################################

module "lb_controller_irsa" {
  source = "../../modules/iam-irsa"

  name                       = "${local.name}-aws-lb-controller"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_provider_url          = module.eks.oidc_provider_url
  namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]

  inline_policy_json = file("${path.module}/../../modules/iam-irsa/policies/aws-load-balancer-controller.json")

  tags = local.tags
}

module "external_dns_irsa" {
  source = "../../modules/iam-irsa"

  name                       = "${local.name}-external-dns"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_provider_url          = module.eks.oidc_provider_url
  namespace_service_accounts = ["kube-system:external-dns"]

  inline_policy_json = file("${path.module}/../../modules/iam-irsa/policies/external-dns.json")

  tags = local.tags
}

module "ebs_csi_irsa" {
  source = "../../modules/iam-irsa"

  name                       = "${local.name}-ebs-csi"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_provider_url          = module.eks.oidc_provider_url
  namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]

  # ebs-csi has a maintained AWS-managed policy; use it.
  policy_arns = ["arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]

  tags = local.tags
}

module "karpenter_irsa" {
  source = "../../modules/iam-irsa"

  name                       = "${local.name}-karpenter"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_provider_url          = module.eks.oidc_provider_url
  namespace_service_accounts = ["kube-system:karpenter"]

  inline_policy_json = templatefile(
    "${path.module}/../../modules/iam-irsa/policies/karpenter.json.tftpl",
    {
      partition              = data.aws_partition.current.partition
      account_id             = data.aws_caller_identity.current.account_id
      region                 = var.aws_region
      cluster_name           = module.eks.cluster_name
      node_role_arn          = module.eks.node_role_arn
      interruption_queue_arn = module.eks.karpenter_interruption_queue_arn
    }
  )

  tags = local.tags
}

###############################################################################
# Data tier — Aurora PostgreSQL
###############################################################################

module "rds" {
  source = "../../modules/rds"

  name       = local.name
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  database_name   = var.rds_database_name
  instance_class  = var.rds_instance_class
  instance_count  = var.rds_instance_count
  master_username = "dbadmin"

  # only the EKS data plane may reach the DB
  allowed_security_group_ids = [module.eks.cluster_primary_security_group_id]

  deletion_protection   = false # dev: allow teardown
  skip_final_snapshot   = true
  backup_retention_days = 7

  tags = local.tags
}

###############################################################################
# Cluster add-ons (Helm) — LB controller + metrics-server
###############################################################################

module "eks_addons" {
  source = "../../modules/eks-addons"

  cluster_name = module.eks.cluster_name
  vpc_id       = module.vpc.vpc_id
  aws_region   = var.aws_region

  enable_aws_load_balancer_controller        = true
  aws_load_balancer_controller_chart_version = var.aws_load_balancer_controller_chart_version
  aws_load_balancer_controller_irsa_role_arn = module.lb_controller_irsa.role_arn

  enable_metrics_server        = true
  metrics_server_chart_version = var.metrics_server_chart_version

  tags = local.tags

  # nodes + IRSA must be ready before charts install
  depends_on = [module.eks]
}
