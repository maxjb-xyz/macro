# Published release images: operator workflow

This document describes the supported path from a source checkout to running
the Macro self-host Compose stack on immutable per-service release images,
so operators never need to compile ~60 GB of Rust build artifacts on the
target host.

Strategy background and alternatives are in
[`release-images.md`](release-images.md). The short version: each Rust
service is baked into its own image using the production-shaped
`docker/Dockerfile`, tagged immutably, and pushed to a registry. A Compose
overlay then points every service at its registry tag instead of the local
`build:` stanza.

## Components

| Piece | Path |
| --- | --- |
| Build + push script | `tooling/selfhost/build-release-images.sh` |
| Published-image Compose overlay | `docker/selfhost/compose.published.yml` |
| Two-service example overlay (prototype) | `docker/selfhost/compose.release-images.example.yml` |

## Prerequisites

- A container registry you can push to. GHCR is the documented default,
  but any OCI registry works.
- Docker with buildx on the build machine (the machine that builds once —
  not the operator's server).
- A checked-out source tree at the commit you want to release.
- `docker login ghcr.io` (a PAT with `write:packages` for GHCR) or an
  interactive login from your CI system.

## One-time release: build and push

Run this on a build machine or in CI, from the repo root:

```bash
# GHCR example — replace my-org with your GitHub org/user.
./tooling/selfhost/build-release-images.sh \
  --registry ghcr.io/my-org \
  --tag v2026.4.28.0 \
  --push
```

What it does:

- Iterates over the default set of Rust HTTP services and workers
  (authentication-service, connection-gateway, contacts-service,
  document-cognition-service, document-storage-service,
  document-upload-finalizer, email-service, email-pubsub-workers,
  notification-service, static-file-service).
- For each one, runs `docker build -f docker/Dockerfile --build-arg
SERVICE_NAME=<cargo_bin> -t <registry>/<service>:<tag> .`
- If `--push` is set, pushes every tag.
- `--tag` defaults to the short git SHA of the checkout; pass an explicit
  semver-style tag for releases.

Useful variations:

```bash
# Build only one service (repeatable flag)
./tooling/selfhost/build-release-images.sh \
  --registry ghcr.io/my-org --tag dev --service authentication-service

# Print the build matrix without running anything
./tooling/selfhost/build-release-images.sh \
  --registry ghcr.io/my-org --dry-run

# Build for a custom Dockerfile override (rare; normally automatic)
./tooling/selfhost/build-release-images.sh \
  --registry ghcr.io/my-org --dockerfile docker/Dockerfile.convert_service \
  --service convert_service
```

Special-case services, intentionally not in the default set:

- `search-processing-service` — needs pdfium handling; build with
  `--service search-processing-service`, which switches to
  `docker/Dockerfile.search_processing_service`.
- `convert-service` — needs LibreOffice/Collabora assets; build with
  `--service convert-service`, which switches to
  `docker/Dockerfile.convert_service`.

JS/worker services (sync_service, lexical_service, ai_editing_worker,
analytics_proxy, websocket_service) keep their own existing Dockerfiles
and are not covered by this script yet.

## Operator-side: run from published images

On the operator host, create or edit `.env` alongside your normal self-host
settings (see `docs/SELF_HOSTING_DURABLE.md`):

```bash
MACRO_RELEASE_IMAGE_REGISTRY=ghcr.io/my-org
MACRO_RELEASE_IMAGE_TAG=v2026.4.28.0
```

If the images are private, run `docker login ghcr.io` once on the operator
host with a read-scoped token.

Then bring the stack up with the published overlay:

```bash
docker compose --project-directory . \
  -f compose.yml \
  -f docker/docker-compose.self-host.yml \
  -f docker/selfhost/compose.published.yml \
  --env-file .env \
  pull

docker compose --project-directory . \
  -f compose.yml \
  -f docker/docker-compose.self-host.yml \
  -f docker/selfhost/compose.published.yml \
  --env-file .env \
  up -d
```

The overlay sets `image:` for each covered service and applies
`build: !reset null` / `command: !reset null` so Compose never tries to
rebuild locally and each container uses the image's baked-in entrypoint
(`dumb-init ./svc`). Everything else — env_file, healthchecks, depends_on,
networks, volumes — is inherited unchanged from the base
`docker/docker-compose.yml` and the self-host lifecycle overlay.

Validate the rendered config before `up`:

```bash
docker compose --project-directory . \
  -f compose.yml \
  -f docker/docker-compose.self-host.yml \
  -f docker/selfhost/compose.published.yml \
  --env-file .env \
  config --images
```

You should see one `<registry>/<service>:<tag>` line per covered service and
the original images for the still-uncovered ones.

## Rollback

Rollback is redeploying the previous immutable tag. Edit
`MACRO_RELEASE_IMAGE_TAG` in `.env` to the prior tag and re-run `pull` +
`up -d`. No rebuild is required.

## Tag discipline

The script accepts any tag; the recommended scheme is:

- `SHORT_SHA` — automatic default; covers every build from CI.
- A stable channel tag such as `stable` or a semver release tag
  (`v2026.4.28.0`) — re-published only from tagged releases.

Operators should always pin to a specific tag in `.env`; never deploy
`latest` in a long-lived environment.

## CI fan-out (GHCR)

The script is CI-friendly — any GitHub Actions job with
`permissions: packages: write` can call it directly:

```yaml
- uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}

- name: Build and push release images
  run: |
    ./tooling/selfhost/build-release-images.sh \
      --registry ghcr.io/${{ github.repository_owner }} \
      --tag ${{ github.sha }} \
      --push
```

For release tags, parameterise `--tag` from `github.ref_name`.

## Smoke test and handoff

After the published-image stack is up, run the operator acceptance smoke
in [`smoke-test-spec.md`](smoke-test-spec.md) — login, document/task/channel
behaviour, search, file storage, workers, persistence — before exposing real
users, exactly as you would after any other deployment or upgrade.
