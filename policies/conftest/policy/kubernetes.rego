# Conftest policy: raw Kubernetes manifests (the "shift-left" twin of Gatekeeper).
# Input: rendered manifests (`helm template ... | conftest test -` or plain YAML).
#
# Mirrors the Gatekeeper deny constraints so a non-compliant manifest fails the PR
# BEFORE it ever reaches a cluster. Keep these rules aligned with
# ../../gatekeeper/constraints/ — same intent, two layers (defense in depth).
#
# Checks (workload kinds: Deployment/StatefulSet/DaemonSet/Job/CronJob/Pod):
#   - image not :latest / untagged, and from an allowed registry
#   - cpu + memory requests AND limits on every container
#   - runAsNonRoot + drop ALL caps + no privilege escalation
#   - liveness + readiness probes on app containers
#   - not the default namespace
package kubernetes

import future.keywords.contains
import future.keywords.if
import future.keywords.in

# First-party registry prefix (anchored: must be at the start of the reference).
ghcr_prefix := "ghcr.io/charanvamsy/"

# ECR uses <account_id>.dkr.ecr.us-east-1.amazonaws.com/ — account id varies, so we
# match on the registry host shape with a regex anchored at the start of the string.
ecr_pattern := `^[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com/`

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod", "ReplicaSet"}

is_workload if input.kind in workload_kinds

# Extract the PodSpec regardless of where it lives in the kind.
pod_spec := input.spec.template.spec if {
	input.kind in {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}
} else := input.spec.jobTemplate.spec.template.spec if {
	input.kind == "CronJob"
} else := input.spec if {
	input.kind == "Pod"
}

pod_metadata := input.spec.template.metadata if {
	input.kind in {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}
} else := input.spec.jobTemplate.spec.template.metadata if {
	input.kind == "CronJob"
} else := input.metadata if {
	input.kind == "Pod"
}

app_containers contains c if {
	is_workload
	some c in object.get(pod_spec, "containers", [])
}

all_containers contains c if {
	is_workload
	some c in object.get(pod_spec, "containers", [])
}

all_containers contains c if {
	is_workload
	some c in object.get(pod_spec, "initContainers", [])
}

# --- namespace -------------------------------------------------------------
deny contains msg if {
	is_workload
	ns := object.get(input.metadata, "namespace", "default")
	ns == "default"
	msg := sprintf("%s/%s targets the 'default' namespace; set an explicit namespace", [input.kind, name])
}

# --- image tag -------------------------------------------------------------
deny contains msg if {
	some c in all_containers
	endswith(c.image, ":latest")
	msg := sprintf("%s/%s container '%s' uses :latest", [input.kind, name, c.name])
}

deny contains msg if {
	some c in all_containers
	not contains(c.image, "@") # no digest
	not image_has_tag(c.image)
	msg := sprintf("%s/%s container '%s' image '%s' has no explicit tag or digest", [input.kind, name, c.name, c.image])
}

# --- allowed registry ------------------------------------------------------
deny contains msg if {
	some c in all_containers
	not from_allowed_registry(c.image)
	msg := sprintf("%s/%s container '%s' image '%s' is not from an allowed registry", [input.kind, name, c.name, c.image])
}

# --- resources -------------------------------------------------------------
deny contains msg if {
	some c in all_containers
	some res in {"cpu", "memory"}
	not object.get(c, ["resources", "requests", res], false)
	msg := sprintf("%s/%s container '%s' missing resources.requests.%s", [input.kind, name, c.name, res])
}

deny contains msg if {
	some c in all_containers
	some res in {"cpu", "memory"}
	not object.get(c, ["resources", "limits", res], false)
	msg := sprintf("%s/%s container '%s' missing resources.limits.%s", [input.kind, name, c.name, res])
}

# --- security context ------------------------------------------------------
deny contains msg if {
	some c in all_containers
	not runs_as_non_root(c)
	msg := sprintf("%s/%s container '%s' must set runAsNonRoot=true (pod or container)", [input.kind, name, c.name])
}

deny contains msg if {
	some c in all_containers
	dropped := {cap | some cap in object.get(c, ["securityContext", "capabilities", "drop"], [])}
	not "ALL" in dropped
	msg := sprintf("%s/%s container '%s' must drop ALL capabilities", [input.kind, name, c.name])
}

deny contains msg if {
	some c in all_containers
	object.get(c, ["securityContext", "allowPrivilegeEscalation"], true) != false
	msg := sprintf("%s/%s container '%s' must set allowPrivilegeEscalation=false", [input.kind, name, c.name])
}

# --- probes (deny here too: CI is the place to require them strictly) -------
deny contains msg if {
	some c in app_containers
	some probe in {"livenessProbe", "readinessProbe"}
	not has_probe(c, probe)
	msg := sprintf("%s/%s container '%s' missing %s", [input.kind, name, c.name, probe])
}

# --- helpers ---------------------------------------------------------------
name := object.get(input.metadata, "name", "<unnamed>")

from_allowed_registry(image) if startswith(image, ghcr_prefix)

from_allowed_registry(image) if regex.match(ecr_pattern, image)

image_has_tag(image) if {
	parts := split(image, "/")
	last := parts[count(parts) - 1]
	contains(last, ":")
}

pod_runs_as_non_root if object.get(pod_spec, ["securityContext", "runAsNonRoot"], false) == true

runs_as_non_root(c) if object.get(c, ["securityContext", "runAsNonRoot"], false) == true

runs_as_non_root(_) if pod_runs_as_non_root

has_probe(c, probe) if {
	p := object.get(c, [probe], {})
	count(p) > 0
}
