# Release image strategy

> Status: adopted and implemented — the per-service baked-image approach is
> wired into `compose.yml` via `docker/selfhost/compose.release-images.yml`
> (deep-merged into a single self-contained `compose.yml` by
> `tooling/selfhost/flatten-compose.py`); the operator workflow is
> `docs/selfhost/published-release-images.md`. This file is the decision record.

This note records the first self-host release-image decision for the Macro Compose stack. The goal is to remove the current dependency on host-built, bind-mounted Rust development binaries for operator-facing self-host runs while keeping the self-host layer additive and easy to rebase.

## Current shape

The upstream/local Compose file (`docker/docker-compose.yml`) defines all Rust HTTP services and workers through the shared `x-rust-services-image` anchor:

- image: `macro-local-rust-services:dev`
- build: `docker/Dockerfile.dev`, target `services_bundle`
- command: `/app/out/<binary>`

The local xtask path improves iteration by generating an override that drops `build:` and bind-mounts host binaries into the small runtime image (`docker/Dockerfile.runtime`). That is correct for development, but it is not a release contract: the host must have matching Linux binaries, the runtime closure is outside the image, and rollback is not an immutable image tag.

## Options compared

### 1. Baked per-service images

Build one image per Rust service or worker. Each image contains exactly one release binary and uses the existing slim runtime pattern from `docker/Dockerfile`:

```bash
docker build \
  -f docker/Dockerfile \
  --build-arg SERVICE_NAME=authentication_service \
  -t ${MACRO_RELEASE_IMAGE_REGISTRY:-macro-release}/authentication-service:${MACRO_RELEASE_IMAGE_TAG:-dev} \
  .
```

Pros:

- Immutable runtime: no host binary bind mount and no host Rust toolchain requirement.
- Natural Compose model: each service has its own image tag and can be rolled forward/back independently.
- Small blast radius: a broken image only affects that service.
- Reuses the existing production-shaped `docker/Dockerfile` instead of inventing a new build system.
- Compatible with existing Compose health checks, networks, env_file, and depends_on.

Cons:

- CI has to build/publish multiple images.
- Shared dependencies are rebuilt unless the registry/build cache is configured well.
- Special-case services still need their specialized Dockerfiles or documented exclusions. `search_processing_service` needs pdfium handling; `convert_service` needs LibreOffice/Collabora assets.

Verdict: recommended path.

### 2. One bundled Rust runtime image

Keep the current `services_bundle` model, but publish it as a release image and run every Rust service from `/app/out/<binary>`.

Pros:

- Smallest conceptual delta from the current local Compose file.
- One image tag to publish and consume.
- Efficient when most services are updated together.

Cons:

- Very large blast radius: every Rust service rolls back/forward together.
- Harder to reason about security scanning and ownership per service.
- Operators cannot pin a hotfix for one service without replacing all Rust services.
- Keeps the development-oriented `/app/out/<binary>` command contract as the production contract.

Verdict: acceptable only as a temporary bootstrap if CI image fan-out is not ready.

### 3. Preview-style artifact mount

Publish/download a tarball of built binaries, unpack it on the host, and mount it into a shared runtime image.

Pros:

- Reuses the existing xtask local flow and preview artifact concepts.
- Fast for CI handoff and short-lived preview stacks.
- Avoids building N service images initially.

Cons:

- Still depends on host filesystem state at runtime.
- Rollback is a tarball plus mount discipline, not a Docker image tag.
- Operators must manage artifact extraction, permissions, architecture, and runtime closure.
- Easy to drift from the Compose image/env contract that production hardening needs.

Verdict: keep for preview/local automation; do not use as the durable self-host release contract.

## Release-image overlay

`docker/selfhost/compose.release-images.yml` carries the per-service image
override for every Macro service (13 Rust + `proxy` + 5 JS/worker), extending
the two-service prototype:

- `authentication-service` -> `${MACRO_RELEASE_IMAGE_REGISTRY}/authentication-service:${MACRO_RELEASE_IMAGE_TAG}`
- `static_file_service` -> `${MACRO_RELEASE_IMAGE_REGISTRY}/static-file-service:${MACRO_RELEASE_IMAGE_TAG}`
- ...and the rest of the 19 Macro services.

The overlay inherits each service's env_file, healthcheck, depends_on, expose,
and networks from the base file. It only changes these fields:

- `image`: point to an immutable per-service release tag.
- `build: !reset null`: remove the inherited development build stanza.
- `command: !reset null`: use the image entrypoint from `docker/Dockerfile` (`dumb-init ./svc`) rather than `/app/out/<binary>`.
- `volumes: !reset []` (JS/worker services): drop the dev bind-mounts.

Docker Compose's `include:` directive cannot override a service an included
file already defines (v2.24+ errors with "conflicts with imported resource";
older versions silently first-win), so the overlay is not applied at
compose-time. `tooling/selfhost/flatten-compose.py` deep-merges all sources
into one self-contained `compose.yml` with no `include:` and no `-f` flags.
Regenerate after editing a source file:

```bash
python3 tooling/selfhost/flatten-compose.py
```

Render check:

```bash
docker compose config --images
```

Local prototype image builds:

```bash
docker build \
  -f docker/Dockerfile \
  --build-arg SERVICE_NAME=authentication_service \
  -t macro-release/authentication-service:dev \
  .

docker build \
  -f docker/Dockerfile \
  --build-arg SERVICE_NAME=static_file_service \
  -t macro-release/static-file-service:dev \
  .
```

## Recommendation

Adopt baked per-service images as the self-host release image strategy.

Implementation order:

1. Maintain `docker/selfhost/compose.release-images.yml` as the per-service image pin source (a service is added only after its image has a published tag and a smoke check).
2. Add CI fan-out for the default Rust services using `docker/Dockerfile` and `SERVICE_NAME=<cargo_bin>`.
3. Publish tags by registry, service, git SHA, and stable channel, for example:
   - `${registry}/authentication-service:${git_sha}`
   - `${registry}/authentication-service:stable`
4. Graduate services into the release overlay only after each image has a smoke check.
5. Handle exceptions explicitly:
   - `search_processing_service`: use `docker/Dockerfile.search_processing_service.prebuilt` or a dedicated release Dockerfile until pdfium/default-feature handling is proven.
   - `convert_service`: use its dedicated LibreOffice/Collabora image path.
   - JS/Worker-side services (`sync_service`, `lexical_service`, `ai_editing_worker`, `analytics_proxy`, `websocket_service`) — **done** (see `build-release-images.yml`): each has a build-time Dockerfile (sync via Rust→wasm builder; lexical via a scoped workspace bundle; ai-editing + analytics + websocket via build-time `bun install`), published to GHCR and wired into `compose.yml`.
6. Once every required service has a published image, the overlay is the production default (done — `flatten-compose.py` bakes it into `compose.yml`), and the production hardening checklist requires immutable image tags.

Do not make the preview artifact mount path the default self-host packaging model. It is useful for CI previews, but it preserves the host-bind-mounted binary failure mode this task is meant to eliminate.
