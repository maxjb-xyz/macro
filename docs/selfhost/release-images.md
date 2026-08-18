# Release images

Operators should never build Rust on the deployment host. CI publishes one
immutable image per service to GHCR; you just pull.

## How it works

CI (`build-release-images.yml`) builds one image per service and pushes it to
`ghcr.io/maxjb-xyz/macro/<image>`, tagged `sha-<full-sha>`, `:latest`, and `v*`
on each release. Builds run on `v*` tags and manual `workflow_dispatch` — not
on every push.

Why one image per service (instead of one big image): a broken image only
affects that service, and each service can roll forward or back independently.

## Point your deploy at published images

In `.env`:

```bash
MACRO_RELEASE_IMAGE_REGISTRY=ghcr.io/maxjb-xyz/macro
MACRO_RELEASE_IMAGE_TAG=sha-<full-sha>      # or a v* tag
```

Then:

```bash
docker compose up -d --wait
```

`compose.yml` pins each Macro service to its release image (via
`docker/selfhost/compose.release-images.yml`, deep-merged by
`tooling/selfhost/flatten-compose.py`). It drops the dev `build:`/`command:`
stanzas and dev bind-mounts so the image's baked-in entrypoint runs.

Validate before booting:

```bash
docker compose config --images
```

## Building manually (optional)

If you aren't using the fork's CI, build and push once from a build machine:

```bash
./tooling/selfhost/build-release-images.sh \
  --registry ghcr.io/YOUR_ORG --tag v2026.x.y.z --push
```

`docker login ghcr.io` first (a `write:packages` token). The script accepts
`--service <name>` to build one image and `--dry-run` to print the matrix.

## Upgrade / rollback

See [`update-rollback.md`](update-rollback.md). The short version: record the
current tag and take a backup, set `MACRO_RELEASE_IMAGE_TAG` to the new tag,
`up -d --wait`, smoke-test, and roll back by restoring the previous tag (or the
previous env plus a database restore if a migration can't be reversed).

## Troubleshooting

- **`manifest unknown`** — the tag wasn't pushed. Re-run the build with `--push`.
- **`unauthorized`** — `docker login ghcr.io` with a `read:packages` token.
- **A service still builds locally** — its `image:` pin is missing, or
  `MACRO_RELEASE_IMAGE_REGISTRY`/`_TAG` aren't set in `.env`.
- **Wrong architecture** — CI builds `linux/amd64`; for arm64, build with
  `--platform linux/arm64` and push to your own registry.
