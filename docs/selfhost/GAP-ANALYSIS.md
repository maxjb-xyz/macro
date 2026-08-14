# Macro Self-Host — Gap Analysis

Status: **production-appliance prototype** (boots, serves, login works) — NOT yet
a production distribution. This lists what the stack is missing and what each
item needs.

## ✅ What works today (reproducible)

One command boots the full product:

```bash
docker compose -f compose.yml -f docker/selfhost/compose.frontend.yml up -d --wait
```

- 28 services + Caddy proxy, all healthy (`--wait` exits 0).
- MacroDB schema auto-migrated on first boot (251 migrations).
- FusionAuth fully provisioned (app, tenant passwordless, JWT lambda, webhooks).
- Frontend built for same-origin backend, served at `/app/`.
- Passwordless login (email → 6-digit code in Mailpit).
- Document/task/channel/message flows, search (OpenSearch), files (LocalStack S3),
  realtime sync/websockets, background queues.
- **Generated secrets** — `tooling/selfhost/generate-secrets.sh` produces a real
  `.env` with random secrets, and the FusionAuth kickstart reads them via
  `#{ENV.*}` (no hardcoded dev values). `.env` is gitignored.

## 🔴 Blocking for real production use

### 1. TLS / public ingress
The proxy serves plain HTTP on port 80. Needs Caddy auto-HTTPS (or an external
TLS terminator) with a real domain, plus correct public URLs/OAuth callbacks.

### 2. Real SMTP
Mailpit is a local mail *catcher* — no delivery. Production needs SMTP/SES with
SPF/DKIM/DMARC, wired into FusionAuth (SMTP settings) and the email service.

### 3. Durable object storage + queues
LocalStack emulates S3/SQS/DynamoDB in-process. For production: real AWS
S3/SQS/DynamoDB, or self-hosted MinIO + ElasticMQ + DynamoDB-compatible store,
with durability and backup.

### 4. Backups / restore (untested)
`tooling/selfhost/backup-restore.sh` exists but has not been run end-to-end
against Postgres, FusionAuth, OpenSearch, Kafka, and object storage.

### 5. Upgrade / migration path
The first-boot migration gate is "0 tables → migrate". On upgrades (existing
data + new migration files) there is no incremental apply / no
`_sqlx_migrations` ledger — a future schema change would be skipped silently.
Needs a real sqlx-migrate runner on boot.

## 🟡 Partial / deferred

### 6. Published release images (CI in place, not yet verified on GHCR)
`tooling/selfhost/build-release-images.sh` + `compose.published.yml` now cover
all 13 Rust services + the frontend proxy, and `.github/workflows/build-release-images.yml`
builds/pushes them to GHCR on every push to `main`. Not yet verified end-to-end
against the registry; the JS/worker services (sync, lexical, ai-editing-worker,
analytics-proxy, websocket) are not covered and keep their wrangler-dev images.
Also: the generic Rust Dockerfile rebuilds the workspace per service (slow);
cargo-chef layer caching is the follow-up.

### 7. Seed/bootstrap service (incomplete)
`compose.seed.yml` + `seed_cli scenario bootstrap` are written, but the
`seed_cli` binary is not yet added to the `services_bundle` build, so the
overlay can't run standalone. Add `seed_cli` to the image build.

### 8. External integrations (stubbed or disabled)
These need operator-owned accounts/credentials + public HTTPS callbacks:

- Google/Gmail login + mail sync
- GitHub login + PR sync (GitHub App)
- Stripe billing
- LiveKit calls (server + license)
- Push notifications (Apple APNs / Firebase FCM)
- Model providers (OpenAI / Anthropic / Cohere / Cerebras keys)
- MCP OAuth (Slack, GitHub)
- Apollo CRM enrichment
- Calendar webhooks

### 9. Observability
Jaeger + `datadog-agent` are in the stack but Datadog has no API key. Production
needs a real metrics/logs/tracing pipeline (OTel collector → backend) and alerts.

### 10. Security hardening
- No WAF / rate limiting on the proxy.
- Internal service auth keys rotate via `generate-secrets.sh`; still no audit
  logging or secret rotation story.
- The FusionAuth admin user (`admin@macro.com`) password is now generated, but
  is still a static bootstrap credential.

## 🟢 Non-blocking tradeoffs

- **GraphQL cache WASM** not built into the proxy image — the normalized cache
  silently degrades to network-only. Restore with `just build-cache-wasm`.
- **Single-node / single-instance** — no horizontal scaling, no HA, no rolling
  deploys. Compose is the ceiling; multi-node needs Kubernetes/Nomad or a
  managed platform.
- **Cloudflare-Worker-style services** (sync, lexical, analytics-proxy,
  ai-editing-worker) run under local `wrangler dev` — fine for one node, not a
  production serverless topology.

## Suggested next steps (priority order)

1. TLS / public ingress (make it safe to expose).
2. Verify release-image CI on GHCR + cover the JS/worker services.
3. Real SMTP + object storage (make integrations functional).
4. Incremental migrations on boot (make upgrades safe).
5. Backup/restore drill (make data durable).
6. Observability + alerting.
7. Then, integration-by-integration: Google → GitHub → Stripe → LiveKit → push.
