#!/usr/bin/env bash
# DevOps failure mode: an edge misroute. Every pod is healthy, every dashboard
# is green, and users get the wrong application.
#
# Repoints the app's Ingress rule from <app>-frontend:80 to <app>-backend:4000
# -- the shape of a copy-paste mistake in ingress/<app>-ingress.yaml. Both the
# Service and the port exist, so the AWS Load Balancer Controller reconciles it
# happily and swings the shared ALB's target group onto the backend pods. The
# ALB then health-checks "/" against an Express app that has no "/" route, gets
# a 404, and marks every target unhealthy.
#
# What happens next surprises people, and is the point of the exercise: an ALB
# whose target group has NO healthy targets fails open and forwards to them
# anyway, so users never see a clean 503. They get the backend's own
# "404 Cannot GET /" (with X-Powered-By: Express in the headers) while /api/*
# keeps returning 200 -- and Kubernetes reports nothing wrong at all.
#
# Usage: break-ingress.sh <app> [--undo]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_DIR="${REPO_ROOT}/.chaos-backup"
LAB_DOMAIN="${LAB_DOMAIN:-$(cat "$REPO_ROOT/.lab-domain" 2>/dev/null || echo '<your-domain>')}"

APP="${1:?usage: break-ingress.sh <app> [--undo]}"
MODE="${2:-break}"

NS="$APP"
ING="$APP"
BACKUP="${BACKUP_DIR}/${APP}-ingress.backend"
SVC_PATH="/spec/rules/0/http/paths/0/backend/service"

patch_backend() {
  kubectl -n "$NS" patch ingress "$ING" --type=json -p "[
    {\"op\": \"replace\", \"path\": \"${SVC_PATH}/name\", \"value\": \"$1\"},
    {\"op\": \"replace\", \"path\": \"${SVC_PATH}/port/number\", \"value\": $2}
  ]"
}

if [[ "$MODE" == "--undo" ]]; then
  if [[ -f "$BACKUP" ]]; then
    # kubectl jsonpath writes no trailing newline, so read returns non-zero
    # even though it populated both variables -- and under set -e that would
    # abort the undo before it patched anything. Newer backups end with a
    # newline; '|| true' keeps older ones working too.
    read -r GOOD_SVC GOOD_PORT < "$BACKUP" || true
  else
    GOOD_SVC="${APP}-frontend"
    GOOD_PORT=80
  fi
  patch_backend "$GOOD_SVC" "$GOOD_PORT"
  rm -f "$BACKUP"
  cat <<EOF

Ingress repointed at ${GOOD_SVC}:${GOOD_PORT}. The controller takes a minute or
two to reconcile and for the ALB target group to report healthy again:
  curl -o /dev/null -w "%{http_code}\n" https://${APP}.${LAB_DOMAIN}/
EOF
  exit 0
fi

mkdir -p "$BACKUP_DIR"
# Never overwrite an existing backup. Running a chaos script twice without
# an --undo in between would otherwise save the ALREADY-BROKEN values over
# the good ones, and --undo would then faithfully restore the fault.
if [ ! -f "$BACKUP" ]; then
  kubectl -n "$NS" get ingress "$ING" \
    -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name} {.spec.rules[0].http.paths[0].backend.service.port.number}{"\n"}' \
    > "$BACKUP"
else
  echo "note: a fault is already active here -- keeping the original backup"
fi
echo "Current Ingress backend: $(cat "$BACKUP")"

echo "Repointing ${ING} at ${APP}-backend:4000 ..."
patch_backend "${APP}-backend" 4000

cat <<EOF

Give the AWS Load Balancer Controller a minute or two to reconcile, then:

  # what users now get -- read the headers, they name which service answered
  curl -i https://${APP}.${LAB_DOMAIN}/ | head -12

  # ...while the API the ALB is now pointed at answers perfectly well
  curl -o /dev/null -w "%{http_code}\n" https://${APP}.${LAB_DOMAIN}/api/restaurants

  # meanwhile, in Kubernetes, nothing is wrong
  kubectl -n ${NS} get pods
  kubectl -n ${NS} get endpoints

  # the change itself, and what the controller did with it
  kubectl -n ${NS} describe ingress ${ING}
  kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=50 | grep ${APP}

Datadog APM shows the backend unexpectedly receiving GET / and returning 404.
Open Trace Explorer and filter service:${APP}-backend resource_name:"GET /";
confirm http.status_code:404 on the spans. The Scenario Signals dashboard and
Unexpected backend root traffic monitor use the same real trace metric. ALB
target health still lives in AWS:
  aws elbv2 describe-target-health --region us-east-1 --target-group-arn <arn>
See docs/runbooks/ingress-502s.md.

Undo:
  ${BASH_SOURCE[0]} ${APP} --undo
EOF
