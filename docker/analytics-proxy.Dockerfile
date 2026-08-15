FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
	&& rm -rf /var/lib/apt/lists/*
RUN npm install -g bun

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

WORKDIR /app/services/analytics-proxy

# Install the service's own deps at build time (hono + wrangler) so the image
# is immutable and needs no runtime npm/bun network access — unlike the old
# bind-mounted dev path, where `bun install` ran on every container start.
COPY services/analytics-proxy/package.json services/analytics-proxy/bun.lock ./
RUN bun install --frozen-lockfile

# Source + wrangler config. No bind-mount: wrangler dev serves from the image.
COPY services/analytics-proxy/ .

EXPOSE 8098

# Forward OTLP (both signals) to the local otel-collector by default (--var
# overrides the wrangler.jsonc host defaults); override via env for a real
# Datadog intake. No DD_API_KEY locally, so the worker skips key injection.
CMD ["sh", "-c", "exec npx wrangler dev --env local --ip 0.0.0.0 --port 8098 --var OTLP_TRACES_INTAKE_URL:${OTLP_TRACES_INTAKE_URL:-http://otel-collector:4318} --var OTLP_LOGS_INTAKE_URL:${OTLP_LOGS_INTAKE_URL:-http://otel-collector:4318}"]
