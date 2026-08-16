# Instructor Answer Keys

**Do not share this file with students before they've attempted the
exercises in `docs/incident-scenarios/`.** Each section below gives the
exact setup command to trigger the incident, the expected diagnosis path,
the fix, and what to listen for in the student's postmortem.

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
