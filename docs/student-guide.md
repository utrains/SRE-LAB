# Student Guide

This lab teaches a Datadog-first troubleshooting loop across Amazon EKS, ECR, ALB, Kubernetes, and application workloads. Amazon RDS PostgreSQL remains the application datastore, but database troubleshooting is not one of the five incidents.

## 1. Prepare and deploy

Complete the prerequisites and `scripts/setup.sh` workflow in the [README](../README.md#quick-start). Supplying both `DATADOG_API_KEY` and `DATADOG_APP_KEY` installs the Agent and imports dashboards and monitors. Never commit credentials.

```bash
kubectl get nodes
kubectl get deployments -A
kubectl get pods -A
```

Open all five applications and establish a healthy baseline in the per-app dashboards and **SRE Lab Scenario Signals**.

## 2. Troubleshooting workflow

For every incident, start with Datadog, scope the affected service and time, investigate Kubernetes and AWS with a specific question, connect evidence before changing anything, apply the documented recovery, then validate Kubernetes, application behavior, external traffic, and Datadog.

## 3. Five scenarios and Datadog coverage

| Scenario | Datadog symptom | Dashboard or monitor | Investigation |
|---|---|---|---|
| [1. Bad Container Image](incident-scenarios/01-bad-container-image.md) | `kubernetes_state.deployment.replicas_unavailable`; image-pull events | Scenario Signals; Deployment unavailable | Deployment, pods, events, ECR tag |
| [2. Bad ConfigMap](incident-scenarios/02-bad-configmap-rollout.md) | Unavailable replicas, `kubernetes.containers.restarts`, probe events | Scenario Signals; Deployment unavailable and Pod restarts | Logs, ConfigMap, probe ports |
| [3. OOMKilled](incident-scenarios/03-oomkilled-resource-limits.md) | `kubernetes.memory.usage`, `kubernetes.memory.limits`, restarts | Scenario Signals; Memory saturation and Pod restarts | Previous state and resource limits |
| [4. Bad Ingress](incident-scenarios/04-alb-ingress-routing.md) | Backend `GET /` APM traces with HTTP 404 | Scenario Signals; Unexpected backend root traffic | ALB, Ingress, Service, endpoints |
| [5. High Latency](incident-scenarios/05-high-application-latency.md) | p95 `trace.express.request` and slow traces | Ecommerce dashboard; High p95 latency | APM, workload metrics, logs, chaos state |

The Ingress monitor counts unexpected backend root requests. Confirm 404 on the spans in APM Trace Explorer. AWS target health requires AWS CLI because this repository does not install the Datadog AWS integration.

## 4. Chaos script quick reference

Each student can trigger and recover faults in their own lab deployment. Run only one scenario at a time, wait for its Datadog signal, and complete recovery before continuing.

| Scenario | Trigger | Recovery |
|---|---|---|
| Bad image | `./scripts/chaos/bad-deploy.sh banking banking-backend banking-backend` | `kubectl rollout undo deployment/banking-backend -n banking` |
| Bad ConfigMap | `./scripts/chaos/break-config.sh banking` | `./scripts/chaos/break-config.sh banking --undo` |
| OOMKilled | `./scripts/chaos/shrink-limits.sh support-tickets` | `./scripts/chaos/shrink-limits.sh support-tickets --undo` |
| Bad Ingress | `./scripts/chaos/break-ingress.sh food-delivery` | `./scripts/chaos/break-ingress.sh food-delivery --undo` |
| High latency | `./scripts/chaos/inject-latency.sh ecommerce 3000` | Reset every affected process with `./scripts/chaos/reset.sh ecommerce` or the README port-forward method |

Other scripts remain supporting demonstrations, not primary scenarios.

## 5. Evidence and teardown

Record the start time, first Datadog signal, affected tags, key command output, root cause, recovery, external validation, monitor recovery, and one prevention action. Do not read [instructor-answer-keys.md](incident-scenarios/instructor-answer-keys.md) until completion. Follow the [README teardown instructions](../README.md#cost) when finished.
