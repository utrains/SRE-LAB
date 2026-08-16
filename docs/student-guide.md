# Student Guide

Welcome to the SRE lab. You'll deploy five real applications to a shared
Kubernetes cluster, wire up your own Datadog account to observe them, then
deliberately break things and practice diagnosing and fixing them like an
on-call engineer would.

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
ACM cert, DNS-validated automatically during `setup.sh` -- no extra step or
warning to click through), and plain HTTP requests redirect to HTTPS
automatically:

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
| `reset.sh` | `<app>` | `./scripts/chaos/reset.sh ecommerce` |

Each script prints its own reset/rollback command after it runs, so you
don't need to memorize the undo step. Note `scale-to-zero` and `bad-deploy`
aren't undone by `reset.sh` -- each one prints the exact `kubectl` command
to revert it instead.

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
   tied to `docs/runbooks/high-latency.md`.
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
8. **Repeat** with a different incident scenario, then try triggering one
   yourself directly with the scripts in `scripts/chaos/` and writing your
   own scenario for a classmate.

## 8. Tear down

When you're done, avoid leaving the lab running (it costs real money):

```bash
./scripts/teardown.sh
```

Then double-check the AWS console for anything orphaned (see the output
of `teardown.sh` for exactly what to check).
