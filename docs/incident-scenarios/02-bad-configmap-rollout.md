# Scenario 2: Bad ConfigMap Rollout

## Objective

Diagnose a rollout where application configuration and Kubernetes health probes no longer agree.

## Trigger the Incident

Run this from the repository root against your own lab environment:

```bash
./scripts/chaos/break-config.sh student-portal
```

The script saves the current port, changes the ConfigMap, and restarts the student portal backend Deployment. Wait for Datadog and Kubernetes to observe the rollout failure before troubleshooting.

## Situation

The student portal has reduced rollout capacity after a configuration release. Existing pods may still serve requests, but new pods do not become Ready.

## Symptoms

- New pods fail to become Ready.
- Restart counts may increase while older pods still serve.

## What You Know

- Datadog shows unavailable replicas and increasing container restarts for `student-portal-backend`.
- Kubernetes health events began after a rollout.
- The process in each new container appears to start.

## Start With Datadog

1. Go to **Infrastructure > Kubernetes > Explorer**, select **Pods**, set **Past 30 Minutes**, and enter `kube_namespace:student-portal kube_deployment:student-portal-backend` in **Filter by**. Compare Ready status and restarts on the old and new pods.
2. Go to **Events > Explorer** and search `kube_namespace:student-portal status:(warning OR error)`. Open the readiness-probe, liveness-probe, or BackOff event for the newest backend pod.
3. Go to **Logs > Explorer**, set **Past 30 Minutes**, and search `service:student-portal-backend`. Open a startup log and record the port on which the process is listening.

Record the newest pod, first probe-event timestamp, restart change, and logged listening port.

## Troubleshooting

1. Check the rollout and identify the unhealthy new pod.

```bash
kubectl get deployment student-portal-backend -n student-portal
kubectl get pods -n student-portal -l app=student-portal-backend
```

Expected output: the rollout is incomplete, and the newest pod is not Ready or is restarting while older pods remain Running.

2. Inspect the new pod.

```bash
kubectl describe pod <pod-name> -n student-portal
```

Expected output: events show readiness or liveness probe failures against port `4000`, often followed by `BackOff` or a container restart.

3. Read the application startup logs.

```bash
kubectl logs <pod-name> -n student-portal
```

Expected output: the application reports that it is listening on port `4001`. This conflicts with the probes checking port `4000`.

4. Compare the ConfigMap value with the Deployment probes.

```bash
kubectl get configmap student-portal-backend-config -n student-portal -o yaml
kubectl get deployment student-portal-backend -n student-portal \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.port}{"\n"}'
```

Expected output: the ConfigMap contains `PORT: "4001"`, but the readiness probe returns `4000`. The port mismatch is the root cause.

## Important Clues

Connect the probe failures to the application listening port and the port checked by the readiness and liveness probes.

## Root Cause

Record the configuration and probe mismatch supported by your evidence. Confirm it with the instructor after the exercise.

## Fix

```bash
./scripts/chaos/break-config.sh student-portal --undo
```

The script restores the saved `PORT` value and restarts the Deployment.

## Validation

```bash
kubectl rollout status deployment/student-portal-backend -n student-portal
kubectl get pods -n student-portal
```

Confirm every pod is Ready, restarts stop increasing, the app works, and both Datadog monitors recover.

## DevOps Lesson

Validate configuration and health-probe contracts together before rollout.

## STAR Method

### Situation

Summarize the partial-capacity rollout.

### Task

Explain why only new pods needed investigation.

### Action

Describe the Datadog, event, log, ConfigMap, and probe comparison.

### Result

State how readiness and monitor recovery were verified.

## Natural Spoken Version

Use the matching example in [DevOps STAR Scenarios](../devops-star-scenarios.md#2-bad-configmap-rollout) after completing the lab.
