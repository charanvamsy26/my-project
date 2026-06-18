# tools/

Operational tooling that runs *alongside* the platform rather than being part of
the demo-api application itself.

| Tool                | Purpose |
| ------------------- | ------- |
| [`auto-remediation/`](auto-remediation/) | Self-healing controller: watches demo-api's SLO error-budget burn in Prometheus and automatically performs a rolling restart (or Argo CD rollback) when a breach is sustained. Backs the "auto-healing workflows" / "MTTR -40%" reliability story. Dry-run by default. |

Each tool is self-contained (its own README, Dockerfile, tests, and deploy
manifests) and complies with the repo's Gatekeeper constraints when deployed.
