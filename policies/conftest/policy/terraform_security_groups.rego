# Conftest policy: AWS security groups / rules in a Terraform plan.
# Input: `terraform show -json` plan output.
#
# Enforces:
#   - no ingress from 0.0.0.0/0 (or ::/0) to admin ports (22 SSH, 3389 RDP)
#   - flags any 0.0.0.0/0 ingress to a non-web port as a warning
# Covers both inline rules on aws_security_group AND standalone
# aws_security_group_rule / aws_vpc_security_group_ingress_rule.
#
# WHY: an SSH/RDP port open to the whole internet is the classic initial-access
# vector. Bastions/load balancers should be the only internet-facing entry points,
# and they don't expose 22/3389. Caught pre-apply, in the PR.
package terraform.security_groups

import future.keywords.contains
import future.keywords.every
import future.keywords.if
import future.keywords.in

open_cidrs := {"0.0.0.0/0", "::/0"}
admin_ports := {22, 3389}

# Web ports we tolerate from anywhere (still warned, never denied).
web_ports := {80, 443}

changed_resources(resource_type) := [r |
	some r in input.resource_changes
	r.type == resource_type
	some action in r.change.actions
	action in {"create", "update"}
]

# Normalize an ingress rule into {from, to, cidrs} regardless of source schema.
ingress_rules contains rule if {
	# Inline ingress on aws_security_group.
	some sg in changed_resources("aws_security_group")
	some block in object.get(sg.change.after, "ingress", [])
	rule := {
		"address": sg.address,
		"from": block.from_port,
		"to": block.to_port,
		"cidrs": cidr_set(block),
	}
}

ingress_rules contains rule if {
	# Standalone aws_security_group_rule of type ingress.
	some r in changed_resources("aws_security_group_rule")
	a := r.change.after
	a.type == "ingress"
	rule := {
		"address": r.address,
		"from": a.from_port,
		"to": a.to_port,
		"cidrs": cidr_set(a),
	}
}

ingress_rules contains rule if {
	# Newer aws_vpc_security_group_ingress_rule (one CIDR per rule).
	some r in changed_resources("aws_vpc_security_group_ingress_rule")
	a := r.change.after
	rule := {
		"address": r.address,
		"from": a.from_port,
		"to": a.to_port,
		"cidrs": {a.cidr_ipv4},
	}
}

# Collect IPv4 + IPv6 CIDRs from whichever fields exist on the block.
cidr_set(block) := cidrs if {
	v4 := object.get(block, "cidr_blocks", [])
	v6 := object.get(block, "ipv6_cidr_blocks", [])
	cidrs := {c | some c in array.concat(v4, v6)}
}

# A rule covers `port` if port is within [from, to].
covers_port(rule, port) if {
	rule.from <= port
	port <= rule.to
}

# DENY: admin port reachable from an open CIDR.
deny contains msg if {
	some rule in ingress_rules
	some cidr in rule.cidrs
	cidr in open_cidrs
	some port in admin_ports
	covers_port(rule, port)
	msg := sprintf(
		"security group '%s' allows ingress to admin port %d from %s; restrict to a bastion/VPN CIDR",
		[rule.address, port, cidr],
	)
}

# WARN: any non-web port open to the world (broad exposure worth a look).
warn contains msg if {
	some rule in ingress_rules
	some cidr in rule.cidrs
	cidr in open_cidrs
	not exposes_only_web(rule)
	not exposes_admin(rule) # already a deny; don't double-report
	msg := sprintf(
		"security group '%s' allows ingress to port range %d-%d from %s; confirm this should be internet-facing",
		[rule.address, rule.from, rule.to, cidr],
	)
}

exposes_only_web(rule) if {
	every p in numbers.range(rule.from, rule.to) {
		p in web_ports
	}
}

exposes_admin(rule) if {
	some port in admin_ports
	covers_port(rule, port)
}
