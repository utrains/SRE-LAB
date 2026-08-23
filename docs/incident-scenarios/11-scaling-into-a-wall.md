# Incident 11 (bonus): Scaling Into a Wall

**App:** ecommerce
**Difficulty:** Hard
**Starts with:** a change, but one that only shows itself under load (see
[devops-vs-sre.md](../devops-vs-sre.md#where-the-incident-starts))
**Ties to runbook:** `docs/runbooks/high-latency.md`

This one is not part of the core ten and is not condition- or
change-driven in the clean way the others are -- it's both at once, which
is deliberately the point. It's the scenario that forces the full path:
dashboard, to a real trace, to a real `kubectl` fix, on infrastructure
Terraform doesn't own but a platform team absolutely does (the
`HorizontalPodAutoscaler`).

## Briefing (read this, then start)

Traffic to ecommerce has been climbing all week -- nothing dramatic, just
steady growth. This morning, checkout starts feeling slow again, the way
it did during the Black Friday incident, except this time there's no
error rate to go with it, and it doesn't come and go -- it just sits
there, elevated, no matter how many times you retry.

## Your task

1. Open the ecommerce dashboard. What's p95 doing, and what's error rate
   doing? Compare the shape of this against Incident 1 -- same widget
   moving, or a different signature?
2. Check what shipped: `kubectl -n ecommerce rollout history
   deployment/ecommerce-backend`. If it's clean, the Deployment isn't
   where to keep looking.
3. Open **APM > Traces**, sort by duration, and read the flame graph for a
   slow checkout trace. Is the added time inside one identifiable span
   (a slow query, a slow call), or is it spread evenly across the whole
   request -- consistent with the request simply waiting its turn on a
   busy process rather than being blocked by any one thing?
4. Check `kubectl -n ecommerce top pods`. Is it one pod running hot, or
   all of them?
5. Now look one layer up from the Deployment:
   ```bash
   kubectl -n ecommerce get hpa ecommerce-backend
   ```
   Read the `TARGETS` column against the `REPLICAS` column, and compare
   `REPLICAS` to the `MAXPODS` ceiling. What does it tell you if
   `REPLICAS` has been sitting at the max for a while and `TARGETS` is
   still above 100% of the target utilization?
6. Compare the current `maxReplicas` against
   `apps/ecommerce/k8s/hpa-backend.yaml` in the repo. Is the live object
   still what's checked in?
7. Fix it, and confirm two things separately: the `REPLICAS` count in
   `kubectl get hpa` actually climbs past where it was stuck, and p95 on
   the dashboard comes back down a minute or two later. One without the
   other isn't a fix.
8. Answer the question this scenario exists for: this wasn't a bad
   config value or a bad credential -- the number that broke things was
   *correct* when it was set. What made it wrong later, and whose job is
   it to notice that a static ceiling has drifted out from under real
   traffic?
9. Write the postmortem from both chairs (see
   [devops-vs-sre.md](../devops-vs-sre.md#two-ways-to-tell-the-same-incident)).
   The DevOps version explains the mechanism: a real capacity ceiling,
   not a bug. The SRE version explains the cost: how much budget a slow
   but working checkout burns compared to a hard failure, and why nothing
   paged until you went looking.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

This is *not* the same shape as Incident 1. There, the dashboard signal
was there because of a fixed injected delay, and it would look identical
at 3am with zero traffic. Here, ask: does this incident depend on how
much traffic is actually arriving right now? What does that tell you
about where to look -- the app, or something that decides how many
copies of the app exist?
</details>

<details>
<summary>Hint 2</summary>

`kubectl -n ecommerce get hpa ecommerce-backend -o yaml` shows you the
live `spec.maxReplicas`. It will not match `minReplicas: 2, maxReplicas:
6` in `apps/ecommerce/k8s/hpa-backend.yaml` in the repo -- someone patched
the live object directly without going through the pipeline, which is
its own finding worth putting in the postmortem.
</details>

<details>
<summary>Hint 3</summary>

The fix is a real `kubectl` change, not a chaos-script reset:
```bash
kubectl -n ecommerce patch hpa ecommerce-backend \
  --type=merge -p '{"spec":{"maxReplicas":6}}'
```
Reapplying `apps/ecommerce/k8s/hpa-backend.yaml` directly (rather than a
one-off `patch`) is the better long-term answer -- it's worth discussing
*why* in the postmortem: a live edit that never went back into the repo
is exactly the kind of drift `07-the-4pm-config-change.md` is also
about, just one layer up the stack.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
