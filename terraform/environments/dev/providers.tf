###############################################################################
# Provider configuration for the dev environment
#
# The root module owns provider configuration (region, default tags, auth). The
# reusable modules only declare required_providers — they never configure one.
###############################################################################

provider "aws" {
  region = var.aws_region

  # Stamp every resource with the platform's standard tags automatically.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Resolve the EKS cluster for the helm provider. These data sources read the
# cluster created in this same apply; Terraform orders them after module.eks.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

# Helm provider authenticates to the cluster via the AWS CLI token helper (IRSA-
# friendly, no long-lived kubeconfig).
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
