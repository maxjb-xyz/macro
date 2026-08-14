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
  -f docker/docker-compose.yml \
  -f docker/docker-compose.self-host.yml config >/dev/null
docker compose --project-directory . \
  -f docker/docker-compose.yml \
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

LocalStack and the local CloudFront-shaped proxy in the base stack are smoke
test dependencies, not a production object-storage choice. Do not point a
long-lived deployment at them without a separately designed persistence and
recovery plan.

## Mail and authentication

Mailpit is for local smoke tests only. Configure a real SMTP relay, sender
domain, SPF/DKIM/DMARC, and bounce handling before enabling passwordless login
for users. Replace all `local` auth keys and FusionAuth API/client secrets;
rotate them as operator-managed secrets rather than committing them to `.env`.

Google/Gmail, GitHub, Stripe, LiveKit, model providers, push notifications, and
calendar/webhook integrations are not optional product surfaces. Their local
stub values only satisfy boot-time config. A production self-host deployment
must configure or explicitly disable each one at the product-policy level.

## Backup and restore hooks

The repository intentionally provides hooks, not a provider-specific backup
implementation. Wire these commands into the host's backup scheduler and
replace the placeholders with the chosen encrypted destination:

```bash
# TODO(operator): dump both databases to an encrypted, off-host destination.
docker compose -f docker/docker-compose.yml -f docker/docker-compose.self-host.yml \
  exec -T postgres pg_dumpall -U user > /BACKUP_DEST/macro-postgres.sql
docker compose -f docker/docker-compose.yml -f docker/docker-compose.self-host.yml \
  exec -T db pg_dumpall -U postgres > /BACKUP_DEST/fusionauth.sql

# TODO(operator): snapshot/copy the named volumes, or use a volume-aware tool.
docker run --rm -v macro_postgres_data:/source:ro -v /BACKUP_DEST:/backup \
  alpine tar czf /backup/macro-postgres-volume.tgz -C /source .

# TODO(operator): restore only during a planned outage, after validating the
# destination and stopping services that write the target volume.
docker run --rm -v macro_postgres_data:/target -v /BACKUP_DEST:/backup \
  alpine tar xzf /backup/macro-postgres-volume.tgz -C /target
```

Restore drills must include Postgres, FusionAuth, object storage, and the
operator's secret material. Record RPO/RTO, retention, encryption, and the
rollback point in the deployment notes. Never run `docker compose down -v` as
part of routine maintenance.
