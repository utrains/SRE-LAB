# Incident 2: Payday Panic

**App:** banking
**Difficulty:** Medium
**Ties to runbook:** `docs/runbooks/db-connection-exhaustion.md`

## Briefing (read this, then start)

It's the 1st of the month -- payday for a lot of your users. Several
customers report the banking app "won't load my balance" and one says
their transfer just hung. Nothing looks obviously wrong from the outside
at first glance.

## Your task

1. Try logging in at `https://banking.$(cat .lab-domain)` and loading the dashboard.
   What actually happens?
2. Check the pods: `kubectl -n banking get pods`. Are they `Running`? Are
   they `Ready`?
3. `/readyz` exists for a reason -- use it.
4. Once you've identified and fixed the immediate problem, explain in your
   postmortem why `/healthz` didn't catch this but `/readyz` did (or
   would have, if you'd checked it first) -- then be ready to explain it
   out loud, from memory, in under two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

`curl https://banking.$(cat .lab-domain)/readyz` -- what does it say, and why?
</details>

<details>
<summary>Hint 2</summary>

This one isn't a crash. The process is fine. Something about its
dependency isn't.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
