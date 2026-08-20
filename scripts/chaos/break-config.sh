#!/usr/bin/env bash
# DevOps failure mode: a config change that passes review, merges cleanly, and
# only breaks on the next pod restart.
#
# Patches the backend's ConfigMap so the container listens on a port nothing
# else in the cluster knows about, then rolls the Deployment to pick it up.
# Both probes in apps/<app>/k8s/deployment-backend.yaml still target 4000, so
# new pods start, get connection-refused on every probe, never join the
# Service, and eventually CrashLoopBackOff on the failed liveness check. The
# old ReplicaSet keeps serving the whole time -- which is exactly why this
# class of bug reaches production and then sits there unnoticed until a node
# recycles.
#
# Usage: break-config.sh <app> [--undo]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_DIR="${REPO_ROOT}/.chaos-backup"

APP="${1:?usage: break-config.sh <app> [--undo]}"
MODE="${2:-break}"

NS="$APP"
CM="${APP}-backend-config"
DEPLOY="${APP}-backend"
BACKUP="${BACKUP_DIR}/${APP}-backend-config.port"
BAD_PORT=4001

if [[ "$MODE" == "--undo" ]]; then
  GOOD_PORT="$(cat "$BACKUP" 2>/dev/null || echo 4000)"
  kubectl -n "$NS" patch configmap "$CM" \
    -p "{\"data\":{\"PORT\":\"${GOOD_PORT}\"}}"
  kubectl -n "$NS" rollout restart "deployment/$DEPLOY"
  rm -f "$BACKUP"
  echo ""
  echo "PORT restored to ${GOOD_PORT} and ${DEPLOY} rolled. Watch it recover:"
  echo "  kubectl -n ${NS} rollout status deployment/${DEPLOY}"
  exit 0
fi

mkdir -p "$BACKUP_DIR"
# Never overwrite an existing backup. Running a chaos script twice without
# an --undo in between would otherwise save the ALREADY-BROKEN values over
# the good ones, and --undo would then faithfully restore the fault.
if [ -f "$BACKUP" ]; then
  echo "note: a fault is already active here -- keeping the original backup (PORT=$(cat "$BACKUP"))"
else
  kubectl -n "$NS" get configmap "$CM" -o jsonpath='{.data.PORT}' > "$BACKUP"
fi

echo "Patching ${CM}: PORT $(cat "$BACKUP") -> ${BAD_PORT}"
kubectl -n "$NS" patch configmap "$CM" -p "{\"data\":{\"PORT\":\"${BAD_PORT}\"}}"

echo ""
echo "ConfigMap changed. Note that nothing is broken yet -- env vars are read"
echo "at container start, so the running pods keep serving on 4000 until"
echo "something restarts them. Rolling the Deployment now to simulate the next"
echo "deploy (or a node recycle) landing on the new config:"
kubectl -n "$NS" rollout restart "deployment/$DEPLOY"

cat <<EOF

Watch the new pods fail their probes and the rollout stall:
  kubectl -n ${NS} get pods -w
  kubectl -n ${NS} describe pod \$(kubectl -n ${NS} get pods -l app=${DEPLOY} --sort-by=.metadata.creationTimestamp -o name | tail -1)
  kubectl -n ${NS} rollout status deployment/${DEPLOY} --timeout=60s

Undo:
  ${BASH_SOURCE[0]} ${APP} --undo
EOF
