# Instructor Answer Keys

Keep this file from students until an exercise is complete. Triggers mutate a live lab. Recovery commands match `scripts/chaos/`.

## 1. Bad Container Image Deployment

### Situation

The banking backend rollout references an ECR tag that does not exist. The old ReplicaSet may remain available while the new one stalls.

### Symptoms

New pods show `ErrImagePull` or `ImagePullBackOff`, unavailable replicas increase, and rollout status times out.

### Datadog

Use **SRE Lab Scenario Signals**, `kubernetes_state.deployment.replicas_unavailable{kube_deployment:banking-backend}`, the **[SRE Lab] Deployment has unavailable replicas** monitor, and Kubernetes image-pull events collected by the Cluster Agent.

### Root Cause

`banking-backend` references `sre-lab/banking-backend:does-not-exist`.

### Troubleshooting Path

Datadog -> Deployment -> pod describe -> events -> image -> ECR tags.

### Commands

```bash
./scripts/chaos/bad-deploy.sh banking banking-backend banking-backend
kubectl rollout status deployment/banking-backend -n banking
kubectl describe pod <new-pod> -n banking
kubectl get events -n banking --sort-by=.lastTimestamp
kubectl get deployment banking-backend -n banking -o yaml
aws ecr describe-images --repository-name sre-lab/banking-backend --region us-east-1
```

### Important Clues

The new ReplicaSet uses `:does-not-exist`; ECR does not list that tag; old pods may remain Ready.

### Fix

```bash
kubectl rollout history deployment/banking-backend -n banking
kubectl rollout undo deployment/banking-backend -n banking
```

### Validation

Confirm rollout completion, all pods Ready, a working app, unavailable replicas at zero, and monitor recovery.

### DevOps Lesson

Validate image existence before deployment and preserve rollback history.

## 2. Bad ConfigMap Rollout

### Situation

The banking ConfigMap changed `PORT` from 4000 to 4001 and restarted the Deployment. Probes still check 4000.

### Symptoms

New pods fail probes, restart, and prevent rollout completion while old pods may serve.

### Datadog

Use `kubernetes_state.deployment.replicas_unavailable`, `kubernetes.containers.restarts`, their two monitors, probe-failure events, and `service:banking-backend` logs.

### Root Cause

`banking-backend-config` supplies `PORT=4001`, but readiness and liveness probes target 4000.

### Troubleshooting Path

Datadog -> rollout -> pods -> describe/events -> logs -> ConfigMap -> probes.

### Commands

```bash
./scripts/chaos/break-config.sh banking
kubectl rollout status deployment/banking-backend -n banking --timeout=60s
kubectl get pods -n banking
kubectl describe pod <new-pod> -n banking
kubectl logs <new-pod> -n banking
kubectl describe configmap banking-backend-config -n banking
kubectl get deployment banking-backend -n banking -o yaml
```

### Important Clues

Logs say `listening on 4001`; probe events show failures on 4000.

### Fix

```bash
./scripts/chaos/break-config.sh banking --undo
```

### Validation

Confirm rollout completion, Ready pods, stable restarts, application success, and monitor recovery.

### DevOps Lesson

Validate configuration and health-check contracts together.

## 3. OOMKilled and Kubernetes Resource Limits

### Situation

The support-tickets backend memory request and limit were reduced to 20Mi, below observed startup requirements.

### Symptoms

Pods restart, previous state says `OOMKilled`, and service stability degrades.

### Datadog

Use `kubernetes.memory.usage`, `kubernetes.memory.limits`, `kubernetes.containers.restarts`, the memory-saturation and pod-restarts monitors, and Kubernetes events.

### Root Cause

The configured 20Mi limit is below the Node.js backend's measured requirement.

### Troubleshooting Path

Datadog -> restarting pod -> previous state -> top -> Deployment resources -> usage versus limit.

### Commands

```bash
./scripts/chaos/shrink-limits.sh support-tickets
kubectl get pods -n support-tickets
kubectl top pods -n support-tickets
kubectl describe pod <pod> -n support-tickets
kubectl logs <pod> -n support-tickets --previous
kubectl get deployment support-tickets-backend -n support-tickets -o yaml
```

### Important Clues

Exit 137, `Reason: OOMKilled`, and a 20Mi request and limit.

### Fix

```bash
./scripts/chaos/shrink-limits.sh support-tickets --undo
```

This restores the saved baseline, normally request 128Mi and limit 256Mi. Future tuning must use observed headroom.

### Validation

Confirm stable Ready pods, no new restarts, memory below limit, successful requests, and recovered monitors.

### DevOps Lesson

Kubernetes accepting a resource value does not prove the workload can run within it.

## 4. ALB and Kubernetes Ingress Routing Failure

### Situation

The food-delivery Ingress routes `/` to `food-delivery-backend:4000` instead of `food-delivery-frontend:80`.

### Symptoms

DNS and ALB are reachable and workloads are healthy, but users receive `404 Cannot GET /`.

### Datadog

APM Trace Explorer shows `service:food-delivery-backend`, resource `GET /`, and `http.status_code:404`. Use **SRE Lab Scenario Signals** and **[SRE Lab] Unexpected backend root traffic**, based on `trace.express.request.hits.by_http_status{http.status_code:404,resource_name:get_/}`. ALB target health still requires AWS inspection.

### Root Cause

The Ingress backend Service and port are wrong.

### Troubleshooting Path

Datadog APM -> DNS -> ALB/listener/rule/target health -> Ingress -> Service -> endpoints -> pods.

### Commands

```bash
./scripts/chaos/break-ingress.sh food-delivery
kubectl describe ingress food-delivery -n food-delivery
kubectl get svc,endpoints,pods -n food-delivery
aws elbv2 describe-load-balancers --region us-east-1
aws elbv2 describe-listeners --load-balancer-arn <alb-arn> --region us-east-1
aws elbv2 describe-rules --listener-arn <listener-arn> --region us-east-1
aws elbv2 describe-target-health --target-group-arn <target-group-arn> --region us-east-1
```

### Important Clues

Express generates the response; live Ingress points at the backend; the repository manifest points at the frontend.

### Fix

```bash
./scripts/chaos/break-ingress.sh food-delivery --undo
```

### Validation

Confirm frontend routing, an external 200 response, and backend root traces returning to zero.

### DevOps Lesson

Validate the user traffic path even when every pod is healthy.

## 5. High Application Latency Using Datadog

### Situation

An implemented chaos setting adds 3000ms before requests handled by an ecommerce backend pod.

### Symptoms

Some requests are slow; pods stay Ready; p95 and slow traces increase without matching CPU or memory saturation.

### Datadog

Use `p95:trace.express.request{env:lab,service:ecommerce-backend}`, **[SRE Lab] High p95 latency**, the ecommerce dashboard, APM traces, logs, and Kubernetes resource widgets.

### Root Cause

The backend's reproducible container behavior injects response delay. This is not a database fault.

### Troubleshooting Path

Datadog latency -> affected service -> slow trace -> Kubernetes workload -> metrics/events/logs -> chaos state.

### Commands

```bash
./scripts/chaos/inject-latency.sh ecommerce 3000
kubectl get pods -n ecommerce
kubectl top pods -n ecommerce
kubectl get deployment -n ecommerce
kubectl describe pod <pod> -n ecommerce
kubectl logs <pod> -n ecommerce
curl -s https://ecommerce.$(cat .lab-domain)/api/chaos
```

### Important Clues

Trace time increases while infrastructure metrics remain normal; chaos state reports nonzero latency.

### Fix

```bash
./scripts/chaos/reset.sh ecommerce
```

Repeat per pod or use the README port-forward procedure because state is per process.

### Validation

Generate requests and confirm normal p95, improved traces, healthy pods, normal metrics, and monitor recovery.

### DevOps Lesson

Scope latency with observability before changing workloads.
