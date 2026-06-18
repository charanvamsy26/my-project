###############################################################################
# eks-addons module — Helm-installed cluster add-ons
#
# Installs the cluster add-ons that are easier to manage as Helm releases than as
# EKS managed add-ons:
#   * AWS Load Balancer Controller — provisions ALBs/NLBs for Ingress/Service.
#   * metrics-server               — powers `kubectl top` and HPA.
#
# Heavier platform components (ArgoCD, kube-prometheus-stack, Gatekeeper,
# Karpenter, external-dns) are intentionally NOT here — they belong to the
# GitOps/app-of-apps layer so they are version-controlled and self-healing.
# Bootstrapping just enough (LB controller + metrics-server) via Terraform avoids
# a circular dependency where ArgoCD itself needs an ALB to be reachable.
###############################################################################

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12"
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  count = var.enable_aws_load_balancer_controller ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_load_balancer_controller_chart_version
  namespace  = var.namespace

  # Don't proceed until the controller's pods are actually healthy.
  wait    = true
  timeout = 600

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.aws_region
    vpcId       = var.vpc_id

    serviceAccount = {
      create = true
      name   = var.aws_load_balancer_controller_service_account
      # IRSA: the controller assumes this role instead of using node credentials.
      annotations = {
        "eks.amazonaws.com/role-arn" = var.aws_load_balancer_controller_irsa_role_arn
      }
    }

    # Run two replicas for availability and scrape Prometheus metrics.
    replicaCount = 2

    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "200m", memory = "256Mi" }
    }
  })]
}

resource "helm_release" "metrics_server" {
  count = var.enable_metrics_server ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = var.namespace

  wait    = true
  timeout = 300

  values = [yamlencode({
    args = [
      # Standard on EKS where kubelet serving certs aren't in the cluster CA chain.
      "--kubelet-insecure-tls",
      "--kubelet-preferred-address-types=InternalIP",
    ]
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "100m", memory = "128Mi" }
    }
  })]
}
