# Student Guide

Welcome to the lab. You'll deploy five real applications to a shared
Kubernetes cluster, wire up your own Datadog account to observe them, then
deliberately break things and practice diagnosing and fixing them like an
on-call engineer would.

Two kinds of engineer answer that pager, and this lab trains both. The
**DevOps** half is the delivery path: a change shipped, something stopped
being healthy, and you work back from "what changed" through Datadog to
`kubectl` and a rollback. The **SRE** half is the service level: what the
incident cost against an error budget, whether detection was good enough,
and what to change so the next one is cheaper. Read
[devops-vs-sre.md](devops-vs-sre.md) before section 7 -- it lays out the
whole path end to end and is the single most interview-relevant document
here.

## 1. Prerequisites

- `terraform`, `aws` CLI (configured with credentials for the lab AWS
  account), `kubectl`, `docker`, `helm`, and `jq` installed locally.
- A GitHub/email account to sign up for Datadog with.

## 2. Create your own Datadog account

Each student uses their **own** free Datadog trial -- there is no shared
account, and nothing in this repo contains a real API key.

1. Go to [datadoghq.com](https://www.datadoghq.com/) and start a free
   trial.
2. Once logged in, go to **Organization Settings > API Keys** and copy
   your **API key** -- this is required.
3. Go to **Organization Settings > Application Keys** and copy your
   **Application key** too -- optional, but without it `setup.sh` installs
   the Agent (metrics/APM/logs all work) and skips browser monitoring
   (RUM) and the dashboard/monitor import in step 3 below.
4. Note your org's **site** -- look at the URL once you're logged in, it's
   the `<site>` part of `app.<site>` (e.g. `us5.datadoghq.com`,
   `datadoghq.eu`, `ap1.datadoghq.com`). Trials aren't all on the same
   site; getting this wrong is the classic failure mode here -- the agent
   pods still come up `Running` but silently fail to authenticate, and
   nothing ever shows up in your dashboard, so double check it.

## 3. Deploy the lab

From the repo root:

```bash
DATADOG_API_KEY=<your-datadog-api-key> \
DATADOG_APP_KEY=<your-datadog-app-key> \
DATADOG_SITE=<your-site, default datadoghq.com> \
  ./scripts/setup.sh
```

This runs `terraform apply`, configures `kubectl`, and -- since both
`DATADOG_API_KEY` and `DATADOG_APP_KEY` are set -- provisions a Datadog RUM
application per app before building anything. It then builds and pushes
all 10 container images to ECR (each frontend's image has its RUM config
baked in at build time), provisions a database + least-privilege user per
app on the shared RDS instance, deploys every app, installs the AWS Load
Balancer Controller, installs the Datadog Agent, and imports every
dashboard/monitor. Expect this to take 15-20 minutes, mostly waiting on the
EKS cluster and ALB to come up.

You can omit all three `DATADOG_*` variables to skip Datadog (Agent, RUM,
dashboards/monitors) entirely for now and install it later by re-running
this exact command with them set -- everything else in the script is safe
to re-run. Once it finishes, confirm in the Datadog UI: go to **APM >
Traces** and browse one of the apps (e.g. add a product to your ecommerce
cart) -- you should see a trace appear within a few seconds. With just
`DATADOG_API_KEY` set, that trace starts at the backend (`backend ->
Postgres`); with `DATADOG_APP_KEY` also set, RUM is wired up too, so the
same trace now starts in your browser and spans all the way through --
`frontend -> backend -> Postgres` -- because each frontend proxies its own
`/api/*` calls same-origin (see `docs/architecture.md#observability-datadog`
for how that connection actually works). If you provided an app key, also
check **Dashboards > Dashboard List** for the 6 imported dashboards,
**Monitors > Manage Monitors** for the 4 imported monitors, and **Digital
Experience > RUM Applications** for the 5 provisioned RUM apps
(`sre-lab-<app>`).

**If your traces start at the backend and the browser span is missing**,
RUM didn't make it into the frontend bundle. It's baked in at build time,
so this is decided when the image is built, not at runtime. Check it from
the browser console on any app page:

```js
window.DD_RUM            // undefined means the bundle has no RUM config
window.DD_RUM.getInitConfiguration()   // applicationId, service, site
```

If it's undefined, re-run `setup.sh` with `DATADOG_APP_KEY` set once to
provision the RUM applications. From then on the ids and client tokens are
cached in `.rum-apps.json` at the repo root (gitignored), so later runs
*without* the app key still build the frontends with RUM -- which matters,
because the note below recommends omitting the app key on re-runs to avoid
duplicating dashboards.

Re-running with a new `DATADOG_API_KEY` (e.g. switching accounts) is safe
-- the script restarts the Agent pods so they pick up the new key, and RUM
provisioning reuses each app's existing RUM application by name rather
than creating a duplicate. Monitor import is also safe to re-run --
it updates each existing monitor by name rather than erroring on a
duplicate. **Dashboard import is the one exception**: the Datadog API has
no update-by-name for dashboards, so re-running creates a fresh duplicate
of all 6 every time -- only pass `DATADOG_APP_KEY` on the run(s) where you
actually want (re-)import to happen, and manually delete old dashboard
copies from **Dashboards > Dashboard List** if you've re-run with it set
more than once.

## 4. Point your browser at the apps

All five apps share one ALB (routed by hostname). There's no manual DNS or
hosts-file step: each app's URL is a real Route 53 subdomain
(`<app>.<your-domain>`, where `<your-domain>` is whatever you set
`dns_zone_name` to in `terraform/terraform.tfvars` -- see
[terraform/terraform.tfvars.example](../terraform/terraform.tfvars.example)),
aliased to the ALB. `setup.sh` creates these DNS records itself once the ALB
is up, so the URLs work immediately, no copying an IP or editing anything
locally.

That domain suffix is also written to `.lab-domain` in the repo root, which
the chaos scripts under `scripts/chaos/` read automatically:

```bash
cat .lab-domain
# or build a specific app's URL directly:
echo "https://ecommerce.$(cat .lab-domain)"
```

Now visit each app in your browser (substituting your own domain). Each one
is served over HTTPS with a real, browser-trusted certificate (a wildcard
ACM cert that `setup.sh` finds, or requests and DNS-validates for you on a
first run -- no extra step or warning to click through), and plain HTTP
requests redirect to HTTPS automatically:

- https://ecommerce.\<your-domain\>
- https://banking.\<your-domain\>
- https://food-delivery.\<your-domain\>
- https://student-portal.\<your-domain\>
- https://support-tickets.\<your-domain\>

Demo login credentials (banking and student-portal) use password
`demo123` -- see each app's `sql/init.sql` for the exact usernames.

## 5. Reading dashboards and monitors like an on-call engineer

Before breaking anything, it's worth knowing what you're actually looking
at -- both the dashboard widgets and the monitors that watch them exist to
answer specific questions, not just to look busy.

### Dashboards: the four golden signals

Every app's dashboard (`datadog/dashboards/<app>.json`) and the `SRE Lab
Overview` dashboard are built around the same four questions, in the same
order, every time -- this is deliberate, and it's the same structure you'll
see on a real team's service dashboard:

| Widget | Golden signal | The question it answers | What "look closer" means |
|---|---|---|---|
| Request Throughput | Traffic | How much load is this service under right now? | A sudden drop can mean upstream is failing before requests even arrive here -- don't assume quiet means healthy |
| Error Rate | Errors | What fraction of requests are failing? | Any sustained rise above baseline, even before it trips a monitor |
| p95 Latency | Latency | How slow is the slowest-but-typical request? | p95, not average -- a slow tail is invisible in an average but very visible to real users |
| Pod Memory Usage | Saturation | How close is this service to its resource ceiling? | Climbing steadily toward the container limit (256Mi for backends -- see `apps/<app>/k8s/deployment-backend.yaml`) predicts an `OOMKilled` before it happens |
| Pod Restarts | Saturation (crash proxy) | Is something crash-looping? | Any nonzero count outside a deploy window |
| Recent Error Logs | (qualitative) | What do the errors actually say? | The other five widgets tell you *that* something's wrong; this one starts telling you *what* |

Traffic and Errors together are also how you tell "nobody's using it" apart
from "everybody's getting errors" -- two very different situations that a
single "error rate" number alone can't distinguish (5 errors out of 5
requests reads identically to 5 errors out of 5,000 unless you also look at
throughput).

### Monitors: states, not just alerts

Each of the 4 monitors (`datadog/monitors/*.json`) lives in one of four
states in **Monitors > Manage Monitors**:

- **OK** (green) -- the query is below its warning threshold.
- **Warn** (yellow) -- past the warning threshold, not yet critical. This is
  your early signal: something is trending wrong before it's actually
  breaking anything.
- **Alert** (red) -- past the critical threshold. This is the one that
  should page someone.
- **No Data** (gray) -- the underlying metric hasn't reported recently,
  which is its own signal (an app that's stopped emitting metrics entirely
  is at least as concerning as one reporting bad ones).

Clicking into a monitor shows its state history -- useful for exactly the
question "did this just start, or has it been flapping for an hour?" that
you'll need an answer to before writing a postmortem.

### Logs and events: what the dashboard can't tell you

Dashboards tell you *that* something is wrong and *how big*. The exact
reason lives in two other places, and several incidents in this lab can
only be solved from them:

| Where | Query | What it gives you |
|---|---|---|
| **Logs** | `service:<app>-backend status:error` | The application's own error text -- a failed query, a rejected credential, a stack trace. Every container's logs are collected (`containerCollectAll` in `datadog/helm-values.yaml`) |
| **Logs** | `kube_namespace:<app> "password authentication failed"` | Free-text search across everything in one namespace, for when you know the phrase but not the service |
| **Events** | `source:kubernetes kube_namespace:<app>` | What *Kubernetes* thinks: probe failures, `OOMKilled`, `BackOff`, image pull errors, evictions. These are never in application logs, and are collected because `collectEvents` is enabled |

A pod that fails its readiness probe is pulled out of the Service and stops
receiving traffic, so it stops producing normal logs too -- which is why
each backend logs `readiness check failed: <reason>` explicitly
(`apps/<app>/backend/src/index.js`). That one line is often the entire
diagnosis.

The habit to build: dashboard to size it, logs or events to name it, and
only then a terminal. See
[devops-vs-sre.md](devops-vs-sre.md#5-the-decision-does-this-need-kubectl-at-all)
for the table that maps a log line to the command that should follow it.

None of the 4 thresholds here are arbitrary round numbers -- each is tied to
something concrete:

| Monitor | Warning | Critical | Tied to |
|---|---|---|---|
| `high-latency-p95` | 500ms | 1000ms (2x) | Warning fires exactly at ecommerce's checkout SLO from `docs/slo-sla-sli.md` ("99.5% of checkout requests complete in under 500ms") -- you get warned right at the line, before you're in breach |
| `high-error-rate` | 1% | 5% | Well inside the 0.5-5% error budgets defined per app in `docs/slo-sla-sli.md`, so a warning fires while there's still budget left to react with |
| `memory-saturation` | 180MB | 220MB | Backend containers are limited to 256Mi (`apps/<app>/k8s/deployment-backend.yaml`) -- 220MB is close enough to that ceiling that an `OOMKilled` is imminent, not hypothetical |
| `pod-restarts` | 1 in 5 minutes | 2+ in 5 minutes | One restart could be anything; two in five minutes is the actual signature of a crash loop |

This is the habit worth building: a threshold should always be able to
answer "why here and not somewhere else," the same way each row above can.

## 6. Chaos script quick reference

Run these from the repo root. `<app>` is one of `ecommerce`, `banking`,
`food-delivery`, `student-portal`, `support-tickets` -- also the namespace
name and the deployment prefix (`<app>-backend`), which is why it's repeated
in the `scale-to-zero`/`bad-deploy` syntax below. See
[README.md](../README.md#breaking-things-on-purpose) for what each failure
mode actually does and how to observe it.

| Script | Syntax | Example |
|---|---|---|
| `inject-latency.sh` | `<app> [ms]` | `./scripts/chaos/inject-latency.sh ecommerce 3000` |
| `inject-errors.sh` | `<app> [rate 0-1]` | `./scripts/chaos/inject-errors.sh banking 0.5` |
| `memory-spike.sh` | `<app> [mb]` | `./scripts/chaos/memory-spike.sh support-tickets 300` |
| `cpu-spike.sh` | `<app> [seconds]` | `./scripts/chaos/cpu-spike.sh food-delivery 10` |
| `drop-db-connection.sh` | `<app>` | `./scripts/chaos/drop-db-connection.sh student-portal` |
| `kill-random-pod.sh` | `<namespace>` | `./scripts/chaos/kill-random-pod.sh banking` |
| `scale-to-zero.sh` | `<namespace> <deployment>` | `./scripts/chaos/scale-to-zero.sh support-tickets support-tickets-backend` |
| `bad-deploy.sh` | `<namespace> <deployment> <container>` | `./scripts/chaos/bad-deploy.sh banking banking-backend banking-backend` |
| `break-config.sh` | `<app> [--undo]` | `./scripts/chaos/break-config.sh banking` |
| `rotate-secret.sh` | `<app> [--undo]` | `./scripts/chaos/rotate-secret.sh ecommerce` |
| `break-ingress.sh` | `<app> [--undo]` | `./scripts/chaos/break-ingress.sh food-delivery` |
| `shrink-limits.sh` | `<app> [mi] [--undo]` | `./scripts/chaos/shrink-limits.sh support-tickets` |
| `reset.sh` | `<app>` | `./scripts/chaos/reset.sh ecommerce` |

Each script prints its own reset/rollback command after it runs, so you
don't need to memorize the undo step. Note `scale-to-zero` and `bad-deploy`
aren't undone by `reset.sh` -- each one prints the exact `kubectl` command
to revert it instead.

The bottom four are different in kind from the rest, and it's worth knowing
why before you run them. The first five inject a *condition* into a running
pod over HTTP: nothing is deployed, nothing changes on disk, and
`reset.sh` clears them. The last four make a real **change** to the
cluster -- a ConfigMap, a Secret, an Ingress, a Deployment's resources --
exactly the way a person or a pipeline would, and then let the consequence
play out. They each take `--undo` rather than being cleared by `reset.sh`,
because some of them (notably `rotate-secret.sh`) overwrite the only copy
of a value that exists in the cluster; the original is saved to
`.chaos-backup/` so `--undo` can put it back.

That distinction is the same one incidents have in real life, and
[devops-vs-sre.md](devops-vs-sre.md#where-the-incident-starts) explains why
your first triage question should be which of the two you're looking at.

## 7. Task list

Work through these roughly in order. Take notes as you go -- you'll need
them for the postmortems.

1. **Deploy.** Complete steps 2-4 above. Confirm all five apps load and
   you can complete one real user action in each (add to cart and check
   out in ecommerce, log in and check a balance in banking, place an
   order in food-delivery, view grades in student-portal, file a ticket
   in support-tickets).
2. **Observe baseline.** Open each app's Datadog dashboard
   (`datadog/dashboards/<app>.json`) and the `SRE Lab Overview` dashboard
   with everything healthy, reading each widget per section 5 above. This is
   what "normal" looks like -- you'll need it for comparison later. Also
   open **Monitors > Manage Monitors** once while everything's OK, so you
   know what the non-alerting state actually looks like.
3. **Break something.** Pick an incident from `docs/incident-scenarios/`
   (or ask your instructor to trigger one) without reading the answer
   key -- e.g. `01-the-silent-checkout.md` is an ecommerce latency problem
   tied to `docs/runbooks/high-latency.md`. There are ten, in two families:

   - **01-06 are condition-driven.** Nothing shipped; the system met a
     limit nobody moved. Symptoms are loud -- latency, errors, restarts --
     and the monitors generally catch them.
   - **07-10 are change-driven.** Somebody shipped a config value, a
     rotated credential, an ingress edit, or a resource limit. These are
     the ones a DevOps engineer meets most, and they are deliberately
     quiet: in several of them, customer impact is zero and no monitor
     fires usefully. Finding them means starting from `rollout history`
     and the Kubernetes events, not from the dashboard.

   Do at least one of each before you say you've done the lab.
4. **Observe in Datadog.** Find the incident in your dashboards before
   you go looking at `kubectl` -- which widget moved first, and by how
   much?
5. **Diagnose.** Use the relevant runbook in `docs/runbooks/` if you get
   stuck, but try the diagnostic commands yourself first.
6. **Fix it**, then confirm recovery in both the app itself and the
   Datadog dashboard (metrics take a minute or two to reflect the fix).
7. **Write a postmortem** for the incident: what broke, how you found it,
   how you fixed it, how much error budget it burned (see
   `docs/error-budget.md` for the calculation method), and one concrete
   prevention step.
8. **Tell it from both chairs.** Give the walkthrough as the DevOps
   engineer who owns the delivery path, then again as the SRE who owns the
   service level -- see
   [devops-vs-sre.md](devops-vs-sre.md#two-ways-to-tell-the-same-incident)
   for a worked pair. The second version is the hard one on scenarios
   07-10, where customer impact is often zero and you still have to explain
   why the incident mattered. Ninety seconds each, out loud, from memory.
9. **Repeat** with a different incident scenario, then try triggering one
   yourself directly with the scripts in `scripts/chaos/` and writing your
   own scenario for a classmate.
10. **Close the detection gap you found.** Scenarios 07-10 each expose
    something none of the four imported monitors can see. Build one monitor
    that would have caught your incident (there are two ready-made queries
    in [devops-vs-sre.md](devops-vs-sre.md#the-detection-gap)), then
    re-trigger the same fault and confirm it actually fires. An alert you
    have watched fire is worth ten you have only written.

## 8. Tear down

When you're done, avoid leaving the lab running (it costs real money):

```bash
./scripts/teardown.sh
```

Then double-check the AWS console for anything orphaned (see the output
of `teardown.sh` for exactly what to check).
