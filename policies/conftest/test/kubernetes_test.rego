# Unit tests for the kubernetes.rego conftest policy.
# Run with:  conftest verify -p policy test    (or: opa test policy test)
#
# Strategy: feed a known-good demo-api Deployment (must produce ZERO denies) and a
# deliberately-bad Deployment (must trip every rule). This is the regression net
# that guarantees demo-api keeps passing as the policy evolves.
package kubernetes

import future.keywords.if
import future.keywords.in

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A compliant demo-api Deployment — mirrors the demo-api Helm output.
good_demo_api := {
	"apiVersion": "apps/v1",
	"kind": "Deployment",
	"metadata": {
		"name": "demo-api",
		"namespace": "demo",
		"labels": {
			"app.kubernetes.io/name": "demo-api",
			"app.kubernetes.io/part-of": "my-project",
			"app.kubernetes.io/managed-by": "Helm",
		},
	},
	"spec": {
		"replicas": 2,
		"template": {
			"metadata": {"labels": {"app.kubernetes.io/name": "demo-api"}},
			"spec": {
				"securityContext": {"runAsNonRoot": true},
				"containers": [{
					"name": "demo-api",
					"image": "ghcr.io/charanvamsy26/demo-api:1.0.0",
					"ports": [{"containerPort": 8000}],
					"resources": {
						"requests": {"cpu": "50m", "memory": "64Mi"},
						"limits": {"cpu": "250m", "memory": "128Mi"},
					},
					"securityContext": {
						"allowPrivilegeEscalation": false,
						"readOnlyRootFilesystem": true,
						"capabilities": {"drop": ["ALL"]},
					},
					"livenessProbe": {"httpGet": {"path": "/healthz", "port": 8000}},
					"readinessProbe": {"httpGet": {"path": "/readyz", "port": 8000}},
				}],
			},
		},
	},
}

# A deliberately non-compliant Deployment: default ns, :latest, wrong registry,
# no resources, root, no probes.
bad_deployment := {
	"apiVersion": "apps/v1",
	"kind": "Deployment",
	"metadata": {"name": "bad-app", "namespace": "default"},
	"spec": {"template": {
		"metadata": {},
		"spec": {"containers": [{
			"name": "bad",
			"image": "docker.io/library/nginx:latest",
		}]},
	}},
}

# A demo-api ECR-mirror variant — must also pass the registry rule.
good_ecr_image := "123456789012.dkr.ecr.us-east-1.amazonaws.com/demo-api:1.0.0"

# ---------------------------------------------------------------------------
# Positive: demo-api passes cleanly
# ---------------------------------------------------------------------------

test_good_demo_api_has_no_denials if {
	count(deny) == 0 with input as good_demo_api
}

test_good_demo_api_ecr_image_allowed if {
	# swap the image for the ECR-mirror form; still zero denials
	d := json.patch(good_demo_api, [{
		"op": "replace",
		"path": "/spec/template/spec/containers/0/image",
		"value": good_ecr_image,
	}])
	count(deny) == 0 with input as d
}

# ---------------------------------------------------------------------------
# Negative: bad deployment trips the expected rules
# ---------------------------------------------------------------------------

test_bad_deployment_blocks_default_namespace if {
	some msg in deny with input as bad_deployment
	contains(msg, "default")
}

test_bad_deployment_blocks_latest_tag if {
	some msg in deny with input as bad_deployment
	contains(msg, ":latest")
}

test_bad_deployment_blocks_disallowed_registry if {
	some msg in deny with input as bad_deployment
	contains(msg, "not from an allowed registry")
}

test_bad_deployment_requires_resources if {
	some msg in deny with input as bad_deployment
	contains(msg, "resources.requests.cpu")
}

test_bad_deployment_requires_nonroot if {
	some msg in deny with input as bad_deployment
	contains(msg, "runAsNonRoot")
}

test_bad_deployment_requires_drop_all if {
	some msg in deny with input as bad_deployment
	contains(msg, "drop ALL capabilities")
}

test_bad_deployment_requires_probes if {
	some msg in deny with input as bad_deployment
	contains(msg, "livenessProbe")
}

# Targeted regressions on single fields ------------------------------------

test_missing_limits_is_denied if {
	d := json.remove(good_demo_api, ["/spec/template/spec/containers/0/resources/limits"])
	some msg in deny with input as d
	contains(msg, "resources.limits")
}

test_root_pod_is_denied if {
	d := json.patch(good_demo_api, [{
		"op": "replace",
		"path": "/spec/template/spec/securityContext/runAsNonRoot",
		"value": false,
	}])
	some msg in deny with input as d
	contains(msg, "runAsNonRoot")
}
