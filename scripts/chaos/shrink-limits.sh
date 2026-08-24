#!/usr/bin/env bash
# DevOps failure mode: a resource limit tuned down to fit a quota, with no idea
# what the process actually needs at runtime.
#
# Patches the backend Deployment's memory request and limit down to 20Mi. A
# backend needs roughly 31Mi resident once Express, pg and dd-trace are
# loaded, so 20Mi is below what it takes just to start: new pods are
# OOMKilled during startup (exit 137) and land in CrashLoopBackOff, while the
# old pods keep serving. Nothing leaked; the resource ceiling moved.
#
# The value matters more than it looks. Measured on this lab: 64Mi and 32Mi
# both leave the process running (32Mi only kills it occasionally, since
# usage sits right at the line), so anything less decisive than 20Mi gives
# students a scenario that quietly doesn't reproduce.
#
# 20Mi is still above the namespace LimitRange's 16Mi floor, so the API
# server accepts it without complaint. That is the point of the scenario:
# admission control enforces bounds, not whether a number makes sense for a
# given workload.
#
# Usage: shrink-limits.sh <app> [mi] [--undo]   (default 20Mi)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_DIR="${REPO_ROOT}/.chaos-backup"

APP="${1:?usage: shrink-limits.sh <app> [mi] [--undo]}"
ARG2="${2:-20}"
if [[ "$ARG2" == "--undo" ]]; then
  MODE="--undo"; MI=20
else
  MI="$ARG2"; MODE="${3:-break}"
fi

NS="$APP"
DEPLOY="${APP}-backend"
BACKUP="${BACKUP_DIR}/${APP}-backend.memory"
RES_PATH="/spec/template/spec/containers/0/resources"

patch_memory() {
  kubectl -n "$NS" patch deployment "$DEPLOY" --type=json -p "[
    {\"op\": \"replace\", \"path\": \"${RES_PATH}/requests/memory\", \"value\": \"$1\"},
    {\"op\": \"replace\", \"path\": \"${RES_PATH}/limits/memory\", \"value\": \"$2\"}
  ]"
}

if [[ "$MODE" == "--undo" ]]; then
  if [[ -f "$BACKUP" ]]; then
    # See break-ingress.sh: kubectl jsonpath emits no trailing newline, so a
    # bare read returns non-zero and set -e would abort the undo.
    read -r GOOD_REQ GOOD_LIM < "$BACKUP" || true
  else
    GOOD_REQ=128Mi
    GOOD_LIM=256Mi
  fi
  patch_memory "$GOOD_REQ" "$GOOD_LIM"
  rm -f "$BACKUP"
  echo ""
  echo "Memory restored to requests=${GOOD_REQ} limits=${GOOD_LIM}. Watch it recover:"
  echo "  kubectl -n ${NS} rollout status deployment/${DEPLOY}"
  exit 0
fi

mkdir -p "$BACKUP_DIR"
# Never overwrite an existing backup. Running a chaos script twice without
# an --undo in between would otherwise save the ALREADY-BROKEN values over
# the good ones, and --undo would then faithfully restore the fault.
if [ ! -f "$BACKUP" ]; then
  kubectl -n "$NS" get deployment "$DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory} {.spec.template.spec.containers[0].resources.limits.memory}{"\n"}' \
    > "$BACKUP"
else
  echo "note: a fault is already active here -- keeping the original backup"
fi
echo "Current memory (requests limits): $(cat "$BACKUP")"

echo "Shrinking ${DEPLOY} memory request and limit to ${MI}Mi ..."
patch_memory "${MI}Mi" "${MI}Mi"

cat <<EOF

The patch triggers a rolling update on its own -- no restart needed, the pod
template changed. New pods usually die during startup; if one survives, the
first real request through it finishes the job.

  kubectl -n ${NS} get pods -w
  kubectl -n ${NS} describe pod \$(kubectl -n ${NS} get pods -l app=${DEPLOY} --sort-by=.metadata.creationTimestamp -o name | tail -1) | grep -A5 "Last State"
  kubectl -n ${NS} get events --sort-by=.lastTimestamp | tail -20

Expect Reason: OOMKilled, and the [SRE Lab] Pod restarts monitor to fire.
See docs/runbooks/oomkill.md.

Undo:
  ${BASH_SOURCE[0]} ${APP} --undo
EOF
