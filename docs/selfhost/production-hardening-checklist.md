# Production hardening checklist

Status: definition checklist for turning the single-host self-host Compose stack
from dev-only into production-ish. This document does not claim the current stack
is production ready; it maps each required hardening item to the Compose/env/proxy
change that must exist before exposing real users.

## Current rendered baseline

Generated with:

```bash
env MACRO_ENV_FILE=$PWD/.env.selfhost.example \
  docker compose --project-directory . \
  -f compose.yml \
  -f docker/docker-compose.self-host.yml \
  --env-file .env.selfhost.example \
  config --format json
```

Observed baseline:

- 29 services render.
- 8 services currently have `restart:` in `docker/docker-compose.self-host.yml`:
  `postgres`, `redis`, `kafka`, `search`, FusionAuth `db`, `fusionauth`,
  `localstack`, and `mailpit`.
- 2 services render without a Compose healthcheck, both intentional one-shot
  bootstrap jobs gated by `service_completed_successfully`: `postgres_bootstrap`
  and `kafka_topics`. Every long-running service now has a healthcheck (HTTP
  readiness via `curl`/`bun`/`node` fetch, Mailpit `readyz`, nginx `/healthz`,
  or a worker process-liveness probe).
- No rendered service currently has a Compose `logging:` retention policy.
- No rendered service currently has Compose resource reservations or limits.

## Gate checklist mapped to Compose changes

| Gate | Production-ish requirement | Current state | Required Compose/env/proxy change | Verification |
| --- | --- | --- | --- | --- |
| TLS and reverse proxy | Only the intended browser/API entrypoint is public; HTTP redirects to HTTPS; WebSocket upgrades and long request timeouts work; internal services stay on Compose networks only. | Compose exposes internal ports but does not define a public edge proxy or certificates. `docs/SELF_HOSTING_DURABLE.md` assigns TLS to an operator proxy. | Add an operator edge overlay or external proxy config for Caddy/Traefik/nginx. Publish only the frontend/API hostnames, terminate TLS there, route WebSocket paths to `sync_service`/gateway as needed, set proxy timeouts, and keep all service-to-service URLs internal. Do not publish Postgres, Redis, Kafka, OpenSearch, FusionAuth DB, LocalStack, or Mailpit to the internet. | `docker compose config` shows no unintended `ports:` on internal services; external scan sees only 80/443; browser login/document/websocket flows pass over HTTPS. |
| Auth and public URL correctness | Browser-facing URLs, OAuth redirect URIs, issuer/audience, sender domains, and signed-file/CDN URLs all use the canonical public HTTPS origin. | `.env.selfhost.example` classifies these keys; local `.env.example` values are not production values. | Use `.env.selfhost.example` as the template and replace `BASE_URL`, `FUSIONAUTH_PUBLIC_URL`, `FUSIONAUTH_OAUTH_REDIRECT_URI`, `ISSUER`, `AUDIENCE`, `SENDER_BASE_ADDRESS`, and CDN/signing URL keys with the real public origins. Keep Compose-internal `OVERRIDE_*_SERVICE_URL` values on service hostnames unless a service is deliberately externalized. | Rendered config contains no `localhost` or Compose hostnames in public URL env values; OAuth/passwordless callback succeeds from a clean browser. |
| Restart policies | Every long-running production service restarts after process crash and host reboot, with graceful stop windows for stateful services and workers. One-shot bootstrap jobs do not restart forever. | `docker/selfhost/compose.production.yml` adds `restart: unless-stopped` + `stop_grace_period` to all 28 long-running services; one-shot jobs (`postgres_bootstrap`, `kafka_topics`, `fusionauth_provision_idps`) stay `service_completed_successfully`/no-restart. | Keep the overlay's service list in sync with `compose.yml` as services are added/renamed. | `docker compose config` shows restart on every long-running service and none on one-shot jobs; `docker restart`/host reboot smoke passes. |
| Health checks | Every service that receives traffic or gates dependency startup has a meaningful healthcheck; workers have a liveness or dependency probe where practical. | Done: HTTP services use `curl -f`/`bun`/`node` fetch probes, `mailpit` uses `readyz`, `static_file_cdn` uses a `/healthz` nginx location, and pure SQS workers (`document_upload_finalizer`, `email_pubsub_workers`) use a process-liveness probe. One-shot jobs (`postgres_bootstrap`, `kafka_topics`) intentionally stay `service_completed_successfully`. | Keep healthcheck probes aligned with each image's available tools (curl in Rust dev/release images, `readyz` for Mailpit, `bun`/`node` fetch for JS services). For pure workers without an endpoint, keep the process-liveness probe or add a lightweight health endpoint in the image. Avoid making one-shot bootstrap jobs long-running only to satisfy healthcheck shape. | `docker compose ps` reports healthy services after boot; `tooling/scripts/self-host-smoke.sh` fails on `docker compose ps --filter health=unhealthy`; smoke plan covers workers by exercising queue-backed behavior. |
| Resource limits | Stateful stores and application services have explicit CPU/memory budgets sized for the host so one component cannot exhaust the node. | `docker/selfhost/compose.production.yml` sets conservative `deploy.resources.limits` (memory + cpus) on all long-running services; operators tune per host/dataset. | Tune the conservative ceilings in `compose.production.yml` for the operator's dataset size and concurrency. | Rendered config contains resources for all long-running services; load/smoke test shows no OOM loops; host monitoring confirms headroom. |
| Log retention | Container logs rotate locally and important logs are exported off-host before rotation. | `docker/selfhost/compose.production.yml` sets `json-file` + `max-size:10m`/`max-file:3` on all long-running services. Off-host export is operator-defined. | Add the operator's centralized log driver or export pipeline; state a retention/redaction policy. | `docker inspect` shows log rotation on each service; log volume cannot fill disk during a soak run; off-host logs contain startup, health, auth, worker, and error events. |
| Disabled integrations | Features backed only by stubs, local emulators, or missing provider approvals are explicitly disabled or fail closed; boot success is not treated as feature readiness. | Env surface is preserved by `.env.selfhost.example`; `docs/SELF_HOSTING_INTEGRATIONS.md` identifies local-emulated, external-required, and stubbed areas. | Keep env keys visible, leave credentials blank where boot permits, and set obvious `CHANGEME_DISABLED_BY_POLICY_*` placeholders only when config loading requires non-empty values. Add product-level disable switches or routing policy before exposing unsupported Google/Gmail, GitHub, Stripe, push, LiveKit, model-provider, calendar, analytics, or Apollo features. Replace LocalStack/Mailpit with real providers or keep those flows smoke-only. | Smoke tests prove disabled features are not advertised or fail closed; configured providers have callback/webhook URLs on the public HTTPS host. |
| Durable storage and backup | Postgres, FusionAuth, object storage, Kafka, Redis, and OpenSearch have an off-host backup/restore path and no routine command deletes volumes. | Current persistence plan and `tooling/selfhost/backup-restore.sh` cover named volumes; LocalStack object data is explicitly non-durable. | Keep named volumes in Compose, never use `down -v`, configure production S3-compatible object storage outside LocalStack, and wire `tooling/selfhost/backup-restore.sh` or operator-specific backup jobs to encrypted off-host storage. Add a future LocalStack durable profile only if it has an explicit data volume and restore path. | Backup dry-run/inventory succeeds; restore drill on a separate host satisfies `docs/selfhost/persistence-backup-restore.md`. |
| Immutable images | Runtime containers use pinned release images, not host-built dev bundles or bind-mounted binaries. Rollback is changing image tags, not editing host artifacts. | `docker/selfhost/compose.published.yml` replaces host-built dev images with per-service `ghcr.io` release images for all services (13 Rust services + proxy + 5 JS/worker services). | Keep `compose.published.yml` in sync with CI's image list. Pin by SHA; document specialized-image exceptions. | Rendered config for production overlay has no dev `build:` stanzas for released services; image tags are immutable SHAs; rollback test starts previous tag set. |
| Update and rollback path | Operators can take a backup, apply new Compose/env/image versions, run smoke checks, and roll back to the previous known-good tag/env/backup. | `docs/selfhost/update-rollback.md` records the full procedure: record state → backup → new image tag → `up -d --wait` → smoke → rollback (tag-only, or env + database restore when migrations aren't reversible). | Keep the runbook current with the compose overlay chain and practice the drill on a non-production host. | Practice upgrade and rollback on a non-production host; record RPO/RTO, backup ID, image tag set, and smoke results. |
| Observability and alerts | Operators can see health, crash loops, disk pressure, backup failures, queue lag, and auth/email failures before users report them. | Jaeger/Datadog profiles exist for local/dev tracing, but production alerting is operator-defined. | Decide whether to keep OTLP/Datadog, add another collector, or use host/container monitoring. Add Compose env/labels for telemetry only after API keys and privacy policy are defined. Alert on unhealthy containers, restart loops, disk usage, backup age, TLS expiry, and failed provider callbacks. | Alert test fires for a stopped service, expired cert test path, and stale backup marker; telemetry does not require dummy production secrets. |

## Compose overlay backlog

Implemented (see `docker/selfhost/`):

- `compose.frontend.yml` — Caddy proxy + durable LocalStack + IdP provisioner.
- `compose.published.yml` — immutable per-service release images (13 Rust
  services + proxy).
- `compose.production.yml` — `restart: unless-stopped` + log rotation +
  conservative `deploy.resources.limits` for all long-running services.
- `update-rollback.md` — the update/rollback runbook.

Remaining:

1. Reverse-proxy/edge config can live outside Compose if the operator already
   owns host ingress, but the deployment runbook must record its routing, TLS,
   timeout, and WebSocket settings (Caddy is the in-stack default).
2. Observability: add the operator's collector (OTLP/vector/etc.) and alerting
   on unhealthy containers, restart loops, disk, backup age, TLS expiry, and
   failed provider callbacks.
3. Publish release images for the JS/worker services (`sync_service`,
   `lexical_service`, `ai_editing_worker`, `analytics_proxy`,
   `websocket_service`) so the operator host never builds anything.

## Minimum production-ish definition

A self-host deployment can be called production-ish only when all of these are
true:

- Public traffic enters through HTTPS on the canonical hostnames.
- The rendered Compose config has restart, healthcheck, log-retention, and
  resource policies for every long-running service, or a documented exception.
- Public URL/auth/env values come from the self-host env contract and contain no
  local-only stubs for enabled features.
- Unsupported integrations are disabled or fail closed, not silently advertised.
- Durable object storage and off-host backups are configured and a restore drill
  has passed.
- Runtime images are immutable and rollback has been tested with the previous
  image/env/Compose set.
- The smoke test in `smoke-test-spec.md` passes after boot, restart, update, and
  rollback, verifying login, document/storage behavior, search/persistence,
  workers, and websocket paths.
