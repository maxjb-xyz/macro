#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="compose.yml"
ENV_FILE=".env"
BACKUP_DIR=""
PROJECT_NAME="$(basename "$ROOT_DIR")"
FORCE_DESTRUCTIVE_RESTORE=false
DRY_RUN=false

STATEFUL_SERVICES=(postgres redis search kafka fusionauth db)
APP_WRITER_SERVICES=(
  authentication-service
  connection_gateway
  contacts_service
  document_cognition_service
  document_storage_service
  document_upload_finalizer
  email_service
  email_pubsub_workers
  notification_service
  search_processing_service
  static_file_service
  sync_service
  ai_editing_worker
  analytics_proxy
  lexical_service
)

# archive-name:docker-volume-name
VOLUME_ARCHIVES=(
  macro-postgres-volume.tar.gz:macro_postgres_data
  redis-volume.tar.gz:macro_redis_data
  opensearch-volume.tar.gz:macro_opensearch_data
  kafka-volume.tar.gz:macro_kafka_data
  fusionauth-db-volume.tar.gz:fusionauth_db_data
  fusionauth-config-volume.tar.gz:fusionauth_config
  # Present when durable LocalStack is enabled (it is, by default, via the
  # localstack swap in compose.frontend.yml); skipped otherwise.
  localstack-volume.tar.gz:macro_localstack_data
)

usage() {
  cat <<'USAGE'
Usage: tooling/selfhost/backup-restore.sh <command> [options]

Commands:
  inventory             Print rendered Compose volumes and mounted state paths
  backup                Create logical DB dumps and quiesced volume archives
  restore               Restore archives into Docker volumes (destructive gate required)

Options:
  --backup-dir DIR      Backup directory (default: artifacts/selfhost-backups/<timestamp> for backup)
  --env-file FILE       Compose env file (default: .env; .env.example is used when .env is absent)
  --dry-run             Print destructive or service-impacting commands without running them
  --i-understand-data-loss
                        Required for restore. Restore overwrites existing Docker volume contents.
  -h, --help            Show this help

This is an operator skeleton, not a complete production backup system. Copy the
resulting backup directory to encrypted off-host storage and verify restore on a
separate host before trusting it.
USAGE
}

log() {
  printf '[selfhost-backup] %s\n' "$*" >&2
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '+ ' >&2
    printf '%q ' "$@" >&2
    printf '\n' >&2
  else
    "$@"
  fi
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required tool: $1" >&2
    exit 127
  fi
}

resolve_env_file() {
  if [[ ! -f "$ENV_FILE" && -f "$ROOT_DIR/.env.example" ]]; then
    ENV_FILE=".env.example"
  fi
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "env file not found: $ENV_FILE" >&2
    exit 64
  fi
  ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
}

compose() {
  # compose.yml includes the upstream base + self-host overlays + release-image
  # overrides, so a single file drives backup/restore.
  env "MACRO_ENV_FILE=$ENV_FILE" docker compose \
    --project-directory "$ROOT_DIR" \
    -f "$ROOT_DIR/$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    "$@"
}

ensure_backup_dir() {
  if [[ -z "$BACKUP_DIR" ]]; then
    BACKUP_DIR="$ROOT_DIR/artifacts/selfhost-backups/backup-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  mkdir -p "$BACKUP_DIR"
  BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"
}

write_manifest() {
  {
    echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "repo_root=$ROOT_DIR"
    git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null | sed 's/^/commit=/' || true
    echo "compose_file=$COMPOSE_FILE"
    echo "compose_project=$PROJECT_NAME"
    echo "env_file=$ENV_FILE"
    sha256sum "$ENV_FILE" 2>/dev/null | sed 's/^/env_sha256=/' || true
    printf 'stateful_services=%s\n' "${STATEFUL_SERVICES[*]}"
    printf 'app_writer_services=%s\n' "${APP_WRITER_SERVICES[*]}"
    printf 'volume_archives=%s\n' "${VOLUME_ARCHIVES[*]}"
  } >"$BACKUP_DIR/manifest.env"
  compose config --volumes >"$BACKUP_DIR/compose-volumes.txt"
  compose config --images >"$BACKUP_DIR/compose-images.txt"
}

inventory() {
  require_tool docker
  resolve_env_file
  log "Rendered volumes:"
  compose config --volumes
  log "Mounted named volumes and bind mounts:"
  compose config --format json | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
for name, svc in sorted(cfg.get("services", {}).items()):
    mounts = svc.get("volumes") or []
    interesting = []
    for mount in mounts:
        typ = mount.get("type")
        source = mount.get("source")
        target = mount.get("target")
        ro = mount.get("read_only")
        if typ in {"volume", "bind"}:
            interesting.append((typ, source, target, ro))
    if interesting:
        print(name)
        for typ, source, target, ro in interesting:
            flag = "ro" if ro else "rw"
            print(f"  {typ}: {source} -> {target} ({flag})")
'
}

backup() {
  require_tool docker
  require_tool sha256sum
  require_tool git
  resolve_env_file
  ensure_backup_dir
  log "Writing backup to $BACKUP_DIR"
  write_manifest

  log "Stopping application writer services"
  run compose stop -t 30 "${APP_WRITER_SERVICES[@]}"

  log "Creating logical database dumps"
  run compose exec -T postgres pg_dumpall -U user >"$BACKUP_DIR/macro-postgres.sql"
  run compose exec -T db pg_dumpall -U postgres >"$BACKUP_DIR/fusionauth-postgres.sql"

  log "Stopping stateful services for quiesced volume archives"
  run compose stop -t 60 "${STATEFUL_SERVICES[@]}"

  for pair in "${VOLUME_ARCHIVES[@]}"; do
    archive="${pair%%:*}"
    volume="${pair##*:}"
    if ! docker volume inspect "$volume" >/dev/null 2>&1; then
      log "Skipping $volume (not present — durable LocalStack overlay not enabled)"
      continue
    fi
    log "Archiving $volume -> $archive"
    run docker run --rm \
      -v "$volume:/source:ro" \
      -v "$BACKUP_DIR:/backup" \
      alpine:3 \
      sh -ceu "tar czf /backup/$archive -C /source ."
  done

  log "Computing checksums"
  if [[ "$DRY_RUN" != "true" ]]; then
    (cd "$BACKUP_DIR" && sha256sum ./* >SHA256SUMS)
  fi

  log "Restarting stack"
  run compose up -d
  log "Backup skeleton complete. Copy $BACKUP_DIR to encrypted off-host storage."
}

restore() {
  require_tool docker
  resolve_env_file
  if [[ "$FORCE_DESTRUCTIVE_RESTORE" != "true" ]]; then
    echo "restore is destructive; rerun with --i-understand-data-loss" >&2
    exit 64
  fi
  if [[ -z "$BACKUP_DIR" || ! -d "$BACKUP_DIR" ]]; then
    echo "restore requires --backup-dir DIR" >&2
    exit 64
  fi
  BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

  log "Stopping full stack before restore"
  run compose down --remove-orphans

  for pair in "${VOLUME_ARCHIVES[@]}"; do
    archive="${pair%%:*}"
    volume="${pair##*:}"
    if [[ ! -f "$BACKUP_DIR/$archive" ]]; then
      if [[ "$volume" == "macro_localstack_data" ]]; then
        log "Skipping $archive (not in this backup — durable LocalStack overlay was not enabled at backup time)"
        continue
      fi
      echo "missing archive: $BACKUP_DIR/$archive" >&2
      exit 66
    fi
    log "Restoring $archive -> $volume"
    run docker volume create "$volume" >/dev/null
    run docker run --rm \
      -v "$volume:/target" \
      -v "$BACKUP_DIR:/backup:ro" \
      alpine:3 \
      sh -ceu "rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null || true; tar xzf /backup/$archive -C /target"
  done

  log "Starting stateful services first"
  run compose up -d postgres db redis kafka search fusionauth
  log "Start remaining services after stateful health checks pass:"
  log "  docker compose --project-directory $ROOT_DIR -f $COMPOSE_FILE --env-file $ENV_FILE up -d"
}

main() {
  if [[ $# -eq 0 ]]; then
    usage >&2
    exit 64
  fi

  command="$1"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backup-dir)
        BACKUP_DIR="${2:?missing value for --backup-dir}"
        shift 2
        ;;
      --env-file)
        ENV_FILE="${2:?missing value for --env-file}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --i-understand-data-loss)
        FORCE_DESTRUCTIVE_RESTORE=true
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
  case "$command" in
    inventory) inventory ;;
    backup) backup ;;
    restore) restore ;;
    -h|--help) usage ;;
    *)
      echo "unknown command: $command" >&2
      usage >&2
      exit 64
      ;;
  esac
}

main "$@"
