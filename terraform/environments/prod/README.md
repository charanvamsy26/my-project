# environment: prod

The **prod** root module — the high-availability platform.
Cluster name: **`my-project-prod`**.

## What it provisions

```
module.vpc            10.1.0.0/16, 3 AZs, NAT gateway PER AZ, flow logs
module.eks            my-project-prod (K8s 1.30), m5.xlarge nodes (3-9), IRSA, full control-plane logs
module.*_irsa         least-privilege IRSA roles: LB controller, external-dns, ebs-csi, karpenter
module.rds            Aurora PostgreSQL, writer + reader (multi-AZ), deletion protection ON
module.eks_addons     AWS Load Balancer Controller + metrics-server (Helm)
```

## HA / hardening choices (vs dev)

| Choice                          | Effect |
|---------------------------------|--------|
| `single_nat_gateway = false`    | one NAT per AZ → egress survives an AZ outage |
| `m5.xlarge` nodes, 3-9          | one node minimum per AZ, room to scale |
| `instance_count = 2` (Aurora)   | writer + reader, automatic failover |
| full `cluster_log_types`        | complete control-plane audit trail |
| `deletion_protection = true`    | DB cannot be casually destroyed |
| `skip_final_snapshot = false`   | a snapshot is always taken before deletion |
| distinct CIDR `10.1.0.0/16`     | non-overlapping with dev (peering-ready) |

## Before you apply — production checklist

- [ ] Set `<account_id>` in `backend.tf`.
- [ ] **Restrict `endpoint_public_access_cidrs`** to your VPN/office ranges — the
      example default `0.0.0.0/0` is a placeholder you must override.
- [ ] Review node sizing/limits against expected load.
- [ ] Confirm `deletion_protection = true` (it is, by default).
- [ ] Have a peer review the `terraform plan` output.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # set real endpoint CIDRs!

terraform init
terraform plan                  # REVIEW CAREFULLY
terraform apply

$(terraform output -raw configure_kubectl)
kubectl get nodes
```

## Outputs

Same shape as dev: `configure_kubectl`, `irsa_role_arns`,
`karpenter_node_instance_profile_name`, `karpenter_interruption_queue_name`,
`rds_writer_endpoint`, `rds_reader_endpoint`, `rds_secret_arn`.

## Tearing down

`deletion_protection = true` on Aurora means `terraform destroy` will **fail** until
you flip it off deliberately. This friction is intentional — production data should
never be one command away from deletion.
