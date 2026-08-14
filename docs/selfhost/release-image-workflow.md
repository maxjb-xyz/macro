# Release images: build once, deploy anywhere

Operators should not build 60 GB of Rust artifacts on the deployment host.
This document describes the supported path from a source checkout to a
Compose stack that runs immutable, registry-published images.

## Overview

| Path | When to use |
|---|---|
| `tooling/selfhost/build-release-images.sh` + `compose.published.yml` | You (or a release engineer) build images once and push them to a registry you control. Operators pull. |
| CI fan-out (follow-up work) | The project publishes images to GHCR on every release tag. Operators reference them directly. |

Either path ends with the operator running `compose.published.yml`, which
removes every `build:` stanza and points each service at an immutable image
tag.

## Prerequisites on the build host

The build host needs Docker, git, and enough disk for the Rust build cache.
This is a one-time / per-release machine — not the operator's server.

## Step 1 — Build and push images (release engineer)

```bash
git checkout <release-tag>
./tooling/selfhost/build-release-images.sh \
  --registry ghcr.io/YOUR_ORG \
  --tag v2026.4.28.0 \
  --push
```

What the script does:

- Builds one image per Rust service from `docker/Dockerfile` using
  `--build-arg SERVICE_NAME=<cargo_bin>`.
- Tags each as `<registry>/<service-name>:<tag>` (service names are kebab-case,
  e.g. `authentication-service`, `connection-gateway`).
- With `--push`, pushes every tag.
- Skips `search_processing_service` (pdfium) and `convert_service`
  (LibreOffice) unless you pass `--service <name>` explicitly — those need
  their specialized Dockerfiles and are not yet part of the default set.
- Does NOT build the JS/worker services (`sync_service`, `lexical_service`,
  `ai_editing_worker`, `analytics_proxy`, `websocket_service`). Those still
  build on the operator host from their per-service Dockerfiles.

To authenticate to GHCR for the push:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u YOUR_USERNAME --password-stdin
```

The token needs `write:packages` for your org.

### Tag discipline

Use the git tag / VERSION as the image tag so the Compose stack, the source
checkout, and the running images all agree:

```bash
--tag "$(cat VERSION | tr -d 'v')"     # or the literal tag, e.g. v2026.4.28.0
```

Avoid `latest`. Immutable tags are what make rollback `docker compose pull &&
up -d` instead of a rebuild.

## Step 2 — Configure the operator host

On the deployment host, in your operator `.env`:

```bash
MACRO_RELEASE_IMAGE_REGISTRY=ghcr.io/YOUR_ORG
MACRO_RELEASE_IMAGE_TAG=v2026.4.28.0
```

If the registry is private, log in once on the operator host:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u YOUR_USERNAME --password-stdin
```

A read-only `read:packages` token is sufficient here.

## Step 3 — Run the stack

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

`compose.published.yml` overrides each covered service with:

- `image:` pointing at your registry/tag.
- `build: !reset null` — removes the inherited dev build stanza.
- `command: !reset null` — uses the image's built-in entrypoint
  (`dumb-init ./svc`) instead of the dev `/app/out/<binary>` path.

Sanity-check the rendered config before booting:

```bash
docker compose --project-directory . \
  -f compose.yml \
  -f docker/docker-compose.self-host.yml \
  -f docker/selfhost/compose.published.yml \
  --env-file .env \
  config | grep -E "image:|build:" | head -40
```

You should see `image: ghcr.io/...` for every covered service and no `build:`
stanzas on them.

## Upgrade / rollback

Upgrade:

```bash
# on the build host
./tooling/selfhost/build-release-images.sh --registry ghcr.io/YOUR_ORG --tag vNEW --push

# on the operator host
# edit .env: MACRO_RELEASE_IMAGE_TAG=vNEW
docker compose ... pull && docker compose ... up -d
```

Rollback: set `MACRO_RELEASE_IMAGE_TAG` back to the previous tag, `pull`,
`up -d`. No rebuild on the operator host in either direction.

## Services NOT covered by this overlay

These still use their own Dockerfiles on the operator host (or need a
dedicated release-image follow-up):

- `search_processing_service` — pdfium handling; see
  `docker/Dockerfile.search_processing_service`.
- `convert_service` — LibreOffice / Collabora assets; see
  `docker/Dockerfile.convert_service`.
- `sync_service`, `lexical_service`, `ai_editing_worker`, `analytics_proxy`,
  `websocket_service` — JS/worker side, separate build pipeline.

Until those get published images, the operator host still needs Docker build
capability for them, but the heavy Rust workspace build is eliminated.

## Troubleshooting

- **`manifest unknown` on pull** — the tag was not pushed. Re-run the build
  script with `--push` and the same `--tag` the operator is asking for.
- **`unauthorized` on pull** — the operator host needs `docker login` to the
  registry, or the package visibility is private and the token lacks
  `read:packages`.
- **A service still tries to build on the operator host** — the overlay order
  is wrong. `compose.published.yml` must come AFTER
  `docker/docker-compose.self-host.yml` on the command line.
- **Image is the wrong architecture** — the build script builds for the host
  architecture. For arm64 operators from an x86_64 build host, add
  `--platform linux/arm64` to the `docker build` invocation in the script or
  build with buildx.

## See also

- `docs/selfhost/release-images.md` — strategy decision record.
- `docs/SELF_HOSTING_DURABLE.md` — overall operator contract.
- `tooling/selfhost/backup-restore.sh` — volume/database backup skeleton.
