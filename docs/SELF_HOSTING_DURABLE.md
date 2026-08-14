# Durable Docker Compose operator contract

This is the smallest operator layer on top of the upstream local Compose
stack. It is for a single Docker host and keeps the application service graph
unchanged. It does not turn the local development images, secrets, or local
AWS emulation into a production service.

## Start and stop

Create an operator-owned `.env` from `.env.example`, then replace every local
secret and integration placeholder before exposing the host:

```bash
cp .env.example .env
docker compose --project-directory . \
  -f compose.yml \
  -f docker/docker-compose.self-host.yml config >/dev/null
docker compose --project-directory . \
  -f compose.yml \
  -f docker/docker-compose.self-host.yml up -d
```

The overlay adds `restart: unless-stopped` and graceful stop windows to the
existing Postgres, Redis, Kafka, OpenSearch, and FusionAuth containers. It does
not use `down -v`; removing volumes is an intentional data-destruction event.

Before enabling real users, review the integration contract in
[`SELF_HOSTING_INTEGRATIONS.md`](SELF_HOSTING_INTEGRATIONS.md). The Compose
stack preserves Macro's integration surface, but several features require
operator-owned external credentials, provider approvals, public HTTPS callback
URLs, and webhook routing before they are functional.

## Durable data

The base Compose files already use explicit single-host volumes:

| Data | Volume | Backup priority |
| --- | --- | --- |
| Macro Postgres | `macro_postgres_data` | required |
| Redis | `macro_redis_data` | recommended; rebuildable only if queue loss is acceptable |
| Kafka | `macro_kafka_data` | recommended; rebuildable only if replay loss is acceptable |
| OpenSearch | `macro_opensearch_data` | recommended; rebuildable from Postgres only if that is verified |
| FusionAuth database | `fusionauth_db_data` | required |
| FusionAuth config | `fusionauth_config` | required |

Back up the volumes and databases to storage outside the Docker host. Volume
names are stable across container recreation but are not backups. Pin image
versions and test restores on a separate host before upgrades.

## Hostname and TLS assumptions

The stack is single-host and container-to-container URLs use Compose service
names. Publish only the intended web entrypoint through an operator-managed
reverse proxy. Set `BASE_URL`, `FUSIONAUTH_PUBLIC_URL`, and
`FUSIONAUTH_OAUTH_REDIRECT_URI` to the public HTTPS hostname; never use the
internal names or `localhost` outside a local test.

TLS termination, certificates, HTTP-to-HTTPS redirects, WebSocket upgrades,
proxy timeouts, and the allowed origin/CORS policy belong to that reverse
proxy. The repository overlay does not expose a certificate authority or
generate certificates. Keep FusionAuth's public URL and OAuth redirect URI
on the same canonical hostname policy as the application.

## Object storage

Production file durability must use operator-selected S3-compatible object
storage (managed S3 is the default recommendation) with versioning and a
retention policy. Configure the bucket, region, endpoint, and credentials in
the operator `.env` and verify the document/static-file event and queue
contracts before cutover.

The base stack starts LocalStack and provisions the local buckets, queues, and
tables needed by smoke tests. LocalStack and the local CloudFront-shaped proxy
are not a production object-storage choice. Do not point a long-lived
deployment at them without a separately designed persistence and recovery plan.

## Mail and authentication

Mailpit is included for local smoke tests only. Configure a real SMTP relay,
sender domain, SPF/DKIM/DMARC, and bounce handling before enabling passwordless
login for users. Replace all `local` auth keys and FusionAuth API/client
secrets; rotate them as operator-managed secrets rather than committing them to
`.env`.

Google/Gmail, GitHub, Stripe, LiveKit, model providers, push notifications, and
calendar/webhook integrations are not optional product surfaces. Their local
stub values only satisfy boot-time config. A production self-host deployment
must configure or explicitly disable each one at the product-policy level.

## Backup and restore hooks

The production hardening gate checklist lives in
[`selfhost/production-hardening-checklist.md`](selfhost/production-hardening-checklist.md).
It maps TLS/reverse proxy, restart policies, resource limits, health checks, log
retention, auth/public URL correctness, disabled integrations, and
update/rollback requirements to the Compose/env/proxy changes that must exist
before exposing real users.

The detailed persistence inventory, backup/restore order, and upgrade safety
rules live in
[`selfhost/persistence-backup-restore.md`](selfhost/persistence-backup-restore.md).
The first operator script skeleton is
`tooling/selfhost/backup-restore.sh`.

The boot/restart acceptance smoke for operators lives in
[`selfhost/smoke-test-spec.md`](selfhost/smoke-test-spec.md). Run it after
initial boot, restart, backup/restore, update, and rollback drills to prove
login, document/task/channel behavior, search, file storage, workers, and
persistence before exposing users again.

The repository intentionally provides hooks, not a provider-specific backup
implementation. Wire those commands into the host's backup scheduler and
replace local artifact storage with the chosen encrypted destination:

```bash
tooling/selfhost/backup-restore.sh inventory
tooling/selfhost/backup-restore.sh backup --backup-dir /BACKUP_DEST/macro-$(date -u +%Y%m%dT%H%M%SZ)

# Restore is destructive and must only run during a planned outage, after
# validating the backup directory and testing on a separate host.
tooling/selfhost/backup-restore.sh restore \
  --backup-dir /BACKUP_DEST/macro-YYYYMMDDTHHMMSSZ \
  --i-understand-data-loss
```

Restore drills must include Postgres, FusionAuth, object storage, and the
operator's secret material. Record RPO/RTO, retention, encryption, and the
rollback point in the deployment notes. Never run `docker compose down -v` as
part of routine maintenance.
