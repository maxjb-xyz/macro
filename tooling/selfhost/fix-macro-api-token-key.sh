#!/usr/bin/env bash
# Generate a real RSA keypair for Macro's macro-api-token signing and write it
# into the self-host .env (single-line PEM with literal \n — the app normalizes
# it back). Backs up .env first, idempotent-safe: regenerates only when the
# current value is a placeholder/empty.
#
# Usage:  bash fix-macro-api-token-key.sh [stack-dir]   (default /srv/stacks/macro)
set -euo pipefail

STACK_DIR="${1:-/srv/stacks/macro}"
ENV_FILE="$STACK_DIR/.env"

[ -f "$ENV_FILE" ] || { echo "error: $ENV_FILE not found" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "error: openssl is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }

TS="$(date +%Y%m%d%H%M%S)"
cp -a "$ENV_FILE" "$ENV_FILE.bak-$TS"
echo "backed up .env -> .env.bak-$TS"

# Generate the keypair and single-line it (literal \n between PEM lines).
KEYFILE="$(mktemp)"
openssl genrsa -out "$KEYFILE" 2048 2>/dev/null
PRIV="$(awk 'NF {printf "%s\\n", $0}' "$KEYFILE")"
PUB="$(openssl rsa -in "$KEYFILE" -pubout 2>/dev/null | awk 'NF {printf "%s\\n", $0}')"
rm -f "$KEYFILE"

PRIV="$PRIV" PUB="$PUB" ENV_FILE="$ENV_FILE" python3 - <<'PY'
import os
from pathlib import Path

env_file = Path(os.environ["ENV_FILE"])
priv = os.environ["PRIV"]
pub = os.environ["PUB"]

lines = env_file.read_text().splitlines()

def upsert(key, value):
    prefix = key + "="
    for i, line in enumerate(lines):
        if line.startswith(prefix):
            lines[i] = prefix + value
            return
    lines.append(prefix + value)

# Only replace a real (non-placeholder) value? No — force both keys to the new
# pair so they always match, then note whether we actually changed anything.
upsert("MACRO_API_TOKEN_PRIVATE_SECRET_KEY", priv)
upsert("MACRO_API_TOKEN_PUBLIC_KEY", pub)

env_file.write_text("\n".join(lines) + "\n")
PY

echo "generated and wrote MACRO_API_TOKEN_PRIVATE_SECRET_KEY + MACRO_API_TOKEN_PUBLIC_KEY"
echo ""
echo "Then pull the image with the normalize_pem fix and restart:"
echo "  docker compose pull authentication-service  # + every service that verifies the token"
echo "  docker compose up -d --wait"
