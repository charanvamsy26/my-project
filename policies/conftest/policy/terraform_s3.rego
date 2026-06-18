# Conftest policy: AWS S3 buckets in a Terraform plan.
# Input: `terraform show -json tfplan.binary > plan.json` (the planned-values /
# resource_changes representation). Run in CI before `terraform apply`.
#
# Enforces, for every aws_s3_bucket being created/updated:
#   - block public access (all four flags via aws_s3_bucket_public_access_block)
#   - no public ACL (public-read / public-read-write / authenticated-read)
#   - server-side encryption configured
#   - versioning enabled
#
# WHY here AND in Gatekeeper? S3 isn't a Kubernetes object — Gatekeeper can't see it.
# Public/unencrypted buckets are the single most common AWS data-leak; catching them
# in the PR (conftest) is the only pre-provision guardrail.
package terraform.s3

import future.keywords.contains
import future.keywords.every
import future.keywords.if
import future.keywords.in

# --- helpers ---------------------------------------------------------------

# Resources of a given type from the plan's resource_changes, that are being
# created or updated (ignore deletes / no-ops).
changed_resources(resource_type) := [r |
	some r in input.resource_changes
	r.type == resource_type
	actions := r.change.actions
	some action in actions
	action in {"create", "update"}
]

# The "after" state of a planned resource.
after(r) := r.change.after

# --- public ACL ------------------------------------------------------------

public_acls := {"public-read", "public-read-write", "authenticated-read"}

deny contains msg if {
	some r in changed_resources("aws_s3_bucket")
	acl := after(r).acl
	acl in public_acls
	msg := sprintf("S3 bucket '%s' sets a public ACL '%s'; use private ACLs only", [r.address, acl])
}

# --- public access block ---------------------------------------------------
# Every bucket must be paired with an aws_s3_bucket_public_access_block that has all
# four flags = true. We collect the set of bucket references that ARE protected and
# flag any created bucket whose name isn't covered.

protected_buckets contains name if {
	some r in changed_resources("aws_s3_bucket_public_access_block")
	a := after(r)
	a.block_public_acls == true
	a.block_public_policy == true
	a.ignore_public_acls == true
	a.restrict_public_buckets == true
	name := a.bucket
}

deny contains msg if {
	some r in changed_resources("aws_s3_bucket")
	bucket_ref := bucket_identifier(r)
	not bucket_ref in protected_buckets
	msg := sprintf("S3 bucket '%s' has no fully-locked aws_s3_bucket_public_access_block (all four block_* flags must be true)", [r.address])
}

# A public_access_block references a bucket by id/name; match on bucket name when
# present, else fall back to the resource name segment.
bucket_identifier(r) := name if {
	name := after(r).bucket
} else := r.name

# --- encryption ------------------------------------------------------------
# Newer AWS provider: encryption is a separate aws_s3_bucket_server_side_encryption_configuration.
# (S3 is encrypted by default since 2023, but we require an EXPLICIT config so the
# KMS key + algorithm are reviewed and pinned, not left to the account default.)

encrypted_buckets contains name if {
	some r in changed_resources("aws_s3_bucket_server_side_encryption_configuration")
	name := after(r).bucket
}

deny contains msg if {
	some r in changed_resources("aws_s3_bucket")
	bucket_ref := bucket_identifier(r)
	not bucket_ref in encrypted_buckets
	msg := sprintf("S3 bucket '%s' has no explicit aws_s3_bucket_server_side_encryption_configuration", [r.address])
}

# --- versioning ------------------------------------------------------------
# Required for state buckets and recommended everywhere (recover from overwrite/delete).

versioned_buckets contains name if {
	some r in changed_resources("aws_s3_bucket_versioning")
	after(r).versioning_configuration[_].status == "Enabled"
	name := after(r).bucket
}

warn contains msg if {
	some r in changed_resources("aws_s3_bucket")
	bucket_ref := bucket_identifier(r)
	not bucket_ref in versioned_buckets
	msg := sprintf("S3 bucket '%s' does not have versioning enabled (recommended)", [r.address])
}
