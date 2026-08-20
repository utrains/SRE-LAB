# Incident 8: The Rotated Password

**App:** ecommerce
**Difficulty:** Medium
**Starts with:** a change (see
[devops-vs-sre.md](../devops-vs-sre.md#where-the-incident-starts))
**Ties to runbook:** `docs/runbooks/config-and-secret-drift.md`

## Briefing (read this, then start)

Security asked for database credentials to be rotated this quarter.
Somebody started with ecommerce this morning. The ticket is marked done.

This afternoon, a deploy that was supposed to go out is sitting in the
pipeline, stuck. No monitor has fired. Checkout still works when you try
it, and every customer-facing metric is normal. The on-call engineer's
first message in chat was "is ecommerce down? it doesn't look down."

It isn't down. Work out what state it is actually in, and how long it can
stay there.

## Your task

1. Establish the facts before the theory -- note that `maxUnavailable` is
   0 for a 2-replica Deployment, so Kubernetes will not remove a working
   pod until a new one is Ready:
   ```bash
   kubectl -n ecommerce get pods
   kubectl -n ecommerce get endpoints ecommerce-backend
   kubectl -n ecommerce rollout status deployment/ecommerce-backend --timeout=30s
   ```
   How many pods exist, and how many of them can actually receive traffic?
2. In Datadog, search the logs for the ecommerce backend
   (`service:ecommerce-backend status:error`). The error message names the
   root cause almost exactly -- read it before you go looking at YAML.
3. Confirm it from the app's own health endpoints. `/healthz` and `/readyz`
   disagree with each other here, and that disagreement is the entire
   lesson:
   ```bash
   kubectl -n ecommerce port-forward <not-ready-pod> 14000:4000
   curl -s localhost:14000/healthz | jq .
   curl -s localhost:14000/readyz  | jq .
   ```
4. Explain, before fixing anything, **why the app still works for
   customers** despite the failure -- specifically, what the still-working
   pods know that the new ones don't.
5. Fix it, and confirm both the READY count and the endpoint list recover.
6. Then answer the uncomfortable question: the credential the working pods
   are using no longer exists anywhere except in their own memory. What
   happens on the next node recycle, HPA scale-up, or eviction -- and what
   does that mean about how urgent this was?
7. Write the postmortem from both chairs (see
   [devops-vs-sre.md](../devops-vs-sre.md#two-ways-to-tell-the-same-incident)),
   then be ready to explain either version out loud, from memory, in under
   two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

`Running` is not `Ready`. Only `Ready` pods are in a Service's endpoints,
and only pods in the endpoints get traffic from the ALB. Read the READY
column, then `kubectl -n ecommerce get endpoints ecommerce-backend` to see
the consequence.
</details>

<details>
<summary>Hint 2</summary>

`/readyz` in this lab runs a real `SELECT 1` against Postgres
(`apps/ecommerce/backend/src/index.js`), and returns the failure reason in
the response body. `/healthz` only reports that the process is alive, which
is why liveness never restarted anything.
</details>

<details>
<summary>Hint 3</summary>

Two systems are supposed to hold the same value here: the `PGPASSWORD` key
in the `ecommerce-db-credentials` Secret, and the password on the
`ecommerce_app` role in RDS. Only one of them was rotated.

```bash
kubectl -n ecommerce get secret ecommerce-db-credentials -o jsonpath='{.data.PGUSER}' | base64 -d
```
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
