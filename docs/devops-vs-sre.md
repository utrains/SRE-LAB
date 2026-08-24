# DevOps Delivery and SRE Observability

The lab keeps an SRE observability approach while focusing its incidents on DevOps delivery and platform failures.

```text
Datadog symptom -> scope -> Kubernetes or AWS evidence -> root cause -> recovery -> Datadog validation
```

| Scenario | DevOps responsibility | SRE signal |
|---|---|---|
| Bad container image | CI/CD, ECR tag, Deployment rollout | Unavailable replicas and events |
| Bad ConfigMap | Configuration and probe contract | Probe events, unavailable replicas, restarts |
| OOMKilled | Resource requests and limits | Memory saturation and restarts |
| ALB/Ingress routing | Request-path configuration | Unexpected backend root traces and 404 spans |
| High latency | Workload behavior | p95 latency and slow traces |

Start with Datadog to answer what changed, when, and which workload is affected. Then use `kubectl` or AWS CLI to test a hypothesis. Do not restart pods first because that can remove evidence. Validate Kubernetes readiness, application behavior, external traffic, and Datadog recovery. See the [student guide](student-guide.md), [scenarios](incident-scenarios/), and [STAR examples](devops-star-scenarios.md).
