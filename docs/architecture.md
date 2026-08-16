# Architecture

## Overview

The SRE lab runs five independent full-stack applications on a single shared
Amazon EKS cluster, backed by a single shared Amazon RDS for PostgreSQL
instance. Each app is a self-contained namespace with its own frontend,
backend, database, and (for food-delivery) an in-cluster Redis cache. The
AWS Load Balancer Controller watches one `Ingress` resource per app and
provisions a single shared Application Load Balancer (ALB) that routes
traffic to all five apps by hostname. Datadog's Agent and Cluster Agent run
cluster-wide and collect infrastructure metrics, container logs, and APM
traces from every app.

<img width="512" height="341" alt="image" src="https://github.com/user-attachments/assets/ffc1ab59-e5de-4046-ac25-a89e3438c0c0" />


## Compute: Amazon EKS

- One managed node group, `t3.medium` instances, 2-5 nodes (see
  `terraform/eks.tf`), spread across two private subnets in two AZs.
- Kubernetes 1.33, API access managed via EKS access entries (no aws-auth
  ConfigMap).
- Each app gets its own namespace with a `ResourceQuota` and `LimitRange`
  (see `namespaces/`) so students can observe real resource-pressure
  failure modes (pods stuck `Pending`, OOMKilled at the container limit,
  etc.) rather than infinite headroom.

## Networking

- A single VPC with 2 public subnets (NAT gateway, and the ALB's
  interfaces) and 2 private subnets (EKS nodes and RDS). Public subnets
  are tagged `kubernetes.io/role/elb`, private subnets
  `kubernetes.io/role/internal-elb` -- how the controller auto-discovers
  which subnets an internet-facing ALB's interfaces should land in (see
  `terraform/vpc.tf`).
- The **AWS Load Balancer Controller** runs in `kube-system`, installed
  once via Helm (`scripts/setup.sh`) and authenticated via IRSA: an IAM
  OIDC identity provider trusts the EKS cluster's OIDC issuer, and an IAM
  role scoped to the `aws-load-balancer-controller` service account is
  assumed through it (see `terraform/alb-controller.tf`), granting exactly
  the EC2/ELB permissions in
  `terraform/policies/aws-load-balancer-controller-iam-policy.json` (the
  upstream project's published policy) -- nothing broader, and no static
  IAM user credentials anywhere in the cluster.
- Each app gets one `Ingress` resource (`ingress/<app>-ingress.yaml`)
  routing by hostname (`<app>.<your-domain>`, a Route 53 alias record
  pointing at the ALB by name -- see `terraform/dns.tf`) to that app's
  frontend Service. `<your-domain>` is whatever `dns_zone_name` is set to
  in `terraform/terraform.tfvars` (see
  `terraform/terraform.tfvars.example`).
  All five carry `alb.ingress.kubernetes.io/group.name: sre-lab`, so the
  controller provisions and shares **one ALB** across all five apps
  (one set of listener rules, host-routed) instead of five -- otherwise
  five separate ALBs would roughly 5x the load-balancer cost of the lab
  for no pedagogical benefit, the same reasoning behind the single shared
  RDS instance below.
- `alb.ingress.kubernetes.io/target-type: ip` makes the ALB register pod
  IPs directly as targets (via the VPC CNI), rather than routing through
  a NodePort on every node -- one less hop, and Service objects for every
  app stay plain `ClusterIP` since the ALB talks to pods directly and
  the Ingress is the only externally-reachable object.
- **HTTPS**: `terraform/acm.tf` requests a wildcard ACM certificate for
  `*.<your-domain>`, DNS-validated against the same Route 53 hosted zone
  `dns.tf` already looks up -- no extra prerequisite beyond what's already
  required for plain HTTP. Each Ingress carries the resulting certificate
  ARN (`alb.ingress.kubernetes.io/certificate-arn`), a second listener on
  443 (`alb.ingress.kubernetes.io/listen-ports`), and
  `alb.ingress.kubernetes.io/ssl-redirect: '443'`, which makes the
  controller add an HTTP-to-HTTPS redirect rule on the 80 listener. Since
  that redirect applies to every path, `scripts/chaos/*.sh` call
  `https://` directly rather than relying on the redirect (a redirected
  `POST` can silently become a `GET`, which would break the chaos hooks).

## Database: Amazon RDS for PostgreSQL

- **One shared RDS instance** (`db.t3.micro`, PostgreSQL 17) backs all five
  apps. Each app gets its own database (`ecommerce_db`, `banking_db`,
  `food_delivery_db`, `student_portal_db`, `support_tickets_db`) and its
  own least-privilege role, created by `scripts/setup.sh` after
  `terraform apply` using the Terraform-generated master credentials.
- The instance sits in private subnets with `publicly_accessible = false`.
  Its security group allows inbound TCP 5432 **only** from the EKS
  cluster's security group -- nothing else, including the internet or the
  student's own laptop, can reach it directly. This is also why database
  provisioning happens via a short-lived pod running inside the cluster
  (`kubectl run ... postgres:17-alpine -- psql ...`) rather than from the
  student's machine.
- **Production tradeoff**: a real production system would very likely give
  each service (or at least each environment) its own RDS instance, so
  that one app's noisy queries, connection storms, or maintenance windows
  can't affect another app's availability, and so that blast radius from a
  compromised app credential is contained to that app's data. We use one
  shared instance here purely to keep AWS costs predictable for a
  classroom of students running this simultaneously -- five
  `db.t3.micro` instances plus five sets of storage would multiply the
  lab's cost for no pedagogical benefit. Note also that by default,
  PostgreSQL grants `CONNECT` on every database to `PUBLIC`, so an app's
  database role can technically open a connection to another app's
  database (though it has no table-level grants there). A hardened
  multi-tenant setup would explicitly `REVOKE CONNECT ... FROM PUBLIC` per
  database.
- **Food-delivery's Redis** is the one exception: it runs in-cluster as a
  plain Kubernetes `Deployment`, because it only caches order-status
  values with a 5 second TTL. There's no data there worth protecting or
  persisting -- if the pod restarts, the cache simply repopulates from
  Postgres on the next read.

## Application layer

Every backend is Node.js + Express, and every frontend is React + Vite +
Tailwind served as a static bundle by nginx, for consistency across the
five apps (see `apps/<app>/backend` and `apps/<app>/frontend`). Each
backend exposes:

- `GET /healthz` -- liveness only, always returns 200 if the process is up.
- `GET /readyz` -- readiness, which runs a real `SELECT 1` against Postgres.
  This is deliberate: the most realistic failure mode with an external,
  network-attached database is "the app is running fine but can't reach
  the database," and a liveness-only check would never catch that.
- `POST /api/chaos/*` -- the built-in chaos hooks (latency, error rate, a
  simulated DB-connection drop, a CPU-blocking spike, and a memory-retaining
  spike), documented in `scripts/chaos/` and used throughout
  `docs/runbooks/` and `docs/incident-scenarios/`.

Unified service tagging (`env`, `service`, `version`) is applied as both
pod labels (`tags.datadoghq.com/*`) and container env vars (`DD_ENV`,
`DD_SERVICE`, `DD_VERSION`) on every Deployment, so a trace, a log line, and
a container metric for the same pod all correlate in Datadog automatically.

## Observability: Datadog

Each student runs their own free-trial Datadog account -- nothing in this
repo contains a real API key. Passing `DATADOG_API_KEY` (and optionally
`DATADOG_APP_KEY`, `DATADOG_SITE`) to `scripts/setup.sh` installs the
Datadog Agent and Cluster Agent via Helm (`datadog/helm-values.yaml`) with
APM and log collection enabled, and -- if an app key was provided --
imports every dashboard/monitor via the Datadog API (see step 10/10 in
`scripts/setup.sh`). Every backend requires `dd-trace` as the very first
line executed (`src/tracer.js`, loaded via `-r`).

That covers the backend. The frontend is a static SPA served by nginx --
there's no server process for `dd-trace` to patch, so browser-side
visibility is a separate Datadog product (RUM), wired up separately:
if both `DATADOG_API_KEY` and `DATADOG_APP_KEY` are set, step 3/10 of
`scripts/setup.sh` provisions a Datadog RUM application per app via the
RUM Applications API (`POST /api/v2/rum/applications`, reusing an existing
one by name on re-runs rather than duplicating), and step 4/10 bakes the
resulting `applicationId`/`clientToken` into that app's frontend build as
`VITE_`-prefixed Docker build args (Vite only exposes env vars present at
*build* time -- a static bundle has no runtime env injection the way a
Deployment's env vars work). `apps/<app>/frontend/src/rum.js`, imported
first in `main.jsx` (same "load before anything else" pattern as
`tracer.js` on the backend), initializes `@datadog/browser-rum` with those
values and `allowedTracingUrls: [window.location.origin]`.

That last part is what makes a single HTTP request genuinely traceable
frontend -> backend -> Postgres in APM, not just conceptually adjacent:
each frontend's nginx proxies `/api/*` to its own backend Service
internally (see `nginx.conf`), so from the browser's perspective every API
call is same-origin -- `window.location.origin` alone is sufficient for
RUM to inject trace-propagation headers into it, no CORS configuration or
cross-origin allowlisting needed, and dd-trace on the receiving end (any
reasonably current version; this lab pins `^5.0.0`) picks the trace up
automatically. The result: a RUM session's span for, say, `GET
/api/products` stitches directly into that same request's backend APM
trace. Session Replay is deliberately left off
(`sessionReplaySampleRate: 0`) to keep RUM scoped to tracing rather than
screen recording.

See `docs/student-guide.md` for the exact account setup and env vars, and
`datadog/dashboards/` + `datadog/monitors/` for the dashboard and monitor
definitions themselves.

## What's deliberately simplified for a training lab

| Simplification | What production would do instead |
|---|---|
| One shared RDS instance for all 5 apps | One instance per app/environment |
| Plaintext password comparison for banking/student-portal demo login | bcrypt/argon2 hashing, real session management |
| One shared ALB (`IngressGroup`) across all 5 apps | One ALB per app/environment, plus AWS WAF attached |
| Chaos endpoints reachable over the public Ingress | Chaos hooks gated behind a separate internal-only port/network policy |
| Terraform state stored locally | Remote state (S3 + DynamoDB lock table) |
