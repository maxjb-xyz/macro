# Back up and restore

How to back up and restore a single-node Macro deployment. The approach is
conservative on purpose: stop writers, copy data off-host, verify a restore on
a separate host, and never treat Compose volumes as backups.

## Scope

This plan covers the Compose topology rendered by:

```bash
docker compose config --volumes
```

Current rendered named volumes:

| Data owner | Compose service | Compose volume | Docker volume name | Path in container | Backup class | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Macro Postgres | `postgres` | `db` | `macro_postgres_data` | `/var/lib/postgresql` | required | Primary relational state for Macro services. Prefer logical dumps plus volume snapshots. |
| Redis | `redis` | `cache` | `macro_redis_data` | `/data` | conditional | Redis is partly cache-like, but losing it may lose transient queues/session/last-online state. Back it up for durable appliances until every Redis use is classified as rebuildable. |
| OpenSearch | `search` | `opensearch_data` | `macro_opensearch_data` | `/usr/share/opensearch/data` | recommended | Search index can theoretically be rebuilt from source systems only after a tested reindex runbook exists. Back it up for now. |
| Kafka (Redpanda) | `kafka` | `kafka_data` | `macro_kafka_data` | `/var/lib/redpanda/data` | recommended | Contains broker metadata, offsets, and retained topic data. Required for no-message-loss restore. |
| FusionAuth database | `db` | `db_data` | `fusionauth_db_data` | `/var/lib/postgresql/data` | required | FusionAuth identity, users, tenants, applications, and API-key state. |
| FusionAuth config | `fusionauth` | `fusionauth_config` | `fusionauth_config` | `/usr/local/fusionauth/config` | required | FusionAuth runtime config outside the DB. |
| LocalStack object data | `localstack` | `localstack_data` | `macro_localstack_data` | `/persisted-data` | recommended | S3/SQS/DynamoDB state (durable LocalStack profile). Prefer real S3-compatible storage with versioning for production. |

Bind mounts observed in the rendered stack are source/config mounts, not durable application state, except that local worker services may write development artifacts into the repository checkout. They are not a substitute for backing up service-owned data stores.

## Backup model

Use both logical exports and volume archives:

1. Logical database exports
   - `pg_dumpall` from `postgres` for Macro Postgres.
   - `pg_dumpall` from FusionAuth's `db` service.
   - Store dumps in encrypted off-host storage.
   - Keep dumps even when also taking volume snapshots; logical dumps are easier to inspect and can survive some engine/version changes.

2. Quiesced volume archives
   - Stop app services and writers before copying volume bytes.
   - Archive all required/recommended named volumes with a short manifest.
   - Use helper containers instead of host-specific Docker volume paths.
   - Store archives off-host after local creation.

3. Object storage backups
   - For production, use real S3-compatible object storage with bucket versioning, lifecycle/retention, and provider backup controls.
   - The self-host LocalStack profile stores S3/SQS/DynamoDB in the
     `macro_localstack_data` volume; include it in backups, but prefer real
     object storage with versioning for production.

4. Secrets and env
   - Back up operator-managed secret material separately from repository files: `.env`, reverse-proxy secrets, OAuth/FusionAuth client secrets, SMTP credentials, object-storage credentials, signing keys, and any external-provider configuration.
   - Do not place real secrets in repository docs, artifacts, or unencrypted tarballs.

## Safe backup procedure

1. Confirm the stack resolves and record versions:

```bash
docker compose config --volumes
```

2. Enter maintenance mode at the edge, or otherwise stop user traffic.
3. Stop application writers before copying storage. At minimum, stop the Rust services, worker services, Cloudflare-worker local services, and any public frontend/proxy containers. Leave stateful stores up for logical dumps.
4. Run logical database exports.
5. Stop stateful services before volume archives: `postgres`, `redis`, `search`, `kafka`, `fusionauth`, and FusionAuth `db`.
6. Archive volumes and write a manifest containing commit, Compose files, service image references, env file checksum, volume list, and backup timestamp.
7. Restart the stack and run smoke checks.
8. Copy the backup directory to encrypted off-host storage and verify the remote object checksums.

The script skeleton at `tooling/selfhost/backup-restore.sh` implements the inventory and backup scaffolding and keeps restore behind an explicit destructive flag.

## Restore order

Restore only during a planned outage, preferably onto a separate host first.

1. Install compatible Docker/Compose and check out the intended repository version.
2. Restore operator-owned secrets/env and reverse-proxy configuration.
3. Keep the stack down. Never restore into live writer containers.
4. Create missing Docker volumes.
5. Restore volume archives to empty volumes.
6. Start only stateful services first:
   - `postgres`
   - FusionAuth `db`
   - `redis`
   - `kafka`
   - `search`
   - `fusionauth`
7. Validate stateful health checks and FusionAuth status.
8. Start app services and workers.
9. Run smoke checks for auth, document open/edit/reload, search, file upload/download, channel/message flow, websocket collaboration, and background worker logs.
10. Re-enable user traffic after validation.

Fallback option: if volume restore fails but logical dumps are healthy, restore Postgres and FusionAuth from the dumps, then rebuild OpenSearch/Kafka/Redis only when corresponding rebuild/replay runbooks exist. Until those runbooks are proven, treat this as degraded recovery.

## Upgrade safety rules

- Take a fresh backup and complete a restore drill before image, schema, Compose, or configuration upgrades.
- Never run `docker compose down -v` for routine maintenance. It deletes named volumes.
- Pin service images for durable deployments; do not upgrade from floating tags without a rollback point.
- Do not change the Redpanda node-id (`--node-id 0`) when reusing `macro_kafka_data`; a mismatch makes the broker not find its existing data.
- Treat Postgres major-version upgrades as data migrations, not container replacements. Use logical dump/restore or the official upgrade path.
- Treat OpenSearch major-version upgrades as index migrations with a rollback plan.
- Keep FusionAuth app and DB versions compatible; test kickstart/API readiness after restore.
- Do not assume Redis loss is safe until every Redis-backed feature has an explicit loss/rebuild classification.
- Do not rely on LocalStack for production object durability without adding and testing a dedicated data-volume backup path.
- Record RPO/RTO, retention, encryption target, and last successful restore drill date in operator deployment notes.

## Minimum restore drill acceptance

A restore drill is not complete until a clean host or fresh Docker project can:

- Boot the restored Compose stack without recreating empty state.
- Log in through FusionAuth/passwordless auth.
- Open an existing document and verify persisted edits.
- Find existing content through search.
- Upload and download a file through the configured object-storage path.
- Send and read a channel/message event.
- Show no crash loops in stateful services or background workers.
