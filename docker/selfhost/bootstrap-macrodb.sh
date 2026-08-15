#!/usr/bin/env bash
# One-shot MacroDB bootstrap: wait for Postgres, ensure macrodb exists, then
# apply migrations incrementally. Runs inside the postgres_bootstrap container.
#
# NOTE: postgres creates `macrodb` itself on fresh initdb (POSTGRES_DB=macrodb).
# Migration is idempotent/incremental via the `_macro_migrations` ledger, so
# this runs on every boot and only applies new migrations (safe for upgrades).

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

# Ensure macrodb exists (defensive; postgres already creates it via POSTGRES_DB).
if ! $PSQL -tAc "SELECT 1 FROM pg_database WHERE datname = 'macrodb'" | grep -q 1; then
  createdb -h postgres -U user macrodb
fi

/bin/bash /migrate.sh
