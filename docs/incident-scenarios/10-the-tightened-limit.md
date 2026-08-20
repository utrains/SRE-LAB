# Incident 10: The Tightened Limit

**App:** support-tickets
**Difficulty:** Easy-Medium
**Starts with:** a change (see
[devops-vs-sre.md](../devops-vs-sre.md#where-the-incident-starts))
**Ties to runbook:** `docs/runbooks/failed-rollout.md`,
`docs/runbooks/oomkill.md`

## Briefing (read this, then start)

The platform team spent this week trimming resource requests and limits
across the cluster -- the namespaces were reserving far more than anything
actually used, and capacity planning wanted it back. The support-tickets
change went out an hour ago.

Since then, the `[SRE Lab] Pod restarts detected` monitor has fired
repeatedly for support-tickets. Filing a ticket still works every time you
try it, and no customer has noticed anything.

You have seen this symptom before. Scenario 05, the midnight memory leak,
looked exactly like this: repeated `OOMKilled` on support-tickets. The
runbook for that one concluded there was nothing to actively fix.

Do not assume it's the same incident. Prove which one it is.

## Your task

1. Confirm the symptom, precisely:
   ```bash
   kubectl -n support-tickets get pods
   kubectl -n support-tickets describe pod <pod> | grep -A5 "Last State"
   ```
2. Look at the memory widget on the support-tickets dashboard over the last
   few hours. An OOMKill happens when usage crosses the limit -- so which
   of those two moved? That single question separates this scenario from
   scenario 05, and it is answerable from the dashboard alone.
3. Confirm your answer with the change history, not with a guess:
   ```bash
   kubectl -n support-tickets rollout history deployment/support-tickets-backend
   kubectl -n support-tickets rollout history deployment/support-tickets-backend --revision=<latest>
   kubectl -n support-tickets get deployment support-tickets-backend \
     -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
   ```
4. Note what the namespace's `LimitRange` (`namespaces/support-tickets.yaml`)
   did and did not prevent here. Why was this change accepted by the API
   server at all?
5. Fix it, and confirm pods stay up through at least one real user action
   in the app.
6. Then answer the design question: the limit that was set is a legal
   value, the pods were provably killed by it, and nobody measured what the
   process actually needs before changing it. **Where should that
   measurement have come from, and what should have blocked the change?**
7. Write the postmortem from both chairs (see
   [devops-vs-sre.md](../devops-vs-sre.md#two-ways-to-tell-the-same-incident)),
   then be ready to explain either version out loud, from memory, in under
   two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

`OOMKilled` is one symptom with two very different causes: the process
started using more memory, or somebody lowered the ceiling. The fix, the
blame and the prevention item are different for each. `rollout history` is
the fastest way to tell them apart.
</details>

<details>
<summary>Hint 2</summary>

Compare the current resources block against another app's:

```bash
kubectl -n support-tickets get deployment support-tickets-backend \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
kubectl -n banking get deployment banking-backend \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
```

Every backend in this lab ships with the same values -- one of them no
longer does.
</details>

<details>
<summary>Hint 3</summary>

Unlike scenarios 07 and 08, the bad value here *is* in the Deployment's pod
template, so `kubectl -n support-tickets rollout undo
deployment/support-tickets-backend` genuinely does fix it. Being able to say
why it works here and not there is worth more than the fix itself.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
