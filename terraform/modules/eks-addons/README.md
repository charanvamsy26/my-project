# module: eks-addons

Installs the **minimum** set of cluster add-ons via Helm that the platform needs
before the GitOps layer takes over:

| Add-on                         | Why it's here (and not in GitOps) |
|--------------------------------|-----------------------------------|
| **AWS Load Balancer Controller** | ArgoCD, Grafana, and `demo-api` are exposed through ALB Ingress. The controller has to exist before any Ingress can get an ALB — chicken/egg with ArgoCD. |
| **metrics-server**             | Tiny, dependency-free, and needed for `kubectl top` + HPA from day one. |

Everything heavier — **ArgoCD (app-of-apps), kube-prometheus-stack, OPA Gatekeeper,
Karpenter, external-dns** — is deliberately **NOT** managed here. Those live in the
GitOps repo so they're version-controlled, self-healing, and reviewable as code.

## Requires the Helm provider

The root module must configure the `helm` provider against the cluster, e.g.:

```hcl
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
```

## Usage

```hcl
module "eks_addons" {
  source = "../../modules/eks-addons"

  cluster_name = module.eks.cluster_name
  vpc_id       = module.vpc.vpc_id
  aws_region   = "us-east-1"

  enable_aws_load_balancer_controller        = true
  aws_load_balancer_controller_irsa_role_arn = module.lb_controller_irsa.role_arn

  enable_metrics_server = true

  tags = local.tags

  # ensure nodes + IRSA exist first
  depends_on = [module.eks]
}
```

## Notes

- Chart versions are **pinned** (no floating `latest`) so upgrades are deliberate.
- The LB controller runs **2 replicas** with resource requests/limits.
- metrics-server uses `--kubelet-insecure-tls` (standard on EKS).
- `wait = true` makes Terraform block until the releases are healthy, so dependent
  resources/Ingresses don't race ahead.

## Outputs

`aws_load_balancer_controller_installed`, `aws_load_balancer_controller_release_name`,
`metrics_server_installed`, `metrics_server_release_name`.
