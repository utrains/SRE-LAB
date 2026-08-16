# Incident 6: The Noisy Neighbor

**App:** Multiple -- ecommerce and banking, but really the shared RDS
instance behind every app
**Difficulty:** Hard
**Ties to runbook:** `docs/runbooks/rds-connection-limit.md`

## Briefing (read this, then start)

Support tickets are coming in from customers of *two different apps* at
once: some ecommerce shoppers are seeing checkout hang, and a few banking
customers say their dashboard occasionally won't load. Neither app's own
dashboard looks dramatically broken, and neither team touched a deploy
today. The one thing on-call remembers: an overnight analytics export job
runs against a couple of the app databases, and nobody's confirmed it
finished cleanly.

## Your task

1. Confirm this is bigger than one app: check `/readyz` (or the Datadog
   dashboard) for **every** app, not just the one you got paged for. Do
   more than one show trouble at the same time?
2. RDS has no public access, so you can't just connect from your laptop --
   `docs/runbooks/rds-connection-limit.md` has the exact `kubectl run`
   command to check `max_connections` versus current connections *from
   inside the cluster*, broken down by database.
3. Find out what's actually holding connections open -- not just how
   many there are, but which queries, and for how long.
4. Clear the stuck connections and confirm both apps recover.
5. In your postmortem, explain why restarting the ecommerce or banking
   *Deployment* would not have fixed this on its own, and what you'd
   change (see the RDS tradeoff table in `docs/architecture.md`) so one
   stray job can't do this to every app sharing the instance again -- then
   be ready to explain it out loud, from memory, in under two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

This isn't a bug in ecommerce's or banking's code -- both apps' backends
are fine. Something else connected to the shared instance is misbehaving
and squeezing everyone else's headroom. `docs/runbooks/rds-connection-limit.md`
has the query that tells you which database(s) are holding the most
connections right now.
</details>

<details>
<summary>Hint 2</summary>

`pg_stat_activity` has a `query` and a `state` column, not just a count.
`state = 'idle in transaction'` with a `query_start` from a while ago is
the signature of a connection that opened a transaction and never
committed, rolled back, or closed -- exactly what a hung batch job looks
like. `pg_terminate_backend(pid)` ends a specific connection without
touching anything else on the instance.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
