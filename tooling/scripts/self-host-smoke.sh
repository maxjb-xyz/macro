#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACTS_DIR=""
SKIP_STACK=false
KEEP_STACK=true
COMPOSE_FILE="docker/docker-compose.yml"
PROJECT_NAME="macro"
ENV_FILE=".env"

usage() {
  cat <<'USAGE'
Usage: tooling/scripts/self-host-smoke.sh [options]

Bring up the disposable self-host Phase 1 stack with plain Docker Compose and
capture operator evidence under artifacts/self-host-smoke/.

Options:
  --artifacts-dir DIR    Evidence output directory
  --env-file FILE        Compose env file (default: .env; .env.example is used when .env is absent)
  --skip-stack           Only run cheap static checks; do not start Docker stack
  --down                 Tear the stack down after capture
  -h, --help             Show this help

Operators only need Docker with the Compose plugin. Nix, Rust, Cargo, and Just
are never required by this wrapper.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts-dir)
      ARTIFACTS_DIR="${2:?missing value for --artifacts-dir}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:?missing value for --env-file}"
      shift 2
      ;;
    --skip-stack)
      SKIP_STACK=true
      shift
      ;;
    --down)
      KEEP_STACK=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

cd "$ROOT_DIR"

if [[ -z "$ARTIFACTS_DIR" ]]; then
  ARTIFACTS_DIR="artifacts/self-host-smoke/compose-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$ARTIFACTS_DIR"

if [[ ! -f "$ENV_FILE" && -f .env.example ]]; then
  ENV_FILE=".env.example"
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "env file not found: $ENV_FILE" | tee -a "$ARTIFACTS_DIR/blockers.txt" >&2
  exit 64
fi
ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
COMPOSE=(env "MACRO_ENV_FILE=$ENV_FILE" docker compose --project-directory . -f "$COMPOSE_FILE" --env-file "$ENV_FILE")

run_capture() {
  local name="$1"
  shift
  echo "+ $*" | tee "$ARTIFACTS_DIR/${name}.cmd"
  "$@" >"$ARTIFACTS_DIR/${name}.out" 2>"$ARTIFACTS_DIR/${name}.err"
}

run_capture_allow_failure() {
  local name="$1"
  shift
  echo "+ $*" | tee "$ARTIFACTS_DIR/${name}.cmd"
  if "$@" >"$ARTIFACTS_DIR/${name}.out" 2>"$ARTIFACTS_DIR/${name}.err"; then
    echo 0 >"$ARTIFACTS_DIR/${name}.exit"
  else
    local status=$?
    echo "$status" >"$ARTIFACTS_DIR/${name}.exit"
    return "$status"
  fi
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required operator tool: $1" | tee -a "$ARTIFACTS_DIR/blockers.txt" >&2
    return 1
  fi
}

{
  echo "compose_file=$COMPOSE_FILE"
  echo "compose_project=$PROJECT_NAME"
  echo "env_file=$ENV_FILE"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git rev-parse HEAD 2>/dev/null | sed 's/^/commit=/' || true
} >"$ARTIFACTS_DIR/summary.env"

require_tool docker || {
  echo "Phase 1 smoke cannot run in this environment; see $ARTIFACTS_DIR/blockers.txt" >&2
  exit 127
}

if command -v git >/dev/null 2>&1; then
  run_capture git-status git status --short --branch
fi
run_capture compose-config "${COMPOSE[@]}" config

if [[ "$SKIP_STACK" == "true" ]]; then
  echo "skip_stack=true" >>"$ARTIFACTS_DIR/summary.env"
  echo "Static checks complete. Artifacts: $ARTIFACTS_DIR"
  exit 0
fi

run_capture compose-up "${COMPOSE[@]}" up -d --wait --wait-timeout 120
run_capture compose-ps "${COMPOSE[@]}" ps

{
  echo "compose_project=$PROJECT_NAME"
  echo "network=databases"
  echo "network=auth"
  echo "network=macro_services"
  echo "network=macro_auth_internal"
  echo "volume=macro_postgres_data"
  echo "volume=macro_redis_data"
  echo "volume=macro_opensearch_data"
  echo "volume=macro_kafka_data"
  echo "volume=fusionauth_db_data"
  echo "volume=fusionauth_config"
} >"$ARTIFACTS_DIR/resource-names.txt"

run_capture_allow_failure docker-ps docker ps --filter "label=com.docker.compose.project=$PROJECT_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
run_capture_allow_failure docker-network-inspect docker network inspect databases auth macro_services || true
run_capture_allow_failure docker-volume-inspect docker volume inspect macro_postgres_data macro_redis_data macro_opensearch_data macro_kafka_data fusionauth_db_data fusionauth_config || true
run_capture_allow_failure docker-logs "${COMPOSE[@]}" logs --no-color --tail 200 || true

cat >"$ARTIFACTS_DIR/manual-smoke-checklist.md" <<EOF
# Manual Phase 1 Browser Smoke

Use the ports published by docker compose ps.

- Auth: complete passwordless login through Mailpit if a code is required.
- Documents: open a document, create or edit content, reload, and confirm it persists.
- Channels/messages: send a message in a channel and confirm another persona with access can see it.
- Search: search for document/channel/message text and record whether the expected result appears.
- File upload/download: upload a small disposable file, open/download it, and confirm local object storage serves it back.
- WebSockets/collaboration: open the same document as two personas and confirm live edits or presence updates arrive without refresh.
- Background workers: trigger a queue-backed flow, then check docker-logs.out for successful worker processing and no crash loops.

Classify every failure in failure-log.md as one of:

- upstream local-stack bug
- self-hosting gap
- operator decision
EOF

touch "$ARTIFACTS_DIR/failure-log.md"

if [[ "$KEEP_STACK" == "true" ]]; then
  echo "Stack left running for manual smoke. Tear it down with:" | tee "$ARTIFACTS_DIR/next-steps.txt"
  echo "docker compose --project-directory . -f $COMPOSE_FILE down" | tee -a "$ARTIFACTS_DIR/next-steps.txt"
else
  run_capture compose-down "${COMPOSE[@]}" down
fi

echo "Phase 1 smoke capture complete. Artifacts: $ARTIFACTS_DIR"
