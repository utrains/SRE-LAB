#!/usr/bin/env bash
# End-to-end setup: terraform apply -> configure kubectl -> provision Datadog
# RUM apps -> build/push images -> create per-app databases on the shared RDS
# instance -> create k8s secrets -> deploy every app -> install the AWS Load
# Balancer Controller and Ingresses -> optionally install Datadog -> print
# next steps.
#
# Requires: terraform, aws cli (configured), kubectl, docker, helm, jq.
# RDS has no public access, so per-app databases are created via a short-lived
# pod running inside the cluster (the only thing allowed to reach RDS:5432).
#
# Optional: set DATADOG_API_KEY (and DATADOG_APP_KEY, DATADOG_SITE) to also
# install the Datadog Agent, provision a RUM application per app (so browser
# sessions trace end-to-end into each backend's APM traces -- see step 3/10
# and apps/<app>/frontend/src/rum.js), and import dashboards/monitors -- see
# step 10/10.

set -euo pipefail

# This script uses associative arrays (declare -A) and expands possibly-empty
# arrays under `set -u`, both of which need bash 4.4+. macOS still ships bash
# 3.2 as /bin/bash, where this fails several steps in with a confusing
# "declare: -A: invalid option" -- so say so up front instead.
if [ -z "${BASH_VERSINFO:-}" ] \
  || [ "${BASH_VERSINFO[0]}" -lt 4 ] \
  || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "This script needs bash 4.4 or newer (found: ${BASH_VERSION:-not bash})." >&2
  echo "" >&2
  echo "macOS ships bash 3.2. Install a current one and run the script with it:" >&2
  echo "  brew install bash" >&2
  echo "  \$(brew --prefix)/bin/bash ./scripts/$(basename "${BASH_SOURCE[0]}")" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
# Pinned rather than 'latest' so a class all gets the same thing (see step 9).
METRICS_SERVER_VERSION="v0.9.0"

APPS=(ecommerce banking food-delivery student-portal support-tickets)

echo "==> Preflight checks"

missing_tools=()
for tool in terraform aws kubectl docker helm envsubst nslookup curl jq; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if [ "${#missing_tools[@]}" -gt 0 ]; then
  echo "Missing required tool(s): ${missing_tools[*]} -- see Prerequisites in README.md." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon isn't running (or isn't reachable) -- start it and re-run." >&2
  exit 1
fi

if ! CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null); then
  echo "AWS CLI isn't authenticated -- run 'aws configure' (or set up SSO) and re-run." >&2
  exit 1
fi
echo "    AWS identity: ${CALLER_ARN}"
case "$CALLER_ARN" in
  *:root)
    echo "    Running as the AWS account root user -- terraform/eks.tf's caller_is_root guard" \
         "handles this automatically, no extra steps needed." ;;
esac

if [ ! -f "$TF_DIR/terraform.tfvars" ]; then
  echo "terraform/terraform.tfvars not found. Run:" >&2
  echo "  cp terraform/terraform.tfvars.example terraform/terraform.tfvars" >&2
  echo "then edit it to set dns_zone_name, and re-run." >&2
  exit 1
fi

DNS_ZONE_NAME=$(grep -E '^\s*dns_zone_name\s*=' "$TF_DIR/terraform.tfvars" | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$DNS_ZONE_NAME" ] || [ "$DNS_ZONE_NAME" = "example.com" ]; then
  echo "terraform/terraform.tfvars still has the placeholder dns_zone_name -- set it to your real" >&2
  echo "Route 53 hosted zone domain and re-run." >&2
  exit 1
fi

ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$DNS_ZONE_NAME" \
  --query "HostedZones[?Name=='${DNS_ZONE_NAME}.'].Id" --output text | head -n1)
if [ -z "$ZONE_ID" ]; then
  echo "No public Route 53 hosted zone found for '${DNS_ZONE_NAME}' in this AWS account." >&2
  echo "Create one (or point dns_zone_name at a domain that already has one) -- see Prerequisites" >&2
  echo "in README.md." >&2
  exit 1
fi

# Terraform only ever creates records *inside* this hosted zone -- it never
# touches the domain's registrar-level NS delegation. If that delegation
# doesn't point at this zone's nameservers, the 5 app URLs will never
# resolve publicly no matter how correctly everything else deploys. Catch
# that here, before spending ~20 minutes and real money finding out the
# hard way.
ROUTE53_NS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Type=='NS'].ResourceRecords[].Value" --output text \
  | tr '\t' '\n' | sed 's/\.$//' | sort)
PUBLIC_NS=$(nslookup -type=NS "$DNS_ZONE_NAME" 8.8.8.8 2>/dev/null \
  | awk '/nameserver =/{print $NF}' | sed 's/\.$//' | sort)

if [ -z "$PUBLIC_NS" ] || [ "$ROUTE53_NS" != "$PUBLIC_NS" ]; then
  echo "" >&2
  echo "WARNING: '${DNS_ZONE_NAME}' does not appear to be delegated to this Route 53 hosted zone." >&2
  echo "  This hosted zone's nameservers:" >&2
  echo "$ROUTE53_NS" | sed 's/^/    /' >&2
  echo "  What the public internet currently sees for ${DNS_ZONE_NAME}:" >&2
  echo "${PUBLIC_NS:-<no answer -- domain may not be registered/delegated at all>}" | sed 's/^/    /' >&2
  echo "  Infra will still deploy fine either way -- but the 5 app URLs won't resolve publicly" >&2
  echo "  until this is fixed at your domain's registrar (update its NS records to match the" >&2
  echo "  list above)." >&2
  echo "" >&2
  read -r -p "Continue anyway? [y/N] " reply
  case "$reply" in
    [Yy]*) ;;
    *) echo "Aborted. Fix NS delegation (or pick a different dns_zone_name) and re-run." >&2; exit 1 ;;
  esac
fi

echo "==> 1/10 terraform apply"
cd "$TF_DIR"
terraform init -input=false

# The five Route 53 alias records (dns.tf) are gated behind
# create_dns_records, which defaults to false because the ALB they alias
# doesn't exist yet on a first run. On a *re-run* that default is actively
# harmful: a plain apply here deletes all five records, and step 9 doesn't
# recreate them until ~10 minutes later, so every app URL returns NXDOMAIN
# for the whole build-and-deploy phase. That matters because re-running this
# script is the documented way to add Datadog to an existing lab.
#
# So: if the shared ALB is already out there, keep the records. The lookup is
# read-only and falls back to the old behaviour if it fails for any reason
# (no state yet, no permission), which is never worse than not checking.
CREATE_DNS=false
EXISTING_CLUSTER=$(terraform output -raw cluster_name 2>/dev/null || true)
EXISTING_REGION=$(terraform output -raw region 2>/dev/null || true)
if [ -n "$EXISTING_CLUSTER" ] && [ -n "$EXISTING_REGION" ] \
  && terraform state list 2>/dev/null | grep -q '^aws_route53_record\.app\['; then
  ALB_COUNT=$(aws resourcegroupstaggingapi get-resources \
    --region "$EXISTING_REGION" \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${EXISTING_CLUSTER}" \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --query 'length(ResourceTagMappingList)' --output text 2>/dev/null || echo 0)
  if [ "$ALB_COUNT" != "0" ] && [ "$ALB_COUNT" != "None" ]; then
    CREATE_DNS=true
    echo "    existing ALB found -- keeping the Route 53 records instead of"
    echo "    deleting and recreating them (app URLs stay up during this run)"
  fi
fi

terraform apply -auto-approve -var="create_dns_records=${CREATE_DNS}"

CLUSTER_NAME=$(terraform output -raw cluster_name)
REGION=$(terraform output -raw region)
VPC_ID=$(terraform output -raw vpc_id)
RDS_ADDRESS=$(terraform output -raw rds_address)
RDS_PORT=$(terraform output -raw rds_port)
RDS_MASTER_USER=$(terraform output -raw rds_master_username)
RDS_MASTER_PASSWORD=$(terraform output -raw rds_master_password)
ALB_CONTROLLER_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)
LAB_DOMAIN=$(terraform output -raw lab_domain)
CERT_ARN=$(terraform output -raw acm_certificate_arn)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
echo "$LAB_DOMAIN" > "$REPO_ROOT/.lab-domain"

echo "==> 2/10 configure kubectl"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "==> 3/10 provision Datadog RUM applications (optional)"
# Populated (per app) only when both keys are set below. Read with
# ${RUM_APP_IDS[$app]:-} elsewhere, since under set -u a missing key in a
# *declared* (even empty) associative array is fine, but the frontend build
# loop needs that guard either way.
declare -A RUM_APP_IDS
declare -A RUM_CLIENT_TOKENS
# Provisioned RUM ids/tokens are cached here (gitignored) so a later run
# WITHOUT an application key can still bake RUM into the frontend bundles.
# Without this cache, re-running setup.sh with only DATADOG_API_KEY set --
# which is exactly what the README recommends, to avoid duplicating
# dashboards -- rebuilds all 5 frontends with RUM stripped out, and browser
# spans silently disappear from every trace.
RUM_CACHE="$REPO_ROOT/.rum-apps.json"
if [ -n "${DATADOG_API_KEY:-}" ] && [ -n "${DATADOG_APP_KEY:-}" ]; then
  DATADOG_SITE="${DATADOG_SITE:-datadoghq.com}"
  for app in "${APPS[@]}"; do
    rum_name="sre-lab-${app}"
    # List + reuse-by-name rather than always creating: the RUM Applications
    # API has no upsert, and unlike the dashboard/monitor import below (which
    # already duplicates on every re-run -- see README Troubleshooting),
    # duplicate RUM apps would silently orphan the previous run's
    # clientToken, breaking any browser tab that still has it cached.
    existing_id=$(curl -sf "https://api.${DATADOG_SITE}/api/v2/rum/applications" \
      -H "DD-API-KEY: ${DATADOG_API_KEY}" \
      -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
      | jq -r --arg name "$rum_name" '.data[] | select(.attributes.name == $name) | .id' | head -n1)
    if [ -n "$existing_id" ]; then
      echo "    reusing existing RUM application for ${app}"
      # client_token isn't included in the list response, only single-GET.
      client_token=$(curl -sf "https://api.${DATADOG_SITE}/api/v2/rum/applications/${existing_id}" \
        -H "DD-API-KEY: ${DATADOG_API_KEY}" \
        -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
        | jq -r '.data.attributes.client_token')
      RUM_APP_IDS[$app]="$existing_id"
      RUM_CLIENT_TOKENS[$app]="$client_token"
    else
      echo "    creating RUM application for ${app}"
      response=$(curl -sf -X POST "https://api.${DATADOG_SITE}/api/v2/rum/applications" \
        -H "Content-Type: application/json" \
        -H "DD-API-KEY: ${DATADOG_API_KEY}" \
        -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
        -d "{\"data\":{\"type\":\"rum_application_create\",\"attributes\":{\"name\":\"${rum_name}\",\"type\":\"browser\"}}}")
      RUM_APP_IDS[$app]=$(echo "$response" | jq -r '.data.id')
      RUM_CLIENT_TOKENS[$app]=$(echo "$response" | jq -r '.data.attributes.client_token')
    fi
  done

  # Cache for app-key-less re-runs (see RUM_CACHE comment above).
  : > "${RUM_CACHE}.tmp"
  for app in "${APPS[@]}"; do
    jq -n --arg a "$app" --arg id "${RUM_APP_IDS[$app]}" --arg t "${RUM_CLIENT_TOKENS[$app]}" \
      '{($a): {id: $id, token: $t}}' >> "${RUM_CACHE}.tmp"
  done
  jq -s add "${RUM_CACHE}.tmp" > "$RUM_CACHE" && rm -f "${RUM_CACHE}.tmp"

elif [ -n "${DATADOG_API_KEY:-}" ] && [ -f "$RUM_CACHE" ]; then
  echo "    no DATADOG_APP_KEY this run -- reusing cached RUM config from .rum-apps.json"
  echo "    (delete that file if you want frontends rebuilt without RUM)"
  for app in "${APPS[@]}"; do
    cached_id=$(jq -r --arg a "$app" '.[$a].id // empty' "$RUM_CACHE")
    cached_token=$(jq -r --arg a "$app" '.[$a].token // empty' "$RUM_CACHE")
    if [ -n "$cached_id" ] && [ -n "$cached_token" ]; then
      RUM_APP_IDS[$app]="$cached_id"
      RUM_CLIENT_TOKENS[$app]="$cached_token"
    fi
  done
else
  echo "    DATADOG_API_KEY/DATADOG_APP_KEY not set -- skipping. Frontends build and run fine"
  echo "    without RUM; re-run with both set (plus the same DATADOG_SITE if that's non-default)"
  echo "    to add it later -- this step, like Datadog install below, is safe to re-run."
fi

echo "==> 4/10 build and push images to ECR"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

IMAGE_TAG="$(date +%Y%m%d%H%M%S)"
for app in "${APPS[@]}"; do
  for part in backend frontend; do
    image="sre-lab/${app}-${part}"
    echo "    building ${image}:${IMAGE_TAG}"
    BUILD_ARGS=()
    if [ "$part" = "frontend" ] && [ -n "${RUM_APP_IDS[$app]:-}" ]; then
      BUILD_ARGS=(
        --build-arg "VITE_DD_APPLICATION_ID=${RUM_APP_IDS[$app]}"
        --build-arg "VITE_DD_CLIENT_TOKEN=${RUM_CLIENT_TOKENS[$app]}"
        --build-arg "VITE_DD_SITE=${DATADOG_SITE:-datadoghq.com}"
        --build-arg "VITE_DD_SERVICE=${app}-frontend"
        --build-arg "VITE_DD_ENV=lab"
        --build-arg "VITE_DD_VERSION=1.0.0"
      )
    fi
    docker build --platform linux/amd64 "${BUILD_ARGS[@]}" -t "${ECR_REGISTRY}/${image}:${IMAGE_TAG}" "$REPO_ROOT/apps/${app}/${part}"
    docker push "${ECR_REGISTRY}/${image}:${IMAGE_TAG}"
  done
done

echo "==> 5/10 create namespaces"
kubectl apply -f "$REPO_ROOT/namespaces/"

echo "==> 6/10 create per-app databases on shared RDS instance"
for app in "${APPS[@]}"; do
  db_name="${app//-/_}_db"
  db_user="${app//-/_}_app"
  db_password=$(openssl rand -hex 16)

  echo "    provisioning ${db_name} / ${db_user}"
  {
    echo "SELECT 'CREATE DATABASE ${db_name}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db_name}')\\gexec"
    echo "DO \$\$ BEGIN CREATE ROLE ${db_user} WITH LOGIN PASSWORD '${db_password}'; EXCEPTION WHEN duplicate_object THEN ALTER ROLE ${db_user} WITH PASSWORD '${db_password}'; END \$\$;"
    echo "GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};"
  } | kubectl run "pg-init-${app}" --rm -i --restart=Never -n "$app" \
      --image=postgres:17-alpine --env="PGPASSWORD=${RDS_MASTER_PASSWORD}" \
      --command -- psql -h "$RDS_ADDRESS" -U "$RDS_MASTER_USER" -d postgres -v ON_ERROR_STOP=1 -f -

  cat "$REPO_ROOT/apps/${app}/backend/sql/init.sql" | kubectl run "pg-schema-${app}" --rm -i --restart=Never -n "$app" \
      --image=postgres:17-alpine --env="PGPASSWORD=${RDS_MASTER_PASSWORD}" \
      --command -- psql -h "$RDS_ADDRESS" -U "$RDS_MASTER_USER" -d "$db_name" -v ON_ERROR_STOP=1 -f -

  echo "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${db_user}; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${db_user};" \
    | kubectl run "pg-grant-${app}" --rm -i --restart=Never -n "$app" \
      --image=postgres:17-alpine --env="PGPASSWORD=${RDS_MASTER_PASSWORD}" \
      --command -- psql -h "$RDS_ADDRESS" -U "$RDS_MASTER_USER" -d "$db_name" -v ON_ERROR_STOP=1 -f -

  kubectl create secret generic "${app}-db-credentials" -n "$app" \
    --from-literal=PGHOST="$RDS_ADDRESS" \
    --from-literal=PGPORT="$RDS_PORT" \
    --from-literal=PGDATABASE="$db_name" \
    --from-literal=PGUSER="$db_user" \
    --from-literal=PGPASSWORD="$db_password" \
    --dry-run=client -o yaml | kubectl apply -f -
done

echo "==> 7/10 deploy food-delivery redis"
kubectl apply -f "$REPO_ROOT/apps/food-delivery/redis/deployment.yaml"

echo "==> 8/10 deploy all apps"
for app in "${APPS[@]}"; do
  k8s_dir="$REPO_ROOT/apps/${app}/k8s"
  for manifest in "$k8s_dir"/*.yaml; do
    ECR_REGISTRY="$ECR_REGISTRY" IMAGE_TAG="$IMAGE_TAG" envsubst '${ECR_REGISTRY} ${IMAGE_TAG}' < "$manifest" | kubectl apply -f -
  done
done

# A successful `kubectl apply` only means the API server accepted the manifest.
# It says nothing about whether the new pods ever became Ready -- a rollout can
# stall on a bad image, a failed probe, an OOMKill loop or a namespace quota
# with no headroom for the surge pod, and this script would still exit 0 with
# every app quietly running the previous version. That is the exact failure
# mode docs/runbooks/failed-rollout.md is about, so don't ship it here.
echo "    verifying every rollout actually became healthy"
rollout_failures=()
for app in "${APPS[@]}"; do
  for component in backend frontend; do
    if ! kubectl -n "$app" rollout status "deployment/${app}-${component}" --timeout=180s >/dev/null 2>&1; then
      rollout_failures+=("${app}/${app}-${component}")
    fi
  done
done

if [ ${#rollout_failures[@]} -gt 0 ]; then
  echo "" >&2
  echo "ERROR: these deployments never became healthy:" >&2
  for f in "${rollout_failures[@]}"; do
    ns="${f%%/*}"; deploy="${f##*/}"
    echo "  - $f" >&2
    kubectl -n "$ns" get pods -l "app=${deploy}" --no-headers 2>/dev/null | sed 's/^/      /' >&2
    kubectl -n "$ns" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null \
      | tail -3 | sed 's/^/      /' >&2
  done
  echo "" >&2
  echo "Diagnose with: kubectl -n <namespace> describe pod <pod>" >&2
  echo "See docs/runbooks/failed-rollout.md. Fix the cause and re-run this script." >&2
  exit 1
fi

echo "==> 9/10 install metrics-server + the AWS Load Balancer Controller, apply Ingress, and create DNS records"

# metrics-server serves the metrics.k8s.io API. Without it `kubectl top` fails
# and -- more importantly for this lab -- every HorizontalPodAutoscaler sits at
# `cpu: <unknown>/70%` forever and can never scale, which makes
# scripts/chaos/cpu-spike.sh's whole point (watch the HPA scale out) impossible
# to demonstrate. EKS does not ship it by default.
echo "    installing metrics-server"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" >/dev/null
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ALB_CONTROLLER_ROLE_ARN" \
  --wait --timeout=5m

for manifest in "$REPO_ROOT"/ingress/*.yaml; do
  LAB_DOMAIN="$LAB_DOMAIN" CERT_ARN="$CERT_ARN" envsubst '${LAB_DOMAIN} ${CERT_ARN}' < "$manifest" | kubectl apply -f -
done

echo ""
echo "==> Waiting for the ALB to come up (can take a couple of minutes on a fresh cluster)..."
for i in $(seq 1 30); do
  ALB_HOST=$(kubectl -n ecommerce get ingress ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$ALB_HOST" ] && break
  sleep 10
done

if [ -z "$ALB_HOST" ]; then
  echo "ALB hostname didn't appear in time -- check 'kubectl -n ecommerce describe ingress ecommerce' and re-run this script."
  exit 1
fi

# The Route 53 alias records (dns.tf) look the ALB up by tag, which only
# works once it exists -- that's why create_dns_records defaults to false on
# the terraform apply in step 1 and only gets turned on here.
echo "==> Creating Route 53 DNS records for the ALB (*.${LAB_DOMAIN})"
cd "$TF_DIR"
terraform apply -auto-approve -var="create_dns_records=true"
cd "$REPO_ROOT"

echo "==> 10/10 install the Datadog Agent (optional)"
if [ -z "${DATADOG_API_KEY:-}" ]; then
  echo "    DATADOG_API_KEY not set -- skipping. Everything above is safe to"
  echo "    re-run, so install it later with:"
  echo "      DATADOG_API_KEY=<key> [DATADOG_APP_KEY=<key>] [DATADOG_SITE=<site>] ./scripts/setup.sh"
  DATADOG_INSTALLED=false
else
  DATADOG_SITE="${DATADOG_SITE:-datadoghq.com}"

  # Existence check rather than `kubectl apply`: step 5/10 already created this
  # namespace (with a label) via namespaces/datadog.yaml, and applying a bare
  # Namespace object on top would silently strip that label via the normal
  # 3-way merge (fields owned by the previous apply but absent from this one
  # get removed). Only create it if it's genuinely missing.
  kubectl get namespace datadog >/dev/null 2>&1 || kubectl create namespace datadog

  SECRET_ARGS=(--from-literal "api-key=${DATADOG_API_KEY}")
  if [ -n "${DATADOG_APP_KEY:-}" ]; then
    SECRET_ARGS+=(--from-literal "app-key=${DATADOG_APP_KEY}")
  fi
  kubectl create secret generic datadog-secret --namespace datadog "${SECRET_ARGS[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -

  helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
  helm repo update >/dev/null

  HELM_ARGS=(--set "datadog.site=${DATADOG_SITE}")
  if [ -n "${DATADOG_APP_KEY:-}" ]; then
    HELM_ARGS+=(--set "datadog.appKeyExistingSecret=datadog-secret")
  fi
  helm upgrade --install datadog datadog/datadog \
    --namespace datadog \
    -f "$REPO_ROOT/datadog/helm-values.yaml" \
    "${HELM_ARGS[@]}"

  # A Secret-only change (e.g. switching accounts on a re-run) isn't picked up
  # by already-running pods and isn't detected as a Helm diff either --
  # restart explicitly so the agent always ends up on the key/site just set.
  if kubectl get daemonset datadog -n datadog >/dev/null 2>&1; then
    kubectl rollout restart daemonset/datadog -n datadog >/dev/null
    kubectl rollout restart deployment/datadog-cluster-agent -n datadog >/dev/null
  fi

  echo "    waiting for the agent to come up..."
  for i in $(seq 1 30); do
    kubectl get daemonset datadog -n datadog >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl rollout status daemonset/datadog -n datadog --timeout=180s
  kubectl rollout status deployment/datadog-cluster-agent -n datadog --timeout=180s
  DATADOG_INSTALLED=true

  DATADOG_DASHBOARDS_IMPORTED=false
  if [ -n "${DATADOG_APP_KEY:-}" ]; then
    echo "    importing dashboards and monitors"
    for f in "$REPO_ROOT"/datadog/dashboards/*.json; do
      curl -sf -X POST "https://api.${DATADOG_SITE}/api/v1/dashboard" \
        -H "Content-Type: application/json" \
        -H "DD-API-KEY: ${DATADOG_API_KEY}" \
        -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
        -d @"$f" > /dev/null
    done
    # Unlike dashboards (which the Datadog API happily duplicates on every
    # re-run), monitors reject an exact duplicate outright with a 400 --
    # which, under set -e, would abort the whole script right at the last
    # step. Update-by-name instead: every monitor here carries
    # team:sre-lab, so list by that tag and PUT to the existing id if a
    # name match is found, POST only for genuinely new monitors.
    for f in "$REPO_ROOT"/datadog/monitors/*.json; do
      monitor_name=$(jq -r '.name' "$f")
      existing_monitor_id=$(curl -sf "https://api.${DATADOG_SITE}/api/v1/monitor?monitor_tags=team%3Asre-lab" \
        -H "DD-API-KEY: ${DATADOG_API_KEY}" \
        -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
        | jq -r --arg name "$monitor_name" '.[] | select(.name == $name) | .id' | head -n1)
      if [ -n "$existing_monitor_id" ]; then
        curl -sf -X PUT "https://api.${DATADOG_SITE}/api/v1/monitor/${existing_monitor_id}" \
          -H "Content-Type: application/json" \
          -H "DD-API-KEY: ${DATADOG_API_KEY}" \
          -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
          -d @"$f" > /dev/null
      else
        curl -sf -X POST "https://api.${DATADOG_SITE}/api/v1/monitor" \
          -H "Content-Type: application/json" \
          -H "DD-API-KEY: ${DATADOG_API_KEY}" \
          -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
          -d @"$f" > /dev/null
      fi
    done
    DATADOG_DASHBOARDS_IMPORTED=true
  fi
fi

echo ""
echo "================================================================"
echo " Setup complete."
echo "================================================================"
echo "All 5 apps share this one ALB (routed by hostname via an IngressGroup)."
echo "DNS is live in Route 53 -- these URLs work immediately, no manual step:"
echo ""
echo "  https://ecommerce.${LAB_DOMAIN}"
echo "  https://banking.${LAB_DOMAIN}"
echo "  https://food-delivery.${LAB_DOMAIN}"
echo "  https://student-portal.${LAB_DOMAIN}"
echo "  https://support-tickets.${LAB_DOMAIN}"
echo ""
if [ "$DATADOG_INSTALLED" = "true" ]; then
  if [ "$DATADOG_DASHBOARDS_IMPORTED" = "true" ]; then
    echo "Datadog Agent installed and reporting, dashboards and monitors imported."
  else
    echo "Datadog Agent installed and reporting. Set DATADOG_APP_KEY and re-run to"
    echo "also import the dashboards and monitors."
  fi
else
  echo "Next: install the Datadog Agent with your own API key:"
  echo "  DATADOG_API_KEY=<key> [DATADOG_APP_KEY=<key>] [DATADOG_SITE=<site>] ./scripts/setup.sh"
fi
if [ -n "${DATADOG_API_KEY:-}" ] && [ -n "${DATADOG_APP_KEY:-}" ]; then
  echo "Frontends were built with Datadog RUM enabled -- browser sessions trace"
  echo "end-to-end into each backend's APM traces in APM > Traces."
fi
