# Quick start

Get the full Macro product running on one Docker host in about five minutes.

## What you need

- Docker Engine with the Compose plugin (`docker compose`).
- A host with at least 16 GB RAM and 100 GB free disk.
- Outbound internet to pull images.

## 1. Clone and generate secrets

```bash
git clone https://github.com/maxjb-xyz/macro.git
cd macro
./tooling/selfhost/generate-secrets.sh
```

`generate-secrets.sh` writes a real `.env` with fresh random secrets (FusionAuth
keys, JWT signing key, admin password, internal service auth keys). It refuses
to overwrite an existing `.env`, and `.env` is gitignored.

## 2. Boot

```bash
docker compose up -d --wait
```

No `-f` flags. `compose.yml` is the full stack: base services, databases,
FusionAuth, the Caddy proxy, Redpanda, and published images. The first run
pulls the release images from GHCR; expect a few minutes, not a Rust build.

On first boot the stack provisions itself:

- **Postgres** — creates `macrodb` and applies every migration.
- **FusionAuth** — a kickstart creates the Macro app, tenant, and passwordless
  config.

Both are idempotent, so re-running on an existing volume is safe.

## 3. Open the app

```text
http://localhost/app/
```

The proxy redirects `/` to `/app/` on port 80.

## 4. Sign in (passwordless)

1. On the login page, choose **Continue with email** and enter any address.
2. The 6-digit code is captured by Mailpit, not real email:
   ```text
   http://localhost/mailpit/
   ```
3. Enter the code in the app.

## What works out of the box

- Documents, tasks, channels, and messages (Postgres + Redis + Redpanda).
- Search (self-hosted OpenSearch).
- File storage (S3 — durable LocalStack, survives restarts).
- Real-time sync and websockets (self-hosted workers).
- Background jobs and queues (SQS/DynamoDB — durable LocalStack).
- Passwordless login (FusionAuth + Mailpit).

## What needs external accounts

These need your own credentials and are stubbed or disabled until you set them
up. See [`integrations.md`](integrations.md) for the how-to:

- Google/Gmail login and sync
- GitHub login and PR sync
- Stripe billing (optional — self-host unlocks every paywalled feature by default)
- LiveKit calls
- Push notifications (Apple/FCM)
- AI model providers (OpenAI/Anthropic/Cerebras)
- Apollo, calendar webhooks, analytics pixels

## Switch to real AWS S3/SQS/DynamoDB

Object storage and queues run on durable LocalStack by default. To use real AWS:

1. In `.env`, remove `LOCAL_AWS_URL` entirely (an empty value is not real AWS —
   it makes every object-store call fail).
2. Set real `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.
3. The `localstack` container becomes idle; leave it running or remove it.

## Seed sample content (optional)

`docker/selfhost/compose.seed.yml` seeds an admin user, workspace, channel, and
welcome document on first boot:

```bash
docker compose -f compose.yml -f docker/selfhost/compose.seed.yml up seed
```

The seeded admin signs in at `admin@seed.macro.local` (override with
`SEED_ADMIN_EMAIL`).

## Stop it

```bash
docker compose down
```

Do **not** use `down -v` — that deletes all data.

## Notes

- The stack is single-node and single-instance: a production appliance, not a
  horizontally scaled deployment.
- `analytics_proxy` installs its own dependencies on first boot and needs
  outbound npm access. It is excluded from the start gate, so it never blocks
  boot.

## Next

- Before real users → [`production-checklist.md`](production-checklist.md)
- Back up your data → [`backup-restore.md`](backup-restore.md)
