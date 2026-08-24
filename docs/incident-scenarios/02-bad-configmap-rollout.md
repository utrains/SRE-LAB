# Scenario 2: Bad ConfigMap Rollout

## Objective

Diagnose a rollout where application configuration and Kubernetes health probes no longer agree.

## Trigger the Incident

Run this from the repository root against your own lab environment:

```bash
./scripts/chaos/break-config.sh banking
```

The script saves the current port, changes the ConfigMap, and restarts the banking backend Deployment. Wait for Datadog and Kubernetes to observe the rollout failure before troubleshooting.

## Situation

The banking application has reduced rollout capacity after a configuration release. Existing pods may still serve requests, but new pods do not become Ready.

## Symptoms

- New pods fail to become Ready.
- Restart counts may increase while older pods still serve.

## What You Know

- Datadog shows unavailable replicas and increasing container restarts for `banking-backend`.
- Kubernetes health events began after a rollout.
- The process in each new container appears to start.

## Start With Datadog

Use **SRE Lab Scenario Signals** to inspect `kubernetes_state.deployment.replicas_unavailable` and `kubernetes.containers.restarts`. Review Events for readiness and liveness probe failures and Logs for `service:banking-backend`. The unavailable-replicas and pod-restarts monitors cover this failure.

## Troubleshooting

Check rollout health and identify the newest pods.

```bash
kubectl get deployments -n banking
kubectl get pods -n banking
kubectl rollout status deployment/banking-backend -n banking
kubectl describe pod <pod-name> -n banking
kubectl get events -n banking --sort-by=.lastTimestamp
kubectl logs <pod-name> -n banking
```

After confirming probe failures, compare workload configuration with the probes and rollout history.

```bash
kubectl get configmaps -n banking
kubectl describe configmap banking-backend-config -n banking
kubectl get deployment banking-backend -n banking -o yaml
kubectl rollout history deployment/banking-backend -n banking
```

## Important Clues

Connect the probe failures to the application listening port and the port checked by the readiness and liveness probes.

## Root Cause

Record the configuration and probe mismatch supported by your evidence. Confirm it with the instructor after the exercise.

## Fix

```bash
./scripts/chaos/break-config.sh banking --undo
```

The script restores the saved `PORT` value and restarts the Deployment.

## Validation

```bash
kubectl rollout status deployment/banking-backend -n banking
kubectl get pods -n banking
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
