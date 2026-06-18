# Policy-as-Code (`policies/`)

This directory holds the **policy-as-code** layer for `my-project`. Policies are
treated like any other source artifact: version-controlled, peer-reviewed, tested
in CI, and rolled out through GitOps (ArgoCD). Two complementary engines are used,
both built on the **Open Policy Agent (OPA)** / Rego language:

| Engine | Runs | Catches | Layout |
| ------ | ---- | ------- | ------ |
| **[OPA Gatekeeper](https://open-policy-agent.github.io/gatekeeper/)** | In-cluster admission controller on EKS | Non-compliant Kubernetes objects **at apply time** (and continuously via audit) | [`gatekeeper/`](gatekeeper/) |
| **[Conftest](https://www.conftest.dev/)** | CI (GitHub Actions), pre-merge | Bad Terraform plans & raw k8s manifests **before they ever reach a cluster** | [`conftest/`](conftest/) |

> **Why both?** Gatekeeper is the runtime *enforcement* backstop — it is the last
> line of defense and protects against drift / out-of-band `kubectl apply`.
> Conftest *shifts left*: it fails the PR so an engineer gets feedback in seconds
> instead of discovering a rejected admission in a deploy pipeline. Defense in
> depth — the same intent (no `:latest`, encryption on, no public S3) is checked at
> two layers.

---

## What is policy-as-code?

Instead of relying on wiki pages, checklists, or "ask the platform team in Slack",
the rules that govern *what may run* in the platform are encoded as machine-checked
policies. Benefits:

- **Consistency** — the same rule is applied to every workload, every time, with no
  human in the loop to forget it.
- **Auditability** — `git log` is the change history for every rule. Reviews,
  approvals, and rollbacks are first-class.
- **Testability** — policies ship with unit tests (`conftest verify`, Gatekeeper
  template `gator` tests) so a regression in a rule is caught like any code bug.
- **Self-service guardrails** — teams move fast inside known-safe boundaries rather
  than waiting on manual sign-off.

---

## Gatekeeper: how it works

Gatekeeper is a [validating admission webhook](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
plus an audit controller, driven by two CRD kinds:

1. **`ConstraintTemplate`** — defines a *reusable, parameterized rule* in Rego and
   generates a new CRD (the constraint kind). Think of it as a class.
   See [`gatekeeper/templates/`](gatekeeper/templates/).
2. **Constraint** — an *instance* of a template: it selects which objects the rule
   applies to (`match`), supplies parameters, and sets the `enforcementAction`.
   See [`gatekeeper/constraints/`](gatekeeper/constraints/).

```
ConstraintTemplate (K8sRequiredLabels)  -->  generates CRD: K8sRequiredLabels
        Constraint (must-have-owner-label)  -->  instance of that CRD
```

### Install

See [`gatekeeper/install/`](gatekeeper/install/) for the kustomization that pins the
upstream Gatekeeper release and applies our cluster `Config`. The short version:

```bash
# 1. Install the Gatekeeper control plane (pinned, via our kustomization)
kubectl apply -k policies/gatekeeper/install

# 2. Wait for the webhook to be ready before applying policy
kubectl -n gatekeeper-system rollout status deploy/gatekeeper-controller-manager
kubectl -n gatekeeper-system rollout status deploy/gatekeeper-audit

# 3. Templates first (they create CRDs), then the constraints that use them
kubectl apply -f policies/gatekeeper/templates/
kubectl apply -f policies/gatekeeper/constraints/
```

In `my-project` all three steps are owned by **ArgoCD** (app-of-apps) so the cluster
state always matches this repo. Sync waves ensure ordering: `install` (wave 0) →
`templates` (wave 1) → `constraints` (wave 2). The manual commands above are for
local/break-glass use.

> **Ordering matters.** A Constraint references a CRD that its ConstraintTemplate
> creates. Applying a constraint before its template exists will fail with
> `no matches for kind`. Templates → constraints, always.

---

## `audit` vs `enforce` (dryrun vs deny)

Every constraint has an `enforcementAction` that controls what happens when a
resource violates it:

| `enforcementAction` | Admission (apply time) | Audit (background scan) |
| ------------------- | ---------------------- | ----------------------- |
| `deny`    | **Rejects** the request | Reports violations on the constraint's `status` |
| `dryrun`  | Allows the request | Reports violations (visibility only) |
| `warn`    | Allows, returns a warning to the client | Reports violations |

**Audit** is the controller that periodically (default every 60s, configured in our
`Config`) scans *existing* cluster objects and writes any violations to each
constraint's `status.violations`, regardless of `enforcementAction`. This is how you
measure blast radius **before** flipping a rule to `deny`.

### Recommended rollout pattern (used here)

```
1. Ship the constraint as `dryrun`.
2. Watch audit:  kubectl get <constraintKind> <name> -o yaml  (status.totalViolations)
3. Fix or exempt the offenders.
4. Flip to `deny` once totalViolations == 0.
```

Our defaults are documented per file in
[`gatekeeper/constraints/README.md`](gatekeeper/constraints/README.md). Critical,
unambiguous, security-relevant rules ship in **`deny`** from day one (e.g. allowed
registries, runAsNonRoot, block default namespace). Rules that commonly surface
legacy debt ship in **`dryrun`** (e.g. require PDB, require probes) until the fleet
is clean.

Inspect violations across all constraints:

```bash
kubectl get constraints   # lists every constraint kind/instance
kubectl get k8sallowedrepos allowed-image-registries -o jsonpath='{.status.totalViolations}'
```

---

## Exemptions

Real platforms always have legitimate exceptions (system DaemonSets that need
host access, the monitoring stack, Gatekeeper itself). We grant exemptions in three
escalating ways — prefer the narrowest one that solves the problem:

### 1. `match` scoping (preferred)

Each constraint only matches the namespaces/kinds it should. We use
`excludedNamespaces` to skip system/platform namespaces and `namespaceSelector` /
`labelSelector` for finer control. Example (from a real constraint here):

```yaml
match:
  kinds:
    - apiGroups: [""]
      kinds: ["Pod"]
  excludedNamespaces:
    - kube-system
    - gatekeeper-system
    - monitoring          # kube-prometheus-stack components
```

### 2. Cluster-wide exempt namespaces (Gatekeeper `Config`)

The Gatekeeper `Config` ([`gatekeeper/install/config.yaml`](gatekeeper/install/config.yaml))
lists namespaces that the **admission webhook ignores entirely**. This is the
strongest, broadest exemption and is reserved for namespaces that must never be
blocked even if the webhook is misbehaving (`kube-system`, `gatekeeper-system`):

```yaml
spec:
  match:
    - excludedNamespaces: ["kube-system", "gatekeeper-system"]
      processes: ["*"]
```

### 3. Per-object annotation (break-glass, audited)

For a single object that legitimately must violate a rule, label its namespace
(not the object) so the constraint's `namespaceSelector` skips it, **or** for true
one-offs use a dedicated allow-list parameter on the constraint. We avoid blanket
object-level annotations; every exemption should be reviewable in Git and have an
owner. Document the *why* in the resource's annotations:

```yaml
metadata:
  annotations:
    policy.my-project.io/exemption-reason: "legacy job, tracked in JIRA PLAT-1234"
    policy.my-project.io/exemption-owner: "platform-team"
```

> **Exemptions are debt.** Every one should reference a ticket and an owner, and be
> revisited. A broad `excludedNamespaces` is a smell unless it's a system namespace.

---

## Directory layout

```
policies/
├── README.md                  # you are here
├── gatekeeper/
│   ├── install/               # pin + install Gatekeeper control plane + Config
│   ├── templates/             # ConstraintTemplates (reusable Rego rules)
│   └── constraints/           # Constraints (instances: match + params + action)
└── conftest/                  # CI-time OPA policies for Terraform plans & manifests
    ├── policy/                # Rego rules
    ├── test/                  # Rego unit tests + example inputs
    └── README.md
```

## Conventions

- File names are **kebab-case**; one ConstraintTemplate / Constraint per file.
- Every constraint sets `metadata.labels` `app.kubernetes.io/part-of: my-project`.
- Constraints exempt `kube-system`, `gatekeeper-system`, and (where a workload
  concern) `monitoring` unless there is a reason not to.
- All Rego is written for the **Gatekeeper Rego v1** runtime (`if`/`contains`
  keywords, explicit `import`s) which is the default on current Gatekeeper.
