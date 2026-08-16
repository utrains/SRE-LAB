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
3. Form a hypothesis, confirm it, fix it.
4. Write a one-paragraph postmortem: what broke, how you found it, how you
   fixed it, and one thing you'd do to prevent it next time -- then be
   ready to explain it out loud, from memory, in under two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

Check whether the app has any built-in failure-injection state active:
`curl https://ecommerce.$(cat .lab-domain)/api/chaos`
</details>

<details>
<summary>Hint 2</summary>

`docs/runbooks/high-latency.md` has the exact diagnostic commands.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
