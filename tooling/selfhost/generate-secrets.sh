#!/usr/bin/env bash
# Generate a real .env with random secrets for the Macro self-host stack.
#
# Replaces the placeholder values in .env.example with freshly generated secrets
# and writes .env. Refuses to overwrite an existing .env.
#
# Requirements: openssl, python3.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [ -f .env ]; then
  echo "error: .env already exists; refusing to overwrite it" >&2
  echo "       back it up and remove it first, or edit it manually." >&2
  exit 1
fi

command -v openssl >/dev/null 2>&1 || { echo "error: openssl is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }

gen_hex() { openssl rand -hex "${1:-32}"; }
gen_b64() { openssl rand -base64 "${1:-32}" | tr -d '\n'; }

# Same value is used as both FusionAuth API key and secret.
FA_API_KEY="$(gen_hex 32)"
# Same value is used by document_storage_service and the shared internal auth.
DSS_AUTH_KEY="$(gen_hex 32)"

FA_CLIENT_SECRET="$(gen_b64 32)"
JWT_SECRET="$(gen_hex 48)"
FA_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr '+/' 'Aa')"
# Internal service-to-service auth. These five keys were all "local" in
# .env.example and MUST share one value: e.g. document_storage_service calls
# lexical with INTERNAL_API_SECRET_KEY but lexical verifies INTERNAL_AUTH_KEY,
# and the FusionAuth webhook verifies INTERNAL_API_KEY. Splitting them breaks
# cross-service auth.
INTERNAL_KEY="$(gen_hex 32)"
INTERNAL_API_SECRET_KEY="$INTERNAL_KEY"
INTERNAL_API_KEY="$INTERNAL_KEY"
INTERNAL_AUTH_KEY="$INTERNAL_KEY"
SYNC_AUTH_KEY="$INTERNAL_KEY"
DOC_PERM_JWT="$INTERNAL_KEY"
AUTH_SVC_SECRET="$(gen_hex 32)"
MCP_KEY="$(gen_b64 32)"

# Macro API token signing uses RS256 (crates/macro_auth/src/macro_api_token.rs).
# Store the PEM as a single line with literal \n so it fits in an env file;
# the app's normalize_pem() turns those back into real newlines.
KEYFILE="$(mktemp)"
openssl genrsa -out "$KEYFILE" 2048 2>/dev/null
PRIVATE_PEM="$(awk 'NF {printf "%s\\n", $0}' "$KEYFILE")"
PUBLIC_PEM="$(openssl rsa -in "$KEYFILE" -pubout 2>/dev/null | awk 'NF {printf "%s\\n", $0}')"
rm -f "$KEYFILE"

export FA_API_KEY FA_CLIENT_SECRET JWT_SECRET FA_ADMIN_PASSWORD \
       INTERNAL_API_SECRET_KEY INTERNAL_API_KEY INTERNAL_AUTH_KEY \
       AUTH_SVC_SECRET SYNC_AUTH_KEY DOC_PERM_JWT DSS_AUTH_KEY MCP_KEY \
       PRIVATE_PEM PUBLIC_PEM

python3 - "$@" <<'PY'
import os, sys
from pathlib import Path

values = {
    "FUSIONAUTH_API_KEY": os.environ["FA_API_KEY"],
    "FUSIONAUTH_API_KEY_SECRET_KEY": os.environ["FA_API_KEY"],
    "FUSIONAUTH_CLIENT_SECRET_KEY": os.environ["FA_CLIENT_SECRET"],
    "FUSIONAUTH_ADMIN_PASSWORD": os.environ["FA_ADMIN_PASSWORD"],
    "JWT_SECRET_KEY": os.environ["JWT_SECRET"],
    "INTERNAL_API_SECRET_KEY": os.environ["INTERNAL_API_SECRET_KEY"],
    "INTERNAL_API_KEY": os.environ["INTERNAL_API_KEY"],
    "INTERNAL_AUTH_KEY": os.environ["INTERNAL_AUTH_KEY"],
    "AUTHENTICATION_SERVICE_SECRET_KEY": os.environ["AUTH_SVC_SECRET"],
    "SYNC_SERVICE_AUTH_KEY": os.environ["SYNC_AUTH_KEY"],
    "DOCUMENT_PERMISSION_JWT": os.environ["DOC_PERM_JWT"],
    "DOCUMENT_STORAGE_SERVICE_AUTH_KEY": os.environ["DSS_AUTH_KEY"],
    "SERVICE_INTERNAL_AUTH_KEY": os.environ["DSS_AUTH_KEY"],
    "MCP_CREDENTIALS_KEY_SECRET_NAME": os.environ["MCP_KEY"],
    "MACRO_API_TOKEN_PRIVATE_SECRET_KEY": os.environ["PRIVATE_PEM"],
    "MACRO_API_TOKEN_PUBLIC_KEY": os.environ["PUBLIC_PEM"],
}

src = Path(".env.example")
out = Path(".env")
lines = src.read_text().splitlines()
written = []
seen = set()
for line in lines:
    if line.strip() == "" or line.lstrip().startswith("#") or "=" not in line:
        written.append(line)
        continue
    key = line.split("=", 1)[0].strip()
    if key in values:
        written.append(f"{key}={values[key]}")
        seen.add(key)
    else:
        written.append(line)

missing = set(values) - seen
if missing:
    print(f"error: .env.example is missing keys that need secret values: {sorted(missing)}", file=sys.stderr)
    sys.exit(1)

out.write_text("\n".join(written) + "\n")
print(f"wrote {out} ({len(seen)} secrets generated)")
print("keep it secret — .env is gitignored and must never be committed.")
PY

chmod 600 .env 2>/dev/null || true
