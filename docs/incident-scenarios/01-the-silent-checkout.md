# Incident 1: The Silent Checkout

**App:** ecommerce
**Difficulty:** Easy
**Ties to runbook:** `docs/runbooks/high-latency.md`

## Briefing (read this, then start)

It's Black Friday. Support is getting reports that customers are
abandoning their carts -- the checkout button spins for a long time, and a
few customers say it eventually shows an error. Your dashboards are
green-ish but something feels off. Figure out what's wrong and fix it.

## Your task

1. Open the `ecommerce` dashboard in Datadog. What do you see in p95
   latency and error rate over the last 15 minutes?
2. Reproduce the customer experience yourself: place an order at
   `https://ecommerce.$(cat .lab-domain)`.
3. Before you form a hypothesis, check whether anything shipped:
   `kubectl -n ecommerce rollout history deployment/ecommerce-backend`. A
   clean history is itself a finding -- it tells you this is a condition,
   not a change, before you've looked at a single line of code.
4. Open **APM > Traces** for `ecommerce-backend`, sort by duration
   descending, and open the flame graph for the slowest checkout trace.
   Is the time spent in the app itself, in a `postgres.query` child span,
   or somewhere else? This is the step that turns "checkout is slow" into
   an actual diagnosis instead of a guess -- do it before you reach for
   `curl .../api/chaos`.
5. Confirm your hypothesis and fix it.
6. Write a one-paragraph postmortem: what broke, how you found it
   (name the trace step specifically -- "I read the flame graph and saw
   the time was/wasn't in the DB span" is a stronger sentence than "I
   checked the dashboard"), how you fixed it, and one concrete prevention
   step tied to something real -- an HPA `maxReplicas` headroom check, a
   synthetic hitting checkout every minute, or a monitor threshold tied to
   the SLO in `docs/slo-sla-sli.md` -- not just "add more monitoring." Be
   ready to explain it out loud, from memory, in under two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

Check whether the app has any built-in failure-injection state active:
`curl https://ecommerce.$(cat .lab-domain)/api/chaos`
</details>

<details>
<summary>Hint 2</summary>

`docs/runbooks/high-latency.md` has the exact diagnostic commands,
including how to read the APM flame graph.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
