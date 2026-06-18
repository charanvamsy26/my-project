# Unit tests for terraform_encryption.rego.
# Run with:  conftest verify -p policy test   (or: opa test policy test)
package terraform.encryption

import future.keywords.if
import future.keywords.in

encrypted_plan := {"resource_changes": [
	{
		"address": "aws_ebs_volume.data",
		"type": "aws_ebs_volume",
		"name": "data",
		"change": {"actions": ["create"], "after": {"encrypted": true}},
	},
	{
		"address": "aws_db_instance.app",
		"type": "aws_db_instance",
		"name": "app",
		"change": {"actions": ["create"], "after": {"storage_encrypted": true}},
	},
	{
		"address": "module.eks.aws_eks_cluster.this",
		"type": "aws_eks_cluster",
		"name": "this",
		"change": {"actions": ["create"], "after": {
			"name": "eks-gitops-platform-prod",
			"encryption_config": [{"resources": ["secrets"], "provider": [{"key_arn": "arn:aws:kms:us-east-1:123456789012:key/abc"}]}],
		}},
	},
]}

unencrypted_plan := {"resource_changes": [
	{
		"address": "aws_ebs_volume.data",
		"type": "aws_ebs_volume",
		"name": "data",
		"change": {"actions": ["create"], "after": {"encrypted": false}},
	},
	{
		"address": "aws_db_instance.app",
		"type": "aws_db_instance",
		"name": "app",
		"change": {"actions": ["create"], "after": {"storage_encrypted": false}},
	},
	{
		"address": "module.eks.aws_eks_cluster.this",
		"type": "aws_eks_cluster",
		"name": "this",
		"change": {"actions": ["create"], "after": {"name": "eks-gitops-platform-dev", "encryption_config": []}},
	},
]}

test_encrypted_resources_pass if {
	count(deny) == 0 with input as encrypted_plan
}

test_unencrypted_ebs_denied if {
	some msg in deny with input as unencrypted_plan
	contains(msg, "EBS volume")
}

test_unencrypted_rds_denied if {
	some msg in deny with input as unencrypted_plan
	contains(msg, "RDS instance")
}

test_eks_without_encryption_config_denied if {
	some msg in deny with input as unencrypted_plan
	contains(msg, "EKS cluster")
}
