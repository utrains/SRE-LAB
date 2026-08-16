# Incident 3: The Stuck Order

**App:** food-delivery
**Difficulty:** Medium
**Ties to runbook:** none dedicated -- this one is a variant of
`docs/runbooks/db-connection-exhaustion.md` for a cache dependency instead
of the primary database.

## Briefing (read this, then start)

A diner places an order on `https://food-delivery.$(cat .lab-domain)` and the order
tracking page just spins on "Fetching status..." forever, or the status
never advances past "Order Placed." Orders are still being created
successfully -- it's specifically the status tracking that's broken.

## Your task

1. Place an order and watch the tracking page. What's actually happening
   in the Network tab / via `curl https://food-delivery.$(cat .lab-domain)/api/orders/<id>/status`?
2. This app has a dependency the others don't -- find it in
   `docs/architecture.md` and check its pods.
3. Fix it, then confirm the tracking page recovers on its own (no redeploy
   of the backend needed -- why?).
4. Write a postmortem, then be ready to explain it out loud, from memory,
   in under two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

`kubectl -n food-delivery get pods` -- count how many components you'd
expect to see for this app versus the other four.
</details>

<details>
<summary>Hint 2</summary>

The backend's `/readyz` only checks Postgres, not this other dependency
(see `apps/food-delivery/backend/src/index.js`). That's a deliberate
scope decision -- is it the right one? Discuss in your postmortem.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
