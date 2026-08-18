# Maintaining the fork

Notes for people working on `maxjb-xyz/macro`, the self-host fork. Operators who
only run the stack do not need this.

## What this fork is

A compatibility fork: it tracks upstream Macro and adds a self-host Docker
Compose path while keeping upstream application code intact. Self-host changes
live only in:

- `docs/selfhost/`
- `docker/selfhost/` (Compose overlays)
- `tooling/selfhost/` (flatten, secrets, backup scripts)
- `.env.selfhost.example`

## Where fork-only work goes

Prefer these locations:

- `docker/selfhost/` — Compose overlays and image definitions.
- `tooling/selfhost/` — flatten/secret/backup orchestration.
- `docs/selfhost/` — operator and maintainer docs.
- `.env.selfhost.example` — env surface template.

Avoid, unless there is no smaller path:

- Editing service business logic just to satisfy self-host.
- Forking generated clients or schemas.
- Committing secrets or real credentials.
- Adding cloud-provider infra before the Compose path is proven.

Every fork-only patch should answer:

1. Is this a temporary shim or a durable self-host contract?
2. Can it be upstreamed?
3. Which validation proves it still works after an upstream sync?
4. Which operator responsibility does it introduce?

## Upstream sync

Sync on a short-lived branch and keep the PR reviewable:

```bash
git remote add upstream https://github.com/macro-inc/macro.git 2>/dev/null || true
git fetch origin main
git fetch upstream main
git switch -c sync-upstream-$(date +%Y%m%d) origin/main
git merge --no-ff upstream/main
just check
docker compose config --quiet
```

Open a draft PR into `maxjb-xyz/macro` `main`. The PR body should note the
upstream commit range, fork-only files touched, validation results, and any
operator-facing or security changes.

Escalate instead of auto-resolving when upstream touches authentication,
migrations, secrets, billing, queue/topic contracts, or anything that would
make the Compose smoke pass only by disabling a service.

## Release image strategy

The fork publishes one immutable image per service to GHCR, built by CI on `v*`
tags, so operators never build Rust on their host. Each image is pinned by
`MACRO_RELEASE_IMAGE_REGISTRY` + `MACRO_RELEASE_IMAGE_TAG` in `.env`. See
[`release-images.md`](release-images.md) for the operator workflow and
`docker/selfhost/compose.release-images.yml` for the pins.

## Known gaps

[`GAP-ANALYSIS.md`](GAP-ANALYSIS.md) tracks what still separates this stack
from production. Read it before claiming a feature is production-ready.
