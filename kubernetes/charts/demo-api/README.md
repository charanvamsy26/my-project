# demo-api Helm chart

Helm chart that deploys **demo-api** — the reference Flask workload of the
**eks-gitops-platform** platform — onto EKS, hardened to production defaults. It renders a
Deployment plus Service, ServiceAccount, ALB Ingress, HorizontalPodAutoscaler,
ConfigMap, ServiceMonitor (Prometheus Operator), PodDisruptionBudget, and a
NetworkPolicy.

* Image: `ghcr.io/charanvamsy26/demo-api:<tag>` (never `:latest`)
* Namespace: `demo`
* Ingress: AWS Load Balancer Controller (ALB), host `demo-api.example.com`
* Metrics: scraped via ServiceMonitor by kube-prometheus-stack

## Layout

```
charts/demo-api/
├── Chart.yaml
├── values.yaml          # documented defaults
├── values-dev.yaml      # dev overlay (eks-gitops-platform-dev)
├── values-prod.yaml     # prod overlay (eks-gitops-platform-prod)
├── .helmignore
├── README.md            # this file
└── templates/
    ├── _helpers.tpl
    ├── deployment.yaml
    ├── service.yaml
    ├── serviceaccount.yaml
    ├── ingress.yaml
    ├── hpa.yaml
    ├── configmap.yaml
    ├── secret.yaml              # only rendered for an inline databaseUrl
    ├── servicemonitor.yaml
    ├── poddisruptionbudget.yaml
    ├── networkpolicy.yaml
    └── NOTES.txt
```

## Usage

```bash
# Lint
helm lint charts/demo-api -f charts/demo-api/values.yaml

# Render (dev)
helm template demo-api charts/demo-api \
  -n demo -f charts/demo-api/values.yaml -f charts/demo-api/values-dev.yaml

# Install/upgrade (prod)
helm upgrade --install demo-api charts/demo-api \
  -n demo --create-namespace \
  -f charts/demo-api/values.yaml -f charts/demo-api/values-prod.yaml \
  --set image.tag=0.1.0
```

In **eks-gitops-platform** this chart is normally delivered by **ArgoCD** (app-of-apps),
not installed by hand.

## Security posture

* Pod runs as **non-root** (uid/gid 10001), `runAsNonRoot: true`.
* `readOnlyRootFilesystem: true`; a small `emptyDir` is mounted at `/tmp` for
  gunicorn/Python scratch.
* `allowPrivilegeEscalation: false`, **all Linux capabilities dropped**,
  `seccompProfile: RuntimeDefault`.
* ServiceAccount token auto-mount is **disabled** (the app makes no API calls).
* Default-deny-ingress **NetworkPolicy** with explicit allows for Prometheus
  scrapes and ingress traffic.
* Resource **requests and limits** are always set.

These map to the Gatekeeper / Pod Security ("restricted") policies enforced in
the cluster.

## Values reference

### Image & basics

| Key                  | Default                          | Description |
| -------------------- | -------------------------------- | ----------- |
| `replicaCount`       | `2`                              | Replicas when autoscaling is disabled (initial count when enabled). |
| `image.repository`   | `ghcr.io/charanvamsy26/demo-api`   | Image repo. |
| `image.pullPolicy`   | `IfNotPresent`                   | Correct for immutable tags. |
| `image.tag`          | `""` → `Chart.appVersion`        | Image tag; set explicitly in CI/CD. |
| `imagePullSecrets`   | `[]`                             | Pull secrets for private registries. |
| `nameOverride`       | `""`                             | Override chart name in resource names. |
| `fullnameOverride`   | `""`                             | Fully override the resource name prefix. |

### ServiceAccount

| Key                                          | Default | Description |
| -------------------------------------------- | ------- | ----------- |
| `serviceAccount.create`                      | `true`  | Create a dedicated SA. |
| `serviceAccount.annotations`                 | `{}`    | Annotations (e.g. IRSA role ARN). |
| `serviceAccount.name`                        | `""`    | SA name; generated when empty. |
| `serviceAccount.automountServiceAccountToken`| `false` | Auto-mount the SA token. Off by default. |

### Pod metadata & security

| Key                   | Default | Description |
| --------------------- | ------- | ----------- |
| `podAnnotations`      | prometheus.io scrape annotations | Added to every pod. |
| `podLabels`           | `{}`    | Extra pod labels. |
| `podSecurityContext`  | non-root 10001, fsGroup, RuntimeDefault seccomp | Pod-level security. |
| `securityContext`     | drop ALL caps, RO rootfs, no privesc | Container-level security. |

### Service

| Key                    | Default     | Description |
| ---------------------- | ----------- | ----------- |
| `service.type`         | `ClusterIP` | Type (external access via ALB). |
| `service.port`         | `80`        | Service port. |
| `service.targetPort`   | `8000`      | Container port (matches the app). |
| `service.annotations`  | `{}`        | Extra Service annotations. |

### Ingress (ALB)

| Key                    | Default                 | Description |
| ---------------------- | ----------------------- | ----------- |
| `ingress.enabled`      | `true`                  | Create the ALB Ingress. |
| `ingress.className`    | `alb`                   | IngressClass for the AWS LB Controller. |
| `ingress.host`         | `demo-api.example.com`  | Public hostname (placeholder). |
| `ingress.path`         | `/`                     | Path. |
| `ingress.pathType`     | `Prefix`                | Path matching. |
| `ingress.annotations`  | internet-facing, IP target, HTTP→HTTPS redirect, ACM cert, healthcheck=/healthz | ALB controller config. **Set `alb.ingress.kubernetes.io/certificate-arn` to a real ACM ARN.** |
| `ingress.tls`          | `[]`                    | Optional TLS blocks (usually unneeded with ACM). |

### Resources & autoscaling

| Key                                              | Default | Description |
| ------------------------------------------------ | ------- | ----------- |
| `resources.requests.cpu`                         | `100m`  | CPU request (scheduling/HPA basis). |
| `resources.requests.memory`                      | `128Mi` | Memory request. |
| `resources.limits.memory`                        | `256Mi` | Memory limit (CPU limit set in prod overlay). |
| `autoscaling.enabled`                            | `true`  | Create the HPA. |
| `autoscaling.minReplicas`                        | `2`     | Min replicas. |
| `autoscaling.maxReplicas`                        | `6`     | Max replicas. |
| `autoscaling.targetCPUUtilizationPercentage`     | `70`    | CPU target. |
| `autoscaling.targetMemoryUtilizationPercentage`  | `null`  | Memory target (off). |

### Probes

| Key                | Default                    | Description |
| ------------------ | -------------------------- | ----------- |
| `livenessProbe`    | httpGet `/healthz` on `http` | Liveness. |
| `readinessProbe`   | httpGet `/readyz` on `http`  | Readiness. |
| `startupProbe`     | httpGet `/healthz`, up to ~60s | Startup grace. |

### Configuration & database

| Key                          | Default | Description |
| ---------------------------- | ------- | ----------- |
| `config`                     | APP_NAME/LOG_LEVEL/DB_CONNECT_TIMEOUT | Non-secret env vars → ConfigMap. |
| `databaseUrl`                | `""`    | Optional Postgres DSN. Empty = stateless. Renders a Secret if set. |
| `databaseUrlExistingSecret`  | `""`    | Name of an existing Secret with a `DATABASE_URL` key. Preferred over inlining. |

### Observability, availability & networking

| Key                                       | Default                         | Description |
| ----------------------------------------- | ------------------------------- | ----------- |
| `serviceMonitor.enabled`                  | `true`                          | Create a ServiceMonitor. |
| `serviceMonitor.interval`                 | `30s`                           | Scrape interval. |
| `serviceMonitor.scrapeTimeout`            | `10s`                           | Scrape timeout. |
| `serviceMonitor.path`                     | `/metrics`                      | Metrics path. |
| `serviceMonitor.labels`                   | `release: kube-prometheus-stack`| Must match your Prometheus selector. |
| `podDisruptionBudget.enabled`             | `true`                          | Create a PDB. |
| `podDisruptionBudget.minAvailable`        | `1`                             | Min available (use one of min/max). |
| `podDisruptionBudget.maxUnavailable`      | `null`                          | Max unavailable. |
| `networkPolicy.enabled`                   | `true`                          | Default-deny-ingress + allows. |
| `networkPolicy.allowMonitoringNamespace`  | `true`                          | Allow scrapes from monitoring ns. |
| `networkPolicy.monitoringNamespaceLabel`  | `monitoring`                    | Monitoring namespace name. |
| `networkPolicy.allowIngressController`    | `true`                          | Allow ingress traffic to the app port. |

### Scheduling & misc

| Key                            | Default | Description |
| ------------------------------ | ------- | ----------- |
| `topologySpreadConstraints`    | zone (soft) + hostname (soft); prod overlay makes zone hard | Multi-AZ/node spread. Selector is injected by the template. |
| `nodeSelector` / `tolerations` / `affinity` | `{}` / `[]` / `{}` | Standard scheduling controls. |
| `extraVolumes` / `extraVolumeMounts` | `[]` / `[]` | Extra volumes (a `/tmp` emptyDir is always added). |
| `commonLabels`                 | part-of/project/managed-by | Standard labels on all resources. |
| `environment`                  | `dev`   | Sets the `environment`/`Environment` label. |

## Notes on placeholders

`<ACM_CERTIFICATE_ARN>` (and the `<DEV/PROD_ACM_CERTIFICATE_ARN>` variants) are
placeholders — replace with the ACM certificate ARN provisioned by Terraform
before the HTTPS listener will come up. The `databaseUrl*` values are empty by
default; the service runs in stateless mode until a DB is wired in.
