# module: vpc

A reusable, 3-AZ VPC purpose-built for EKS.

## What it creates

- 1 VPC with DNS support + hostnames enabled (required by EKS).
- 1 internet gateway.
- **Public subnets** (one per AZ) — host NAT gateways and internet-facing ALBs.
  Tagged `kubernetes.io/role/elb = 1`.
- **Private subnets** (one per AZ) — host EKS nodes, pods, and Aurora.
  Tagged `kubernetes.io/role/internal-elb = 1`.
- **NAT gateways** — either a single shared NAT (cost-optimized, `single_nat_gateway = true`)
  or one per AZ (HA, `single_nat_gateway = false`).
- Per-AZ private route tables (so each AZ egresses through its local NAT in HA mode).
- Optional **VPC flow logs** to CloudWatch with a dedicated least-privilege IAM role.

## EKS / Karpenter / LB Controller discovery tags

When `eks_cluster_name` is set, all subnets get
`kubernetes.io/cluster/<name> = shared`. Combined with the role tags above, this lets
the AWS Load Balancer Controller place internet-facing ALBs in public subnets and
internal ALBs/NLBs in private subnets, and lets Karpenter discover where to launch nodes.

## Usage

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source = "../../modules/vpc"

  name                 = "eks-gitops-platform-dev"
  cidr_block           = "10.0.0.0/16"
  azs                  = slice(data.aws_availability_zones.available.names, 0, 3)
  public_subnet_cidrs  = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
  private_subnet_cidrs = ["10.0.64.0/20", "10.0.80.0/20", "10.0.96.0/20"]

  single_nat_gateway = true              # dev: one NAT to save cost
  eks_cluster_name   = "eks-gitops-platform-dev"

  tags = local.tags
}
```

## Key inputs

| Variable               | Default       | Notes                                        |
|------------------------|---------------|----------------------------------------------|
| `name`                 | —             | Base name for all resources                  |
| `cidr_block`           | `10.0.0.0/16` | VPC CIDR                                      |
| `azs`                  | —             | 2 or 3 AZs (computed via data source)        |
| `public_subnet_cidrs`  | —             | one per AZ, same order                        |
| `private_subnet_cidrs` | —             | one per AZ, same order                        |
| `single_nat_gateway`   | `false`       | `true` = cheap (dev), `false` = HA (prod)    |
| `enable_flow_logs`     | `true`        | CloudWatch flow logs + IAM role               |
| `eks_cluster_name`     | `""`          | emits the cluster discovery tag when set      |

## Outputs

`vpc_id`, `vpc_cidr_block`, `public_subnet_ids`, `private_subnet_ids`,
`private_route_table_ids`, `public_route_table_id`, `nat_gateway_ids`, `nat_public_ips`,
`availability_zones`.
