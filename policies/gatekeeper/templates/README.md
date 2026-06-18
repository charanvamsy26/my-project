# Gatekeeper ConstraintTemplates (`gatekeeper/templates/`)

`ConstraintTemplate`s are the **reusable, parameterized rules** (written in Rego).
Each one generates a new CRD; the matching [`../constraints/`](../constraints/)
instantiate those CRDs with a `match` block, parameters, and an enforcement action.

> **Apply order:** templates **before** constraints. A constraint references the CRD
> its template creates, so applying it first fails with `no matches for kind`.
> ArgoCD handles this via sync waves (templates = wave 1, constraints = wave 2).

## The templates

| File | Generated kind | What it enforces |
| ---- | -------------- | ---------------- |
| `required-labels.yaml` | `K8sRequiredLabels` | Required labels present, with optional value regex (ownership/provenance). |
| `disallow-latest-tag.yaml` | `K8sDisallowLatestTag` | No `:latest` and no untagged images; require explicit tag or digest. |
| `require-resources.yaml` | `K8sRequireResources` | Every container sets requests **and** limits (default cpu + memory). |
| `require-security-context.yaml` | `K8sRequireSecurityContext` | `runAsNonRoot`, drop `ALL` caps, no privilege escalation, no privileged. |
| `allowed-registries.yaml` | `K8sAllowedRegistries` | Images only from allowed registry prefixes (ghcr.io + ECR). |
| `require-probes.yaml` | `K8sRequireProbes` | App containers define liveness **and** readiness probes. |
| `block-default-namespace.yaml` | `K8sBlockDefaultNamespace` | No workloads in the `default` namespace. |
| `require-pdb.yaml` | `K8sRequirePDB` | *(optional)* multi-replica Deployments covered by a matching PDB. |

## Rego conventions used here

- **Rego v1 syntax** (`import future.keywords.{contains,if,in}`) — the default on
  current Gatekeeper. Partial rules use `violation contains {"msg": ...} if { ... }`.
- Each rule emits the Gatekeeper-standard `violation` set of `{"msg": "..."}`.
- We iterate `containers`, `initContainers`, and (where relevant) `ephemeralContainers`
  so init/debug containers can't bypass a rule.
- Safe field access via `object.get(obj, path, default)` so a missing field produces a
  clear violation instead of an undefined (silently-passing) rule.
- `exemptImages` parameters allow narrow, reviewable per-image carve-outs.

## Cross-object templates

`K8sRequirePDB` reads other objects (`PodDisruptionBudget`) from OPA's inventory
cache (`data.inventory.namespace[...]`). For this to work the Gatekeeper `Config`
**must sync** that kind — it does (see [`../install/config.yaml`](../install/config.yaml)).
Cross-object admission has an inherent cache race (an object applied in the same
batch may not be cached yet), so `K8sRequirePDB` ships as **dryrun**.

## Testing templates

Templates can be unit-tested without a cluster using
[`gator`](https://open-policy-agent.github.io/gatekeeper/website/docs/gator/) (the
Gatekeeper policy test tool). Put `*_test.yaml` suites next to a template and run:

```bash
gator verify ./policies/gatekeeper/...
```

CI runs `gator` against this directory; `conftest` ([`../../conftest/`](../../conftest/))
covers the IaC/manifest side.

## Adding a new template

1. Write the `ConstraintTemplate` here (kebab-case file, one per file).
2. Add a `Constraint` in [`../constraints/`](../constraints/) — start it `dryrun`.
3. Watch audit (`status.totalViolations`), fix offenders, then flip to `deny`.
4. Document the new rule in this table and in the constraints README.
