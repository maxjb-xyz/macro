#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTANCE="selfhost"
PORT_BASE="31000"
ARTIFACTS_DIR=""
SKIP_STACK=false
KEEP_STACK=true
SCENARIO_FILE="tooling/seed_cli/seed/scenarios/team-perms.json"

usage() {
  cat <<'USAGE'
Usage: tooling/scripts/self-host-smoke.sh [options]

Bring up the disposable self-host Phase 1 stack, seed the team permissions
scenario, and capture operator evidence under artifacts/self-host-smoke/.

Options:
  --instance NAME        Stack instance name (default: selfhost)
  --port-base PORT       Deterministic port window base (default: 31000)
  --artifacts-dir DIR    Evidence output directory
  --scenario-file FILE   Seed scenario path (default: tooling/seed_cli/seed/scenarios/team-perms.json)
  --skip-stack           Only run cheap static checks; do not start Docker stack
  --down                 Tear the stack down after capture
  -h, --help             Show this help

The stack is kept running by default so an operator can finish the browser smoke
from the URLs printed by `just stack status`.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance)
      INSTANCE="${2:?missing value for --instance}"
      shift 2
      ;;
    --port-base)
      PORT_BASE="${2:?missing value for --port-base}"
      shift 2
      ;;
    --artifacts-dir)
      ARTIFACTS_DIR="${2:?missing value for --artifacts-dir}"
      shift 2
      ;;
    --scenario-file)
      SCENARIO_FILE="${2:?missing value for --scenario-file}"
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
  ARTIFACTS_DIR="artifacts/self-host-smoke/${INSTANCE}-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$ARTIFACTS_DIR"

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
    echo "missing required tool: $1" | tee -a "$ARTIFACTS_DIR/blockers.txt" >&2
    return 1
  fi
}

{
  echo "instance=$INSTANCE"
  echo "port_base=$PORT_BASE"
  echo "scenario_file=$SCENARIO_FILE"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git rev-parse HEAD | sed 's/^/commit=/'
} >"$ARTIFACTS_DIR/summary.env"

missing=0
require_tool git || missing=1
require_tool docker || missing=1
require_tool just || missing=1
require_tool cargo || missing=1

if [[ ! -f "$SCENARIO_FILE" ]]; then
  echo "missing seed scenario: $SCENARIO_FILE" | tee -a "$ARTIFACTS_DIR/blockers.txt" >&2
  missing=1
fi

if [[ "$missing" -ne 0 ]]; then
  echo "Phase 1 smoke cannot run in this environment; see $ARTIFACTS_DIR/blockers.txt" >&2
  exit 127
fi

if command -v nix >/dev/null 2>&1; then
  run_capture nix-flake-check nix flake metadata --no-write-lock-file
else
  echo "nix not installed; run this script from inside nix develop on operator machines" \
    | tee -a "$ARTIFACTS_DIR/operator-decisions.txt"
fi

run_capture git-status git status --short --branch
run_capture compose-config docker compose --project-directory . -f docker/docker-compose.yml config
run_capture validate-local-compose cargo run --quiet --manifest-path Cargo.toml -p xtask_local --features local-stack -- validate-local-compose --instance "$INSTANCE" --port-base "$PORT_BASE"
run_capture validate-local-env cargo run --quiet --manifest-path Cargo.toml -p xtask_local --features local-stack -- validate-local-env --instance "$INSTANCE" --port-base "$PORT_BASE" --no-doppler

if [[ "$SKIP_STACK" == "true" ]]; then
  echo "skip_stack=true" >>"$ARTIFACTS_DIR/summary.env"
  echo "Static checks complete. Artifacts: $ARTIFACTS_DIR"
  exit 0
fi

run_capture doctor-local just doctor-local --instance "$INSTANCE" --port-base "$PORT_BASE"
run_capture stack-up just stack up --instance "$INSTANCE" --port-base "$PORT_BASE" --no-doppler
run_capture stack-status-json just stack status --instance "$INSTANCE" --port-base "$PORT_BASE" --json
run_capture stack-status just stack status --instance "$INSTANCE" --port-base "$PORT_BASE"
run_capture seed-apply just seed-scenario --instance "$INSTANCE" --port-base "$PORT_BASE" apply --file "$SCENARIO_FILE"
run_capture seed-status just seed-scenario --instance "$INSTANCE" --port-base "$PORT_BASE" status --file "$SCENARIO_FILE"
run_capture seed-matrix just seed-scenario --instance "$INSTANCE" --port-base "$PORT_BASE" matrix --file "$SCENARIO_FILE"

GENERATED_DIR="infra/local/generated/$INSTANCE"
if [[ -d "$GENERATED_DIR" ]]; then
  find "$GENERATED_DIR" -maxdepth 2 -type f | sort >"$ARTIFACTS_DIR/generated-files.txt"
fi

if [[ "$INSTANCE" == "macro" ]]; then
  PROJECT_NAME="macro"
  NETWORKS=(databases auth)
  VOLUMES=(
    macro_postgres_data
    macro_redis_data
    macro_opensearch_data
    macro_kafka_data
    fusionauth_db_data
    fusionauth_config
  )
else
  PROJECT_NAME="macro-${INSTANCE}"
  NETWORKS=("databases-${INSTANCE}" "auth-${INSTANCE}")
  VOLUMES=(
    "macro_postgres_data_${INSTANCE}"
    "macro_redis_data_${INSTANCE}"
    "macro_opensearch_data_${INSTANCE}"
    "macro_kafka_data_${INSTANCE}"
    "fusionauth_db_data_${INSTANCE}"
    "fusionauth_config_${INSTANCE}"
  )
fi
{
  echo "compose_project=$PROJECT_NAME"
  printf 'network=%s\n' "${NETWORKS[@]}"
  printf 'volume=%s\n' "${VOLUMES[@]}"
} >"$ARTIFACTS_DIR/resource-names.txt"
GENERATED_ENV="$GENERATED_DIR/local.generated.env"
COMPOSE_ARGS=(docker compose --project-directory . -p "$PROJECT_NAME" -f docker/docker-compose.yml)
if [[ -f "$GENERATED_DIR/docker-compose.override.yml" ]]; then
  COMPOSE_ARGS+=(-f "$GENERATED_DIR/docker-compose.override.yml")
fi
if [[ -f "$GENERATED_ENV" ]]; then
  COMPOSE_ARGS+=(--env-file "$GENERATED_ENV")
fi
run_capture_allow_failure docker-ps docker ps --filter "label=com.docker.compose.project=$PROJECT_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
run_capture_allow_failure docker-network-inspect docker network inspect "${NETWORKS[@]}" || true
run_capture_allow_failure docker-volume-inspect docker volume inspect "${VOLUMES[@]}" || true
run_capture_allow_failure docker-logs "${COMPOSE_ARGS[@]}" logs --no-color --tail 200 || true

cat >"$ARTIFACTS_DIR/manual-smoke-checklist.md" <<EOF
# Manual Phase 1 Browser Smoke

Use the URLs in stack-status.out.

- Auth: open a seeded persona login link from seed-apply.out, confirm passwordless login completes through Mailpit if a code is required.
- Documents: open a seeded document, create or edit content, reload, and confirm it persists.
- Channels/messages: open a seeded channel, send a message, and confirm another persona with access can see it.
- Search: search for seeded document/channel/message text and record whether the expected result appears.
- File upload/download: upload a small disposable file, open/download it, and confirm local object storage serves it back.
- WebSockets/collaboration: open the same document as two personas and confirm live edits or presence updates arrive without refresh.
- Background workers: trigger a flow backed by LocalStack queues, then check docker-logs.out for successful worker processing and no crash loops.

Classify every failure in failure-log.md as one of:

- upstream local-stack bug
- self-hosting gap
- operator decision
EOF

touch "$ARTIFACTS_DIR/failure-log.md"

if [[ "$KEEP_STACK" == "true" ]]; then
  echo "Stack left running for manual smoke. Tear it down with:" | tee "$ARTIFACTS_DIR/next-steps.txt"
  echo "just stack down --instance $INSTANCE --port-base $PORT_BASE" | tee -a "$ARTIFACTS_DIR/next-steps.txt"
else
  run_capture stack-down just stack down --instance "$INSTANCE" --port-base "$PORT_BASE"
fi

echo "Phase 1 smoke capture complete. Artifacts: $ARTIFACTS_DIR"
