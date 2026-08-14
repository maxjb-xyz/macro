#!/usr/bin/env bash
set -uo pipefail

# Host-only validation for the Compose operator path. This is intentionally a
# handoff tool: do not run it in CI or as part of the ordinary contributor gate.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACTS_DIR=""
ENV_FILE=".env.example"
KEEP_STACK=false
PROJECT_NAME="macro"
COMPOSE_FILE="docker/docker-compose.yml"
STATUS=0

usage() {
  cat <<'USAGE'
Usage: tooling/scripts/host-test-handoff.sh [options]

Run the Docker-daemon-only Phase 1 host test and capture a reviewable evidence
bundle under artifacts/host-test/. The stack is removed when the script ends.

Options:
  --artifacts-dir DIR    Evidence directory (default: artifacts/host-test/<timestamp>)
  --env-file FILE        Compose env file (default: .env.example)
  --keep-stack           Leave the stack running after capture for browser checks
  -h, --help             Show this help

This script is for Maximus after the repo is ready for host validation. It is
not a replacement for the plain Docker Compose operator commands in the docs.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifacts-dir) ARTIFACTS_DIR="${2:?missing value for --artifacts-dir}"; shift 2 ;;
    --env-file) ENV_FILE="${2:?missing value for --env-file}"; shift 2 ;;
    --keep-stack) KEEP_STACK=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

cd "$ROOT_DIR"
[[ -n "$ARTIFACTS_DIR" ]] || ARTIFACTS_DIR="artifacts/host-test/compose-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ARTIFACTS_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "env file not found: $ENV_FILE" | tee "$ARTIFACTS_DIR/blockers.txt" >&2
  exit 2
fi

COMPOSE=(docker compose --project-directory . --file "$COMPOSE_FILE" --project-name "$PROJECT_NAME" --env-file "$ENV_FILE")

record() {
  local name="$1"
  shift
  printf '+ %q' "$1" >"$ARTIFACTS_DIR/${name}.cmd"
  local arg
  for arg in "${@:2}"; do printf ' %q' "$arg" >>"$ARTIFACTS_DIR/${name}.cmd"; done
  printf '\n' >>"$ARTIFACTS_DIR/${name}.cmd"
  if "$@" >"$ARTIFACTS_DIR/${name}.out" 2>"$ARTIFACTS_DIR/${name}.err"; then
    echo 0 >"$ARTIFACTS_DIR/${name}.exit"
  else
    local code=$?
    echo "$code" >"$ARTIFACTS_DIR/${name}.exit"
    STATUS=1
  fi
}

record_docker() {
  local name="$1"
  shift
  record "$name" docker "$@"
}

{
  echo "format_version=1"
  echo "compose_file=$COMPOSE_FILE"
  echo "compose_project=$PROJECT_NAME"
  echo "env_file=$ENV_FILE"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git rev-parse HEAD 2>/dev/null | sed 's/^/commit=/' || true
} >"$ARTIFACTS_DIR/manifest.env"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" | tee "$ARTIFACTS_DIR/blockers.txt" >&2
  exit 127
fi

record_docker docker-version version
record_docker daemon-info info
if [[ "$(cat "$ARTIFACTS_DIR/daemon-info.exit")" != 0 ]]; then
  echo "Docker daemon is unavailable; no Compose host test was attempted." | tee "$ARTIFACTS_DIR/blockers.txt" >&2
  exit 125
fi

record compose-version "${COMPOSE[@]}" version
record compose-config "${COMPOSE[@]}" config
record compose-up "${COMPOSE[@]}" up -d --wait --wait-timeout 180
record compose-ps "${COMPOSE[@]}" ps
record localstack-health "${COMPOSE[@]}" exec -T localstack curl -fsS http://localhost:4566/_localstack/health
record localstack-sqs "${COMPOSE[@]}" exec -T localstack awslocal sqs list-queues
record localstack-s3 "${COMPOSE[@]}" exec -T localstack awslocal s3api list-buckets
record localstack-dynamodb "${COMPOSE[@]}" exec -T localstack awslocal dynamodb list-tables
record mailpit-health "${COMPOSE[@]}" exec -T localstack curl -fsS http://mailpit:8025/api/v1/info
record compose-logs "${COMPOSE[@]}" logs --no-color --tail 200

cat >"$ARTIFACTS_DIR/failure-log.md" <<'EOF'
# Host-test failure log

Record each observed issue here and use one bucket from
`docs/HOST_TEST_HANDOFF.md`: `environment`, `compose/config`, `service/startup`,
`runtime/dependency`, or `product/manual`.
EOF

if [[ "$KEEP_STACK" == "false" ]]; then
  record compose-down "${COMPOSE[@]}" down
else
  cat >"$ARTIFACTS_DIR/next-steps.txt" <<EOF
Stack left running for manual checks. Reclaim it with:
docker compose --project-directory . -f $COMPOSE_FILE --project-name $PROJECT_NAME --env-file $ENV_FILE down
EOF
fi

echo "finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$ARTIFACTS_DIR/manifest.env"
echo "Host-test evidence: $ARTIFACTS_DIR"
exit "$STATUS"
