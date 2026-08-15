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
  `docker/selfhost/` (both merged into `compose.yml` automatically):
  - `compose.frontend.yml` — Caddy proxy + durable LocalStack + IdP provisioner.
  - `compose.production.yml` — restart + log rotation + resource limits.
  - Release-image overrides live inline in `compose.yml` itself.
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

`compose.yml` is the full production stack: it includes the upstream base,
`compose.frontend.yml`, and `compose.production.yml`, and pins every Macro
service to its release image inline — no `COMPOSE_FILE`, no `-f` flags. For
local/dev build-from-source, run the base file directly:

```bash
docker compose -f docker/docker-compose.yml up -d
```

The older `docs/SELF_HOSTING_*.md` files and `docker/docker-compose.self-host.yml`
predate this directory and are superseded by the docs above.
