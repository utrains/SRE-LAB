# Incident 4: Grades Gone Missing

**App:** student-portal
**Difficulty:** Medium
**Ties to runbook:** `docs/runbooks/pod-crash-loop.md`

## Briefing (read this, then start)

Someone on the platform team just shipped a release to student-portal
right before finals week. Within minutes, a few students report the
grades page is intermittent -- sometimes it loads, sometimes it spins,
and it seems to be getting worse.

## Your task

1. Check the rollout status: `kubectl -n student-portal rollout status
   deployment/student-portal-backend`. Is it progressing normally?
2. Look at the pods -- are all of them `Running`, or are some stuck?
3. Identify what changed and get the service back to fully healthy.
4. In your postmortem, explain why *some* requests still succeeded during
   this incident instead of the whole app going down at once -- then be
   ready to explain it out loud, from memory, in under two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

`kubectl -n student-portal get pods` -- read the `STATUS` column
carefully, not just `READY`.
</details>

<details>
<summary>Hint 2</summary>

`kubectl -n student-portal rollout undo deployment/student-portal-backend`
reverts to the last known-good image. Confirm *why* the new one failed
before you assume undo is the full fix.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
