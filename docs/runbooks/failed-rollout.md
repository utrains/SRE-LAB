# Runbook: Rollout Stuck / Never Went Healthy

The delivery-path runbook. Use this whenever a Deployment was changed and
the new pods never became `Ready` -- whatever the reason. Covers incident
scenarios 04, 07 and 10.

## Symptoms

- `kubectl get pods` shows a mix of healthy pods and new ones stuck in
  `ImagePullBackOff`, `CrashLoopBackOff`, or `Running` with `0/1` in the
  READY column.
- Users see **nothing at all**, or an intermittent failure. This is the
  confusing part: `RollingUpdate` won't tear down old, healthy pods until
  enough new ones are ready, so a broken rollout usually degrades capacity
  rather than causing an outage. Old pods keep serving on the old config
  until something -- a node recycle, a scale-up, an eviction -- takes them
  away.
- Datadog: the `[SRE Lab] Pod restarts detected` monitor may fire (crash
  loop / OOMKill cases) or **may not fire at all** (an `ImagePullBackOff`
  or a failing readiness probe never restarts anything). Error rate and
  p95 often stay completely flat. See
  [devops-vs-sre.md](../devops-vs-sre.md#the-detection-gap).

## Diagnostic commands

Start with the rollout, not the pod -- you want to know *what changed*
before you know *how it broke*.

```bash
# Is the rollout actually stuck, or just slow?
kubectl -n <namespace> rollout status deployment/<deployment> --timeout=60s

# What revisions exist, and what changed in the newest one?
kubectl -n <namespace> rollout history deployment/<deployment>
kubectl -n <namespace> rollout history deployment/<deployment> --revision=<n>

# How many replicas does it think it has vs. how many are usable?
kubectl -n <namespace> get deployment <deployment>
# READY 2/2 is healthy; 2/3 or 1/2 with an age of minutes is a stalled rollout

# Which pod is new, and why isn't it Ready?
kubectl -n <namespace> get pods -o wide --sort-by=.metadata.creationTimestamp
kubectl -n <namespace> describe pod <newest-pod>     # read the Events block at the bottom
kubectl -n <namespace> logs <newest-pod>
kubectl -n <namespace> logs <newest-pod> --previous  # if it already restarted

# Namespace-wide event history, newest last
kubectl -n <namespace> get events --sort-by=.lastTimestamp | tail -20
```

In Datadog, the same events are searchable without a terminal:

```
source:kubernetes kube_namespace:<namespace>
service:<app>-backend status:error
```

## Reading the `describe pod` Events block

That block names the root cause almost every time. The four you'll meet in
this lab:

| Event / State | Root cause | Fix |
|---|---|---|
| `Failed to pull image ... not found` / `ImagePullBackOff` | The image tag doesn't exist in ECR -- a typo, or a build that never pushed | `rollout undo`, then fix the pipeline |
| `Readiness probe failed: ... connection refused` | The container isn't listening on the port the probe checks -- a config/port mismatch | Fix the ConfigMap, then roll |
| `Readiness probe failed: HTTP probe failed with statuscode: 503` | The process is up but a dependency check fails -- see [config-and-secret-drift.md](config-and-secret-drift.md) | Fix the dependency or the credential |
| `Last State: Terminated, Reason: OOMKilled` + `Back-off restarting` | The memory limit is below what the process needs | Check whether the *limit* moved or *usage* grew -- see [oomkill.md](oomkill.md) |

The distinction in that last row is the whole of scenario 10: an OOMKill
from a limit someone tuned down looks identical to an OOMKill from a leak,
and `rollout history` is what tells them apart.

## The quota trap

If new pods sit at `0/1` with no obvious error, or the rollout doesn't
create a new pod at all, check the namespace quota:

```bash
kubectl -n <namespace> describe quota
kubectl -n <namespace> get events --sort-by=.lastTimestamp | grep -i "exceeded quota"
```

Every namespace in this lab has a `ResourceQuota` and a `LimitRange` (see
`namespaces/<app>.yaml`). A `RollingUpdate` needs headroom for a surge pod
above the current replica count -- if the quota has none, the rollout
blocks quietly rather than failing loudly.

## Fix

1. **Revert first, diagnose after.** You've already captured the events and
   logs above; the artefacts survive the rollback.
   ```bash
   kubectl -n <namespace> rollout undo deployment/<deployment>
   kubectl -n <namespace> rollout status deployment/<deployment>
   ```
2. If the bad value lives in a ConfigMap or Secret rather than the pod
   template, `rollout undo` will **not** fix it -- the Deployment's spec
   never changed. Fix the object, then roll:
   ```bash
   kubectl -n <namespace> patch configmap <app>-backend-config -p '{"data":{"PORT":"4000"}}'
   kubectl -n <namespace> rollout restart deployment/<deployment>
   ```
   That difference catches people out constantly, and it is worth being
   able to explain: `rollout undo` restores a pod template, not the world
   the pods run in.
3. Confirm recovery on both layers -- pods ready, and the app actually
   serving:
   ```bash
   kubectl -n <namespace> get pods
   curl -o /dev/null -w "%{http_code}\n" https://<app>.$(cat .lab-domain)/
   ```

## Prevention

- Gate the deploy on the rollout actually becoming healthy, not on the
  apply succeeding:
  ```bash
  kubectl -n <namespace> rollout status deployment/<deployment> --timeout=120s
  ```
  Without this, a pipeline reports a green deploy for a rollout that can
  never finish.
- Alert on unavailable replicas, which catches all four root causes above
  with one monitor (see
  [devops-vs-sre.md](../devops-vs-sre.md#the-detection-gap)).
- Keep config in version control and apply it from there, so
  `rollout history` and `git log` tell the same story. A `kubectl patch`
  run by hand is invisible to both.

## Reproduce this in the lab

```bash
scripts/chaos/bad-deploy.sh <namespace> <deployment> <container>   # bad image tag
scripts/chaos/break-config.sh <app>                                # wrong port in the ConfigMap
scripts/chaos/shrink-limits.sh <app>                               # memory limit below what the app needs

# undo, respectively:
kubectl -n <namespace> rollout undo deployment/<deployment>
scripts/chaos/break-config.sh <app> --undo
scripts/chaos/shrink-limits.sh <app> --undo
```
