# Macro self-host — documentation index

Single-host Macro deployment. Start here, then follow the doc that matches your
question.

## Quick start

- **I want to boot it now** → [`MVP-QUICKSTART.md`](MVP-QUICKSTART.md) — clone →
  `generate-secrets.sh` → `docker compose up` → `http://localhost/app/`.

## Going to production

- **What's left before I can expose real users?** →
  [`production-hardening-checklist.md`](production-hardening-checklist.md) — the
  gate-by-gate checklist (TLS, restart, resources, logging, backups, images,
  update/rollback, observability). The Compose overlays it maps to are in
  `docker/selfhost/`:
  - `compose.frontend.yml` — Caddy proxy + durable LocalStack + IdP provisioner.
  - `compose.published.yml` — immutable per-service release images.
  - `compose.production.yml` — restart + log rotation + resource limits.
- **What's still not done / where are the gaps?** →
  [`GAP-ANALYSIS.md`](GAP-ANALYSIS.md).

## Configuration

- **What does every env var mean?** → [`env-contract.md`](env-contract.md) +
  the annotated template `.env.selfhost.example` (copy it to `.env.selfhost`).
- **How do I wire Google / GitHub / Outlook / AI?** →
  [`integrations-runbook.md`](integrations-runbook.md).

## Operations

- **Back up and restore** → [`persistence-backup-restore.md`](persistence-backup-restore.md).
- **Update and roll back a release** → [`update-rollback.md`](update-rollback.md).
- **Build/publish release images** → [`published-release-images.md`](published-release-images.md)
  (operator workflow) and [`release-images.md`](release-images.md) (decision record).
- **Smoke-test a deployment** → [`smoke-test-spec.md`](smoke-test-spec.md).

## Canonical production compose chain

```bash
docker compose up -d --wait
```

`generate-secrets.sh` writes a `COMPOSE_FILE` line into `.env`, so that one
command merges the base graph with the three self-host overlays
(`compose.frontend.yml`, `compose.published.yml`, `compose.production.yml`).
The explicit expansion is:

```bash
docker compose --project-directory . \
  -f compose.yml \
  -f docker/selfhost/compose.frontend.yml \
  -f docker/selfhost/compose.published.yml \
  -f docker/selfhost/compose.production.yml \
  --env-file .env up -d --wait
```

The older `docs/SELF_HOSTING_*.md` files and `docker/docker-compose.self-host.yml`
predate this directory and are superseded by the docs above.
