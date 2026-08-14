#!/usr/bin/env bash
# One-shot MacroDB bootstrap: wait for Postgres, then apply migrations if the
# schema is empty. Runs inside the postgres_bootstrap container.
#
# NOTE: postgres creates `macrodb` itself on fresh initdb (POSTGRES_DB=macrodb),
# so the database always exists. The migration gate is therefore "are there
# tables yet", not "does the database exist".

set -euo pipefail

PSQL="psql -h postgres -U user -d postgres"

# Postgres restarts once after a fresh initdb; wait for a stable connection.
ready=0
for i in $(seq 1 60); do
  if $PSQL -tAc 'SELECT 1' >/dev/null 2>&1; then
    ready=1
    break
  fi
  echo "waiting for postgres ($i/60)..."
  sleep 2
done

if [ "$ready" -ne 1 ]; then
  echo "postgres never became reachable" >&2
  exit 1
fi

table_count="$($PSQL -d macrodb -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')")"

if [ "$table_count" -gt 0 ]; then
  echo "macrodb already migrated (${table_count} tables) — skipping"
  exit 0
fi

echo "macrodb is empty — applying migrations"
/bin/bash /migrate.sh
