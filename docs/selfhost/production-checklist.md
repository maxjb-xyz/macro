# Production checklist

The gate between "it boots locally" and "real users can use it". Work through
this list before exposing a self-hosted Macro to anyone, and re-check it after
any major change.

## The gates

| Gate | What "done" looks like | How to do it |
| --- | --- | --- |
| TLS + reverse proxy | Only the web entrypoint is public; HTTP redirects to HTTPS; WebSockets and long requests work; internal services stay on the Compose network. | Publish only the proxy ports (80/443). Terminate TLS at the edge (Caddy, Traefik, nginx, or Cloudflare Tunnel). Route WebSocket paths to `sync_service`. Never publish Postgres, Redis, Redpanda, OpenSearch, LocalStack, or Mailpit. |
| Public URLs | `BASE_URL`, `FUSIONAUTH_PUBLIC_URL`, `FUSIONAUTH_OAUTH_REDIRECT_URI`, `ISSUER`, `AUDIENCE`, and `SENDER_BASE_ADDRESS` use the real public HTTPS host. | Replace the placeholders in `.env` per [`configuration.md`](configuration.md). Keep `OVERRIDE_*_SERVICE_URL` values on Compose hostnames. |
| Restart + health | Every long-running service restarts on crash/reboot and has a healthcheck; one-shot jobs don't loop. | Already done by `compose.production.yml`. Verify with `docker compose ps` — all healthy, one-shots exited. |
| Resource limits | Each service has CPU/memory ceilings sized for the host. | Already set conservatively in `compose.production.yml`; tune per host in that file. |
| Log retention | Logs rotate locally and export off-host. | Local rotation is set; add your own off-host export and redaction policy. |
| Backups | Postgres, FusionAuth, object storage, Redis, Redpanda, and OpenSearch have an off-host backup/restore path. | See [`backup-restore.md`](backup-restore.md). Never run `down -v`. |
| Immutable images | Runtime uses pinned release images, not dev bundles or bind-mounts. | Done by `compose.release-images.yml`; pin `MACRO_RELEASE_IMAGE_TAG` in `.env`. |
| Update/rollback | You can back up, apply a new tag, smoke-test, and roll back. | See [`update-rollback.md`](update-rollback.md); practice the drill. |
| Disabled integrations | Unsupported features fail closed and aren't advertised. | Leave credentials blank; see [`integrations.md`](integrations.md). |
| Observability | You can see health, crash loops, disk, backup failures, and auth/email errors. | Add your own collector/alerting; alert on unhealthy containers, disk, TLS expiry, stale backups. |

## When can you call it production?

A deployment is production-ready only when all of these hold:

- Traffic enters over HTTPS on the canonical hostnames.
- Restart, healthcheck, log-retention, and resource policies cover every
  long-running service.
- Public URL/auth/env values come from [`configuration.md`](configuration.md)
  with no local stubs for enabled features.
- Unsupported integrations are disabled or fail closed.
- Object storage and backups are configured and a restore drill has passed.
- Images are pinned and rollback has been tested.
- The smoke test passes after boot, restart, update, and rollback.

## Compose overlays

These source files in `docker/selfhost/` make up `compose.yml` (regenerate with
`tooling/selfhost/flatten-compose.py` after editing any of them):

- `compose.frontend.yml` — Caddy proxy + durable LocalStack + IdP provisioner.
- `compose.production.yml` — restart, log rotation, resource limits.
- `compose.light-infra.yml` — Redpanda instead of JVM Kafka.
- `compose.release-images.yml` — per-service GHCR image pins.

## Still open

- Reverse-proxy/edge config can live outside Compose if you already own host
  ingress, but record its routing, TLS, timeouts, and WebSocket settings.
- Observability and alerting are operator-defined; nothing is wired by default.
