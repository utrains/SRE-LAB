# Runbook: High Latency

## Symptoms

- `[SRE Lab] High p95 latency` monitor fires for a service (see
  `datadog/monitors/high-latency-p95.json`).
- Users report slow page loads or slow API responses; the app's dashboard
  shows p95 latency climbing above 500ms-1s.

## Diagnostic commands

```bash
# Is it one pod or all pods? Check CPU/memory per pod
kubectl -n <namespace> top pods

# Are readiness probes still passing, or is the pod struggling that badly?
kubectl -n <namespace> get pods

# In Datadog APM: open the service's trace list, sort by duration desc,
# and look at the flame graph for the slowest resource (endpoint).
```

Use the trace to decide whether time is spent in application code or
workload behavior. In this scenario, look at what the request handler does
(for example, ecommerce's `checkout` endpoint calls a
simulated payment processor with a 150-350ms delay by design
-- see `apps/ecommerce/backend/src/routes.js`).

## Common root causes in this lab

- **Injected latency** via the chaos hook (`POST /api/chaos/latency`) --
  check `GET /api/chaos` on the pod to see current chaos state.
- **Real downstream slowness** -- a busy shared RDS instance, or simply
  too much traffic for the current replica count (see HPA in
  `apps/<app>/k8s/hpa-backend.yaml`).

## Fix

1. Check `GET https://<app>.$(cat .lab-domain)/api/chaos` first -- if a chaos hook is
   active, reset it:
   ```bash
   curl -X POST https://<app>.$(cat .lab-domain)/api/chaos/reset
   ```
2. If it's real load, confirm the HPA is scaling:
   ```bash
   kubectl -n <namespace> get hpa
   ```
   If it's pinned at `maxReplicas` and still slow, you're out of horizontal
   headroom -- either raise `maxReplicas` or investigate why each pod isn't
   handling more throughput (often a downstream bottleneck, not a CPU one).
3. If the slow span is a specific query, that's a code/index fix, not an
   ops fix -- file it, don't just restart pods and hope.

## Prevention

- Keep the four golden signals (`datadog/dashboards/<app>.json`) visible
  by default, not just during incidents, so a latency creep is visible
  before it crosses the SLO threshold.
- Tie the monitor threshold to the actual SLO (see
  `docs/slo-sla-sli.md`) so "high latency" means something specific, not a
  guess.

## Reproduce this in the lab

```bash
scripts/chaos/inject-latency.sh <app> 3000   # 3s of added latency
```
