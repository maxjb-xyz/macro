FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
	&& rm -rf /var/lib/apt/lists/*
RUN npm install -g bun

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

WORKDIR /app

# Install ONLY ai-editing-worker's dependency tree with `--filter`, skipping
# apps/web and the other services' deps (the old full-workspace install dragged
# in ~1420 packages / ~3.8 GB). The filter keeps the hoisted layout + workspace
# symlinks that wrangler needs. All workspace dirs must be present for bun to
# validate the manifest, so COPY the source tree — docker/ai-editing-worker.Dockerfile.dockerignore
# trims it to just the workspace dirs (no crates/, docker/, infra/, etc.).
COPY . .
RUN bun install --filter ai-editing-worker --frozen-lockfile

WORKDIR /app/services/ai-editing-worker

# Transpile the QuickJS sandbox bundle (src/editor-sandbox-code.ts) at build
# time so the image is immutable and never regenerates source on boot.
RUN bun scripts/generate-sandbox.ts

EXPOSE 8933

# BYOK: surface the three AI provider keys as wrangler secrets so the worker
# can read them from c.env. Blank keys degrade gracefully in the router.
CMD ["sh", "-c", "\
  printf 'OPENAI_API_KEY=%s\\nANTHROPIC_API_KEY=%s\\nCEREBRAS_API_KEY=%s\\n' \
    \"${OPENAI_API_KEY}\" \
    \"${ANTHROPIC_API_KEY}\" \
    \"${CEREBRAS_API_KEY}\" \
    > .dev.vars && \
  exec npx wrangler dev \
    --env local \
    --ip 0.0.0.0 \
    --var SYNC_WS_BASE:ws://sync-service:8787\
"]
