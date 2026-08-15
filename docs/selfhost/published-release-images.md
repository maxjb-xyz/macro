# Release images: build once, deploy anywhere

Operators should not build ~60 GB of Rust artifacts on the deployment host.
CI publishes immutable per-service images to GHCR; the operator just pulls.

## What gets published

CI (`build-release-images.yml`) builds one image per service from
`docker/Dockerfile` (or a service-specific Dockerfile) and pushes to
`ghcr.io/<org>/macro/<image>` tagged `sha-<full-sha>` **and** `:latest` on every
push to `main`, plus `v*` on tagged releases.

| Image | Built from | Notes |
| --- | --- | --- |
| `authentication-service`, `connection-gateway`, `contacts-service`, `document-cognition-service`, `document-storage-service`, `document-upload-finalizer`, `email-service`, `email-pubsub-workers`, `notification-service`, `static-file-service`, `unfurl-service`, `image-proxy-service` | `docker/Dockerfile` | `SERVICE_NAME=<cargo_bin>` build arg |
| `search-processing-service` | `docker/Dockerfile.search_processing_service` | pdfium bundled |
| `proxy` | `docker/selfhost/Dockerfile.proxy` | frontend + Caddy |
| `sync-service` | `docker/sync-service.Dockerfile` | Rust→wasm builder + wrangler dev |
| `lexical-service` | `docker/lexical-service.Dockerfile` | scoped workspace build, bundled at build time |
| `ai-editing-worker` | `docker/ai-editing-worker.Dockerfile` | workspace build, sandbox generated at build |
| `analytics-proxy` | `docker/analytics-proxy.Dockerfile` | deps installed at build, wrangler dev |
| `websocket-service` | `docker/websocket-service.Dockerfile` | bun, deps installed at build |

## Building manually (optional)

If you aren't using the fork's CI, build + push once from a build machine (not
the operator's server):

```bash
./tooling/selfhost/build-release-images.sh \
  --registry ghcr.io/YOUR_ORG --tag v2026.x.y.z --push
```

`docker login ghcr.io` first (a `write:packages` token). The script accepts
`--service <name>` to build a single image, `--dry-run` to print the matrix, and
skips `search-processing-service` unless you pass it explicitly.

## Running from published images

In your operator `.env`:

```bash
MACRO_RELEASE_IMAGE_REGISTRY=ghcr.io/YOUR_ORG/macro
MACRO_RELEASE_IMAGE_TAG=sha-<full-sha>      # or a v* tag; avoid :latest for long-lived deploys
```

Then:

```bash
docker compose up -d --wait
```

`compose.yml` pins each Macro service to its release image with:

- `image:` → your registry/tag.
- `build: !reset null`, `command: !reset null` → never rebuild locally; use the
  image's baked-in entrypoint (Rust images run `dumb-init ./svc`; JS/worker
  images run `wrangler dev` or `bun`).
- `volumes: !reset []` → drop the dev bind-mounts (e.g. `.` → `/app`).

Validate before booting:

```bash
docker compose config --images
```

## Upgrade / rollback

See `docs/selfhost/update-rollback.md` — the short version is: record the
current tag + take a backup, set `MACRO_RELEASE_IMAGE_TAG` to the new `sha-*`,
`up -d --wait`, smoke-test, and roll back by restoring the previous tag (or the
previous env + database backup if a migration can't be reversed).

## Troubleshooting

- **`manifest unknown`** — the tag wasn't pushed. Re-run the build with `--push`.
- **`unauthorized`** — `docker login ghcr.io` on the operator host with a
  `read:packages` token (private images).
- **A service still builds locally** — its `image:` override is missing from
  `compose.yml` (or `MACRO_RELEASE_IMAGE_REGISTRY`/`_TAG` aren't set in `.env`).
- **Wrong architecture** — CI builds `linux/amd64`; for arm64 operators, build
  with `--platform linux/arm64` (buildx) and push to your own registry.

## See also

- `docs/selfhost/release-images.md` — the strategy decision record.
- `docs/selfhost/update-rollback.md` — update/rollback runbook.
- `docs/selfhost/GAP-ANALYSIS.md` — remaining gaps.
