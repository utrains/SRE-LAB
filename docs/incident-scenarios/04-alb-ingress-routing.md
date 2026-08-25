# Scenario 4: ALB and Kubernetes Ingress Routing Failure

## Objective

Trace HTTP 404 responses across Datadog, Route 53, ALB, Ingress, Service, endpoints, and pods.

## Trigger the Incident

Run this from the repository root against your own lab environment:

```bash
./scripts/chaos/break-ingress.sh food-delivery
```

The script saves the current Ingress backend and changes the live route. Allow one or two minutes for the AWS Load Balancer Controller to reconcile before testing the public URL.

## Situation

Users receive HTTP 404 from the food delivery home page even though the Kubernetes workloads report healthy.

## Symptoms

- The public hostname returns HTTP 404.
- Kubernetes workloads remain Running and Ready.

## What You Know

- `food-delivery.<lab-domain>` resolves and the ALB accepts connections.
- Pods are Running and Ready.
- Datadog Trace Explorer shows requests to `service:food-delivery-backend` with `http.status_code:404` and resource `GET /`.

## Start With Datadog

1. Go to **Dashboards > SRE Lab Scenario Signals** and set the time range to **Past 30 Minutes**.
2. Inspect **Backend GET / HTTP 404 Responses** for `service:food-delivery-backend`. This widget uses `trace.express.request.hits.by_http_status` filtered by `http.status_code:404` and metric-normalized `resource_name:get_/`.
3. Go to **Monitors > Manage Monitors**, search `[SRE Lab] Unexpected backend root traffic`, open it, and expand the `food-delivery-backend` group.

This repository does not install the Datadog AWS integration, so ALB listeners, rules, and target health are not available in Datadog. Record the 404 trace timestamp and backend pod, then continue with AWS CLI and Kubernetes.

## Troubleshooting

1. Confirm that the workloads are healthy.

```bash
kubectl get pods -n food-delivery
```

Expected output: frontend and backend pods are Running and Ready. This moves the investigation away from pod health and toward request routing.

2. Inspect the public Ingress route.

```bash
kubectl describe ingress food-delivery -n food-delivery
```

Expected output: the `/` path points to `food-delivery-backend:4000`. It should point to `food-delivery-frontend:80`.

3. Confirm that both Services and endpoint sets exist.

```bash
kubectl get svc,endpoints -n food-delivery
```

Expected output: the frontend Service listens on port `80`, the backend listens on `4000`, and both have endpoints. This proves the failure is an incorrect Ingress destination rather than a missing Service or pod.

4. Confirm the ALB is present and serving the incorrect rule.

```bash
aws elbv2 describe-load-balancers --region us-east-1
aws elbv2 describe-listeners --load-balancer-arn <alb-arn> --region us-east-1
aws elbv2 describe-rules --listener-arn <listener-arn> --region us-east-1
```

Expected output: the ALB and HTTPS listener are active, and the host rule forwards traffic to the target group created from the incorrect backend Service. The Ingress backend selection is the root cause.

## Important Clues

Follow DNS to ALB, listener, target group, Ingress, Service, endpoints, pod, and application. Determine why the backend answers a request intended for the frontend.

## Root Cause

Record which routing hop sends traffic to the wrong destination. Confirm it with the instructor after the exercise.

## Fix

```bash
./scripts/chaos/break-ingress.sh food-delivery --undo
kubectl describe ingress food-delivery -n food-delivery
```

The source-of-truth manifest is `ingress/food-delivery-ingress.yaml`, whose backend is `food-delivery-frontend:80`.

## Validation

Test `https://food-delivery.<lab-domain>/`, confirm the controller reconciles the Ingress, and verify the backend `GET /` trace rate returns to zero in Datadog.

## DevOps Lesson

Healthy pods do not guarantee healthy user traffic. Validate the whole routing path.

## STAR Method

### Situation

Summarize the user-visible 404 with healthy workloads.

### Task

Explain the need to locate the failing routing hop.

### Action

Describe the Datadog, AWS, and Kubernetes traffic-path checks.

### Result

State how external access and trace recovery were verified.

## Natural Spoken Version

Use the matching example in [DevOps STAR Scenarios](../devops-star-scenarios.md#4-alb-and-kubernetes-ingress-routing) after completing the lab.

## Brief STAR Example

Users received HTTP 404 responses from one of our applications even though every pod was healthy. My task was to locate the failing hop in the public request path. Datadog showed `GET /` reaching the backend, and the Ingress revealed that `/` targeted port 4000 instead of the frontend on port 80. I corrected the route, waited for ALB reconciliation, and confirmed successful external requests and normal traces.
