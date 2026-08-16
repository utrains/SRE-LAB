# Incident 5: The Midnight Memory Leak

**App:** support-tickets
**Difficulty:** Hard
**Ties to runbook:** `docs/runbooks/oomkill.md`

## Briefing (read this, then start)

Overnight, an on-call alert fired for support-tickets. By the time you
look at it in the morning, the symptom has "resolved itself" a few
times -- but support agents say ticket creation randomly fails, and it
seems to happen a few minutes after each deploy or restart, then clears
up, then comes back.

## Your task

1. Check pod restart counts: `kubectl -n support-tickets get pods`. Is
   anything restarting? How many times?
2. `kubectl -n support-tickets describe pod <pod>` -- what's the
   `Last State` and `Reason` for the most recent restart?
3. Watch memory over time on the app's Datadog dashboard, or with
   `kubectl -n support-tickets top pod <pod> --watch` (a few samples,
   a minute or two apart, since this isn't a live watch flag on `top`).
4. Fix the immediate symptom, then write a postmortem covering: why did it
   "resolve itself" between restarts, and why does that make this kind of
   issue easy to accidentally ignore in a real on-call rotation? Be ready
   to explain it out loud, from memory, in under two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

`OOMKilled` pods get automatically restarted by the Deployment controller
-- that's exactly why the symptom looks self-resolving. It isn't.
</details>

<details>
<summary>Hint 2</summary>

`curl https://support-tickets.$(cat .lab-domain)/api/chaos` shows current
failure-injection state on whichever pod answers the request -- note that
with 2 replicas, only one of them may be affected.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
