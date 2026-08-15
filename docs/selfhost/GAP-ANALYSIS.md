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
- **Incremental migrations** — `_macro.migrations` ledger applies only NEW
  migrations on boot (idempotent re-runs verified).
- **TLS-ready** — `SELF_HOST_DOMAIN` parameter: local = HTTP on :80; set a
  domain = Caddy auto-HTTPS on :443. (Unused until a domain is provisioned.)
- **Full feature unlock** — `SELF_HOST_UNLOCK_ALL=true` (default in the
  generated self-host `.env`) lifts the Stripe paywall: every user is granted
  the professional/AI permissions and the Stripe-backed premium extractor
  passes, so no billing account is required.
- **BYOK AI** — model providers are bring-your-own-key (`ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`, `CEREBRAS_API_KEY`); blank/`local-*` keys degrade to a
  clean "model provider not configured" error instead of a provider failure.

## 📝 Noted — self-hosting product changes (parked, not started)

Decided against immediate implementation; revisit after the infra fixes land.

1. **Stop seeding Macro company users.** Two sources: (a) `support_channel_welcome.rs`
   hardcodes `jacob@/julia@/teo@macro.com` and injects a "Macro Support" channel on
   every signup; (b) the opt-in `seed_cli` scenario. Fix = config-gate the support
   channel (or point it at a configurable support email), keep seed opt-in.
2. **First-user admin onboarding.** Phase 1: `SELF_HOST_FIRST_USER_IS_ADMIN` flag
   (first signup → owner/workspace-admin). Phase 2 (product work): first-run setup
   screen (workspace name, admin, SMTP/storage/AI keys). Needs mapping to Macro's
   actual team/workspace roles first.
3. **Integration vars + graceful degradation** — ✅ done. Unconfigured
   integrations now degrade cleanly instead of 500-ing: `*_ENABLED` flags plus
   blank/`local-*`-dummy credential detection gate each provider, a new
   `/capabilities` endpoint reports the enabled set, the web UI hides disabled
   connect cards, and the auth/email endpoints return "not configured"
   (404/400 with a machine-readable code) rather than
   `"Email provider operation failed"`.

## 🔴 Blocking for real production use

### 1. TLS / public ingress
Code is ready (`SELF_HOST_DOMAIN` → Caddy auto-HTTPS); needs a real domain +
port 443 reachable, plus correct public URLs/OAuth callbacks.

### 2. Real SMTP
FusionAuth outbound SMTP (passwordless codes, notifications) is now configurable
via env vars — `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURITY`, `SMTP_USERNAME`,
`SMTP_PASSWORD`, `SMTP_FROM_EMAIL`, `SMTP_FROM_NAME` — defaulting to the local
Mailpit catcher. Set them for a real provider (SES/SendGrid). Still needs:
SPF/DKIM/DMARC on the sending domain, and the email service's Gmail/IMAP
integration (Google OAuth, not SMTP — see §8).

### 3. Durable object storage + queues (default)
Durable by default: `docker/selfhost/compose.frontend.yml` swaps the ephemeral
LocalStack Community image for `gresau/localstack-persist:4` + a named volume,
so S3/SQS/DynamoDB state survives container recreation (VERIFIED). Production
escape hatch: real AWS S3/SQS/DynamoDB — set `LOCAL_AWS_URL=""` and real
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in `.env`; the localstack container
then sits idle. Caveat: LocalStack went closed-source in March 2026, so both the
official `:4` and the gresau fork are frozen; pin the tag and plan a real-AWS
migration for production.

### 4. Backups / restore (verified: logical dumps + volume archives)
`tooling/selfhost/backup-restore.sh` runs end-to-end. Logical `pg_dumpall`
exports restore cleanly into fresh clusters (MacroDB: 199 tables / 251 ledger
rows; FusionAuth: 91 tables), and quiesced volume archives extract correctly
(PG data at `18/docker/`). Still not covered: LocalStack S3/SQS/DynamoDB
(ephemeral — see #3), off-host storage, and encryption of the backup artifacts.

### 5. Upgrade / migration path (implemented, needs a live-data test)
The `_macro.migrations` ledger applies only NEW migrations on boot (idempotent
verified). Remaining: confirm the upgrade path on a data set that predates a
schema change; the ledger is a filename-based sqlx-compatible table, not sqlx's
own `_sqlx_migrations`.

## 🟡 Partial / deferred

### 6. Published release images (verified on GHCR)
All 14 images (13 Rust services + proxy) are public on GHCR, tagged
`sha-<full-sha>` + `:latest`, and boot green end-to-end (pull + boot + full
functional smoke test). The JS/worker services (sync, lexical, ai-editing-worker,
analytics-proxy, websocket) are not covered and keep their wrangler-dev images.
Follow-up: cargo-chef layer caching to cut rebuild cost.

### 7. Seed/bootstrap service (done, verified)
`compose.seed.yml` runs the one-shot `seed_cli scenario bootstrap` (admin +
workspace + channel + welcome document), idempotent via a `macro_seed_state`
sentinel. `seed_cli` is in the `services_bundle` build, and the bootstrap skips
sqlx migrations when the `_macro.migrations` ledger is present (avoids colliding
with migrate-macrodb.sh). Verified end-to-end.

### 8. External integrations (graceful degradation implemented)
These need operator-owned accounts/credentials + public HTTPS callbacks. Until
configured they now degrade cleanly (see item 3 above): SSO/link endpoints
return `INTEGRATION_NOT_CONFIGURED` (404), `/email/init` returns
`GMAIL_NOT_CONFIGURED` (400), and `/capabilities` drives UI hiding. Real
activation still requires the operator to supply credentials — the step-by-step
runbook is **docs/selfhost/integrations-runbook.md**. Identity providers are
auto-provisioned by the `fusionauth_provision_idps` one-shot service
(config-gated, idempotent; see the runbook).

- Google/Gmail login + mail sync
- GitHub login + PR sync (GitHub App)
- Stripe billing (optional — `SELF_HOST_UNLOCK_ALL` lifts the paywall by default)
- LiveKit calls (server + license)
- Push notifications (Apple APNs / Firebase FCM)
- Model providers (OpenAI / Anthropic / Cerebras keys — BYOK, graceful degradation)
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
7. Then, integration-by-integration: Google → GitHub → Outlook → LiveKit → push
   (Stripe and AI model providers are optional/BYOK, not blocking).
