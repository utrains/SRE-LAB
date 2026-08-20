# Instructor Answer Keys

**Do not share this file with students before they've attempted the
exercises in `docs/incident-scenarios/`.** Each section below gives the
exact setup command to trigger the incident, the expected diagnosis path,
the fix, and what to listen for in the student's postmortem.

## How to use the two-chair material

Every scenario can be told from either side of the room, and the two sides
answer different questions about the same facts -- see
[devops-vs-sre.md](../devops-vs-sre.md) for the full framing.

- Scenarios **1-6** start with a *condition*: nothing shipped, and the
  system met a limit nobody moved. Each key ends with a **Both chairs on
  this one** block giving the DevOps and SRE reading in a few lines each.
- Scenarios **7-10** start with a *change*: somebody shipped a config, a
  credential, an ingress edit, or a limit. These are the DevOps-native
  incidents, and each key carries two full walkthroughs -- **the DevOps
  version** and **the SRE version** -- because a candidate should be able
  to deliver either one.

Have students give the walkthrough for the chair they are interviewing
for, then ask for two sentences from the other chair. The second answer is
where you find out whether they understand the incident or have memorised
a script. A useful prompt when they stall: *"customer impact was zero --
so why did this matter?"*

---

## 1. The Silent Checkout (ecommerce)

**Setup (run before students start):**
```bash
scripts/chaos/inject-latency.sh ecommerce 4000
scripts/chaos/inject-errors.sh ecommerce 0.2
```

**Expected diagnosis path:** Student notices p95 latency and error rate
both elevated on the ecommerce dashboard, confirms by placing an order
(slow, sometimes fails), checks `GET /api/chaos` and sees
`latencyMs: 4000, errorRate: 0.2`.

**Fix:** `curl -X POST https://ecommerce.$(cat .lab-domain)/api/chaos/reset`

**Grading -- listen for:**
- Did they check the dashboard *before* guessing at code?
- Did they distinguish "latency" from "error rate" as two separate
  signals, not one blob of "it's broken"?
- Postmortem prevention idea should mention alerting thresholds or a
  canary/synthetic check catching this before customers report it.

**Talking through it:**

> We started getting Black Friday cart-abandonment reports, and the
> ecommerce dashboard didn't look dramatically red, so I didn't trust my
> gut and went straight to the dashboard instead of guessing at code. Two
> signals were both elevated at once, but they're different problems: p95
> latency was up around 4 seconds, and error rate was sitting around 20%,
> not zero. That distinction mattered, because a slow-but-working checkout
> and a checkout that's actually failing a fifth of the time need
> different follow-up. I reproduced it myself by placing a real order,
> confirmed it matched what customers were describing, then checked our
> chaos-injection endpoint on that pod, which reported `latencyMs: 4000`
> and `errorRate: 0.2`. That told me this was a known, resettable failure
> mode, not a real code regression, so I reset it and confirmed both
> metrics dropped back to baseline within about a minute on the dashboard.
> The prevention piece is the important part: this shouldn't have taken a
> customer complaint to surface -- a latency/error-rate monitor with a
> synthetic check hitting checkout every minute would have paged us before
> a single customer noticed.


**Both chairs on this one:**

- **DevOps angle --** The first thing I establish is that nothing shipped:
  `rollout history` is clean, no config or secret changed, so there is no
  release to revert and this is a condition rather than a change. That
  matters because it decides who owns the next hour, and saying it out loud
  early stops the service owner waiting on me while I investigate something
  that was never mine. Then I stay useful by reading the trace, not by
  restarting pods.
- **SRE angle --** Two signals moved together, and they are two different
  problems: slow-but-working and actually-failing need different responses,
  so collapsing them into "checkout is broken" throws away the distinction
  that decides what to do next. Checkout is our primary SLI, so both cost
  budget and I would size each separately from the graphs. The finding that
  outlives the fix is detection -- customers told us before a monitor did,
  on the highest-traffic day of the year, which means our thresholds are
  tuned for a quieter day than the one that matters.


---

## 2. Payday Panic (banking)

**Setup:**
```bash
scripts/chaos/drop-db-connection.sh banking
```

**Expected diagnosis path:** Login may still succeed (auth doesn't hit the
DB-dependent readiness path directly, but dashboard calls will fail once
readiness fails and the pod is pulled from the Service, or requests to
the affected pod return 503 from `/readyz`-gated logic if checked
directly). Student runs `curl https://banking.$(cat .lab-domain)/readyz`, sees
`503` with `reason: db connection dropped (chaos)`, checks
`kubectl -n banking get pods` and sees pods go `0/1 Ready` after the
readiness probe's `failureThreshold` is exceeded (~30s).

**Fix:** `curl -X POST https://banking.$(cat .lab-domain)/api/chaos/reset`

**Grading -- listen for:**
- Did they check `/readyz` specifically, rather than just restarting
  pods blindly?
- Postmortem should correctly explain that `/healthz` (liveness) stayed
  green throughout -- the process never crashed, only its dependency
  check failed -- and that this is *why* the app has two separate
  endpoints instead of one.

**Talking through it:**

> On payday, customers said the banking dashboard wouldn't load and one
> transfer hung. The first thing I checked wasn't the pods, it was
> `/readyz`, because a hanging feature that isn't a hard crash usually
> means a dependency, not the process itself. `/readyz` came back 503 with
> a reason of a dropped DB connection. Liveness, `/healthz`, was still
> green the whole time -- the Node process never crashed, it just
> couldn't answer the one question that actually matters for serving
> traffic: can I reach the database? Once readiness kept failing past its
> failure threshold, Kubernetes pulled that pod out of the Service on its
> own, which explains why some requests worked and others didn't
> depending on which pod you hit. I reset the chaos state and watched
> pods flip back to Ready within about 30 seconds. The reason I'd bring
> this up unprompted in a conversation about monitoring: it's exactly why
> you want two separate health checks instead of one. If liveness had
> been tied to the database too, Kubernetes would've restarted a
> perfectly healthy process over and over for a problem restarting it
> could never fix.


**Both chairs on this one:**

- **DevOps angle --** Nothing shipped here either, so there is nothing to
  roll back, and my job is the dependency rather than the app: is RDS
  actually reachable from inside the cluster, is the credential still
  valid, did anything change at the network or security-group layer. The
  platform contribution to the durable fix is the probe design this app
  already gets right -- a hard dependency failing should pull a pod out of
  rotation, not restart a perfectly healthy process forever.
- **SRE angle --** Availability here was partial and pod-dependent, which
  is the hardest kind of impact to describe honestly: some customers were
  fine, some could not load a balance, and it depended which pod they hit.
  It spends budget the whole time. The detection gap is that nothing we
  alert on watches readiness -- pods leaving the Service is invisible to all
  four monitors, and we found out because someone looked.


---

## 3. The Stuck Order (food-delivery)

**Setup:**
```bash
kubectl -n food-delivery scale deployment food-delivery-redis --replicas=0
```

**Expected diagnosis path:** Student notices food-delivery has a
component the other four apps don't (Redis, per `docs/architecture.md`).
`kubectl -n food-delivery get pods` shows no `food-delivery-redis` pod.
Order status calls will error (the backend's `ioredis` client will throw
or time out since `maxRetriesPerRequest: 2` in
`apps/food-delivery/backend/src/cache.js`), surfacing as 500s from
`GET /api/orders/:id/status`.

**Fix:**
```bash
kubectl -n food-delivery scale deployment food-delivery-redis --replicas=1
```

**Grading -- listen for:**
- Did they identify Redis specifically as the missing piece, not just
  "something's broken in food-delivery"?
- Discussion point worth drawing out live: `/readyz` in this app
  deliberately only checks Postgres, not Redis (see
  `apps/food-delivery/backend/src/index.js`) -- is that the right scope,
  given Redis here is just a cache and the DB is the source of truth? A
  good answer notes the tradeoff: readiness gating on Redis too would
  pull pods out of rotation for a cache outage that degrades (not breaks)
  functionality, which may be worse than serving slightly-stale/slower
  responses.

**Talking through it:**

> A diner's order tracking page just spun forever, but orders were still
> being placed successfully, so this was scoped to one specific feature,
> not the whole app. Food-delivery is the one app in this lab with a
> component none of the others have, an in-cluster Redis cache for order
> status, so that's where I looked first, and sure enough there was no
> Redis pod running. The status endpoint's Redis client has a low retry
> limit, so it was timing out and returning 500s specifically on the
> status-polling call. I scaled Redis back to one replica and the
> tracking page recovered on its own, no backend redeploy needed, because
> the app reconnects automatically once the dependency is back. What I
> actually want to talk about here is a design decision, not just the
> fix: this app's readiness check deliberately only pings Postgres, not
> Redis. That's a real tradeoff -- if readiness also depended on the
> cache, a Redis outage would pull every pod out of rotation for a
> feature that was degrading, not breaking, checkout or ordering. Serving
> slightly stale status updates is a better failure mode than taking the
> whole app offline over a cache.


**Both chairs on this one:**

- **DevOps angle --** No deploy explains this, but a Deployment sitting at
  zero replicas is a platform fact and Kubernetes does not do that on its
  own, so my first question is what scaled it. The durable fix is not
  scaling it back -- it is that the replica count lives in a manifest we
  apply, so a hand-run `kubectl scale` gets corrected by the next apply
  instead of persisting silently until someone notices.
- **SRE angle --** This is a good argument for an SLI with a defined scope:
  ordering and checkout were completely healthy and only order *tracking*
  was broken, so "food-delivery was down" overstates it and "no impact"
  understates it. The design question worth raising in the review is
  whether readiness should depend on the cache. It deliberately does not,
  and I would keep it that way -- pulling every pod out of rotation over a
  degraded feature is a worse outcome than serving the rest of the app.


---

## 4. Grades Gone Missing (student-portal)

**Setup:**
```bash
scripts/chaos/bad-deploy.sh student-portal student-portal-backend student-portal-backend
```

**Expected diagnosis path:** `kubectl -n student-portal get pods` shows a
mix of `Running` (old ReplicaSet) and `ImagePullBackOff` (new
ReplicaSet) pods -- this is why the symptom is intermittent rather than a
total outage: the Service still has some ready (old) endpoints.
`kubectl -n student-portal rollout status deployment/student-portal-backend`
shows the rollout stuck, waiting for new pods that will never become
ready.

**Fix:** `kubectl -n student-portal rollout undo deployment/student-portal-backend`

**Grading -- listen for:**
- Did they check `describe pod` on the failing pod and see the actual
  `ImagePullBackOff` / `ErrImagePull` reason, rather than assuming a code
  bug?
- Postmortem should explain the *partial* outage is a direct consequence
  of `RollingUpdate`'s default `maxUnavailable`/`maxSurge` -- old pods
  aren't torn down until enough new ones are ready, which is a safety
  feature here, not a bug.

**Talking through it:**

> Right before finals week, a deploy went out to student-portal and
> grades started loading intermittently instead of failing cleanly or
> working fine. Intermittent is a specific signal -- it usually means
> some requests are being served by old, healthy pods and others by new,
> broken ones, which is different from a full outage. `kubectl get pods`
> confirmed that: a mix of `Running` pods from the old ReplicaSet and
> `ImagePullBackOff` pods from the new one. `describe pod` on the failing
> one gave the actual reason instead of me assuming it was a code bug --
> it genuinely couldn't pull the image. Rollout status showed it stuck
> waiting on replicas that were never going to become ready. I rolled
> back with a rollout undo and confirmed the grades endpoint was
> consistently healthy again. The point worth making unprompted: the fact
> that this degraded instead of going fully down wasn't luck, it's
> `RollingUpdate`'s `maxUnavailable` and `maxSurge` doing exactly their
> job -- Kubernetes won't tear down old, healthy pods until enough new
> ones are actually ready, so a bad image gets you a partial outage with
> a safety net, not a total one.


**Both chairs on this one:**

- **DevOps angle --** This one is squarely mine. We shipped a tag that does
  not exist in the registry and the pipeline still reported a green deploy.
  The rollback takes thirty seconds; the fix that matters is that nothing
  between build and deploy verified the image was actually pushed, and
  nothing gated on `rollout status --timeout`. Today "deploy succeeded"
  means "the API server accepted our YAML," which is a different claim from
  "the new version is serving traffic."
- **SRE angle --** The interesting part is that it degraded instead of
  breaking, and degradation is harder to detect than an outage: a fraction
  of requests failing across old and new pods can sit inside an aggregate
  error rate that never crosses a threshold. It burned budget for as long
  as it ran. I would want error rate broken out per endpoint rather than
  per service, so one failing path cannot be averaged into invisibility by
  the healthy ones beside it.


---

## 5. The Midnight Memory Leak (support-tickets)

**Setup:**
```bash
scripts/chaos/memory-spike.sh support-tickets 300
```

**Expected diagnosis path:** One pod OOMKills within moments of the
command (container limit is 256Mi, requested spike is 300MB). Kubernetes
immediately restarts it, which comes back healthy and *without* the
chaos state (in-memory state resets on restart) -- hence "resolves
itself." `kubectl -n support-tickets get pods` shows `RESTARTS: 1` (or
more, if run multiple times) on one pod specifically, not both replicas.
`describe pod` shows `Last State: Terminated, Reason: OOMKilled`.

**Fix:** Nothing to actively fix once it's restarted on its own -- the
point of this scenario is recognizing that a "self-healing" symptom
still needs a root-cause writeup, because next time it might not recover
cleanly (e.g. if it OOMKills mid-request repeatedly under real load
rather than a one-off spike).

**Grading -- listen for:**
- Did they check restart count and `describe pod`, or did they declare
  victory as soon as the app "looked fine again"?
- Postmortem should explicitly call out the risk of alert fatigue /
  under-investigating self-resolving incidents, and mention the
  `[SRE Lab] Memory saturation approaching container limit` monitor as
  the thing that should have paged *before* the OOMKill happened, not
  after.

**Talking through it:**

> This one's interesting because by the time I looked at it, it had
> already "fixed itself" a couple of times, which is exactly the kind of
> incident that's easy to under-investigate. Ticket creation was randomly
> failing right after deploys or restarts, then clearing up on its own. I
> checked restart counts first instead of just confirming the app looked
> fine right now, and one pod specifically had restarted, not both
> replicas. `describe pod` gave the real reason: last state terminated,
> OOMKilled, right at the 256Mi container limit. Kubernetes restarts a
> killed pod automatically, and since this app's chaos/failure state
> lives in memory, the restart also wiped the symptom, which is why it
> looked self-healing. There wasn't an active fix beyond confirming it
> had recovered, but the postmortem is really the point of this one:
> self-resolving incidents are the ones most likely to get waved off with
> "it's fine now," and that's how you end up ignoring a real memory leak
> until it OOMKills mid-request under actual load instead of a one-off
> spike. The real fix here is upstream of the incident -- a
> memory-saturation monitor that pages when usage is climbing toward the
> limit, so you catch it before the kill, not after.


**Both chairs on this one:**

- **DevOps angle --** Nothing shipped and the limits have not changed --
  `rollout history` confirms both -- so this is application behaviour and I
  am the escalation path, not the fix. What I do own is the ceiling:
  whether 256Mi is right, whether the restart was clean, and whether there
  are enough replicas that one OOMKill is invisible to users. Worth
  comparing against scenario 10, where an identical symptom *is* a platform
  change and the fix is mine.
- **SRE angle --** Self-resolving incidents are the ones we systematically
  under-investigate, and the risk is not this occurrence -- it is the same
  kill happening under real load and not recovering cleanly. Budget spent
  is small but not zero: every request in flight when the container died
  failed. The prevention item is about timing, not thresholds. Our
  memory-saturation monitor exists precisely to fire *before* the kill, so
  if the first thing we learned was the restart, that warning threshold is
  doing nothing for us.


---

## 6. The Noisy Neighbor (ecommerce + banking, shared RDS instance)

**Setup (run before students start):** unlike the other 5 scenarios, this
one isn't a single `scripts/chaos/*.sh` call -- it opens real Postgres
connections and holds them idle-in-transaction, to genuinely move
`pg_stat_activity` counts on the shared instance rather than just
toggling in-app state.

```bash
RDS_ADDRESS=$(cd terraform && terraform output -raw rds_address)

for app in ecommerce banking; do
  DB_USER=$(kubectl -n "$app" get secret "${app}-db-credentials" -o jsonpath='{.data.PGUSER}' | base64 -d)
  DB_NAME=$(kubectl -n "$app" get secret "${app}-db-credentials" -o jsonpath='{.data.PGDATABASE}' | base64 -d)
  DB_PASS=$(kubectl -n "$app" get secret "${app}-db-credentials" -o jsonpath='{.data.PGPASSWORD}' | base64 -d)
  for i in $(seq 1 15); do
    kubectl run "hog-${app}-${i}" --rm -i --restart=Never -n "$app" \
      --image=postgres:17-alpine --env="PGPASSWORD=${DB_PASS}" \
      --command -- psql -h "$RDS_ADDRESS" -U "$DB_USER" -d "$DB_NAME" \
      -c "BEGIN; SELECT pg_sleep(600);" &
  done
done
```

This holds 30 idle-in-transaction connections (15 per app) against a
`db.t3.micro` instance's modest `max_connections` ceiling for 10 minutes,
on top of the 5 apps' normal pool traffic -- enough that ecommerce and
banking (and potentially others) start seeing connection
timeouts/`/readyz` failures at the same time. If you need to cut it short:
```bash
for app in ecommerce banking; do
  kubectl -n "$app" get pods -o name | grep hog- | xargs -r kubectl -n "$app" delete
done
```

**Expected diagnosis path:** Student notices *both* ecommerce and banking
have trouble at once (not the single-app pattern from "Payday Panic"),
which is the tell this is instance-level, not app-level. Runs the
`rds-connection-limit.md` diagnostic query, sees `ecommerce_db` and
`banking_db` each holding ~15 more connections than normal. Digging into
`pg_stat_activity`'s `query` and `state` columns (not just the count)
shows a wall of `state = idle in transaction`, `query: SELECT pg_sleep(600)`
rows with an old `query_start` -- the signature of a hung transaction, not
legitimate app traffic (the app's own pool never runs `pg_sleep`).

**Fix:**
```bash
kubectl run pg-fix --rm -i --restart=Never -n ecommerce \
  --image=postgres:17-alpine --env="PGPASSWORD=<master-password>" \
  --command -- psql -h <rds-address> -U <rds-master-user> -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE state = 'idle in transaction' AND query LIKE '%pg_sleep%';"
```
(Or, since this is a simulated lab, just delete the `hog-*` pods per the
"cut it short" command above -- either kills the same underlying
connections.)

**Grading -- listen for:**
- Did they check *every* app instead of only the one they were paged for,
  and recognize "more than one app, same time" as the signature of a
  shared-resource problem rather than coincidence?
- Did they look at what the connections were actually doing
  (`state`/`query`/`query_start`), not just the raw count -- the fix is
  different for "legitimate but heavy traffic" versus "one hung
  transaction," and you can't tell which without looking?
- Postmortem should explain why restarting ecommerce's or banking's own
  Deployment would do nothing here (the culprit connections don't belong
  to either app's backend pods at all), and should connect this back to
  the shared-RDS tradeoff in `docs/architecture.md` -- this is the
  concrete incident that tradeoff predicts.

**Talking through it:**

> Two unrelated apps, ecommerce and banking, started having trouble at
> the same time, and that simultaneity was the actual clue -- one app
> misbehaving is an app problem, two unrelated apps misbehaving at once
> is usually a shared-resource problem. Neither team had deployed that
> day, which ruled out the obvious explanation. I checked every app's
> readiness and dashboards, not just the one I'd been paged for, and
> confirmed it really was scoped to both. Both apps sit on the same RDS
> instance, so I ran the connection-count query from our runbook and saw
> both databases holding noticeably more connections than baseline. The
> count alone doesn't tell you what to do, though -- I looked at
> `pg_stat_activity`'s `state` and `query` columns specifically, and
> found a wall of connections sitting idle in transaction, running
> `pg_sleep`, which is the signature of something that opened a
> transaction and never closed it, not real application traffic. I
> terminated those specific backends and both apps recovered within a
> minute. The thing I'd explain unprompted: restarting either app's own
> Deployment would have done nothing here, because the problem was never
> in their pods, it was a shared dependency being starved by something
> else entirely. That's the concrete cost of one RDS instance backing
> five apps -- it's cheaper, but it means one badly-behaved job can take
> down services that have nothing to do with each other.


**Both chairs on this one:**

- **DevOps angle --** No app deployed, and the connections holding the
  instance hostage do not belong to any app's pods, so this is
  platform-owned even though it surfaced through two application teams. One
  RDS instance behind five apps is a cost decision I can defend, but it
  carries obligations we have not met: per-app connection caps, a pooler in
  front of the instance, and a scheduled job that cannot hold a transaction
  open indefinitely against a shared database.
- **SRE angle --** Two unrelated services degrading at the same moment is
  the signature of a shared dependency, and it is also the case our
  per-service SLOs describe worst -- each app's dashboard looked survivable
  while the combined customer impact was not. It spends from several
  services' budgets at once, from one root cause neither team could have
  prevented. The finding is isolation: we accepted a shared blast radius to
  save money, and this incident is the invoice for that decision, which is
  exactly the trade the error-budget conversation exists to make explicit.


---

## 7. The 4 PM Config Change (banking)

**Setup (run before students start):**
```bash
scripts/chaos/break-config.sh banking
```

The script patches `PORT` in the `banking-backend-config` ConfigMap from
`4000` to `4001`, then runs `rollout restart`. Give it about five minutes
before students start, so the restart count has time to trip the monitor.

**What actually happens:** `maxSurge` is 1 and `maxUnavailable` is 0 for a
2-replica Deployment, so Kubernetes creates exactly one new pod and refuses
to touch the two old ones until it goes `Ready`. The new pod's Express app
binds 4001; both probes still target 4000
(`apps/banking/k8s/deployment-backend.yaml`), so readiness gets connection
refused and never passes, and liveness does the same until kubelet restarts
the container (~55s: `initialDelaySeconds: 10` plus three 15s periods).
That repeats into `CrashLoopBackOff`, which is what fires
`[SRE Lab] Pod restarts detected` (>2 in 5 minutes). The two old pods keep
serving on `PORT=4000` the entire time, because `envFrom` values are read
once at container start -- editing the ConfigMap did not touch them.

**Expected diagnosis path:** `kubectl -n banking get pods` shows two
healthy pods plus one cycling through `CrashLoopBackOff`;
`rollout status` hangs; `rollout history` shows a restart-triggered
revision from 20 minutes ago. `describe pod` on the newest pod gives
`Readiness probe failed: dial tcp 10.x.x.x:4000: connect: connection
refused` and `Back-off restarting failed container`. `kubectl logs` on that
pod says `banking-backend listening on 4001`, which is the moment the
penny drops. Comparing `kubectl exec <old-pod> -- printenv | grep PORT`
(4000) against `kubectl get configmap banking-backend-config -o yaml`
(4001) proves the drift.

**Fix:**
```bash
scripts/chaos/break-config.sh banking --undo
```
(equivalently: patch `PORT` back to `4000`, then `rollout restart`.)

**Grading -- listen for:**
- Did they ask what changed *before* forming a theory? `rollout history`
  and the event stream should come before any YAML reading.
- Did they notice the rollout was stuck, rather than only that a pod was
  restarting? Those are different findings, and only one of them explains
  why customers were fine.
- Did they reach for `kubectl rollout undo`? It's the natural reflex and it
  does **not** work here -- the pod template never changed, only the
  ConfigMap it references. Students who try it, notice it didn't help, and
  explain why have learned the most valuable thing in this scenario.
- Can they explain why the two old pods were unaffected? "Environment
  variables are read at container start" is the answer.
- Did they identify the near miss: at two healthy replicas with a stuck
  rollout, any eviction, node recycle, or HPA scale event that removes a
  pod cannot replace it.

**Talking through it -- the DevOps version:**

> A ConfigMap change went out at 15:52 and the pipeline reported a
> successful deploy. Our pod-restart monitor fired a few minutes later and
> got acknowledged as deploy noise, which is fair -- restarts around a
> deploy are normal. What wasn't normal was that the rollout never
> finished. I started with what changed rather than with the pod: rollout
> history showed a revision from minutes earlier, and rollout status was
> still hanging. The Kubernetes events for the namespace showed readiness
> probes failing with connection refused, which is a specific signal -- the
> container is up and the probe can't reach it, so it's not listening where
> we think it is. The new pod's logs confirmed it: listening on 4001, while
> both probes and the Service target 4000. Someone had changed PORT in the
> ConfigMap. My first instinct was rollout undo, and that would have done
> nothing, because the Deployment's pod template was never the problem --
> the object it references was. I patched the ConfigMap back and rolled;
> pods went Ready in about ninety seconds. Two follow-ups: the pipeline
> gates on apply succeeding rather than on `rollout status --timeout`, so a
> rollout that can never go healthy still reports green, and there's no
> alert on unavailable replicas. Both of those are why this ran for twenty
> minutes instead of two.

**Talking through it -- the SRE version:**

> Customer impact on this one was zero, and that's exactly what I want to
> talk about. Error rate never moved, p95 never moved, we spent no error
> budget, and the app was fully functional the whole time. But for about
> twenty minutes we were running with no ability to replace a pod, and
> nobody knew. If an HPA scale-up or a node recycle had landed in that
> window, the replacement pod could never have become Ready and we'd have
> been degraded or down, during a change nobody was watching any more. So
> the finding isn't the config typo, it's the detection. The one signal we
> got was a restart alert that a human correctly judged as low-value and
> acknowledged, which means our alerting taught someone to ignore the only
> thing that fired. Our four monitors are all symptom-based -- error rate,
> latency, saturation, restarts -- and symptom alerts are the right
> default, but they're structurally blind to a deploy that quietly failed
> while the old version kept serving. What I'd add is one platform alert on
> unavailable replicas, which catches this and three other failure modes
> with one query, and I'd change what "deploy succeeded" means in the
> pipeline. The severity of this incident is a near miss, and near misses
> are the cheapest data we ever get.

---

## 8. The Rotated Password (ecommerce)

**Setup (run before students start):**
```bash
scripts/chaos/rotate-secret.sh ecommerce
```

The script saves the real `PGPASSWORD` to `.chaos-backup/` (gitignored,
because it's the only copy that exists -- see the fix note below),
overwrites it in the `ecommerce-db-credentials` Secret with a value RDS has
never seen, and runs `rollout restart`.

**What actually happens:** one new pod is created (`maxSurge: 1`,
`maxUnavailable: 0`). Its process starts normally and stays `Running` --
`/healthz` is liveness only, so nothing ever restarts it. `/readyz` runs a
real `SELECT 1`, Postgres rejects the credential, and the pod sits `0/1`
forever, out of the Service's endpoints. The two old pods hold the correct
password in their own environment and keep serving. No monitor fires:
error rate, p95 and memory are all normal, and there are no restarts to
count.

**Expected diagnosis path:** `get pods` shows `1/1`, `1/1`, `0/1 Running`
with `RESTARTS: 0` -- the absence of restarts is itself a clue, and rules
out the crash-loop family. `get endpoints ecommerce-backend` lists two
addresses, not three. In Datadog, `service:ecommerce-backend status:error`
shows `readiness check failed: password authentication failed for user
"ecommerce_app"`, repeating every 10 seconds from the one bad pod. Students
can confirm the same thing directly against the pod:

```bash
kubectl -n ecommerce port-forward <not-ready-pod> 14000:4000
curl -s localhost:14000/healthz | jq .   # 200 -- the process is fine
curl -s localhost:14000/readyz  | jq .   # 503 + the auth failure as "reason"
```

**Fix:**
```bash
scripts/chaos/rotate-secret.sh ecommerce --undo
```

Worth saying out loud when you demo the fix: each app's database password
is generated by `setup.sh` with `openssl rand` and stored **only** in the
Secret -- there is no copy in Terraform state. Losing it means re-running
`setup.sh`, which generates a new one and `ALTER ROLE`s it on RDS. That is
a deliberately realistic piece of operational debt.

**Grading -- listen for:**
- Did they read the READY column rather than STATUS? `Running` with `0/1`
  is the whole scenario, and someone who only looks at STATUS reports "all
  pods are running, nothing's wrong."
- Did they connect not-Ready to endpoint membership, i.e. explain the
  mechanism by which an unready pod stops receiving traffic?
- Did they use the logs or `/readyz` to get the *actual* error, or did they
  guess "database problem" and start restarting things?
- Can they explain why the old pods still work? (Their environment was
  populated at container start, from a Secret that has since changed.)
- Did they recognise the urgency despite zero customer impact -- the
  working credential now exists only in the memory of two pods that cannot
  be replaced?
- Bonus: did anyone try `rollout undo`? Same trap as scenario 07, same
  reason it fails.

**Talking through it -- the DevOps version:**

> A credential rotation ticket was closed this morning and a deploy went
> out this afternoon and got stuck. Nothing was down -- checkout worked,
> every dashboard was normal, no monitor fired. `get pods` showed two ready
> pods and one that was Running with zero restarts and zero readiness, and
> zero restarts is informative on its own: the process isn't crashing, so
> this isn't a code or memory problem, it's a dependency check failing. I
> went to the logs for that service in Datadog before touching anything and
> got the exact line -- password authentication failed for user
> ecommerce_app, repeating every ten seconds, which is the readiness probe
> interval. That told me the Secret and the role on RDS disagree. The old
> pods kept working because their environment was populated when they
> started, from a version of the Secret that no longer exists anywhere, and
> that's the part that made this urgent rather than routine: we were one
> eviction away from an outage and the only working copy of the password
> was in process memory. I restored the Secret and rolled the Deployment.
> The prevention item is that we have two systems of record for one value
> and no automation keeping them in step -- rotation should update RDS and
> the Secret in the same operation and then verify by watching the rollout
> actually go Ready, instead of a ticket being marked done at the halfway
> point.

**Talking through it -- the SRE version:**

> Zero customers affected, zero error budget spent, and this is still the
> incident from that week I'd want reviewed. What we actually had was a
> service that could not be replaced running on two pods and a credential
> that existed in no durable store anywhere -- one node recycle from a full
> outage of checkout, which is our primary SLI. None of our four monitors
> can see that state, and I don't think adding a fifth symptom monitor is
> the answer, because there genuinely was no symptom. The gap is that our
> alerting stops at the service boundary and never asks whether the service
> can still heal itself. Concretely I'd alert on unavailable replicas so a
> stalled rollout pages while it's still harmless, and separately I'd treat
> "the running credential can't be reproduced from any source of truth" as
> a standing risk rather than an incident finding. On the budget question:
> if this had turned into an outage during peak checkout, our 99.5%
> monthly target gives us about ten thousand bad requests, and at our
> normal checkout volume a fifteen-minute hard outage spends a meaningful
> fraction of that in one go. The reason to fix a near miss is that the
> same fault costs nothing today and a chunk of the quarter's budget the
> day the timing is worse.

---

## 9. Green Dashboards, Angry Customers (food-delivery)

**Setup (run before students start):**
```bash
scripts/chaos/break-ingress.sh food-delivery
```

The script repoints the food-delivery Ingress rule from
`food-delivery-frontend:80` to `food-delivery-backend:4000`. Allow one to
two minutes for the AWS Load Balancer Controller to reconcile and for the
target group's health checks to fail before students start.

**What actually happens** (verified against a live cluster -- the outcome is
not the one you would predict): both the Service and the port exist, so the
controller accepts the change without complaint and swings the shared ALB's
target group onto the backend pods. The ALB health-checks `/`, which the
Express backend has no route for, so it answers 404 and **every target is
marked unhealthy**. An ALB whose target group contains no healthy targets
*fails open* -- it forwards to all of them regardless -- so users do not get
a clean 503. They get the backend's own `404 Cannot GET /`, with
`X-Powered-By: Express` in the headers. `/api/*` paths keep returning 200
throughout, because the backend genuinely is healthy; it is simply the wrong
service to be answering a browser asking for the SPA.

Nothing in Kubernetes is unhealthy: all pods `1/1 Running`, all Services
with endpoints. And **nothing in the dashboards moves at all** -- not even
throughput. Every widget in `datadog/dashboards/food-delivery.json` is
scoped to `service:food-delivery-backend`; there is no frontend service in
APM (nginx isn't instrumented), so there is no throughput to collapse. The
backend's own throughput actually *holds steady or rises*, because the ALB
health checks now hammer `GET /` every few seconds. Error rate stays flat
too: dd-trace flags 5xx as errors, and a 404 is not a 5xx.

Also worth knowing before you run this with a class: this lab does not
configure the Datadog AWS integration, so there are no ALB metrics and no
target-group health in Datadog. Target health can only be seen from the AWS
console or the CLI. That is not a gap in the exercise, it *is* the
exercise.

**Expected diagnosis path:** `curl -i` returns `404` with
`X-Powered-By: Express` -- the single most informative line in the whole
incident, because it names which of their own services answered. Every
`kubectl` check comes back clean, which pushes the student outward to the
edge. `kubectl -n food-delivery describe ingress food-delivery` shows the
backend pointing at `food-delivery-backend:4000`; diffing against any other
app's Ingress makes it obvious. `aws elbv2 describe-target-health` shows
every target `unhealthy`, which explains the fail-open behaviour. The
controller's logs show a *successful* reconcile, which is the point -- this
is a valid configuration doing exactly what it was told.

**Fix:**
```bash
scripts/chaos/break-ingress.sh food-delivery --undo
```
Then re-check the status code; recovery is not instant, since the
controller has to reconcile and the target group has to pass health checks
again.

**Grading -- listen for:**
- Did they capture the actual status code instead of reporting "the site is
  down"? 503 versus 502 versus 404 point at different things, and
  `docs/runbooks/ingress-502s.md` explains which is which.
- **The key question:** what did they do when the dashboard showed nothing?
  This is the one scenario where the correct finding is "my monitoring
  cannot see this," and the students who get stuck are the ones who keep
  refreshing widgets waiting for one to move. The move is to go back to the
  evidence they already had -- the HTTP response -- and read the headers.
- Did they notice backend throughput was *up*, and work out that the ALB's
  own health checks were generating it? That is the difference between
  reading a graph and understanding what feeds it.
- Did they reason about layers -- app healthy, edge broken -- rather than
  restarting pods that were never the problem?
- Can they explain why a *successful* reconcile is the tell? The controller
  did its job; the input was wrong.
- Prevention answer should be specific: a synthetic/uptime check hitting
  the public URL from outside the cluster, or an alert on throughput
  collapse. "Better monitoring" is not an answer.

**Talking through it -- the DevOps version:**

> Support escalated that food-delivery wouldn't load at all during the
> dinner rush, and every dashboard we had was green. First thing I did was
> reproduce it and actually look at the response instead of trusting the
> description. It wasn't a gateway error -- it was a 404, and the headers
> said `X-Powered-By: Express`. That one line told me the request was
> arriving and being answered by our own API service, which has no route for
> `/`. So this was never an availability problem, it was a routing problem:
> the right traffic was reaching the wrong service. Kubernetes agreed that
> nothing was broken -- every pod Ready, every Service with endpoints -- so I
> went outward and diffed the Ingress against another app's. Ours pointed at
> the backend Service on 4000 instead of the frontend on 80. Completely
> valid config, which is why nothing anywhere errored: the controller
> reconciled it successfully. The ALB then health-checked `/` against an API
> with no `/` route, got 404s, and marked every target unhealthy -- and
> because *all* of them were unhealthy the ALB failed open and kept
> forwarding, which is why customers got our API's 404 page instead of a
> clean 503. I put the Ingress back and confirmed from outside the cluster,
> not from kubectl, because the ALB needs a couple of minutes to reconcile.
> The fix I actually care about is that we had a total customer-facing
> outage with a fully green monitoring stack, because everything we alert on
> is instrumented inside one application. That needs a check that starts
> where the customer starts.

**Talking through it -- the SRE version:**

> This is the one that changed how I think about our monitoring. Total
> outage of food-delivery at peak, and our detection was a support
> escalation -- customers told us, which is the failure mode I care most
> about, independent of the cause. Our entire observability story is
> application telemetry: traces the app emits, errors the app records,
> latency the app measures. All of it is conditional on the request
> reaching the app. When the failure is upstream of the service, our
> instrumentation doesn't degrade gracefully -- it reports on a service that
> was never the broken one. And there was no signal to catch, not even a
> quiet one: I checked, and backend throughput was actually *up*, because the
> load balancer's own health checks were generating traffic. A monitor on
> collapsed throughput would not have caught this. On budget:
> this was a hard outage at peak, so we spent real budget -- I'd size it
> from the throughput graph, taking the requests we'd normally have served
> in that window against the monthly allowance, and it's the kind of number
> that ends a feature sprint. Two action items. A synthetic check from
> outside the cluster against the real public URL, running every minute,
> because that's the only thing that would have caught this. And an alert
> on throughput collapse for services that always have traffic, so silence
> is treated as a signal instead of as good news.

---

## 10. The Tightened Limit (support-tickets)

**Setup (run before students start):**
```bash
scripts/chaos/shrink-limits.sh support-tickets
```

The script patches the support-tickets backend's memory request and limit
down to `20Mi`. Allow a few minutes so restarts accumulate and the monitor
fires.

The number was chosen by measurement, not by eye, and it is worth knowing
why before a student asks: a backend idles around 31Mi resident. At 64Mi
(the old `LimitRange` floor) nothing happens at all, and at 32Mi the pod
sits exactly on the line and is killed only intermittently. 20Mi kills it
reliably during startup. The namespace floor is 16Mi so the value is still
legal -- see `namespaces/<app>.yaml`.

**What actually happens:** the pod template changed, so a rolling update
starts on its own. Node with Express, `pg` and `dd-trace` needs about 31Mi
resident, so at 20Mi the new pod is `OOMKilled` during startup (exit code
137) and lands in `CrashLoopBackOff`, firing
`[SRE Lab] Pod restarts detected`. The old pods keep serving; users notice
nothing. The symptom is byte-for-byte identical to scenario 05, and the
cause is the opposite: nothing leaked, the ceiling moved.

**Expected diagnosis path:** `describe pod` shows `Last State: Terminated,
Reason: OOMKilled, Exit Code: 137` -- the same finding as scenario 05,
which is the trap. The distinguishing move is `rollout history`, plus
comparing the resources block against any other app's (all five ship
identical values, so the odd one out is obvious):

```bash
kubectl -n support-tickets get deployment support-tickets-backend \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
```

The dashboard supports the same conclusion from the other direction: the
memory-usage line for the healthy pods is flat and normal, so usage did not
grow.

**Fix:**
```bash
scripts/chaos/shrink-limits.sh support-tickets --undo
# or, since the pod template itself changed, this genuinely works here:
kubectl -n support-tickets rollout undo deployment/support-tickets-backend
```

**Grading -- listen for:**
- Did they resist pattern-matching to scenario 05? Both are `OOMKilled`;
  the fix, the owner and the prevention item are completely different.
- Did they prove it with `rollout history` or a comparison against another
  app, rather than asserting it?
- Can they explain why the `LimitRange` did **not** stop this? 20Mi is a
  perfectly legal value -- above the configured 16Mi `min`. Admission
  control enforces bounds, not correctness, and no policy in the cluster
  knows what this process actually needs to run.
- Do they know why `rollout undo` works here but not in scenarios 07 and
  08? The bad value is in the pod template this time. A student who can
  articulate that distinction understands Kubernetes configuration better
  than most people interviewing for these roles.
- Prevention should reference measurement: right-sizing from observed usage
  (the memory widget, or Datadog's container metrics) rather than from a
  capacity spreadsheet, and staging the change on one app first.

**Talking through it -- the DevOps version:**

> We were right-sizing resource requests across the cluster and one of the
> changes put support-tickets into a crash loop. The restart monitor fired,
> and the symptom -- OOMKilled, exit 137 -- was identical to a memory-leak
> incident we'd had on the same app a few weeks earlier, so the tempting
> read was "the leak is back." I checked rollout history first, and there
> was a revision from an hour before the first restart, which changes the
> question entirely. An OOMKill means usage crossed the limit; there are
> two ways for that to happen and only one of them is the application's
> fault. Comparing the resources block against the other four backends made
> it obvious: every other app requests 128Mi and limits 256Mi, and this one
> had been set to 20Mi for both. The process needs about 31Mi at startup, so
> it could never have worked. `rollout undo` fixed it
> directly, which is worth noting because it does *not* fix a config drift
> incident -- here the bad value was in the pod template itself. What I'd
> change: the namespace LimitRange accepted 20Mi because it sits above the
> configured minimum, and admission control only enforces bounds, not
> whether a number is sane for a given workload. Right-sizing should come
> from observed usage per workload, and it should go to one app first, not
> all of them in a sweep.

**Talking through it -- the SRE version:**

> Customer impact was nil, because the rolling update refused to remove
> healthy pods for replacements that never became Ready -- which is
> Kubernetes protecting us from our own change, not a control we designed.
> What concerns me is that we've now had two incidents with an identical
> signature and opposite causes, and our alerting cannot tell them apart.
> The restart monitor fires either way and says "pods are restarting,"
> which sends the responder down a memory-leak path that is wrong half the
> time. That's a detection-quality problem as much as a capacity problem: a
> good alert should point at the next question, and this one points at the
> wrong one. Two changes. First, the alert should carry enough context to
> branch -- if the deployment's spec changed within the alert window, say
> so in the notification, because "did the ceiling move or did usage grow"
> is answerable automatically. Second, this is the argument for treating
> resource limits as a change with a blast radius rather than as
> housekeeping: it went to a whole namespace in one sweep with no
> measurement behind the number and no canary. We spent no budget this
> time. The same sweep against ecommerce during checkout hours is an
> outage on our primary SLI, and I'd rather make that argument from a near
> miss than from a postmortem.
