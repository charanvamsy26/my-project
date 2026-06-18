# load-test/k8s — in-cluster k6 Job

Runs the k6 scenarios *inside* the EKS cluster against the in-cluster `demo-api`
Service, so the load originates from the same network path real traffic does.

- [`k6-job.yaml`](k6-job.yaml) — a `ConfigMap` (the k6 scripts) **plus** a
  `batch/v1` Job that mounts them read-only and runs k6.

## Apply / run

```bash
# Loads the scripts (ConfigMap) AND the Job. Defaults to the STEADY scenario.
kubectl apply -f k6-job.yaml

# Follow the run.
kubectl -n demo logs -f job/k6-steady
```

Jobs are immutable once they complete, and `ttlSecondsAfterFinished: 3600`
garbage-collects the Job + Pod an hour after it finishes. To re-run, delete and
re-apply, or create an ad-hoc copy:

```bash
kubectl -n demo delete job k6-steady --ignore-not-found
kubectl apply -f k6-job.yaml
# or, ad-hoc unique name from the same template image/config:
kubectl -n demo create job "k6-steady-$(date +%s)" --image=<the same mirrored image> -- k6 run /scripts/steady.js
```

## Switching to the BURN scenario

Edit the Job in `k6-job.yaml`:

1. Change the container `command` to `["k6", "run", "/scripts/burn.js"]`.
2. Uncomment the `CHAOS_TOKEN` env (and optionally `CHAOS_ERROR_RATE`,
   `CHAOS_LATENCY_MS`, `PEAK_RATE`). `CHAOS_TOKEN` is sourced from a Secret:

   ```bash
   # demo-api must be started with CHAOS_ADMIN_TOKEN equal to this value.
   kubectl -n demo create secret generic demo-api-chaos \
     --from-literal=CHAOS_ADMIN_TOKEN='REPLACE_ME_strong_token'
   ```

3. Rename the Job (e.g. `k6-burn`) so it does not collide with a prior run.

The burn Job is **expected to finish with k6's threshold failures** — that is
the demo. (`restartPolicy: Never` + `backoffLimit: 0` mean the failed Pod is
not retried, so the offered load is a single clean observation.)

## Loading the scripts from the files instead of the inlined copies

The `ConfigMap` in `k6-job.yaml` inlines the scripts so `kubectl apply` is
self-contained. To keep a single source of truth in `../k6/` instead, generate
the ConfigMap from the files (note the **flattened** `options.js` key, because
the in-cluster mount is flat at `/scripts`):

```bash
kubectl -n demo create configmap k6-scripts \
  --from-file=steady.js=../k6/steady.js \
  --from-file=burn.js=../k6/burn.js \
  --from-file=options.js=../k6/lib/options.js \
  --dry-run=client -o yaml | kubectl apply -f -
```

When generated this way, change the import in the script copies from
`'./lib/options.js'` to `'./options.js'` (the inlined ConfigMap copies already
use the flat path).

## Gatekeeper compliance (policies/gatekeeper/constraints)

The Job Pod runs in the `demo` namespace, which is in scope for the cluster's
deny-mode constraints. The manifest is built to pass all of them:

| Constraint | Action | How this Job complies |
| --- | --- | --- |
| `K8sAllowedRegistries` | deny | Image is referenced via the **ECR (or GHCR) mirror** of `grafana/k6`, not `docker.io`. See below. |
| `K8sDisallowLatestTag` | deny | Image pins `0.50.0` — never `:latest`. |
| `K8sRequireResources` | deny | Container sets cpu+memory **requests and limits**. |
| `K8sRequireSecurityContext` | deny | `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `readOnlyRootFilesystem: true`, `seccompProfile: RuntimeDefault`. |
| `K8sRequiredLabels` | deny | Matches `apps/*` workloads (not `batch/Job`), but standard `app.kubernetes.io/*` + `project` labels are set anyway. |
| `K8sRequireProbes` | **dryrun** | Matches Pods but is dryrun and explicitly carves out one-off Jobs; a load generator has no sensible liveness/readiness surface, so no probes are set. |

### Mirroring the k6 image (required for `K8sAllowedRegistries`)

`docker.io/grafana/k6` is **not** an allowed registry. Mirror the pinned tag
into the private ECR (us-east-1) once, then keep `imagePullPolicy: IfNotPresent`:

```bash
UPSTREAM=grafana/k6:0.50.0
ECR=<account_id>.dkr.ecr.us-east-1.amazonaws.com/mirror/grafana/k6:0.50.0
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin <account_id>.dkr.ecr.us-east-1.amazonaws.com
docker pull "$UPSTREAM"
docker tag  "$UPSTREAM" "$ECR"
docker push "$ECR"
```

Then set the Job's `image:` to that `$ECR` value (replace `<account_id>` with the
real AWS account number). If you mirror into GHCR instead, use
`ghcr.io/charanvamsy/k6:0.50.0`. `<account_id>` is the only environment-specific
placeholder — everything else is real and runnable.
