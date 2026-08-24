# Testing the Five Incident Scenarios

This is a live-test checklist, not a claim that a test has run. Use a disposable lab cluster with AWS and Datadog credentials. Test one scenario at a time and recover it before continuing.

| Scenario | Trigger | Expected Kubernetes result | Expected Datadog result | Recovery |
|---|---|---|---|---|
| Bad image | `./scripts/chaos/bad-deploy.sh banking banking-backend banking-backend` | New pods reach `ImagePullBackOff` | Unavailable replicas monitor and image-pull event | `kubectl rollout undo deployment/banking-backend -n banking` |
| Bad ConfigMap | `./scripts/chaos/break-config.sh banking` | New pods fail probes | Unavailable replicas, restarts, probe events | `./scripts/chaos/break-config.sh banking --undo` |
| OOMKilled | `./scripts/chaos/shrink-limits.sh support-tickets` | Previous state is `OOMKilled` | Memory/restart signals and monitors | `./scripts/chaos/shrink-limits.sh support-tickets --undo` |
| Bad Ingress | `./scripts/chaos/break-ingress.sh food-delivery` | Pods stay Ready; external `/` returns 404 | Backend `GET /` trace and monitor | `./scripts/chaos/break-ingress.sh food-delivery --undo` |
| High latency | `./scripts/chaos/inject-latency.sh ecommerce 3000` | Pods normally remain Ready | Slow APM traces and latency monitor | Reset each backend process with `./scripts/chaos/reset.sh ecommerce` or port-forward |

For every test, record trigger time, pod and Deployment state, Datadog ingestion delay, monitor transition, external response, recovery time, and monitor recovery. Follow the detailed commands in `docs/incident-scenarios/` and do not run database-destructive tests.
