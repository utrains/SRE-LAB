#!/usr/bin/env bash
# Breaks something real against the actual RDS database, not an app-level
# toggle. Five apps, five different real Postgres failure classes -- a
# renamed column, a renamed table, a revoked read privilege, a revoked
# write privilege, and a desynced sequence. Every one produces the
# database's own error message and error code, not a synthetic one, and
# every one is reversible with --undo.
#
# Usage: break-schema.sh <app> [--undo]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_DIR="${REPO_ROOT}/.chaos-backup"
TF_DIR="${REPO_ROOT}/terraform"

APP="${1:?usage: break-schema.sh <app> [--undo]}"
MODE="${2:-break}"

# kind: column | table | revoke_select | revoke_insert | sequence
declare -A KIND=(
  [ecommerce]="column"
  [food-delivery]="table"
  [banking]="revoke_select"
  [student-portal]="revoke_insert"
  [support-tickets]="sequence"
)
declare -A TABLE=(
  [ecommerce]="products"
  [food-delivery]="menu_items"
  [banking]="accounts"
  [student-portal]="submissions"
  [support-tickets]="tickets"
)
declare -A COLUMN=(
  [ecommerce]="price_cents"
)
declare -A REPRO_CMD=(
  [ecommerce]='curl -s https://ecommerce.$(cat .lab-domain)/api/cart -H "x-session-id: test"'
  [food-delivery]='curl -s -X POST https://food-delivery.$(cat .lab-domain)/api/orders -H "x-session-id: test" -H "Content-Type: application/json" -d '"'"'{"restaurantId":1,"items":[{"menuItemId":1,"quantity":1}]}'"'"''
  [banking]='TOKEN=$(curl -s -X POST https://banking.$(cat .lab-domain)/api/auth/login -H "Content-Type: application/json" -d '"'"'{"username":"amara.osei","password":"demo123"}'"'"' | jq -r .token)
curl -s https://banking.$(cat .lab-domain)/api/accounts/me -H "Authorization: Bearer $TOKEN"'
  [student-portal]='TOKEN=$(curl -s -X POST https://student-portal.$(cat .lab-domain)/api/auth/login -H "Content-Type: application/json" -d '"'"'{"username":"maya.torres","password":"demo123"}'"'"' | jq -r .token)
curl -s -X POST https://student-portal.$(cat .lab-domain)/api/assignments/1/submit -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '"'"'{"content":"done"}'"'"''
  [support-tickets]='curl -s -X POST https://support-tickets.$(cat .lab-domain)/api/tickets -H "Content-Type: application/json" -d '"'"'{"subject":"test","description":"test"}'"'"''
)

APP_KIND="${KIND[$APP]:-}"
if [[ -z "$APP_KIND" ]]; then
  echo "break-schema.sh has no target configured for '$APP' yet." >&2
  echo "Currently supported: ${!KIND[*]}" >&2
  exit 1
fi

DB_NAME="${APP//-/_}_db"
DB_ROLE="${APP//-/_}_app"
TBL="${TABLE[$APP]}"
COL="${COLUMN[$APP]:-}"
BACKUP="${BACKUP_DIR}/${APP}-schema-break"

cd "$TF_DIR"
RDS_ADDRESS=$(terraform output -raw rds_address)
RDS_MASTER_USER=$(terraform output -raw rds_master_username)
RDS_MASTER_PASSWORD=$(terraform output -raw rds_master_password)
cd "$REPO_ROOT"

run_sql() {
  echo "$1" | kubectl run "pg-break-schema-${APP}" --rm -i --restart=Never -n "$APP" \
    --image=postgres:17-alpine --env="PGPASSWORD=${RDS_MASTER_PASSWORD}" \
    --command -- psql -h "$RDS_ADDRESS" -U "$RDS_MASTER_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -f -
}

query_sql() {
  echo "$1" | kubectl run "pg-query-${APP}" --rm -i --restart=Never -n "$APP" \
    --image=postgres:17-alpine --env="PGPASSWORD=${RDS_MASTER_PASSWORD}" \
    --command -- psql -h "$RDS_ADDRESS" -U "$RDS_MASTER_USER" -d "$DB_NAME" -t -A -v ON_ERROR_STOP=1 -f -
}

case "$APP_KIND" in
  column)
    ERROR_DESC="a real Postgres error: column \"${COL}\" does not exist (code 42703)"
    if [[ "$MODE" == "--undo" ]]; then
      run_sql "ALTER TABLE ${TBL} RENAME COLUMN ${COL}_missing TO ${COL};"
    else
      mkdir -p "$BACKUP_DIR"; echo "column" > "$BACKUP"
      run_sql "ALTER TABLE ${TBL} RENAME COLUMN ${COL} TO ${COL}_missing;"
    fi
    ;;
  table)
    ERROR_DESC="a real Postgres error: relation \"${TBL}\" does not exist (code 42P01)"
    if [[ "$MODE" == "--undo" ]]; then
      run_sql "ALTER TABLE ${TBL}_archived RENAME TO ${TBL};"
    else
      mkdir -p "$BACKUP_DIR"; echo "table" > "$BACKUP"
      run_sql "ALTER TABLE ${TBL} RENAME TO ${TBL}_archived;"
    fi
    ;;
  revoke_select)
    ERROR_DESC="a real Postgres error: permission denied for table ${TBL} (code 42501)"
    if [[ "$MODE" == "--undo" ]]; then
      run_sql "GRANT SELECT ON ${TBL} TO ${DB_ROLE};"
    else
      mkdir -p "$BACKUP_DIR"; echo "revoke_select" > "$BACKUP"
      run_sql "REVOKE SELECT ON ${TBL} FROM ${DB_ROLE};"
    fi
    ;;
  revoke_insert)
    ERROR_DESC="a real Postgres error: permission denied for table ${TBL} (code 42501)"
    if [[ "$MODE" == "--undo" ]]; then
      run_sql "GRANT INSERT ON ${TBL} TO ${DB_ROLE};"
    else
      mkdir -p "$BACKUP_DIR"; echo "revoke_insert" > "$BACKUP"
      run_sql "REVOKE INSERT ON ${TBL} FROM ${DB_ROLE};"
    fi
    ;;
  sequence)
    ERROR_DESC="a real Postgres error: duplicate key value violates unique constraint \"${TBL}_pkey\" (code 23505)"
    if [[ "$MODE" == "--undo" ]]; then
      run_sql "SELECT setval('${TBL}_id_seq', (SELECT COALESCE(MAX(id), 1) FROM ${TBL}));"
    else
      mkdir -p "$BACKUP_DIR"; echo "sequence" > "$BACKUP"
      run_sql "SELECT setval('${TBL}_id_seq', 1, false);"
    fi
    ;;
esac

if [[ "$MODE" == "--undo" ]]; then
  rm -f "$BACKUP"
  echo ""
  echo "Restored. No redeploy needed -- queries succeed again immediately."
  exit 0
fi

cat <<EOF

Done. The next real request against this now fails with ${ERROR_DESC}.
Nothing in the app changed and nothing redeployed.

Reproduce it directly:
${REPRO_CMD[$APP]}

Look for it in Datadog:
  Logs:  service:${APP}-backend status:error
  APM:   Traces > ${APP}-backend, filter to errors

Undo:
  ${BASH_SOURCE[0]} ${APP} --undo
EOF
