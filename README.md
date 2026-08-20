# SRE Lab

A hands-on SRE/DevOps training lab: five polished, full-stack applications
(ecommerce, banking, food-delivery, student-portal, support-tickets) running
on a shared Amazon EKS cluster, backed by a shared Amazon RDS for PostgreSQL
instance, observed with each student's own Datadog account. The point isn't
the apps themselves -- it's practicing the on-call loop: deploy it, break it
on purpose with the built-in chaos hooks, find the break in Datadog before
you go looking with `kubectl`, diagnose it, fix it, then write a postmortem
against a real error budget.

For the full system diagram and the reasoning behind every infrastructure
choice (including the tradeoffs made to keep this cheap and easy for a
classroom of students to stand up independently), see
[docs/architecture.md](docs/architecture.md). For a guided, step-by-step
walkthrough of the whole lab, see [docs/student-guide.md](docs/student-guide.md).
This README is the condensed reference: what's in the repo, how to bring it
up, what each app does, and how to break it.

## Repo layout

```
terraform/         VPC, EKS, node group, RDS, ECR -- flat, no modules (see terraform/*.tf)
namespaces/         Namespace + ResourceQuota + LimitRange per app (namespaces/<app>.yaml)
apps/<app>/         frontend/ (React+Vite+Tailwind), backend/ (Node+Express), k8s/ (Deployments/Services/HPA)
ingress/           One Ingress resource per app, routed by hostname via a shared ALB
datadog/           helm-values.yaml, dashboards/ (importable JSON), monitors/ (importable JSON)
scripts/           setup.sh, teardown.sh, chaos/ (per-failure-mode scripts)
docs/              architecture.md, slo-sla-sli.md, error-budget.md, devops-vs-sre.md, runbooks/, incident-scenarios/, student-guide.md
```

Each of the 5 apps under `apps/` is structured identically:

```
apps/<app>/
  backend/
    src/index.js      Express app entrypoint, mounts routes + chaos middleware
    src/routes.js      The app's real business-logic endpoints
    src/db.js          pg Pool, reads PGHOST/PGUSER/etc. from the Secret setup.sh creates
    src/chaos.js        Chaos endpoints (see "Breaking things on purpose" below)
    src/tracer.js       dd-trace init -- loaded first via `node -r ./src/tracer.js`
    sql/init.sql        Schema + seed data, run once by setup.sh against the shared RDS instance
    Dockerfile
  frontend/            React + Vite + Tailwind SPA, built and served by nginx (see Dockerfile, nginx.conf)
  k8s/                 configmap.yaml, deployment-{backend,frontend}.yaml, service-{backend,frontend}.yaml, hpa-backend.yaml
```

## Prerequisites

- **bash 4.4 or newer** to run `scripts/setup.sh` (it uses associative
  arrays). Linux and Git Bash on Windows are fine; **macOS still ships bash
  3.2**, so run `brew install bash` and invoke the script with it
  (`$(brew --prefix)/bin/bash ./scripts/setup.sh`). The script checks this
  up front and tells you if it is too old.
- `terraform`, `aws` CLI (configured with credentials for the target AWS
  account), `kubectl`, `docker`, `helm`, `jq`, and `envsubst` (from `gettext`;
  not preinstalled on macOS -- `brew install gettext && brew link --force
  gettext`) installed locally.
- Your **own** AWS account you're comfortable spending ~$150-250/month on if
  left running (see [Cost](#cost) below) -- there is no free tier here, this
  provisions real EKS/RDS/NAT infrastructure. Resource names (`sre-lab`
  cluster, RDS instance, ECR repos) are fixed, not parameterized per user --
  this is built for **one deployment per AWS account**, so if multiple
  people are doing this lab, each one needs their own separate account, not
  a shared one.
- An existing Route 53 **public hosted zone in that same AWS account** (any
  domain you control, already set up in Route 53 -- this lab looks it up by
  name, it won't create one for you). It creates five DNS records directly
  under it (`ecommerce.<your-domain>`, `banking.<your-domain>`, etc.), so
  pick a zone where those five names aren't needed for anything else. The
  domain's **registrar-level NS delegation must actually point at this
  hosted zone's nameservers** (Terraform only creates records *inside* the
  zone, it never touches delegation) -- `setup.sh` checks this for you before
  provisioning anything and warns if they don't match, but if you have a
  choice of domains, one already fully managed in Route 53 (nameservers
  registered there too) is the least error-prone option.
- No special AWS IAM setup required -- this works identically whether you
  run it as the AWS account root user or a named IAM identity/role.
  (`terraform/eks.tf` grants both the caller and the account root cluster-admin
  access without creating conflicting duplicate entries when they're the same
  principal.)
- Your own free [Datadog](https://www.datadoghq.com/) trial account. Nothing
  in this repo contains a real API key; each student/user brings their own.

## Quick start

```bash
# 0. Point the lab at your own Route 53 hosted zone
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# then edit terraform/terraform.tfvars and set dns_zone_name to your domain

# 1. Provision AWS infra, build/push all 10 images to ECR, create per-app
#    databases on the shared RDS instance, deploy all 5 apps, install the
#    AWS Load Balancer Controller, create the Route 53 DNS records, and
#    (if you pass Datadog credentials) install the Agent, provision a RUM
#    application per app so browser sessions trace end-to-end into each
#    backend's APM traces, and import every dashboard and monitor. Takes
#    15-20 minutes, mostly waiting on EKS/ALB. Prints the five app URLs at
#    the end -- no /etc/hosts editing needed, they're real DNS names that
#    work immediately.
#    DATADOG_APP_KEY is optional -- without it you still get the Agent
#    (metrics/APM/logs), just not RUM or the dashboard/monitor import. Omit
#    all three DATADOG_* vars to skip Datadog entirely and install it later
#    by re-running this same command with them set.
DATADOG_API_KEY=<your-datadog-api-key> \
DATADOG_APP_KEY=<your-datadog-app-key> \
DATADOG_SITE=datadoghq.com \
  ./scripts/setup.sh

# 2. Visit the apps (the domain is also saved to .lab-domain at the repo
#    root, in case you lose the setup.sh output)
open https://ecommerce.$(cat .lab-domain)

# 3. Break things
./scripts/chaos/inject-latency.sh ecommerce 3000
./scripts/chaos/memory-spike.sh support-tickets 300
./scripts/chaos/kill-random-pod.sh banking

# 4. Tear down when done -- this costs real AWS money while running
./scripts/teardown.sh
```

See [docs/student-guide.md](docs/student-guide.md) for the full walkthrough
with exact commands for every step below.

### What `setup.sh` actually does

`scripts/setup.sh` is a single idempotent-ish script that runs, in order:

0. **Preflight checks** -- verifies every required CLI is installed and
   Docker is running, that AWS credentials work, that `terraform.tfvars`
   exists with a real `dns_zone_name`, that a matching hosted zone exists in
   Route 53, and that the domain's registrar NS delegation actually points
   at it. Fails fast with a specific fix instead of burning ~20 minutes on a
   `terraform apply` that would've deployed fine but left you with URLs that
   never resolve. Also prints which AWS identity you're running as, purely
   informational -- root user or IAM identity both work with no extra steps.
1. `terraform init` / `terraform apply` in `terraform/` -- creates the VPC,
   EKS cluster + managed node group, the shared RDS instance, and 10 ECR
   repositories (one per app per frontend/backend).
2. `aws eks update-kubeconfig` to point `kubectl` at the new cluster.
3. **Optional**, only if `DATADOG_API_KEY` and `DATADOG_APP_KEY` are both
   set: provisions a Datadog RUM application per app via the Datadog API
   (`sre-lab-<app>`), reusing an existing one by name if this is a re-run
   rather than creating a duplicate. The resulting `applicationId`/
   `clientToken` per app feed into step 4's frontend builds. Skipped with a
   clear message otherwise -- frontends still build and run fine without
   RUM, just without browser-side monitoring.
4. Builds and pushes all 10 container images to ECR, tagged with a
   timestamp (so every run produces a fresh, traceable image tag). Each
   frontend image bakes in that app's RUM config (if step 3 ran) as
   `VITE_`-prefixed build args -- see
   [apps/\<app\>/frontend/src/rum.js](apps/ecommerce/frontend/src/rum.js) and
   the Dockerfile.
5. `kubectl apply -f namespaces/` -- creates the 5 app namespaces, each
   with its own `ResourceQuota` and `LimitRange` (see
   [Resource limits](#resource-limits-and-why) below).
6. For each app: creates its database and a least-privilege role on the
   shared RDS instance, applies `sql/init.sql`, and writes a
   `<app>-db-credentials` Secret. This step runs `psql` from a short-lived
   pod inside the cluster (`kubectl run ... postgres:17-alpine`) rather
   than from your machine, because RDS's security group only allows
   inbound 5432 from the EKS node security group -- see
   [docs/architecture.md](docs/architecture.md#database-amazon-rds-for-postgresql).
7. Deploys food-delivery's in-cluster Redis.
8. Applies every app's `k8s/*.yaml` manifests (via `envsubst`, to inject
   the ECR registry URL and image tag).
9. Installs the AWS Load Balancer Controller via Helm (authenticated via
   an IRSA role Terraform already created) and applies `ingress/*.yaml`,
   then polls for the shared ALB's hostname and prints it.
10. **Optional**, only if `DATADOG_API_KEY` is set: creates `datadog-secret`,
    installs the Agent + Cluster Agent via Helm, restarts it if credentials
    changed from a previous run, and (if `DATADOG_APP_KEY` is also set)
    imports every dashboard and monitor via the Datadog API. Skipped with a
    clear message otherwise -- everything above it doesn't depend on this
    step, so it's safe to skip now and install later by re-running with the
    env vars set.

### Connecting `kubectl` manually

`setup.sh` does this for you, but if you need to reconnect in a new shell:

```bash
aws eks update-kubeconfig --name sre-lab --region us-east-1
kubectl get pods -A
```

## How to use this lab

The infrastructure is just the stage -- the actual exercise is the loop
below. Work through it once end-to-end, then repeat with a different app
and a different failure mode. See
[docs/student-guide.md](docs/student-guide.md) section 7 for the full
step-by-step task list with exact commands.

1. Deploy, confirm all five apps work, and install Datadog (dashboards +
   monitors from `datadog/dashboards/` and `datadog/monitors/`). Observe
   the healthy baseline before breaking anything.
2. Break something -- an [incident scenario](docs/incident-scenarios/) or
   your own [chaos script](#breaking-things-on-purpose) -- and find it in
   Datadog *before* reaching for `kubectl`.
3. Diagnose and fix it, using the matching [runbook](docs/runbooks/) if you
   get stuck, then confirm recovery in both the app and the dashboard.
4. Write a postmortem against your
   [error budget](docs/error-budget.md), then repeat with a different
   incident.

Then tell the story twice. Half the incidents here start with a *change*
somebody shipped and half start with a *condition* nobody moved, and the
two are diagnosed, fixed and explained differently --
[docs/devops-vs-sre.md](docs/devops-vs-sre.md) covers the full path from
"what changed" through Datadog logs to the decision about whether `kubectl`
is even the right tool, and gives the DevOps and SRE version of the same
incident side by side.

When you're done for the day, tear down (see [Cost](#cost)) -- nothing in
this lab needs to stay running between sessions.

## The five apps

All five backends are Node.js + Express (instrumented with `dd-trace`, see
`src/tracer.js`) and all five frontends are React + Vite + Tailwind, so the
stack is consistent and the interesting differences are in each app's
domain logic and failure modes.

| App | What it does | Key endpoints (`/api/...`) | Notable |
|---|---|---|---|
| **ecommerce** | Browse products, manage a cart, check out, view past orders | `GET /products`, `GET/POST/DELETE /cart(/items)`, `POST /checkout`, `GET /orders` | Checkout latency/success is the primary SLI -- see [docs/slo-sla-sli.md](docs/slo-sla-sli.md) |
| **banking** | Demo login, view balance/transaction history, transfer funds | `POST /auth/login`, `GET /accounts/me(/transactions)`, `POST /transfer` | Plaintext password comparison for the demo login -- deliberately simplified, see [What's simplified](#whats-deliberately-simplified) |
| **food-delivery** | Browse restaurants/menus, place an order, poll live order status | `GET /restaurants(/:id/menu)`, `POST/GET /orders`, `GET /orders/:id/status` | Order status is cached in an in-cluster Redis with a 5s TTL, the only app with a non-Postgres datastore |
| **student-portal** | Demo login, view courses/grades/assignments, enroll, submit assignments | `POST /auth/login`, `GET /courses`, `POST /enrollments`, `GET /grades`, `GET /assignments`, `POST /assignments/:id/submit` | Same plaintext demo-login pattern as banking |
| **support-tickets** | File and comment on support tickets | `GET/POST /tickets`, `GET /tickets/:id`, `POST /tickets/:id/comments` | Simplest app -- good first target for chaos experiments |

Demo login credentials (banking, student-portal) all use password `demo123`;
see each app's `apps/<app>/backend/sql/init.sql` for the exact seeded
usernames.

Every backend also exposes, regardless of its business logic:

- `GET /healthz` -- liveness only, always 200 if the process is up.
- `GET /readyz` -- readiness, runs a real `SELECT 1` against Postgres, so a
  reachable-app-but-unreachable-database failure actually shows up as
  `NotReady` instead of being masked.
- `POST /api/chaos/*` -- see below.

## Breaking things on purpose

Every backend has chaos hooks built in (`src/chaos.js`), toggled over HTTP
so you can trigger a failure mode against a live pod with a single `curl`
call -- no redeploy needed. `scripts/chaos/*.sh` wrap these (and a few
Kubernetes-level failures) in copy-paste commands:

| Script | Failure mode | What it does |
|---|---|---|
| `inject-latency.sh <app> [ms]` | Slow backend | Adds `ms` (default 3000) of delay before every response |
| `inject-errors.sh <app> [rate]` | Elevated error rate | Randomly returns HTTP 500 at `rate` (0-1, default 0.5) |
| `memory-spike.sh <app> [mb]` | Memory leak / OOMKill | Retains `mb` (default 300) of heap until reset; pairs with the 256Mi container limit to trigger a real `OOMKilled` |
| `cpu-spike.sh <app> [seconds]` | CPU saturation | Blocks the Node.js event loop for `seconds` (default 10), spiking latency for every request that pod serves -- good for demonstrating HPA scale-out |
| `drop-db-connection.sh <app>` | DB connectivity loss | Forces `/readyz` to fail as if RDS were unreachable, without touching the database -- pods go `NotReady` and drop out of the Service |
| `kill-random-pod.sh <namespace>` | Pod crash | Deletes a random pod; the Deployment controller reschedules it immediately (self-healing demo, or run repeatedly to simulate a crash loop) |
| `scale-to-zero.sh <namespace> <deployment>` | Full outage | Scales a Deployment to 0 replicas |
| `bad-deploy.sh <namespace> <deployment> <container>` | Bad release | Points a container at a nonexistent image tag -- new pods sit in `ImagePullBackOff` while old pods keep serving until you roll back |
| `break-config.sh <app> [--undo]` | Bad config rollout | Sets `PORT` in the backend ConfigMap to a value the probes don't check, then rolls the Deployment -- new pods start on the wrong port, fail both probes, and crash-loop while old pods keep serving |
| `rotate-secret.sh <app> [--undo]` | Credential drift | Overwrites `PGPASSWORD` in the app's Secret with a value RDS doesn't know, then rolls the Deployment -- new pods stay `Running` but never `Ready`, because `/readyz` fails authentication |
| `break-ingress.sh <app> [--undo]` | Edge misroute | Repoints the app's Ingress at the backend Service instead of the frontend. Every pod stays healthy, every dashboard stays green, and users get the *backend's* `404 Cannot GET /` -- an ALB with no healthy targets fails open rather than returning 503 |
| `shrink-limits.sh <app> [mi] [--undo]` | Limit set too low | Patches the backend's memory request/limit down to 20Mi, below the ~31Mi the process actually needs -- new pods `OOMKilled` on startup from a manifest change, not a leak |
| `reset.sh <app>` | -- | Clears latency/error-rate/db-drop/memory chaos state on an app. Does **not** undo `kill-random-pod`, `scale-to-zero`, or `bad-deploy` -- those revert with plain `kubectl` (each script prints the exact command). The four change-driven scripts above revert with their own `--undo` flag, since some of them (notably `rotate-secret.sh`) overwrite the only copy of a value in the cluster |

See [How to use this lab](#how-to-use-this-lab) for the recommended
workflow around these scripts.

### Testing a chaos injection end-to-end (and seeing it in Datadog)

`inject-latency.sh` / `inject-errors.sh` / `memory-spike.sh` / `cpu-spike.sh`
only set state on **one pod** -- every backend runs with `minReplicas: 2`
(see each app's `k8s/hpa-backend.yaml`), and a chaos script's single `curl`
goes through the ALB, which routes to a random pod. That pod's chaos state
lives in memory only (`src/chaos.js`), so the other pod(s) stay completely
normal. This is expected, not a bug -- but it means a single injection call
only ever affects a fraction of your traffic, which can look like "nothing
happened" if you check at the wrong moment. Full walkthrough:

1. **Inject.** Run the script as documented, e.g.:
   ```bash
   ./scripts/chaos/inject-latency.sh ecommerce 4000
   ./scripts/chaos/inject-errors.sh ecommerce 0.2
   ```
2. **(Optional) Hit every pod, not just whichever one the ALB picked**, if
   you want the effect on 100% of requests instead of ~1/N:
   ```bash
   kubectl -n ecommerce get pods -l app=ecommerce-backend -o name
   # for each pod:
   kubectl -n ecommerce port-forward pod/<pod-name> 14000:4000
   # in a second terminal, while the port-forward is running:
   curl -X POST http://localhost:14000/api/chaos/latency -H "Content-Type: application/json" -d '{"ms": 4000}'
   curl -X POST http://localhost:14000/api/chaos/errors -H "Content-Type: application/json" -d '{"rate": 0.2}'
   ```
3. **Generate real traffic** -- chaos only fires on real API routes, never
   on `/api/chaos/*` itself (see `chaosMiddleware` in `src/chaos.js`), so
   hitting the chaos endpoint again will never show you the effect:
   ```bash
   for i in $(seq 1 40); do curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" https://ecommerce.$(cat .lab-domain)/api/products; done
   ```
4. **Check Datadog** -- APM > Traces, filter `service:<app>-backend
   env:lab`, or the app's own dashboard / `sre-lab-overview` (imported by
   `setup.sh` step 10/10). Allow 1-2 minutes for ingest lag before it shows up.
5. **Reset** when done -- same caveat applies, `reset.sh` also only reaches
   one random pod per call, so run it twice or repeat the port-forward loop
   from step 2 with `POST /api/chaos/reset`:
   ```bash
   ./scripts/chaos/reset.sh ecommerce
   ./scripts/chaos/reset.sh ecommerce
   curl -s https://ecommerce.$(cat .lab-domain)/api/chaos  # confirm both zeroed out
   ```

## Observability: Datadog

Each student/user installs the Datadog Agent + Cluster Agent once, into
their own free-trial account, by passing `DATADOG_API_KEY` (and
optionally `DATADOG_APP_KEY`, `DATADOG_SITE`) to `scripts/setup.sh` --
see step 10/10 above -- with APM and log collection enabled. See
[docs/architecture.md](docs/architecture.md#observability-datadog) for how
tracing and unified service tagging are wired up. Dashboards live in
`datadog/dashboards/` (one per app, plus `sre-lab-overview.json`), and
monitors live in `datadog/monitors/` (`high-error-rate`,
`high-latency-p95`, `pod-restarts`, `memory-saturation`) -- both get
imported automatically if `DATADOG_APP_KEY` is set.

**Browser monitoring (RUM):** if both `DATADOG_API_KEY` and
`DATADOG_APP_KEY` are set, step 3/10 also provisions a Datadog RUM
application per app (`sre-lab-<app>`) and step 4/10 bakes its
`applicationId`/`clientToken` into that app's frontend build (see
`apps/<app>/frontend/src/rum.js`). Because each frontend's nginx proxies
`/api/*` to its own backend on the same origin (see `nginx.conf`), RUM's
`allowedTracingUrls` is just `window.location.origin` -- no CORS
configuration needed -- so a browser session's spans stitch directly into
that request's backend APM trace. Look under **APM > Traces** for a
`GET /api/products`-type entry and you'll see it start in the browser and
continue into Postgres. Session Replay is deliberately left off
(`sessionReplaySampleRate: 0` in `rum.js`) to keep this scoped to tracing.

See [docs/student-guide.md](docs/student-guide.md) section 3 for the
exact env vars, and [docs/slo-sla-sli.md](docs/slo-sla-sli.md) for what
SLI each dashboard is actually measuring.

## Troubleshooting

Common issues people hit standing this up for the first time, and what
actually fixes them:

| Symptom | Cause | Fix |
|---|---|---|
| `setup.sh` aborts during preflight with an NS delegation warning | Your domain's registrar isn't pointed at the Route 53 hosted zone `dns_zone_name` refers to -- Terraform only creates records *inside* the zone, never the delegation itself | Update the domain's NS records at its registrar to match the list the script prints, then re-run. Or pick a different `dns_zone_name` that's already fully managed in Route 53 |
| `terraform apply` fails on `aws_eks_access_entry` with `ResourceInUseException` | You're running as the AWS account root user, and something (an older checkout, a manual `terraform apply` outside this script) created a duplicate access entry for the same principal | Already handled automatically in current `terraform/eks.tf` (`caller_is_root` skips the redundant entry) -- if you still hit this, you're likely on a stale checkout, pull latest |
| `setup.sh` step 10/10 fails with `duplicate entries for key [name="DD_APM_NON_LOCAL_TRAFFIC"]` | Current Datadog Helm chart versions auto-inject this env var once `datadog.apm` is enabled; an older `datadog/helm-values.yaml` also set it explicitly | Already fixed in current `datadog/helm-values.yaml` (the manual `env:` override was removed) -- pull latest if you still see this |
| `terraform destroy` hangs on `ResourceInUseException` deleting an ACM certificate | Something outside the lab is using the same wildcard certificate -- typically a CloudFront distribution or another load balancer on the same domain. ACM won't delete a certificate in use, so the teardown stalls (and deleting it would have broken that other service anyway) | Fixed: the lab no longer owns certificates. `terraform/acm.tf` reads one as a data source and `setup.sh` requests one outside Terraform if none exists, so `destroy` never targets it. On a lab created before this change, run `terraform state rm aws_acm_certificate.wildcard aws_acm_certificate_validation.wildcard 'aws_route53_record.cert_validation["*.<your-domain>"]'` once, then destroy again |
| `kubectl` suddenly talks to the wrong cluster (namespaces you don't recognise, `namespaces "datadog" not found`) | Starting Docker Desktop rewrites `current-context` in `~/.kube/config` to `docker-desktop`. If its Kubernetes is enabled, every later `kubectl` silently hits your laptop instead of the lab | `aws eks update-kubeconfig --name sre-lab --region us-east-1`, then confirm with `kubectl config current-context`. `setup.sh` does this at step 2, so it only bites mid-session |
| `setup.sh` finished successfully but an app is still running the old image | A rollout can stall (bad image, failed probe, OOMKill loop, or a namespace quota with no headroom for the surge pod) while `kubectl apply` still reports success. `food-delivery` hit this: its extra Redis workload left no room under the old `limits.cpu: "2"` quota, so its backend could never roll | Fixed twice over: the namespace quotas now allow a surge pod and a full HPA scale-out, and `setup.sh` verifies every rollout with `kubectl rollout status` and fails loudly instead of exiting 0. Diagnose a stall with `kubectl -n <app> get events \| grep -i quota` and see [docs/runbooks/failed-rollout.md](docs/runbooks/failed-rollout.md) |
| HPAs show `cpu: <unknown>/70%` and never scale, `kubectl top` says "Metrics API not available" | EKS doesn't ship metrics-server, and nothing was installing it -- so `metrics.k8s.io` didn't exist and `cpu-spike.sh` could never demonstrate an HPA scale-out | `setup.sh` step 9 now installs it. To add it to a running cluster: `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml` |
| A monitor query with `{env:lab}` returns "No data" for `kubernetes_state.*` metrics | Unified service tagging comes from the `tags.datadoghq.com/*` pod labels, so it only reaches pod-level telemetry. Cluster-level data (kube-state-metrics, Kubernetes events) is generated from the API server and never sees those labels | Fixed by `datadog.tags: ["env:lab"]` in `datadog/helm-values.yaml`, which tags everything the Agent and Cluster Agent emit. Re-run `setup.sh` (or `helm upgrade`) to apply it |
| Traces start at the backend -- the browser/frontend span is missing from the flame graph | RUM config is baked into each frontend bundle at **build time**, and `setup.sh` only passes it when `DATADOG_APP_KEY` is set. Re-running `setup.sh` with just `DATADOG_API_KEY` (which this README recommends, to avoid duplicating dashboards) used to rebuild all 5 frontends with RUM stripped out, silently removing browser spans from every trace | Fixed: `setup.sh` now caches the provisioned RUM application ids/tokens to `.rum-apps.json` (gitignored) and reuses them on app-key-less re-runs. Pull latest and re-run `./scripts/setup.sh`. To confirm RUM is live, open an app and check `window.DD_RUM` is defined in the browser console; delete `.rum-apps.json` if you deliberately want frontends built without RUM |
| `kubectl rollout undo` doesn't fix a broken ConfigMap or Secret | `rollout undo` restores a previous *pod template*. When the bad value lives in a ConfigMap or Secret the template references, every revision points at the same (still-wrong) object | Patch the object itself, then `kubectl -n <app> rollout restart deployment/<app>-backend`. See [docs/runbooks/config-and-secret-drift.md](docs/runbooks/config-and-secret-drift.md) -- this is deliberately the subject of incident scenarios 07 and 08 |
| A chaos script's `--undo` says there's no backup to restore from | The four change-driven scripts save the original value to `.chaos-backup/` (gitignored) before overwriting it; the directory was deleted, or the fault was injected from a different checkout | For `break-config.sh`, `break-ingress.sh` and `shrink-limits.sh` the original values are the same across all five apps, and each script falls back to them automatically. `rotate-secret.sh` is the exception -- each app's DB password is generated by `setup.sh` and stored only in the Secret, so recovery means re-running `./scripts/setup.sh` |
| `setup.sh` step 10/10 prints `ERROR: You did not set a datadog.appKey` | Expected if you only passed `DATADOG_API_KEY`, not `DATADOG_APP_KEY` | Harmless for the core lab -- the app key is only used by the optional `clusterAgent.metricsProvider` (Datadog-backed HPA custom metrics) stretch goal, plus RUM and dashboard/monitor import. Metrics, APM, and logs all work without it |
| App URLs return `NXDOMAIN` right after `setup.sh` finishes | DNS propagation lag, or the registrar delegation issue above slipped past preflight (e.g. it was fixed seconds before you ran the script and hadn't propagated yet) | Wait a few minutes and retry; if it persists, re-check NS delegation manually: `aws route53 list-resource-record-sets --hosted-zone-id <zone-id> --query "ResourceRecordSets[?Type=='NS']"` vs `nslookup -type=NS <your-domain> 8.8.8.8` -- the two lists must match exactly |
| Need to hit an app before DNS is fixed | -- | Bypass DNS entirely by talking to the ALB directly with a `Host` header: `curl -k -H "Host: ecommerce.<your-domain>" https://<alb-hostname>/` (get `<alb-hostname>` from `kubectl -n ecommerce get ingress ecommerce`; `-k` skips cert verification since the ALB's TLS cert is issued for `*.<your-domain>`, not its own `*.elb.amazonaws.com` hostname) |
| `inject-latency.sh` / `inject-errors.sh` seem to do nothing, or only affect some requests | Every backend runs `minReplicas: 2`; the script's single `curl` goes through the ALB to one random pod, and chaos state is in-memory per-pod (`src/chaos.js`) -- the other pod(s) are unaffected | Expected, not a bug. See [Testing a chaos injection end-to-end](#testing-a-chaos-injection-end-to-end-and-seeing-it-in-datadog) to hit every pod explicitly via `kubectl port-forward` |
| `scripts/chaos/reset.sh` (or a manual `/api/chaos/reset` call) doesn't seem to clear a `drop-db-connection` fault | The reset request routes through the app's Service/Ingress, but a pod with the DB-connection chaos active has already failed enough readiness probes to be pulled *out* of that Service -- so the reset silently lands on a different, unaffected pod instead | Reset the specific pod directly, bypassing the Service: `kubectl exec -n <app> <pod> -- node -e "require('http').request({host:'localhost',port:4000,path:'/api/chaos/reset',method:'POST'}).end()"` |
| `bad-deploy.sh` leaves the new ReplicaSet at `0/1` with a `FailedCreate`/`ReplicaFailure` condition instead of pods stuck in `ImagePullBackOff` | The target namespace's `ResourceQuota` has no CPU/memory headroom left for the rollout's surge pod (`food-delivery` in particular runs close to its quota with 2 backend + 2 frontend + 1 redis pod already scheduled) -- Kubernetes never gets far enough to attempt the image pull | Same end result either way (old pods keep serving, `kubectl rollout undo` fixes it) -- if you want to see the documented `ImagePullBackOff` behavior specifically, pick a namespace/app with more quota headroom, or raise that namespace's `ResourceQuota` in `namespaces/<app>.yaml` |
| `inject-latency.sh`/`inject-errors.sh` chaos causes an unexpected pod restart, not just a slow/failing response | `/healthz` and `/readyz` are the actual liveness/readiness probes (`apps/<app>/k8s/deployment-backend.yaml`); an older `chaos.js` only exempted `/api/chaos/*`, so injected latency/errors could delay or fail the probe itself and cause kubelet to restart the pod as a side effect | Already fixed in current `apps/*/backend/src/chaos.js` (`/healthz` and `/readyz` are now exempted too) -- pull latest, then re-run `./scripts/setup.sh`. It rebuilds all 10 images with a fresh timestamp tag and re-applies every deployment manifest on every run, which is enough to trigger a rolling update onto the fixed `chaos.js` -- no teardown or manual SQL needed (unlike the seed-duplication row above) |
| `setup.sh` step 3/10 fails calling the Datadog RUM Applications API | `DATADOG_APP_KEY` belongs to a role without permission to create RUM applications (uncommon on a personal free-trial account, more likely on an org-managed one) | Use an App Key scoped to (or a user with) RUM write access, or omit `DATADOG_APP_KEY` to skip RUM/dashboards/monitors for this run and install them later |
| Products/restaurants/tickets duplicate every time `setup.sh` is re-run | Already fixed in current `apps/{ecommerce,food-delivery,support-tickets}/backend/sql/init.sql` (real `UNIQUE` constraints, or an empty-table guard for `support-tickets`, now back the `ON CONFLICT DO NOTHING`/guard clauses) | If you deployed **before** this fix, re-running `setup.sh` alone won't retroactively apply it -- `CREATE TABLE IF NOT EXISTS` never inspects an existing table's column definitions, so the new constraints never reach an already-running cluster's tables. Either tear down/redeploy, or manually run the equivalent `ALTER TABLE ... ADD CONSTRAINT ... UNIQUE (...)` on `products.name`, `restaurants.name`, and `menu_items(restaurant_id, name)` (de-duplicating existing rows first if any already accumulated) |
| A dashboard's `p95 Latency` widget (or the `[SRE Lab] High p95 latency` monitor) shows no data, even though the service is clearly getting traffic | `datadog/dashboards/*.json` and `datadog/monitors/high-latency-p95.json` queried `p95:trace.express.request.duration{...}` -- but Datadog's auto-generated APM trace metric for an Express top-level span is just `trace.express.request` (a distribution metric; percentile functions like `p95:` apply directly to it, no `.duration` suffix). The `.duration` metric name never existed, so the query always returned an empty series, silently | Fixed in current `datadog/dashboards/*.json`, `datadog/monitors/high-latency-p95.json`, and `docs/slo-sla-sli.md` -- pull latest. If you already imported the old dashboards/monitor into your own Datadog account, re-import them (or manually edit each `p95 Latency` widget/the monitor query to drop `.duration`) |
| A chaos-injected error (`inject-errors.sh`, `drop-db-connection.sh`, `rotate-secret.sh`) shows up in Datadog's Error Tracking / trace inspector as "Missing error message and stack trace" | `console.error(...)` populates Log Management, but Error Tracking reads `error.message`/`error.stack`/`error.type` off the **APM span itself**. dd-trace marks a span `status:error` automatically from the HTTP status code, but nothing attaches error details to it unless you explicitly tag it | Fixed in current `apps/*/backend/src/chaos.js` and `index.js` -- each failure path now also does `tracer.scope().active()?.setTag("error", err)` alongside its `console.error`. Pull latest and re-run `./scripts/setup.sh` to rebuild and redeploy all 10 images |

## Resource limits and why

Each namespace (`namespaces/<app>.yaml`) has its own `ResourceQuota` (e.g.
ecommerce: 1 CPU / 1Gi requested, 2 CPU / 2Gi limit, max 20 pods) and
`LimitRange` (per-container default 250m/256Mi, max 1 CPU/1Gi). See
[docs/architecture.md](docs/architecture.md#compute-amazon-eks) for why
these are deliberately tight rather than generous.

## Cost

This provisions a real EKS cluster, 2-5 `t3.medium` nodes, a NAT gateway,
and an RDS instance -- roughly **$150-250/month** if left running
continuously. Always run `./scripts/teardown.sh` when you're done for the
day; it deletes the Ingress resources first (so the shared ALB is released
cleanly by the AWS Load Balancer Controller), uninstalls Datadog, deletes
the app namespaces, and then runs
`terraform destroy`. Double-check the AWS console afterward for anything
orphaned (EC2 Load Balancers, NAT Gateways/EIPs, ECR repos, RDS) -- exact
checklist is printed at the end of the teardown script.

## What's deliberately simplified

This is a training lab, not a production reference architecture -- several
things (a shared RDS instance, plaintext demo-login passwords, a shared
ALB, publicly-reachable chaos endpoints, local Terraform state) are
simplified on purpose to keep it cheap and easy for anyone to stand up
independently. See
[docs/architecture.md](docs/architecture.md#whats-deliberately-simplified-for-a-training-lab)
for the full list and the rationale behind each one.

## Further reading

- [docs/architecture.md](docs/architecture.md) -- full system diagram and design rationale
- [docs/student-guide.md](docs/student-guide.md) -- complete step-by-step walkthrough
- [docs/slo-sla-sli.md](docs/slo-sla-sli.md) -- SLI/SLO/SLA definitions with real per-app examples
- [docs/error-budget.md](docs/error-budget.md) -- how to calculate error budget burn from an incident
- **[docs/monitoring-sre-lab-class-deck.pptx](docs/monitoring-sre-lab-class-deck.pptx)** -- the 62-slide class deck (PDF alongside it): concepts, the lab, all 12 failure modes, and the interview answers from both chairs
- [docs/testing-the-lab.md](docs/testing-the-lab.md) -- checklist for exercising all 12 failure modes: what to expect, what to check in Datadog, how to undo each one
- [docs/devops-vs-sre.md](docs/devops-vs-sre.md) -- who owns what, the change-vs-condition split, and the end-to-end path from alert to Datadog logs to `kubectl` to postmortem, told from both chairs
- [docs/runbooks/](docs/runbooks/) -- diagnostic playbooks (pod crash loops, OOMKill, high latency, DB connection exhaustion, ingress 502s, RDS connection limits, stalled rollouts, config/secret drift)
- [docs/incident-scenarios/](docs/incident-scenarios/) -- ten scripted incidents to practice on (six condition-driven, four change-driven), plus an instructor answer key with a DevOps and an SRE walkthrough for each
