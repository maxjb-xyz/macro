# Macro Self-Host MVP — Quick Start

Boot the full Macro product (frontend + all backend services + local
infrastructure) on one Docker host behind a single Caddy reverse proxy.

## Prerequisites

- Docker Engine with the Compose plugin (`docker compose`).
- A host with **≥ 100 GB free disk**, **≥ 16 GB RAM** (32 GB recommended).
- Outbound internet for image pulls / builds.
- (Optional) a public domain + TLS — see `docs/selfhost/production-hardening-checklist.md`.

## 1. Get the code

```bash
git clone https://github.com/maxjb-xyz/macro.git
cd macro
cp .env.example .env
```

## 2. Boot the stack

```bash
docker compose -f compose.yml -f docker/selfhost/compose.frontend.yml up -d
```

The first run builds all service images (the Rust bundle and the frontend
proxy); expect it to take a while and consume roughly 60 GB of Docker disk.

## 3. Open the app

```text
http://localhost/app/
```

(HTTP on port 80 — the proxy redirects `/` to `/app/`.)

## 4. Sign in (passwordless)

1. On the login page, enter your email and request a code.
2. The code is captured by Mailpit, not real email:
   ```text
   http://localhost/mailpit/
   ```
3. Enter the code in the app.

## What works (local/emulated)

- Document, task, channel, and message flows (Postgres + Redis + Kafka).
- Search (self-hosted OpenSearch).
- File storage (LocalStack S3).
- Real-time sync/websockets (self-hosted workers).
- Background jobs/queues (LocalStack SQS/DynamoDB).
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

## Known MVP tradeoffs

- The GraphQL cache WASM package is not built into the proxy image; the
  normalized cache degrades to network-only at runtime. Build it with
  `just build-cache-wasm` and place it at
  `apps/web/src/lib/graphql-cache/wasm/` to restore it.
- The stack is single-node and single-instance. It is a production-appliance
  prototype, not a horizontally scalable deployment.

## Teardown

```bash
docker compose -f compose.yml -f docker/selfhost/compose.frontend.yml down
```

Do **not** use `down -v` — that deletes all data volumes.

## Optional: seed sample content

```bash
just seed-scenario apply --file tooling/seed_cli/seed/scenarios/team-perms.json
just seed-scenario status --file tooling/seed_cli/seed/scenarios/team-perms.json
```

`status` prints persona login links. Requires the Rust toolchain (`just`).

## Next steps toward production

- TLS/reverse-proxy hardening — `docs/selfhost/production-hardening-checklist.md`
- Durable storage/backups — `docs/selfhost/persistence-backup-restore.md`
- Published release images — `tooling/selfhost/build-release-images.sh`
- Bootstrap smoke checks — `docs/selfhost/smoke-test-spec.md`
