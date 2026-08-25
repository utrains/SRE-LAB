# Scenario 3: OOMKilled and Kubernetes Resource Limits

## Objective

Use Datadog and Kubernetes evidence to distinguish memory pressure from an unsafe container resource limit.

## Trigger the Incident

Run this from the repository root against your own lab environment:

```bash
./scripts/chaos/shrink-limits.sh support-tickets
```

The script saves the current resources and applies a deliberately unsafe memory request and limit. Wait for restarts and Datadog signals before troubleshooting.

## Situation

The support tickets service is unstable. Backend pods restart repeatedly while some requests still succeed.

## Symptoms

- Backend pods restart repeatedly.
- Application stability degrades.

## What You Know

- Datadog shows backend memory near its configured ceiling.
- Container restart counts are increasing.
- The problem began after a workload resource change.

## Start With Datadog

1. Go to **Dashboards > SRE Lab Scenario Signals** and set the time range to **Past 30 Minutes**.
2. In **Memory Usage and Limits**, filter `kube_namespace:support-tickets` and `kube_deployment:support-tickets-backend`. Compare `kubernetes.memory.usage` with `kubernetes.memory.limits` immediately before each restart.
3. In **Container Restarts**, confirm `kubernetes.containers.restarts` increases for the same Deployment.
4. Go to **Monitors > Manage Monitors**, search `[SRE Lab]`, and inspect **Memory saturation approaching container limit** and **Pod restarts detected**. Expand the `support-tickets-backend` group.
5. Go to **Infrastructure > Kubernetes > Explorer**, select **Pods**, and enter `kube_namespace:support-tickets kube_deployment:support-tickets-backend` in **Filter by**. Inspect Status, Restarts, Memory Usage, and Memory Limit.
6. Go to **Events > Explorer** and search `kube_namespace:support-tickets status:(warning OR error)`. Look for BackOff or container termination events. Datadog may show the restart symptom before the exact termination reason.

Record the memory value, configured limit, restart timestamp, pod name, and monitor transition. Confirm the exact `OOMKilled` reason later with `kubectl describe`.

## Troubleshooting

Find the restarting pod and compare live usage with its resource specification.

```bash
kubectl get pods -n support-tickets
kubectl top pods -n support-tickets
kubectl describe pod <pod-name> -n support-tickets
kubectl get events -n support-tickets --sort-by=.lastTimestamp
kubectl logs <pod-name> -n support-tickets --previous
kubectl get deployment support-tickets-backend -n support-tickets -o yaml
```

## Important Clues

Look for `Reason: OOMKilled`. Compare observed memory consumption with `resources.requests.memory` and `resources.limits.memory`.

## Root Cause

Record the relationship between observed memory, the previous container state, and the configured limit. Confirm it with the instructor.

## Fix

Restore the known baseline, then use observed utilization to propose a justified long-term request and limit.

```bash
./scripts/chaos/shrink-limits.sh support-tickets --undo
kubectl rollout status deployment/support-tickets-backend -n support-tickets
```

Do not remove the limit or choose an arbitrary large value.

## Validation

Confirm pods remain Ready, restart counts stop increasing, memory stays below the limit, requests succeed, and both Datadog monitors recover.

## DevOps Lesson

Resource limits must reflect measured workload behavior. Admission control can accept a value that is operationally unsafe.

## STAR Method

### Situation

Summarize the unstable workload.

### Task

Explain how you separated application, Kubernetes, and infrastructure causes.

### Action

Describe the memory, restart, previous-state, and resource comparison.

### Result

State how stability and memory headroom were verified.

## Natural Spoken Version

Use the matching example in [DevOps STAR Scenarios](../devops-star-scenarios.md#3-oomkilled) after completing the lab.
