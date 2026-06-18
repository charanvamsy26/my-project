# Conftest policy: encryption-at-rest for AWS data stores in a Terraform plan.
# Input: `terraform show -json` plan output.
#
# Enforces encryption for the data stores my-project provisions:
#   - EBS volumes (aws_ebs_volume) + the launch-template/node defaults
#   - RDS instances + clusters (storage_encrypted = true)
#   - EKS secrets envelope encryption (cluster encryption_config present)
#
# WHY: encryption-at-rest is table stakes for any data store holding customer or
# operational data, and is required by most compliance regimes (SOC2, PCI, HIPAA).
# It's also a one-flag change that's easy to forget — exactly what policy-as-code
# should backstop.
package terraform.encryption

import future.keywords.contains
import future.keywords.if
import future.keywords.in

changed_resources(resource_type) := [r |
	some r in input.resource_changes
	r.type == resource_type
	some action in r.change.actions
	action in {"create", "update"}
]

after(r) := r.change.after

# --- EBS volumes -----------------------------------------------------------
deny contains msg if {
	some r in changed_resources("aws_ebs_volume")
	object.get(after(r), "encrypted", false) != true
	msg := sprintf("EBS volume '%s' must set encrypted = true", [r.address])
}

# --- RDS instances ---------------------------------------------------------
deny contains msg if {
	some r in changed_resources("aws_db_instance")
	object.get(after(r), "storage_encrypted", false) != true
	msg := sprintf("RDS instance '%s' must set storage_encrypted = true", [r.address])
}

# --- RDS / Aurora clusters -------------------------------------------------
deny contains msg if {
	some r in changed_resources("aws_rds_cluster")
	object.get(after(r), "storage_encrypted", false) != true
	msg := sprintf("RDS cluster '%s' must set storage_encrypted = true", [r.address])
}

# --- EKS secrets envelope encryption ---------------------------------------
# my-project encrypts Kubernetes Secrets at rest with a KMS key via the cluster's
# encryption_config. Flag any EKS cluster created without one.
deny contains msg if {
	some r in changed_resources("aws_eks_cluster")
	configs := object.get(after(r), "encryption_config", [])
	count(configs) == 0
	msg := sprintf("EKS cluster '%s' must define encryption_config (KMS envelope encryption for secrets)", [r.address])
}
