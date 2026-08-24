# Scenario 5: High Application Latency Using Datadog

## Objective

Use Datadog APM to identify a slow workload before investigating Kubernetes and applying a focused recovery.

## Trigger the Incident

Run this from the repository root against your own lab environment:

```bash
./scripts/chaos/inject-latency.sh ecommerce 3000
```

The request reaches one backend pod because chaos state is stored per process. Generate application traffic and wait for APM ingestion before troubleshooting. Repeat through the documented port-forward method only when you want every backend pod affected.

## Situation

Users report that ecommerce pages load slowly. Do not restart pods before scoping the problem.

## Symptoms

- Ecommerce responses are intermittently slow.
- Pods remain Ready.

## What You Know

- Datadog reports elevated p95 latency.
- The issue affects `ecommerce-backend` while pods remain Ready.
- The start time does not match an AWS or database change.

## Start With Datadog

Open the ecommerce dashboard and **SRE Lab Scenario Signals**. Inspect `trace.express.request` p95, throughput, errors, CPU, memory, replicas, logs, and the **High p95 latency** monitor. In APM, open slow `ecommerce-backend` traces and note which spans consume the time.

## Troubleshooting

Use the Datadog service and time window to scope Kubernetes checks.

```bash
kubectl get pods -n ecommerce
kubectl top pods -n ecommerce
kubectl get deployment -n ecommerce
kubectl describe pod <pod-name> -n ecommerce
kubectl logs <pod-name> -n ecommerce
kubectl get events -n ecommerce --sort-by=.lastTimestamp
```

Compare slow traces with CPU, memory, replica count, events, and logs. Inspect workload behavior instead of changing unrelated infrastructure.

## Important Clues

Determine why one or more backend containers add time before every response. Use trace duration and the chaos-state endpoint as evidence.

```bash
curl -s https://ecommerce.$(cat .lab-domain)/api/chaos
```

## Root Cause

Record the workload behavior that accounts for the trace duration while Kubernetes resource metrics remain normal. Confirm it with the instructor.

## Fix

Clear the workload's injected latency. Chaos state is per process, so repeat until every backend pod is reset, or reset each pod through port-forwarding as documented in the README.

```bash
./scripts/chaos/reset.sh ecommerce
```

## Validation

Generate normal requests. Confirm p95 latency and traces return to baseline, pods remain healthy, Kubernetes metrics remain normal, and the Datadog monitor recovers.

## DevOps Lesson

Use traces to isolate the slow workload before taking action. A restart may hide evidence without explaining the cause.

## STAR Method

### Situation

Summarize the latency report and initial scope.

### Task

Explain the need to identify the affected workload before acting.

### Action

Describe the dashboard, trace, Kubernetes, log, and workload-state evidence.

### Result

State how normal latency and healthy pods were verified.

## Natural Spoken Version

Use the matching example in [DevOps STAR Scenarios](../devops-star-scenarios.md#5-high-application-latency) after completing the lab.
