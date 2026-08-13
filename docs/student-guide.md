# Student Guide

Welcome to the SRE lab. You'll deploy five real applications to a shared
Kubernetes cluster, wire up your own Datadog account to observe them, then
deliberately break things and practice diagnosing and fixing them like an
on-call engineer would.

## 1. Prerequisites

- `terraform`, `aws` CLI (configured with credentials for the lab AWS
  account), `kubectl`, `docker`, and `helm` installed locally.
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
   the Agent (metrics/APM/logs all work) and skips only the dashboard and
   monitor import in step 3 below.
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

This runs `terraform apply`, configures `kubectl`, builds and pushes all
10 container images to ECR, provisions a database + least-privilege user
per app on the shared RDS instance, deploys every app, installs the AWS
Load Balancer Controller, and -- since `DATADOG_API_KEY` is set -- installs
the Datadog Agent and imports every dashboard/monitor too. Expect this to
take 15-20 minutes, mostly waiting on the EKS cluster and ALB to come up.

You can omit all three `DATADOG_*` variables to skip Datadog entirely for
now and install it later by re-running this exact command with them set --
everything else in the script is safe to re-run. Once it finishes, confirm
in the Datadog UI: go to **APM > Traces** and browse one of the apps (e.g.
add a product to your ecommerce cart) -- you should see a trace appear
within a few seconds, spanning frontend -> backend -> Postgres. If you
provided an app key, also check **Dashboards > Dashboard List** for the 6
imported dashboards and **Monitors > Manage Monitors** for the 4 imported
monitors.

Re-running with a new `DATADOG_API_KEY` (e.g. switching accounts) is safe
-- the script restarts the Agent pods so they pick up the new key. The
dashboard/monitor import is **not** idempotent, though -- running it twice
creates duplicates, so only pass `DATADOG_APP_KEY` on the run(s) where you
actually want to (re-)import them.

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

## 5. Chaos script quick reference

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

## 6. Task list

Work through these roughly in order. Take notes as you go -- you'll need
them for the postmortems.

1. **Deploy.** Complete steps 2-4 above. Confirm all five apps load and
   you can complete one real user action in each (add to cart and check
   out in ecommerce, log in and check a balance in banking, place an
   order in food-delivery, view grades in student-portal, file a ticket
   in support-tickets).
2. **Observe baseline.** Open each app's Datadog dashboard
   (`datadog/dashboards/<app>.json`) and the `SRE Lab Overview` dashboard
   with everything healthy. This is what "normal" looks like -- you'll
   need it for comparison later.
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

## 7. Tear down

When you're done, avoid leaving the lab running (it costs real money):

```bash
./scripts/teardown.sh
```

Then double-check the AWS console for anything orphaned (see the output
of `teardown.sh` for exactly what to check).
