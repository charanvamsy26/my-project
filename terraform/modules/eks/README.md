# module: eks

Authors an **EKS control plane** and its baseline data plane directly (no upstream
wrapper module), so every security-relevant decision is explicit and reviewable.

## What it creates

| Area              | Resources |
|-------------------|-----------|
| Control plane     | `aws_eks_cluster` (private node placement, configurable public/private API) |
| Encryption        | Dedicated KMS CMK (rotation on) for **secret envelope encryption** |
| Logging           | All control-plane log types → CloudWatch (`/aws/eks/<name>/cluster`) |
| IRSA              | `aws_iam_openid_connect_provider` (thumbprint fetched via `tls` provider) |
| Compute           | Parameterized managed node group(s) on a least-privilege shared node role |
| Core add-ons      | `vpc-cni`, `kube-proxy`, `coredns`, `aws-ebs-csi-driver` (EKS-managed) |
| Karpenter (prereqs)| Node instance profile, SQS interruption queue, EventBridge rules |

## Design notes

- **Secrets are envelope-encrypted** with a CMK created here (`encryption_config`),
  not the default AWS-owned key.
- **Nodes go in private subnets only.** Pass the VPC module's `private_subnet_ids`.
- **Workload AWS permissions come from IRSA**, never the node role. The node role
  carries only the four policies a kubelet needs (worker, CNI, ECR read, SSM).
- **`desired_size` is ignored after creation** so the cluster autoscaler/Karpenter
  can move it without Terraform fighting back.
- **Karpenter is split in two:** this module makes the AWS-side plumbing (instance
  profile + interruption queue/rules) and exports the ARNs; the Karpenter
  controller's IRSA role is built in the `iam-irsa` layer from the policy template,
  and the controller itself is installed by the GitOps layer.

## Usage

```hcl
module "eks" {
  source = "../../modules/eks"

  cluster_name       = "my-project-dev"
  kubernetes_version = "1.30"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids   # private only

  # dev: leave public endpoint open-ish; prod should restrict public_access_cidrs
  endpoint_public_access       = true
  endpoint_public_access_cidrs = ["0.0.0.0/0"]

  cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  node_groups = {
    default = {
      instance_types = ["t3.large"]
      capacity_type  = "ON_DEMAND"
      desired_size   = 2
      min_size       = 2
      max_size       = 4
      labels         = { role = "general" }
    }
  }

  enable_karpenter_prerequisites = true
  enable_irsa                    = true

  # optional: wire the ebs-csi IRSA role created in the iam-irsa layer
  ebs_csi_irsa_role_arn = module.ebs_csi_irsa.role_arn

  tags = local.tags
}
```

## Key outputs (consumed downstream)

| Output | Used by |
|--------|---------|
| `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data` | kubeconfig, helm/kubernetes providers |
| `oidc_provider_arn`, `oidc_provider_url` | every IRSA role |
| `node_role_arn` | Karpenter EC2NodeClass, aws-auth |
| `karpenter_interruption_queue_arn`, `karpenter_node_instance_profile_name` | Karpenter controller + nodeclass |
| `kms_key_arn` | audits / other encrypted services |

## A note on cluster auth

The aws-auth ConfigMap / EKS Access Entries that map the node role and your IAM
principals into the cluster are managed in the GitOps/Kubernetes layer (or can be
added here with `aws_eks_access_entry` if you prefer pure-Terraform auth). Keeping
it out of this module keeps the module reusable across auth strategies.
