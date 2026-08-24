# Runbook: Ingress 502s / 503s

## Symptoms

- Browsing to `https://<app>.$(cat .lab-domain)` returns a gateway error from the
  ALB instead of the app itself. In this lab, a target group with **zero
  healthy targets** (confirmed by testing) makes the ALB return `503
  Service Temporarily Unavailable`; a `502 Bad Gateway` specifically means
  the ALB found a registered target but the connection to it was refused
  or reset mid-request (e.g. the pod crashed between being registered
  healthy and the request arriving). Both point to the same place to
  look.
- Since every app's Ingress uses `alb.ingress.kubernetes.io/target-type:
  ip`, the ALB targets pod IPs directly (the AWS Load Balancer Controller
  watches each Service's endpoints to keep the target group in sync) --
  this is an ALB target-group -> pod problem, not an application-code
  problem -- the app never got the request.
- **You may get no gateway error at all.** An ALB whose target group has
  *some* healthy targets routes only to those; a target group with **zero**
  healthy targets *fails open* and forwards to all of them anyway. So a
  misrouted Ingress that points at a Service whose pods fail the health
  check does not return 503 -- it returns whatever that wrong service says,
  typically a 404. Read the response headers (`X-Powered-By`, `Server`)
  before concluding the load balancer is broken: they tell you which of your
  own services answered.

```bash
# Which target group, and are its targets healthy?
aws elbv2 describe-target-groups --region us-east-1 \
  --query "TargetGroups[?contains(TargetGroupName,'<app-prefix>')].TargetGroupArn" --output text
aws elbv2 describe-target-health --region us-east-1 --target-group-arn <arn>
```

  There are no ALB metrics in Datadog in this lab (the AWS integration isn't
  configured), so target health is only visible from the CLI or the console.

## Diagnostic commands

```bash
# Does the Service have any healthy endpoints at all?
kubectl -n <namespace> get endpoints <app>-frontend

# If empty, the Service has no ready pods to send traffic to -- check why
kubectl -n <namespace> get pods
kubectl -n <namespace> describe pod <pod>

# Check the AWS Load Balancer Controller's own logs for the specific error
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=100 | grep <app>

# Confirm the Ingress resource itself is pointing at the right Service/port
kubectl -n <namespace> get ingress <app> -o yaml
```

## Common root causes in this lab

- **Zero ready replicas** -- the most common cause. If every pod behind
  `<app>-frontend` is failing its readiness probe (or was just scaled to
  0), the target group has no healthy targets and the ALB returns 503
  immediately.
- **Wrong port** in the Ingress or Service (`targetPort` not matching the
  container's actual listening port -- frontends in this lab listen on
  `8080`, backends on `4000`).
- **Ingress pointed at the wrong Service entirely.** Both the Service and
  the port exist, so the controller reconciles it happily and nothing
  errors anywhere; users just get the wrong application. Compare the
  Ingress against another app's, and see
  `scripts/chaos/break-ingress.sh` / incident scenario 4.
- **AWS Load Balancer Controller itself down or mid-restart** -- rare,
  but check `kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller`
  if *every* app 502s simultaneously -- since all 5 apps share one ALB,
  a controller outage (or an ALB/target-group misconfiguration) can take
  all of them down at once, unlike a per-app ALB.

## Fix

1. If the Service has zero endpoints because pods aren't ready, that's
   really a different runbook depending on *why* they're not ready --
   check `pod-crash-loop.md` and the pod events for the workload cause.
2. If replicas were scaled to 0 (deliberately or by accident):
   ```bash
   kubectl -n <namespace> scale deployment/<app>-frontend --replicas=2
   ```
3. If the Ingress/Service port mapping is wrong, fix
   `apps/<app>/k8s/service-frontend.yaml` or
   `ingress/<app>-ingress.yaml` and reapply.

## Prevention

- Keep `minReplicas` on the HPA at 2 (already the default in this lab's
  `hpa-backend.yaml` pattern) so a single pod failure never drops a
  Service to zero endpoints.
- Alert on Service endpoint count, not just pod status, since "pods exist"
  and "pods are routable" are different facts.

## Reproduce this in the lab

```bash
scripts/chaos/break-ingress.sh <app>
curl -o /dev/null -w "%{http_code}\n" https://<app>.$(cat .lab-domain)/
scripts/chaos/break-ingress.sh <app> --undo
```
