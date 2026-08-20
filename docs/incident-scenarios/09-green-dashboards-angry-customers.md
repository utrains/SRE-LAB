# Incident 9: Green Dashboards, Angry Customers

**App:** food-delivery
**Difficulty:** Medium
**Starts with:** a change (see
[devops-vs-sre.md](../devops-vs-sre.md#where-the-incident-starts))
**Ties to runbook:** `docs/runbooks/ingress-502s.md`

## Briefing (read this, then start)

It's the dinner rush. Support is escalating hard: customers cannot open
food-delivery at all. Not slow, not intermittent -- the site does not load.
Several have sent screenshots of a bare white page reading `Cannot GET /`.

You open the food-delivery dashboard and every widget is fine. Error rate:
flat. p95 latency: normal. Memory: normal. No restarts. Every pod is
`1/1 Running`. Both of the monitors you'd expect to fire are sitting in OK.

Someone on the platform side edited ingress config earlier for an unrelated
app. Nobody thinks it's related.

Figure out why your monitoring says everything is fine while your customers
say nothing works.

## Your task

1. Reproduce it and capture the actual response -- "it doesn't load" is not
   a diagnosis. Look at the headers, not just the status code:
   ```bash
   curl -i https://food-delivery.$(cat .lab-domain)/ | head -12
   ```
   Something is answering. Which of your services is it, and how do you
   know? (One header names it outright.) Now try an API path:
   `curl -o /dev/null -w "%{http_code}\n" https://food-delivery.$(cat .lab-domain)/api/restaurants`
   -- and explain why *that* works while the site doesn't.
2. Go back to the dashboard and try to find this incident in it. You will
   fail, and that is the exercise. For each of the six widgets, say what it
   is actually measuring and why a total customer-facing outage doesn't move
   it. Pay particular attention to throughput: it does **not** drop to zero
   here. Work out what is still generating those requests.
3. Establish which layer is healthy and which isn't:
   ```bash
   kubectl -n food-delivery get pods
   kubectl -n food-delivery get endpoints
   kubectl -n food-delivery describe ingress food-delivery
   ```
4. Check the component that turns an Ingress resource into ALB config:
   ```bash
   kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=50 | grep food-delivery
   ```
5. Find the misconfiguration, state exactly why it produces *this* symptom
   -- one of your own services answering with a 404 -- rather than the clean
   503 you might expect from a load balancer with nothing healthy behind it,
   and fix it.
6. Confirm recovery from the customer's side, not just from Kubernetes'
   side. The controller and the ALB take a minute or two to reconcile.
7. Answer the question this scenario exists for: **every dashboard was
   green during a total outage. What would have to change for that not to
   happen again?** Name a specific detector, not "better monitoring."
8. Write the postmortem from both chairs (see
   [devops-vs-sre.md](../devops-vs-sre.md#two-ways-to-tell-the-same-incident)),
   then be ready to explain either version out loud, from memory, in under
   two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

Every widget on every dashboard in this lab is scoped to one service --
`service:food-delivery-backend` (open `datadog/dashboards/food-delivery.json`
and read the queries). Nothing in Datadog is watching the *frontend*, and
nothing is watching the edge in front of it.

So ask the question the other way round: the backend is healthy and serving
requests. Whose requests? If real users can't load the page, where is that
traffic coming from?
</details>

<details>
<summary>Hint 2</summary>

All five apps share one ALB, routed by hostname
(`ingress/<app>-ingress.yaml`). The Ingress resource decides which Service
each hostname's traffic is sent to, and which port. Compare
food-delivery's Ingress against another app's:

```bash
kubectl -n food-delivery get ingress food-delivery -o yaml
kubectl -n banking get ingress banking -o yaml
```
</details>

<details>
<summary>Hint 3</summary>

The ALB health-checks whatever target group it is pointed at, on `/` by
default. Frontends serve a page there; backends are Express apps with no
`/` route, so they answer 404, and the ALB marks every target unhealthy:

```bash
aws elbv2 describe-target-groups --region us-east-1 \
  --query "TargetGroups[?contains(TargetGroupName,'fooddeli')].TargetGroupArn" --output text
aws elbv2 describe-target-health --region us-east-1 --target-group-arn <arn>
```

Then the part that surprises people: an ALB whose target group has **no
healthy targets at all fails open** and forwards to them anyway, rather than
returning 503. So users don't get a clean gateway error -- they get the
wrong application's response, served with a 200-level pipeline behind it.
That is why this looks like "the site is broken" rather than "the load
balancer is down", and why nothing in Datadog registers an error.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
