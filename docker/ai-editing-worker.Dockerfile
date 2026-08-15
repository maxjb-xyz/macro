FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
	&& rm -rf /var/lib/apt/lists/*
RUN npm install -g bun

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

WORKDIR /app

# The worker is a bun workspace member: it imports @macro-inc/* and
# @loro-mirror/core, which are workspace:* deps (local packages/), NOT published
# packages. So the whole workspace must be installed at build time, not just
# this service. docker/ai-editing-worker.Dockerfile.dockerignore re-includes
# /packages and /apps (same as lexical-service's) for this build context.
COPY . .
RUN bun install --frozen-lockfile

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
