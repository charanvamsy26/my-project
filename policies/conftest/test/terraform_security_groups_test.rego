# Unit tests for terraform_security_groups.rego.
# Run with:  conftest verify -p policy test   (or: opa test policy test)
package terraform.security_groups

import future.keywords.if
import future.keywords.in

# SSH open to the world (inline ingress) -> must DENY.
ssh_open_plan := {"resource_changes": [{
	"address": "aws_security_group.bastion",
	"type": "aws_security_group",
	"name": "bastion",
	"change": {"actions": ["create"], "after": {"ingress": [{
		"from_port": 22,
		"to_port": 22,
		"protocol": "tcp",
		"cidr_blocks": ["0.0.0.0/0"],
		"ipv6_cidr_blocks": [],
	}]}},
}]}

# SSH restricted to a VPN CIDR (standalone rule) -> OK.
ssh_restricted_plan := {"resource_changes": [{
	"address": "aws_security_group_rule.ssh_from_vpn",
	"type": "aws_security_group_rule",
	"name": "ssh_from_vpn",
	"change": {"actions": ["create"], "after": {
		"type": "ingress",
		"from_port": 22,
		"to_port": 22,
		"protocol": "tcp",
		"cidr_blocks": ["10.20.0.0/16"],
	}},
}]}

# HTTPS open to the world (ALB) -> allowed, no warn.
https_open_plan := {"resource_changes": [{
	"address": "aws_vpc_security_group_ingress_rule.alb_https",
	"type": "aws_vpc_security_group_ingress_rule",
	"name": "alb_https",
	"change": {"actions": ["create"], "after": {
		"from_port": 443,
		"to_port": 443,
		"ip_protocol": "tcp",
		"cidr_ipv4": "0.0.0.0/0",
	}},
}]}

# Postgres open to the world -> not admin (no deny) but should WARN.
postgres_open_plan := {"resource_changes": [{
	"address": "aws_security_group.db",
	"type": "aws_security_group",
	"name": "db",
	"change": {"actions": ["create"], "after": {"ingress": [{
		"from_port": 5432,
		"to_port": 5432,
		"protocol": "tcp",
		"cidr_blocks": ["0.0.0.0/0"],
	}]}},
}]}

test_ssh_open_to_world_denied if {
	some msg in deny with input as ssh_open_plan
	contains(msg, "admin port 22")
}

test_ssh_restricted_not_denied if {
	count(deny) == 0 with input as ssh_restricted_plan
}

test_https_open_not_denied if {
	count(deny) == 0 with input as https_open_plan
}

test_https_open_not_warned if {
	count(warn) == 0 with input as https_open_plan
}

test_postgres_open_warns_not_denies if {
	count(deny) == 0 with input as postgres_open_plan
	some msg in warn with input as postgres_open_plan
	contains(msg, "internet-facing")
}
