#!/usr/bin/env bash
# Apply MacroDB migrations (crates/macro_db_client/migrations) incrementally.
#
# Tracks applied files in a ledger table so re-running on boot only applies NEW
# migrations — i.e. upgrades work, not just first boot.
#
# sqlx-style semantics: each migration runs in a transaction unless its file
# starts with the `-- no-transaction` marker (e.g. CREATE INDEX CONCURRENTLY).
# Up migrations are *.sql EXCEPT *.down.sql; down migrations are ignored.
#
# The ledger lives in its own `_macro` schema (NOT `public`): the baseline
# migration's guard only runs when `public` is empty, and a ledger table in
# `public` would trip that guard and silently skip the baseline.
#
# Runs inside the postgres_bootstrap one-shot container (psql + migration files
# mounted at /migrations).

set -euo pipefail

PSQL="psql -v ON_ERROR_STOP=1 -h postgres -U user -d macrodb"
MIGRATIONS_DIR="/migrations"

# Ledger table. `filename` is the migration filename (unique); idempotent.
$PSQL -q -c 'CREATE SCHEMA IF NOT EXISTS _macro'
$PSQL -q -c 'CREATE TABLE IF NOT EXISTS _macro.migrations (filename text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())'

applied=0
skipped=0
while IFS= read -r file; do
  base="$(basename "$file")"
  case "$base" in
    *.down.sql) continue ;;       # rollback file — skip
  esac

  if $PSQL -tAc "SELECT 1 FROM _macro.migrations WHERE filename = '${base}'" | grep -q 1; then
    skipped=$((skipped + 1))
    continue
  fi

  if head -10 "$file" | grep -qE '^\s*--\s*no-transaction'; then
    # Cannot run in a transaction (e.g. CREATE INDEX CONCURRENTLY).
    $PSQL -q -f "$file"
    $PSQL -q -c "INSERT INTO _macro.migrations(filename) VALUES ('${base}')"
  else
    # Run the migration and record it atomically in one transaction.
    {
      echo "BEGIN;"
      cat "$file"
      echo "INSERT INTO _macro.migrations(filename) VALUES ('${base}');"
      echo "COMMIT;"
    } | $PSQL -q
  fi
  applied=$((applied + 1))
done < <(find "$MIGRATIONS_DIR" -maxdepth 1 -name '*.sql' ! -name '*.down.sql' | sort -n)

echo "migrated macrodb: ${applied} applied, ${skipped} already present"
