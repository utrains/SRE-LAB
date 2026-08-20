# Testing the Lab

A working checklist for exercising every failure mode in this lab, whether
you're validating a fresh deployment before a class or practising the
on-call loop yourself.

There are **12 injectable failure modes** (13 scripts in `scripts/chaos/`,
one of which -- `reset.sh` -- is the undo tool) and **10 scripted incident
scenarios** in `docs/incident-scenarios/` that wrap them in a story.

Substitute your own domain for `afriqhome.com` throughout, or read it from
`.lab-domain`:

```bash
DOM=$(cat .lab-domain)
```

---

## Part 1 -- Is the platform actually working?

Do this before any chaos. If something here fails, no scenario below will
teach what it's supposed to.

### 1.1 The cluster and the apps

```bash
kubectl config current-context      # must be the sre-lab EKS cluster
kubectl get pods -A                 # every app pod 1/1 Running
kubectl get hpa -A                  # cpu: N%/70%  -- never <unknown>
kubectl top pods -n ecommerce       # proves metrics-server is serving

for a in ecommerce banking food-delivery student-portal support-tickets; do
  curl -s -o /dev/null -w "%{http_code}  $a\n" "https://$a.$(cat .lab-domain)/"
done                                # five 200s
```

> If `kubectl` reports namespaces you don't recognise, Docker Desktop has
> rewritten your context. Fix with
> `aws eks update-kubeconfig --name sre-lab --region us-east-1`.

### 1.2 One real user action per app

Traces only exist if somebody uses the app. In a browser:

| App | Action | Login |
|---|---|---|
| ecommerce | Add to cart, check out | -- |
| banking | Log in, check a balance | password `demo123` |
| food-delivery | Place an order | -- |
| student-portal | View grades | password `demo123` |
| support-tickets | File a ticket | -- |

### 1.3 The observability wiring

In Datadog, confirm all four signals. This is the step people skip, and
it's the one that decides whether the rest of the lab teaches anything.

| Check | Where | What good looks like |
|---|---|---|
| **Traces** | APM > Traces, `service:ecommerce-backend` | A trace spanning **browser -> backend -> Postgres**. If it starts at the backend, RUM didn't load -- check `window.DD_RUM` in the browser console |
| **Logs** | Logs, `service:ecommerce-backend` | Request logs, with `dd.trace_id` injected |
| **Events** | Events, `source:kubernetes kube_namespace:ecommerce` | Kubernetes events present -- this is where probe failures and OOMKills appear later |
| **Metrics** | Dashboards > `SRE Lab - ecommerce` | All six widgets populated |

### 1.4 Write down the baseline

Per app, from its dashboard, while everything is healthy:

| Signal | Value |
|---|---|
| Traffic (req/s) | ______ |
| Error rate (%) | ______ |
| p95 latency (ms) | ______ |
| Memory vs the 256Mi limit | ______ |
| Restart count | ______ |

You cannot answer *"which widget moved first, and by how much?"* without
this, and that is the graded question in every scenario.

---

## Part 2 -- The experiment loop

The same six steps work for all 12 failure modes. The order is the skill.

```bash
# 1. BASELINE
kubectl get pods -n <app>
#    ...and look at the dashboard. Not after. Before.

# 2. INJECT
./scripts/chaos/<script>.sh <app>

# 3. DATADOG FIRST  -- how big, and who?
#    logs:   service:<app>-backend status:error
#    events: source:kubernetes kube_namespace:<app>

# 4. CONFIRM AS A CUSTOMER
curl -s -o /dev/null -w "%{http_code}\n" "https://<app>.$(cat .lab-domain)/"

# 5. ONLY NOW kubectl
kubectl -n <app> get pods                       # READY column, not just STATUS
kubectl -n <app> describe pod <newest-pod>      # read the Events block
kubectl -n <app> logs <newest-pod>
kubectl -n <app> rollout history deployment/<app>-backend

# 6. UNDO, AND PROVE IT
./scripts/chaos/reset.sh <app>          # Family A
./scripts/chaos/<script>.sh <app> --undo # Family C
#    then re-check the widget that moved first, and the app in a browser
```

Handy shell helper for step 5:

```bash
newest() { kubectl -n "$1" get pods -l "app=$1-backend" \
  --sort-by=.metadata.creationTimestamp -o name | tail -1; }
# usage: kubectl -n banking describe $(newest banking)
```

**If you opened a terminal before you opened a dashboard, you skipped the
exercise.**

---

## Part 3 -- The 12 failure modes

### Family A: in-app conditions (5)

Toggled over HTTP against a live pod -- no redeploy, no restart.
`reset.sh` clears all of them.

Two things to know before you start:

- Every backend runs **2 replicas**, and the script's single `curl` goes
  through the ALB to **one random pod**. Partial effects are by design, not
  a bug. To hit a specific pod, `kubectl port-forward` to it and POST to
  `/api/chaos/*` directly.
- `reset.sh` **cannot clear a db-drop**: that pod already failed readiness
  and left the Service, so the reset lands on a healthy one. Reset it
  directly (command in A5).

#### A1. `inject-latency.sh <app> [ms]` -- default 3000

```bash
./scripts/chaos/inject-latency.sh ecommerce 4000
```

- **Expect:** p95 climbs hard; **error rate stays flat**; average barely moves.
- **Datadog:** the p95 widget. Compare it against the average deliberately.
- **Confirm:** `curl https://ecommerce.$DOM/api/chaos` shows `latencyMs: 4000`.
- **Undo:** `./scripts/chaos/reset.sh ecommerce`
- **Teaching point:** slow is not failing. An error-rate monitor never fires
  here, which is why latency needs its own alert.

#### A2. `inject-errors.sh <app> [rate 0-1]` -- default 0.5

```bash
./scripts/chaos/inject-errors.sh banking 0.3
```

- **Expect:** error rate jumps; traces flagged as errors; 5xx in the logs.
- **Datadog:** `service:banking-backend status:error`.
- **Undo:** `./scripts/chaos/reset.sh banking`
- **Teaching point:** errors and latency are two different signals with two
  different responses. Don't collapse them into "it's broken".

#### A3. `memory-spike.sh <app> [mb]` -- default 300

```bash
./scripts/chaos/memory-spike.sh support-tickets 300
```

- **Expect:** memory climbs toward the 256Mi limit, then a real `OOMKilled`
  and a restart. It then looks fine again -- **self-healing**.
- **Check:** `kubectl -n support-tickets describe pod <pod> | grep -A5 "Last State"`
  -> `Reason: OOMKilled`.
- **Undo:** nothing to do; the restart cleared the in-memory state.
- **Teaching point:** self-resolving incidents are the ones most likely to
  be waved off. The memory-saturation monitor exists to fire *before* the
  kill, not after.

#### A4. `cpu-spike.sh <app> [seconds]` -- default 10

```bash
kubectl -n ecommerce get hpa -w     # in a second terminal
./scripts/chaos/cpu-spike.sh ecommerce 60
```

- **Expect:** latency spikes across every endpoint that pod serves, and the
  **HPA scales out** past 2 replicas.
- **Undo:** ends by itself; the HPA scales back down after its cooldown.
- **Teaching point:** saturation shows up as latency everywhere, not as
  errors on one endpoint.

#### A5. `drop-db-connection.sh <app>`

```bash
./scripts/chaos/drop-db-connection.sh student-portal
```

- **Expect:** `/readyz` returns 503, the pod goes `NotReady` after ~30s
  (3 x 10s), and **leaves the Service**. `/healthz` stays 200 the whole time.
- **Datadog:** `service:student-portal-backend status:error` shows
  `readiness check failed: db connection dropped (chaos)`.
- **Check the difference yourself:**
  ```bash
  kubectl -n student-portal port-forward <pod> 14000:4000
  curl -s localhost:14000/healthz   # 200 -- process is alive
  curl -s localhost:14000/readyz    # 503 + the reason
  ```
- **Undo:**
  ```bash
  kubectl exec -n student-portal <pod> -- node -e \
    "require('http').request({host:'localhost',port:4000,path:'/api/chaos/reset',method:'POST'}).end()"
  ```
- **Teaching point:** the single most-asked interview question -- *"a pod
  says Running but users report errors"*. Liveness and readiness gate
  different things, which is why the app has two endpoints.

### Family B: Kubernetes-level conditions (2)

#### B1. `kill-random-pod.sh <namespace>`

```bash
./scripts/chaos/kill-random-pod.sh banking
```

- **Expect:** restart count +1, a brief blip if you're watching closely.
- **Undo:** self-heals -- the Deployment reschedules immediately.
- **Teaching point:** alert on restart *count over a window*, not on a
  single restart.

#### B2. `scale-to-zero.sh <namespace> <deployment>`

```bash
./scripts/chaos/scale-to-zero.sh support-tickets support-tickets-frontend
```

- **Expect:** full outage; the ALB returns 503 with no targets at all.
- **Undo:** `kubectl -n support-tickets scale deployment/support-tickets-frontend --replicas=2`
- **Teaching point:** compare this 503 with case C4's 404 -- an empty target
  group and an unhealthy one behave differently.

### Family C: change-driven -- the DevOps set (5)

Somebody shipped something. These are deliberately quiet: in most of them
**customers stay fine** while the service silently loses its ability to heal.
All except `bad-deploy.sh` revert with `--undo`.

#### C1. `bad-deploy.sh <ns> <deployment> <container>`

```bash
./scripts/chaos/bad-deploy.sh student-portal student-portal-backend student-portal-backend
```

- **Expect:** new pods `ImagePullBackOff`, old pods still serving -> an
  *intermittent* symptom, not an outage.
- **Check:** `kubectl -n student-portal describe pod <new>` -> `Failed to pull image`.
- **Undo:** `kubectl -n student-portal rollout undo deployment/student-portal-backend`
- **Teaching point:** the partial outage is `RollingUpdate` doing its job.

#### C2. `break-config.sh <app>`

```bash
./scripts/chaos/break-config.sh banking     # then wait ~90s
```

- **Expect:** one new pod never becomes Ready, then CrashLoops; the rollout
  stalls; **the app keeps returning 200** from the old pods.
- **Check:**
  ```bash
  kubectl -n banking describe $(newest banking) | tail -8   # connection refused on :4000
  kubectl -n banking logs $(newest banking)                 # "listening on 4001"
  ```
- **Undo:** `./scripts/chaos/break-config.sh banking --undo`
- **Teaching point:** `kubectl rollout undo` does **not** fix this -- the pod
  template never changed, only the ConfigMap it references. Also: env vars
  are read at container start, so the ConfigMap edit did nothing until
  something restarted.

#### C3. `rotate-secret.sh <app>`

```bash
./scripts/chaos/rotate-secret.sh ecommerce
```

- **Expect:** new pod `Running` but `0/1`, with **zero restarts** -- the
  absence of restarts is itself the clue. No monitor fires.
- **Datadog:** `service:ecommerce-backend status:error` ->
  `readiness check failed: password authentication failed for user "ecommerce_app"`.
- **Check:** `kubectl -n ecommerce get endpoints ecommerce-backend` lists 2
  addresses, not 3.
- **Undo:** `./scripts/chaos/rotate-secret.sh ecommerce --undo`
- **Teaching point:** the working credential now exists only in the memory
  of two pods that can't be replaced. Zero customer impact, high urgency.

#### C4. `break-ingress.sh <app>`

```bash
./scripts/chaos/break-ingress.sh food-delivery   # allow 1-2 min to reconcile
```

- **Expect:** a **404 from the backend**, not a gateway error:
  ```bash
  curl -i https://food-delivery.$DOM/ | head -12    # X-Powered-By: Express
  curl -o /dev/null -w "%{http_code}\n" https://food-delivery.$DOM/api/restaurants  # 200
  ```
- **Every dashboard stays green**, and backend throughput *rises* (the ALB
  health-checks it). Target health lives in AWS, not Datadog:
  ```bash
  aws elbv2 describe-target-health --region us-east-1 --target-group-arn <arn>
  ```
- **Undo:** `./scripts/chaos/break-ingress.sh food-delivery --undo`
- **Teaching point:** the best one in the lab. A total customer-facing
  outage with a fully green monitoring stack, because every instrument sits
  *inside* a service that isn't the broken one. An ALB with no healthy
  targets **fails open** rather than returning 503.

#### C5. `shrink-limits.sh <app> [mi]` -- default 20

```bash
./scripts/chaos/shrink-limits.sh support-tickets
```

- **Expect:** new pods `OOMKilled` during startup (exit 137) ->
  `CrashLoopBackOff`; old pods keep serving.
- **Check:** `kubectl -n support-tickets rollout history deployment/support-tickets-backend`
  and compare the resources block against another app's.
- **Undo:** `./scripts/chaos/shrink-limits.sh support-tickets --undo`
- **Teaching point:** identical symptom to A3, opposite cause -- nothing
  leaked, the ceiling moved. `rollout undo` **does** work here (the pod
  template changed), unlike C2 and C3. Being able to explain that
  difference is worth more than the fix.

---

## Part 4 -- The 10 scenarios

Each scenario wraps one or more of the above in a briefing with no answer
attached. Work them without reading
`docs/incident-scenarios/instructor-answer-keys.md` first.

| # | Scenario | App | Starts with | Uses |
|---|---|---|---|---|
| 01 | The Silent Checkout | ecommerce | condition | A1 + A2 |
| 02 | Payday Panic | banking | condition | A5 |
| 03 | The Stuck Order | food-delivery | condition | Redis scaled to 0 |
| 04 | Grades Gone Missing | student-portal | **change** | C1 |
| 05 | The Midnight Memory Leak | support-tickets | condition | A3 |
| 06 | The Noisy Neighbor | ecommerce + banking | condition | manual `pg_sleep` (no script) |
| 07 | The 4 PM Config Change | banking | **change** | C2 |
| 08 | The Rotated Password | ecommerce | **change** | C3 |
| 09 | Green Dashboards, Angry Customers | food-delivery | **change** | C4 |
| 10 | The Tightened Limit | support-tickets | **change** | C5 |

The answer key gives each one a **DevOps walkthrough** and an **SRE
walkthrough** -- see [devops-vs-sre.md](devops-vs-sre.md).

---

## Part 5 -- A suggested running order

Roughly 20-30 minutes each with discussion.

| Order | Run | Why here |
|---|---|---|
| 1 | A1 on support-tickets | Simplest app, cleanest signal; teaches p95 vs average immediately |
| 2 | A5 on banking | Running vs Ready -- the most-asked interview question |
| 3 | A3 on support-tickets | Self-healing incident; sets up the contrast for #5 |
| 4 | C2 on banking | First change-driven one: "what changed?" before "what's broken?" |
| 5 | C5 on support-tickets | Same OOMKill as #3, opposite cause. The contrast is the lesson |
| 6 | C4 on food-delivery | Finish here: total outage, every dashboard green |

Then have each student tell one incident from **both chairs** -- once as the
DevOps engineer who owns the delivery path, once as the SRE who owns the
service level.

---

## Part 6 -- Between runs, and at the end

```bash
# clear in-app state (Family A)
./scripts/chaos/reset.sh <app>

# revert a change-driven fault (Family C)
./scripts/chaos/<script>.sh <app> --undo

# confirm you're clean before the next scenario
kubectl get pods -A | grep -v Running
ls .chaos-backup/ 2>/dev/null      # empty means nothing is still injected
```

When you're done for the day -- the lab costs real money:

```bash
./scripts/teardown.sh
```

Then check the AWS console for anything orphaned; the exact checklist
prints at the end of the script.

---

## Quick troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| A chaos script "does nothing" | It hit one of 2 replicas | Expected. `port-forward` to a specific pod to be deterministic |
| `reset.sh` won't clear a db-drop | That pod left the Service | Reset it directly via `kubectl exec` (see A5) |
| Traces start at the backend | RUM missing from the bundle | Check `window.DD_RUM`; re-run `setup.sh` (see README troubleshooting) |
| HPA shows `<unknown>` | metrics-server missing | `setup.sh` step 9 installs it |
| `kubectl` hits the wrong cluster | Docker Desktop rewrote the context | `aws eks update-kubeconfig --name sre-lab --region us-east-1` |
| A monitor on `kubernetes_state.*{env:lab}` has no data | Cluster metrics need the global tag | Already set via `datadog.tags` in `datadog/helm-values.yaml` |

Full list in [README.md](../README.md#troubleshooting).
