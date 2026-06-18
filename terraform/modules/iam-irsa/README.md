# module: iam-irsa

A reusable factory for **IAM Roles for Service Accounts (IRSA)** on EKS.

IRSA is the secure way to grant a pod AWS permissions: instead of attaching
broad permissions to the node IAM role (which every pod on the node would share),
each workload gets its own role whose trust policy is scoped to a specific
`namespace:serviceaccount`. The pod's projected OIDC token is exchanged for that
role via `sts:AssumeRoleWithWebIdentity`.

## What this module creates

For a single invocation:

- one `aws_iam_role` whose **trust policy** pins:
  - `aud = sts.amazonaws.com`
  - `sub` to exactly the `system:serviceaccount:<ns>:<sa>` subjects you pass
- attachments for any `policy_arns` you provide
- an optional inline policy from `inline_policy_json`

It does **not** create the Kubernetes ServiceAccount — that lives in the
Kubernetes/GitOps layer, annotated with the role ARN this module outputs.

## Usage — one role per workload

```hcl
module "lb_controller_irsa" {
  source = "../../modules/iam-irsa"

  name              = "eks-gitops-platform-dev-aws-lb-controller"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url   # no https:// prefix

  namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]

  # least-privilege policy shipped with this module
  inline_policy_json = file("${path.module}/../../modules/iam-irsa/policies/aws-load-balancer-controller.json")

  tags = local.tags
}
```

Then in the cluster (GitOps layer):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: <module.lb_controller_irsa.role_arn>
```

## Bundled least-privilege policies

| File                                         | Workload                       | Notes |
|----------------------------------------------|--------------------------------|-------|
| `policies/aws-load-balancer-controller.json` | AWS Load Balancer Controller   | Tag-scoped to `elbv2.k8s.aws/cluster` |
| `policies/external-dns.json`                 | external-dns                   | Route53 change + list only |
| `policies/karpenter.json.tftpl`              | Karpenter controller           | Templated — see below |
| ebs-csi                                       | EBS CSI driver                 | Use AWS managed `AmazonEBSCSIDriverPolicy` via `policy_arns` |

### Karpenter policy is a template

The Karpenter policy needs runtime values (account id, region, cluster name,
node role ARN, interruption-queue ARN), so it ships as a `.tftpl` template you
render with `templatefile`:

```hcl
inline_policy_json = templatefile(
  "${path.module}/../../modules/iam-irsa/policies/karpenter.json.tftpl",
  {
    partition               = data.aws_partition.current.partition
    account_id              = data.aws_caller_identity.current.account_id
    region                  = var.aws_region
    cluster_name            = module.eks.cluster_name
    node_role_arn           = module.eks.node_role_arn
    interruption_queue_arn  = module.eks.karpenter_interruption_queue_arn
  }
)
```

### ebs-csi uses an AWS-managed policy

```hcl
module "ebs_csi_irsa" {
  source                     = "../../modules/iam-irsa"
  name                       = "eks-gitops-platform-dev-ebs-csi"
  oidc_provider_arn          = module.eks.oidc_provider_arn
  oidc_provider_url          = module.eks.oidc_provider_url
  namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
  policy_arns                = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
  tags                       = local.tags
}
```

## Inputs / Outputs

Inputs: `name`, `oidc_provider_arn`, `oidc_provider_url`,
`namespace_service_accounts`, `policy_arns`, `inline_policy_json`,
`max_session_duration`, `tags`.

Outputs: `role_arn`, `role_name`, `role_unique_id`.
