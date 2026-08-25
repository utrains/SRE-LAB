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

1. Open **Dashboards > SRE Lab Scenario Signals** with a last-15-minutes window.
2. Filter **Unavailable Replicas** to `kube_namespace:student-portal` and `kube_deployment:student-portal-backend`. Look for a value above zero.
3. In **Container Restarts**, use the same filters and look for a rising `kubernetes.containers.restarts` series.
4. Open **Monitors > Manage Monitors** and inspect **Deployment has unavailable replicas** and **Pod restarts detected**. Expand the `student-portal-backend` alert group.
5. Open **Infrastructure > Kubernetes > Pods** and filter `kube_namespace:student-portal kube_deployment:student-portal-backend`. Compare Ready status and restart counts between older and newer pods.
6. Open **Events > Explorer** with `kube_namespace:student-portal`. Look for readiness/liveness probe failures and BackOff events.
7. Open **Logs > Explorer**, set the last 15 minutes, and search `service:student-portal-backend`. Look for the startup line that reports the listening port.

Record the first unavailable-replica timestamp, newest pod, probe event, restart change, and logged listening port.

## Troubleshooting

Check rollout health and identify the newest pods.

```bash
kubectl get deployments -n student-portal
kubectl get pods -n student-portal
kubectl rollout status deployment/student-portal-backend -n student-portal
kubectl describe pod <pod-name> -n student-portal
kubectl get events -n student-portal --sort-by=.lastTimestamp
kubectl logs <pod-name> -n student-portal
```

After confirming probe failures, compare workload configuration with the probes and rollout history.

```bash
kubectl get configmaps -n student-portal
kubectl describe configmap student-portal-backend-config -n student-portal
kubectl get deployment student-portal-backend -n student-portal -o yaml
kubectl rollout history deployment/student-portal-backend -n student-portal
```

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
