#!/usr/bin/env bash
# Apply MacroDB migrations (crates/macro_db_client/migrations) in version order.
#
# sqlx-style semantics: every migration runs in a transaction unless its file
# starts with the `-- no-transaction` marker (e.g. CREATE INDEX CONCURRENTLY).
# Up migrations are *.sql files EXCEPT *.down.sql; down migrations are ignored.
#
# Runs inside the postgres_bootstrap one-shot container (psql + migration files
# mounted at /migrations). Connections go to the `postgres` service.

set -euo pipefail

PSQL="psql -v ON_ERROR_STOP=1 -h postgres -U user -d macrodb"
MIGRATIONS_DIR="/migrations"

applied=0
# Sort numerically by the leading version timestamp. `sort -n` handles mixed
# widths (0001_... and 2025... and 2026...) because the prefix is numeric.
while IFS= read -r file; do
  base="$(basename "$file")"
  case "$base" in
    *.down.sql) continue ;;       # rollback file — skip
  esac

  # Detect sqlx's `-- no-transaction` marker in the first 10 lines.
  if head -10 "$file" | grep -qE '^\s*--\s*no-transaction'; then
    $PSQL -q -f "$file"
  else
    $PSQL -q -1 -f "$file"
  fi
  applied=$((applied + 1))
done < <(find "$MIGRATIONS_DIR" -maxdepth 1 -name '*.sql' ! -name '*.down.sql' | sort -n)

echo "migrated macrodb: applied ${applied} migrations"
