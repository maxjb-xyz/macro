# Macro self-host

Run the full Macro product — web app and every backend service — on a single
Docker host. You only need Docker with the Compose plugin. No Rust toolchain, no
local build, no `-f` flags: one command boots the whole stack from published
images.

## Three steps

1. **Get it running** → [`quickstart.md`](quickstart.md)
   Clone, generate secrets, `docker compose up -d --wait`, open
   `http://localhost/app/`.

2. **Configure it** → [`configuration.md`](configuration.md) and
   [`integrations.md`](integrations.md)
   Set your domain and email, then turn on the integrations you want: Google,
   Gmail, GitHub, Stripe, AI models, calls, and the rest.

3. **Go to production** → in this order:
   - [`production-checklist.md`](production-checklist.md) — the gate you must
     clear before real users (TLS, backups, limits).
   - [`backup-restore.md`](backup-restore.md) — back up and restore your data.
   - [`release-images.md`](release-images.md) — how images are published and pinned.
   - [`update-rollback.md`](update-rollback.md) — apply a release, roll it back.
   - [`smoke-test.md`](smoke-test.md) — prove the stack still works after changes.

## What `compose.yml` is

`compose.yml` is the entire production stack in one file. It is generated from
source files in `docker/selfhost/`, so you edit the sources and regenerate —
never hand-edit `compose.yml`:

```bash
python3 tooling/selfhost/flatten-compose.py
```

| Source | What it adds |
| --- | --- |
| `compose.frontend.yml` | Caddy reverse proxy + durable LocalStack (S3/SQS/DynamoDB) |
| `compose.production.yml` | restart policy, log rotation, resource limits |
| `compose.light-infra.yml` | Redpanda instead of JVM Kafka (a fraction of the memory) |
| `compose.release-images.yml` | pins every service to a published GHCR image |

## For maintainers

These files are for people contributing to this fork, not for operators running
it:

- [`maintaining.md`](maintaining.md) — fork patch rules and the upstream sync process.
- [`GAP-ANALYSIS.md`](GAP-ANALYSIS.md) — known gaps between this stack and production.
