# Self-host update & rollback runbook

How to apply a new Macro release to a single-host self-host deployment and roll
back to a known-good state if it breaks. Uses the pinned-image + Compose-overlay
model from `docs/selfhost/published-release-images.md`.

## Model

- **State** lives in named volumes (Postgres, FusionAuth, LocalStack S3/SQS/DDB,
  Kafka, Redis, OpenSearch) — never in containers.
- **Code** is immutable per-service images tagged `sha-<full-sha>` (and
  `:latest` / `v*` from CI), referenced by `compose.published.yml`.
- **Config** is `.env` (and `.env.selfhost` if you split it). Both are
  operator-owned and gitignored.

So an update is: new image tag + (optionally) new migrations applied by the
`postgres_bootstrap` one-shot on boot. A rollback is: restore the previous tag,
previous env, and (if a migration can't be reversed) restore the database from
backup.

## 1. Before updating — record the known-good state

```bash
cd /path/to/macro

# Current commit and image tag
git rev-parse HEAD
grep -E '^MACRO_RELEASE_IMAGE_TAG=' .env

# Config checksums (so you can detect accidental edits later)
sha256sum .env .env.selfhost 2>/dev/null

# Backup ID you can restore to
docker compose -f compose.yml -f docker/selfhost/compose.frontend.yml ps
```

## 2. Back up

```bash
./tooling/selfhost/backup-restore.sh backup --out /opt/macro-backups/
```

Note the backup path and the `commit=`/`compose_file=` lines it prints — record
them alongside step 1. If `backup-restore.sh` isn't your tool, run your own
`pg_dump` + volume snapshot and note the restore steps.

## 3. Apply the update

```bash
git pull                       # pull the release commit
git log --oneline -1           # confirm the target commit

# Point at the new images. :latest tracks main; pin a sha for reproducibility:
#   MACRO_RELEASE_IMAGE_TAG=sha-<full-sha>   (CI publishes this on every push)
#   MACRO_RELEASE_IMAGE_TAG=v2026.x.y.z      (CI publishes this on v* tags)
$EDITOR .env   # set MACRO_RELEASE_IMAGE_TAG to the new tag

docker compose --project-directory . \
  -f compose.yml \
  -f docker/selfhost/compose.frontend.yml \
  -f docker/selfhost/compose.published.yml \
  -f docker/selfhost/compose.production.yml \
  --env-file .env up -d --wait
```

`up -d --wait` applies new migrations (via the `postgres_bootstrap` one-shot,
which runs the `_macro.migrations` ledger — only NEW migrations are applied) and
waits for healthy services.

## 4. Smoke test

Run `docs/selfhost/smoke-test-spec.md`, or at minimum confirm:

```bash
docker compose -f compose.yml -f docker/selfhost/compose.frontend.yml ps \
  | grep -E 'unhealthy|Exited|Restarting' || echo "all healthy"

curl -fsS http://localhost/ >/dev/null && echo "frontend reachable"
```

Verify login, document/task/email flows, search, and websocket reconnect on your
own accounts. A release is only "done" when the smoke plan passes after a clean
boot **and** after a `docker restart`.

## 5. Roll back if it breaks

### 5a. Code-only rollback (no destructive migration)

```bash
$EDITOR .env   # set MACRO_RELEASE_IMAGE_TAG back to the previous tag

docker compose --project-directory . \
  -f compose.yml \
  -f docker/selfhost/compose.frontend.yml \
  -f docker/selfhost/compose.published.yml \
  -f docker/selfhost/compose.production.yml \
  --env-file .env up -d --wait
```

### 5b. Full rollback (env + data)

If the update changed env values or ran a migration that isn't backward
compatible, restore everything:

```bash
# 1. Restore the previous env (gitignored — restore from your own copy/secret store)
# 2. Restore the database from the step-2 backup
./tooling/selfhost/backup-restore.sh restore --from /opt/macro-backups/<backup-id>

# 3. Bring the previous image tag back up
$EDITOR .env   # previous MACRO_RELEASE_IMAGE_TAG
docker compose --project-directory . \
  -f compose.yml \
  -f docker/selfhost/compose.frontend.yml \
  -f docker/selfhost/compose.published.yml \
  -f docker/selfhost/compose.production.yml \
  --env-file .env up -d --wait
```

## 6. After a successful update

- Re-run the smoke plan and record the result.
- Keep the previous `sha-*` tag available for at least one release cycle so a
  one-line rollback (5a) is always possible.
- Prune old images only after the current version is confirmed stable:
  `docker image prune -a --filter "until=168h"`.

## Guardrails

- **Never** run `docker compose down -v` — it deletes all data volumes.
- Prefer `sha-<full-sha>` tags over `:latest` for reproducible rollbacks; keep
  `:latest` only for staging.
- If `MACRO_RELEASE_IMAGE_TAG` is changed but a service still shows the old
  version, confirm `compose.published.yml` overrides that service (JS/worker
  services may still use dev images until dedicated release images exist).
- A migration that can't be safely reversed is the trigger for 5b (full data
  restore), not 5a.
