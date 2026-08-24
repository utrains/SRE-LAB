# Runbook: OOMKilled

## Symptoms

- `kubectl get pods` shows a pod restarting with `Reason: OOMKilled` in
  `describe pod`, or `Last State: Terminated, Reason: OOMKilled`.
- `[SRE Lab] Memory saturation approaching container limit` monitor fires
  shortly before the kill (see `datadog/monitors/memory-saturation.json`).
- Requests to that pod fail abruptly mid-response when it dies.

## Diagnostic commands

```bash
# Confirm OOMKilled specifically (vs. a crash for another reason)
kubectl -n <namespace> describe pod <pod> | grep -A5 "Last State"

# Memory trend leading up to the kill
kubectl -n <namespace> top pod <pod>
# In Datadog: the app's dashboard "Pod Memory Usage (Saturation)" widget
# shows the climb over time, which `kubectl top` (a snapshot) won't.
```

## Common root causes in this lab

- **A resource limit reduced below measured workload requirements**, which
  causes Kubernetes to terminate the container during startup or requests.
- Every backend's container `resources.limits.memory` is set to `256Mi`
  (see `apps/<app>/k8s/deployment-backend.yaml`) -- deliberately low, so
  this is easy to trigger and observe in the lab. In a real service, this
  would represent a genuine memory leak or an underprovisioned limit for
  actual peak usage.

## Fix

1. If the lab limit was reduced, restore the saved request and limit:
   ```bash
   scripts/chaos/shrink-limits.sh <app> --undo
   ```
2. If it's a real leak, a restart is a temporary mitigation, not a fix --
   `kubectl -n <namespace> rollout restart deployment/<app>-backend` buys
   time while someone finds the leaking code path.
3. If usage is *legitimately* higher than the limit (not a leak, just
   underprovisioned), raise `resources.limits.memory` in the Deployment
   and redeploy.

## Prevention

- Set requests/limits based on observed steady-state usage plus headroom,
  not guesses -- watch the memory dashboard under realistic load before
  picking a number.
- Alert on memory *approaching* the limit (this lab's monitor triggers at
  ~86% of the 256Mi limit), not just after the OOMKill already happened --
  by then you've already dropped requests.
- Consider `runtimeMetrics: true` in `dd-trace` (already enabled in
  `apps/<app>/backend/src/tracer.js`) to get Node.js heap metrics
  alongside container-level memory, which helps distinguish "the whole
  container is tight" from "the V8 heap specifically is leaking."

## Reproduce this in the lab

```bash
scripts/chaos/shrink-limits.sh <app>
# The script applies a deliberately unsafe 20Mi limit; watch:
kubectl -n <app> get pods -w
```
