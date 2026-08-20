# Incident 7: The 4 PM Config Change

**App:** banking
**Difficulty:** Medium
**Starts with:** a change (see
[devops-vs-sre.md](../devops-vs-sre.md#where-the-incident-starts))
**Ties to runbook:** `docs/runbooks/failed-rollout.md`,
`docs/runbooks/config-and-secret-drift.md`

## Briefing (read this, then start)

A small config change went in this afternoon -- someone was tidying up the
banking backend's ConfigMap -- and the deploy pipeline reported success.
Twenty minutes later, an engineer running a routine `kubectl get pods`
before going home noticed banking looks odd, and asked in chat whether
anyone else was seeing it.

Nobody has complained. Customers can log in, check balances and transfer
money right now. The `[SRE Lab] Pod restarts detected` monitor did fire a
few minutes ago, and it was acknowledged in chat as "deploy noise." Your
instinct might be that there's nothing here.

Find out whether that's true.

## Your task

1. Start where a DevOps engineer starts: **what changed, and when?**
   ```bash
   kubectl -n banking rollout history deployment/banking-backend
   kubectl -n banking get events --sort-by=.lastTimestamp | tail -20
   ```
2. Confirm the customer experience yourself at
   `https://banking.$(cat .lab-domain)` (log in with password `demo123`).
   Is anything actually broken for users right now?
3. Look at the banking dashboard in Datadog, and then at the Kubernetes
   events for the namespace (`source:kubernetes kube_namespace:banking`).
   The restart monitor told you *that* something is restarting; neither it
   nor any dashboard widget tells you what or why. Which signal actually
   names the problem, and why did error rate and p95 never move?
4. Get to the root cause from the event message before you start reading
   YAML. What exactly is the probe complaining about?
5. Fix it, and confirm the rollout completes.
6. Answer the question that makes this scenario worth doing: **how close
   were you to an outage, and what would have taken you over the edge?**
7. Write the postmortem twice -- once as the DevOps engineer who owns the
   pipeline, once as the SRE who owns the service level. The second one is
   harder, because customer impact was zero and you still have to say why
   it mattered. Be ready to deliver either version out loud, from memory,
   in under two minutes.

## Hints (use only if stuck)

<details>
<summary>Hint 1</summary>

Compare the READY column with the STATUS column in
`kubectl -n banking get pods`. `Running` and `Ready` are different facts,
and only one of them decides whether a pod gets traffic.

Then ask why the old pods are still there at all --
`kubectl -n banking get rs` shows you both ReplicaSets.
</details>

<details>
<summary>Hint 2</summary>

`kubectl -n banking describe pod <newest-pod>` -- read the Events block at
the bottom, not the spec at the top.

Then compare what the pod is actually running with against what the
ConfigMap says now:
```bash
kubectl -n banking exec <a-working-pod> -- printenv | grep PORT
kubectl -n banking get configmap banking-backend-config -o yaml
```
</details>

<details>
<summary>Hint 3</summary>

`kubectl rollout undo` is the reflex here, and it does not fix this. The
Deployment's pod template never changed -- only the object it points at
did. See `docs/runbooks/config-and-secret-drift.md`.
</details>

---
Instructor setup and answer key: see
`docs/incident-scenarios/instructor-answer-keys.md` (do not share with
students before the exercise).
