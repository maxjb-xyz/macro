FROM oven/bun:1

WORKDIR /app

# Scoped build context: only lexical-service and its two workspace deps
# (lexical-core, loro-mirror), plus a trimmed workspace manifest + lockfile
# committed under docker/lexical-service/. No whole-repo copy and no
# GITHUB_PACKAGES_TOKEN (the @macro-inc packages are all local workspace:*,
# not published).
COPY docker/lexical-service/package.json ./package.json
COPY docker/lexical-service/bun.lock ./bun.lock
COPY packages/lexical-core/ packages/lexical-core/
COPY packages/loro-mirror/ packages/loro-mirror/
COPY services/lexical-service/ services/lexical-service/

RUN bun install --frozen-lockfile

# Bundle the entry (same as the dev compose command). Bundling hoists/orders the
# circular @lexical/* ESM imports (avoiding a TDZ at runtime) and inlines the
# workspace deps. loro-crdt stays external: bundling it emits its .wasm as a
# second output file (breaking --outfile) and mis-wires wasm instantiation. The
# bundle lives under /app so bun resolves the external loro-crdt import
# relative to /app/node_modules.
RUN cd services/lexical-service \
    && bun build src/server.ts --target=bun --external loro-crdt --outfile=/app/server.bundle.js

EXPOSE 8096

CMD ["bun", "/app/server.bundle.js"]
