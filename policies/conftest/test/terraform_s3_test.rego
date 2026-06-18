# Unit tests for terraform_s3.rego.
# Run with:  conftest verify -p policy test   (or: opa test policy test)
#
# Fixtures mimic the `terraform show -json` resource_changes shape.
package terraform.s3

import future.keywords.if
import future.keywords.in

# A compliant private state bucket + its lock-down siblings.
compliant_plan := {"resource_changes": [
	{
		"address": "module.tfstate.aws_s3_bucket.this",
		"type": "aws_s3_bucket",
		"name": "this",
		"change": {"actions": ["create"], "after": {"bucket": "my-project-tfstate-123456789012", "acl": "private"}},
	},
	{
		"address": "module.tfstate.aws_s3_bucket_public_access_block.this",
		"type": "aws_s3_bucket_public_access_block",
		"name": "this",
		"change": {"actions": ["create"], "after": {
			"bucket": "my-project-tfstate-123456789012",
			"block_public_acls": true,
			"block_public_policy": true,
			"ignore_public_acls": true,
			"restrict_public_buckets": true,
		}},
	},
	{
		"address": "module.tfstate.aws_s3_bucket_server_side_encryption_configuration.this",
		"type": "aws_s3_bucket_server_side_encryption_configuration",
		"name": "this",
		"change": {"actions": ["create"], "after": {"bucket": "my-project-tfstate-123456789012"}},
	},
	{
		"address": "module.tfstate.aws_s3_bucket_versioning.this",
		"type": "aws_s3_bucket_versioning",
		"name": "this",
		"change": {"actions": ["create"], "after": {
			"bucket": "my-project-tfstate-123456789012",
			"versioning_configuration": [{"status": "Enabled"}],
		}},
	},
]}

# A public, unencrypted bucket with no lock-down.
public_plan := {"resource_changes": [{
	"address": "aws_s3_bucket.public_assets",
	"type": "aws_s3_bucket",
	"name": "public_assets",
	"change": {"actions": ["create"], "after": {"bucket": "my-leaky-bucket", "acl": "public-read"}},
}]}

test_compliant_bucket_has_no_denials if {
	count(deny) == 0 with input as compliant_plan
}

test_compliant_bucket_has_no_versioning_warning if {
	count(warn) == 0 with input as compliant_plan
}

test_public_acl_denied if {
	some msg in deny with input as public_plan
	contains(msg, "public ACL")
}

test_missing_public_access_block_denied if {
	some msg in deny with input as public_plan
	contains(msg, "public_access_block")
}

test_missing_encryption_denied if {
	some msg in deny with input as public_plan
	contains(msg, "encryption")
}

test_missing_versioning_warns if {
	some msg in warn with input as public_plan
	contains(msg, "versioning")
}
