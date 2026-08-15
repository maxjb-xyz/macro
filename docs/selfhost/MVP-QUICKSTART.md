# Macro Self-Host MVP — Quick Start

Boot the full Macro product (frontend + all backend services + local
infrastructure) on one Docker host behind a single Caddy reverse proxy.

## Prerequisites

- Docker Engine with the Compose plugin (`docker compose`).
- A host with **≥ 100 GB free disk**, **≥ 16 GB RAM** (32 GB recommended).
- Outbound internet for image pulls / builds.
- (Optional) a public domain + TLS — see `docs/selfhost/production-hardening-checklist.md`.

## 1. Get the code + generate secrets

```bash
git clone https://github.com/maxjb-xyz/macro.git
cd macro
./tooling/selfhost/generate-secrets.sh
```

This writes a real `.env` with freshly generated random secrets (FusionAuth API
key, client secret, JWT signing key, admin password, internal service auth
keys, and the RS256 API-token keypair). It refuses to overwrite an existing
`.env`, and `.env` is gitignored so it is never committed.

The bundled `.env.example` holds placeholder values only for reference — do not
deploy from it directly.

## 2. Boot the stack

```bash
docker compose up -d --wait
```

That's it — no `-f` flags. `compose.yml` is the full production stack (base +
proxy/storage + release images + hardening), so `docker compose` runs it
directly.

The first run pulls the published per-service release images from GHCR (the
fork's CI publishes them publicly) — every service, including the five
JS/worker services (`sync_service`, `lexical_service`, `ai_editing_worker`,
`analytics_proxy`, `websocket_service`). Expect a few minutes of image pulls on
the first boot, not a multi-GB Rust build.

On first boot the stack self-provisions:

- **Postgres schema** — `postgres_bootstrap` creates `macrodb` and applies all
  `crates/macro_db_client/migrations` (251 files) in version order.
- **FusionAuth** — a full kickstart creates the Macro application, tenant
  passwordless config (6-digit code via Mailpit), the JWT population lambda,
  and the user create/delete webhooks.

Both are idempotent: re-running `up` on an existing data volume skips them.

## 3. Open the app

```text
http://localhost/app/
```

(HTTP on port 80 — the proxy redirects `/` to `/app/`.)

## 4. Sign up / sign in (passwordless)

1. On the login page, choose **Continue with email** and enter any address.
2. The 6-digit code is captured by Mailpit, not real email:
   ```text
   http://localhost/mailpit/
   ```
3. Enter the code in the app.

## What works (local/emulated)

- Document, task, channel, and message flows (Postgres + Redis + Kafka).
- Search (self-hosted OpenSearch).
- File storage (S3 — durable LocalStack, survives restarts).
- Real-time sync/websockets (self-hosted workers).
- Background jobs/queues (SQS/DynamoDB — durable LocalStack, survives restarts).
- Passwordless login (FusionAuth + Mailpit).

## What does NOT work out of the box (external-required)

See `docs/selfhost/env-contract.md` and `docs/SELF_HOSTING_INTEGRATIONS.md` for
the full matrix. In brief, these need operator-owned accounts/credentials and
are stubbed or disabled locally:

- Google/Gmail login and sync
- GitHub login and PR sync
- Stripe billing
- LiveKit calls
- Push notifications (Apple/FCM)
- Model providers (OpenAI/Anthropic/Cohere) and MCP OAuth
- Apollo CRM enrichment, calendar webhooks, analytics/ads pixels

## Production: switch to real AWS S3/SQS/DynamoDB

Object storage and queues run on a durable self-hosted LocalStack by default
(`gresau/localstack-persist:4` + a named volume). To use real AWS instead:

1. In `.env`, set `LOCAL_AWS_URL=""` (empty = default AWS endpoints).
2. Set real `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.
3. The `localstack` container becomes idle — leave it running or remove it.

See `docs/selfhost/GAP-ANALYSIS.md` §3 for the tradeoffs (LocalStack went
closed-source in March 2026; the image tag is pinned).

## Known MVP tradeoffs

- The GraphQL cache WASM package is not built into the proxy image; the
  normalized cache degrades to network-only at runtime. Build it with
  `just build-cache-wasm` and place it at
  `apps/web/src/lib/graphql-cache/wasm/` to restore it.
- The `analytics_proxy` worker is a telemetry-only proxy (PostHog + OTLP).
  Its container installs its own deps (`hono`, `wrangler`) at startup, so it
  needs outbound npm access on first boot; it is excluded from the proxy's
  start gate and its absence never blocks the product.
- The stack is single-node and single-instance. It is a production-appliance
  prototype, not a horizontally scalable deployment.

## Teardown

```bash
docker compose down
```

Do **not** use `down -v` — that deletes all data volumes.

## Optional: seed sample content

`docker/selfhost/compose.seed.yml` seeds an admin user + workspace + channel +
welcome document on first boot (idempotent — a sentinel in the `macro_seed_state`
volume skips later runs):

```bash
docker compose -f compose.yml -f docker/selfhost/compose.seed.yml up seed
```

The seeded admin logs in passwordless at `admin@seed.macro.local` (override with
`SEED_ADMIN_EMAIL`). Re-run after changing admin details:

```bash
docker compose -f compose.yml -f docker/selfhost/compose.seed.yml \
  run --rm seed sh -c 'rm -f /seed-state/.bootstrapped && /app/out/seed_cli scenario bootstrap'
```

## Next steps toward production

- TLS/reverse-proxy hardening — `docs/selfhost/production-hardening-checklist.md`
- Durable storage/backups — `docs/selfhost/persistence-backup-restore.md`
- Published release images — `tooling/selfhost/build-release-images.sh`
- Bootstrap smoke checks — `docs/selfhost/smoke-test-spec.md`
