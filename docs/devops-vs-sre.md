# The DevOps chair and the SRE chair

Most of this lab can be worked from either chair, and the two chairs ask
different first questions about the same incident. This doc is the bridge:
what each role owns, where an incident starts for each of them, and the one
path through Datadog that both of them walk before anyone touches
`kubectl`.

If you only read one section, read
[The path, end to end](#the-path-end-to-end). That sequence is the answer to
"walk me through an incident you handled," and it is the thing most
candidates get out of order.

## Two chairs, one incident

Titles vary by company; ownership doesn't. Ownership follows the **layer**,
not the job title.

| | DevOps engineer | SRE |
|---|---|---|
| Owns | The pipeline and the platform: build, image, manifest, config, secret, ingress, cluster | The service level: what "working" means, what it costs when it isn't, and whether detection was good enough |
| First question | "What changed?" | "How much error budget is this burning, and did we find out before customers did?" |
| Pages on | Rollouts that never went healthy, nodes, cluster capacity, the delivery path | Symptoms with user impact: error rate, p95, availability |
| Fixes with | `rollout undo`, a corrected ConfigMap/Secret/manifest, a pipeline guardrail | A rollback *decision*, a load-shedding call, then a durable fix to whatever let it through |
| Closes with | The change reverted, and a pipeline that can no longer ship that mistake | A postmortem with budget spent, a named detection gap, and one prevention item with an owner |

Where there is no SRE function at all -- which is most places advertising a
DevOps role -- the DevOps engineer wears both hats, and the second column
becomes the part of the job people forget to practise. That is exactly the
part interviewers probe.

## Where the incident starts

This is the most useful distinction in the lab, and it maps directly onto
the two families of chaos script.

**A change-driven incident** starts with something a human shipped: a config
value, a rotated credential, an ingress edit, a limit tuned to fit a quota,
a bad image tag. The clock starts at the merge, not at the alert. There is a
`rollout history` entry, a commit, or a pipeline run with a timestamp on it,
and the fastest fix is almost always to put it back.

- `break-config.sh`, `rotate-secret.sh`, `break-ingress.sh`,
  `shrink-limits.sh`, `bad-deploy.sh`

**A condition-driven incident** starts with the system meeting a limit
nobody moved: a slow dependency, a leak, a connection pool exhausted by a
neighbour, a traffic spike. Nothing shipped, and `rollout undo` fixes
nothing because there is nothing to undo.

- `inject-latency.sh`, `inject-errors.sh`, `memory-spike.sh`,
  `cpu-spike.sh`, `drop-db-connection.sh`, `kill-random-pod.sh`

The first branch in any real triage is deciding which of the two you're in,
and the cheapest way to decide is to check for a recent change before you
theorise about anything:

```bash
kubectl -n <app> rollout history deployment/<app>-backend
kubectl -n <app> get events --sort-by=.lastTimestamp | tail -20
```

If a rollout landed minutes before the symptom, you are almost certainly in
the first family: revert first, explain afterwards. If the last rollout was
days ago, stop hunting for a culprit change and start looking at
dependencies and saturation.

## The path, end to end

Eight steps. Both chairs walk the same first five.

### 1. Something changed, or something drifted

For change-driven incidents, write down the time and the artefact: which
Deployment, which ConfigMap, which Secret, which Ingress. That is your
timeline's first row, and you will want it in the postmortem.

### 2. You found out

Name the detector out loud, because it is the first thing an interviewer
listens for: a monitor fired, a synthetic failed, a support ticket arrived,
or a colleague asked if something was up. "A customer told us" is an
acceptable answer *once* -- and then it becomes the prevention item.

The four monitors in `datadog/monitors/` cover error rate, p95 latency,
memory saturation and pod restarts. Note what that list does **not**
include, which several scenarios here exploit: nothing pages on *Running
but not Ready*, on a rollout that stalled, or on throughput falling to
zero. See [The detection gap](#the-detection-gap).

### 3. Datadog first: how big, and who

Open the app dashboard (`datadog/dashboards/<app>.json`) and read the
golden-signal widgets in order. You are answering three questions, not
looking for a culprit yet:

- **Is it one service or several?** Several at once means a shared
  dependency or the platform, not an app.
- **Which widget moved first, and by how much?** Compare against the
  baseline you wrote down while everything was healthy.
- **Is traffic still arriving?** A drop to zero is not calm. It usually
  means requests are dying upstream of the service -- at the ALB, the
  Ingress, or DNS -- and the app never got them.

| What you see | What it usually means |
|---|---|
| p95 up, error rate flat | Slow, not failing. A dependency, a lock, or a blocked event loop |
| Error rate up, p95 flat | Failing fast. Bad config, bad credential, or a dependency refusing connections |
| Both up | Timeouts. Something hangs until it gives up |
| Throughput down, everything else flat | Requests aren't reaching this service. Look at the edge, not the app |
| Everything flat, but users say it's broken | Trust the users. Your instruments may all sit inside a service that isn't the broken one -- go look at the raw HTTP response |
| Memory climbing toward the limit | You have minutes before an `OOMKilled`, not an outage yet |

### 4. Datadog logs and events: the exact error

The dashboard tells you *that* and *how big*. Logs tell you *what*. Every
container's logs are collected (`containerCollectAll: true` in
`datadog/helm-values.yaml`) and tagged by service:

```
service:<app>-backend status:error
kube_namespace:<app> "password authentication failed"
```

Kubernetes events are collected too (`collectEvents: true`), which is what
puts probe failures, image-pull failures and kills in Datadog rather than
only in `kubectl describe`:

```
source:kubernetes kube_namespace:<app>
```

Read the actual message before forming a hypothesis. The words in it decide
your next command, and this is the step people skip when they're nervous.

### 5. The decision: does this need `kubectl` at all?

This is the step that separates a confident responder from a busy one. The
log line tells you which of several situations you're in.

| What the log or event says | What it means | What to do next |
|---|---|---|
| `password authentication failed for user "<app>_app"` | The credential in the Secret doesn't match RDS | `kubectl`: inspect the Secret, restore it, roll the Deployment |
| `Readiness probe failed: ... connection refused` | The container isn't listening where the probe is looking -- a port/config mismatch | `kubectl describe pod`, then fix the ConfigMap and roll |
| `Back-off restarting failed container` with `Reason: OOMKilled` | The process needs more memory than the limit allows | `kubectl`: did the limit move (`rollout history`), or did usage grow? |
| `Failed to pull image ... not found` | The tag doesn't exist in ECR | `kubectl rollout undo`, then fix the pipeline that shipped the tag |
| `ECONNREFUSED` / `timeout` reaching a dependency | Your pod is fine; the thing it needs isn't | Check the dependency first -- `kubectl` on your own app proves nothing |
| Nothing in the logs at all, throughput at zero | Requests never arrived | The edge: Ingress, ALB target health, DNS. Not the pod |
| `chaos: injected failure`, or latency with no errors | An injected app-level condition | `scripts/chaos/reset.sh <app>` -- no `kubectl` needed |

Two of those rows resolve without `kubectl` at all. That's the point of the
step: "restart the pod" is not triage, and an interviewer can tell the
difference immediately.

### 6. `kubectl`: confirm, don't guess

```bash
kubectl -n <app> get pods                      # read the READY column, not just STATUS
kubectl -n <app> describe pod <pod>            # events, last state, probe failures
kubectl -n <app> logs <pod> --previous         # why the last one died
kubectl -n <app> get endpoints <app>-backend   # is anything actually routable
kubectl -n <app> rollout history deployment/<app>-backend
```

`Running` and `Ready` are different facts, and the gap between them is where
most of this lab lives. `Running` means the process hasn't exited. `Ready`
means the readiness probe passed -- and only `Ready` pods are in the
Service's endpoints and behind the ALB.

### 7. Fix, and prove it

Revert first when a change caused it; diagnose afterwards from the artefacts
you already captured.

```bash
kubectl -n <app> rollout undo deployment/<app>-backend
./scripts/chaos/<script>.sh <app> --undo
./scripts/chaos/reset.sh <app>
```

Then prove it two ways, because one isn't evidence: the user action works in
the browser, **and** the widget that moved first came back down. Metrics lag
a minute or two; don't declare victory off the first data point.

### 8. Write it down

Six lines, same afternoon: detection, customer impact, diagnosis, fix,
budget burned (`error-budget.md`), one prevention item with an owner.
Blameless means you name the system and the detection gap, never the person
who merged it.

## The detection gap

Work scenario `07`, `08` or `09` and you'll notice none of the four imported
monitors fire usefully, or at all. That is deliberate, and it's the most
valuable thing in those three scenarios: the lab ships alerts for
*conditions* and none for *the delivery path*. A change-driven incident can
run for an hour with every existing monitor green.

These are the two monitors most teams add after their first incident of this
shape. They are deliberately not pre-imported -- building one of them, out
of your own postmortem's action item, is the exercise:

- **Deployment has unavailable replicas.**
  `max(last_10m):max:kubernetes_state.deployment.replicas_unavailable{env:lab} by {kube_deployment} > 0`
  Catches every stalled rollout: bad image, failed probe, OOMKill loop,
  quota-blocked surge pod. One monitor, four root causes, and it fires while
  the old pods are still serving -- before users notice anything.

- **Throughput collapsed.**
  `sum(last_5m):sum:trace.express.request.hits{env:lab} by {service}.as_count() < 1`
  Catches the failure where nothing errors because nothing arrives: a
  Deployment scaled to zero, a DNS record that disappeared, a Service with no
  endpoints. Only meaningful for a service that always has traffic.

  Be honest with students about its limits, because scenario 09 is a
  counter-example: an edge misroute does **not** collapse backend throughput
  in this lab. The ALB keeps health-checking the pods, so the graph stays up
  while every real user is broken. No metric emitted by the application can
  see a failure that happens in front of the application -- which is why the
  third item below isn't optional.

- **An external check, from outside the cluster.** Not a Datadog metric at
  all: a synthetic (or any uptime check) that requests the real public URL
  the way a customer does and asserts on what comes back. Everything else in
  this lab is instrumented *inside* one service, and scenario 09 is a total
  customer-facing outage that leaves every one of those instruments reading
  normal. Note also that this lab does not configure the Datadog AWS
  integration, so ALB metrics and target-group health are not in Datadog at
  all -- they live in the AWS console and `aws elbv2 describe-target-health`.

Both are platform-layer alerts on the delivery path, which is the DevOps half
of the pager. Neither replaces the four symptom monitors, which are the SRE
half.

## Two ways to tell the same incident

Same outage, two chairs. Both are correct; they answer different questions.
Practise whichever matches the job you're interviewing for, and be able to
gesture at the other.

**The DevOps version** -- ownership of the delivery path:

> A config change merged at 15:40 and the rollout went out at 15:52. The new
> pods came up Running but never Ready, and the rollout stalled with the old
> ReplicaSet still serving, so nothing broke for users yet. I looked at the
> Datadog event stream for that namespace first and saw repeated readiness
> probe failures with connection refused, which told me the container wasn't
> listening where the probe was looking, rather than the app being down.
> `describe pod` confirmed it, and diffing the ConfigMap against the previous
> revision showed the port had changed. I reverted the ConfigMap and rolled
> the Deployment; pods went Ready in about ninety seconds. The real fix was
> upstream of the incident: nothing in our pipeline checks that a rollout
> actually became healthy, so a change that can never become Ready still
> reports success. I added a `rollout status --timeout` gate and an alert on
> unavailable replicas. And we only caught it before customers because the
> old pods held -- that's luck, not design.

**The SRE version** -- ownership of the service level:

> We were one node recycle away from a full outage for about twenty minutes
> and we didn't know it, which is the part I care about. Customer impact was
> zero: p95 and error rate never moved, because the old ReplicaSet kept
> serving the whole time, so we spent no error budget. Every one of our four
> monitors stayed green through the entire window. That's the finding. Our
> alerting is built on symptoms -- error rate, p95, saturation, restarts --
> and symptom alerts are the right default, but they're blind to a service
> running on half its intended capacity with no way to replace a pod. So the
> action item wasn't another symptom alert, it was one platform alert on
> unavailable replicas, plus a change to what we let "deploy succeeded"
> mean. If the same change had gone out during a scale-up event, that
> twenty-minute window is an outage and a serious chunk of the monthly
> budget instead of a near miss.

Notice what the SRE version does *not* do: it doesn't re-tell the diagnosis.
It takes the same facts and answers "what did it cost, what would have caught
it, and what do we change." If you can deliver both versions of one incident,
you're ready for either interview.

## Which scenario trains which

| Scenario | Starts with | DevOps skill | SRE skill |
|---|---|---|---|
| 01 The Silent Checkout | A condition | -- | Latency vs errors as separate signals; p95 over average |
| 02 Payday Panic | A condition | Readiness vs liveness, endpoint membership | Why a dependency check belongs in readiness |
| 03 The Stuck Order | A condition | Scoping to one component | Cache outage as degradation, not failure |
| 04 Grades Gone Missing | A change | `ImagePullBackOff`, `rollout undo`, RollingUpdate safety | Why partial beats total, and what it hides |
| 05 The Midnight Memory Leak | A condition | Restart counts, `describe pod` | Self-resolving incidents still need a writeup |
| 06 The Noisy Neighbor | A condition | Shared-resource diagnosis from inside the cluster | Blast radius of a shared dependency |
| 07 The 4 PM Config Change | A change | Config drift, stalled rollouts, probe failures | The near miss that spent no budget and should still change something |
| 08 The Rotated Password | A change | State drift between two systems of record | Running vs Ready, and partial capacity as silent risk |
| 09 Green Dashboards, Angry Customers | A change | Edge routing, ALB target health, `describe ingress` | Detection that ends at the app boundary instead of at the user |
| 10 The Tightened Limit | A change | Limits vs requests, quotas, `rollout history` | Same symptom, different cause: OOMKill from a ceiling that moved |

## Further reading

- [student-guide.md](student-guide.md) -- the full walkthrough, including the
  DevOps track in section 7
- [runbooks/failed-rollout.md](runbooks/failed-rollout.md) -- the runbook for
  scenarios 04, 07 and 10
- [runbooks/config-and-secret-drift.md](runbooks/config-and-secret-drift.md)
  -- the runbook for scenarios 07 and 08
- [runbooks/ingress-502s.md](runbooks/ingress-502s.md) -- the runbook for
  scenario 09
- [error-budget.md](error-budget.md) -- the arithmetic the SRE version of
  every story ends with
