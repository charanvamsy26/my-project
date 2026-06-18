# Alertmanager

Routing, receivers, and inhibition for the alerts defined in
`../prometheus/rules/alerts.yaml` and `../prometheus/rules/slo-rules.yaml`.

## Routing tree

```
route (default → #eks-gitops-platform-alerts, warnings)
├── alertname=Watchdog                    → null  (consumed by external dead-man's-switch)
├── severity=critical                     → #eks-gitops-platform-alerts-critical   (page, repeat 1h)
└── slo=~".+"                             → #eks-gitops-platform-slo               (SLO burn threads)
```

- **group_by** keeps one incident in one Slack thread instead of N messages.
- **critical** uses a short `group_wait` (10s) and short `repeat_interval` (1h) so a
  real outage pages fast and keeps reminding until resolved.
- **send_resolved: true** everywhere so channels show recovery, not just firing.

## Inhibition rules (noise suppression)

1. A firing **critical** mutes the matching **warning** (same `namespace`/`service`/`alertname`).
2. **TargetDown** mutes the latency/error/SLO alerts for that target — you can't
   trust metrics from a target you can't scrape.
3. **KubeNodeNotReady** mutes the pod-level alerts caused by that node.

## Secrets — the Slack webhook is never committed

`global.slack_api_url` is a `<SLACK_WEBHOOK_URL>` placeholder. In dev/prod the real
value is rendered by External Secrets from AWS Secrets Manager into the Secret that
backs Alertmanager:

```bash
# Local / break-glass only:
kubectl create secret generic \
  alertmanager-kube-prometheus-stack-alertmanager \
  --from-file=alertmanager.yaml=alertmanager.yaml \
  -n monitoring
```

The kube-prometheus-stack chart mounts that Secret as Alertmanager's config (see
`../kube-prometheus-stack/values.yaml`), so this file is the source of truth without
ever exposing the webhook in Git.

## Validate

```bash
amtool check-config alertmanager.yaml
```
