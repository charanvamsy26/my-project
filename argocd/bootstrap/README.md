# `argocd/bootstrap/` — The root app-of-apps

This directory contains the single Application you apply by hand to bring the whole platform up.

## `root-app.yaml`

The **root Application** (`root`) is the app-of-apps. Its source is **not** a chart — it is the
`argocd/apps/` directory of *child* Application manifests. ArgoCD renders that directory, discovers
each child `Application`, and creates it. Each child then deploys its own component (observability,
policy, ingress, the demo-api workload) according to its own sync wave.

```
root  (this Application, wave -1)
 └── renders argocd/apps/*.yaml
      ├── kube-prometheus-stack   (wave 0)
      ├── gatekeeper              (wave 0)
      ├── aws-load-balancer-controller (wave 1)
      └── demo-api                (wave 2)
```

## Apply it

```bash
# Prereq: argocd/install/ has been applied and argocd-server is Ready,
# and the my-project AppProject exists.
kubectl apply -f argocd/bootstrap/root-app.yaml

# Watch the platform converge:
kubectl -n argocd get applications -w
```

## Notes

- `directory.recurse: true` lets you nest child apps in subfolders later without editing root.
- `automated.allowEmpty: false` is a safety net: a broken render of `argocd/apps/` will **not**
  prune every child Application at once.
- `ApplyOutOfSyncOnly=true` keeps reconciles cheap — only changed children are re-applied.
- The root app is wave `-1` so it always settles before the components it generates.
