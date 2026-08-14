#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# --- Defaults ---------------------------------------------------------------
REGISTRY="${MACRO_RELEASE_IMAGE_REGISTRY:-}"
TAG="${MACRO_RELEASE_IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo dev)}"
PUSH=false
SERVICES=()
DOCKERFILE="docker/Dockerfile"
DRY_RUN=false
VERBOSE=false

# --- Rust services built from docker/Dockerfile -----------------------------
# These services share the production-shaped Dockerfile and only differ by
# the Cargo binary name passed as SERVICE_NAME.
# Compose service name -> Cargo binary name. Image names use kebab-case
# (e.g. contacts-service) while Compose service names use snake_case.
RUST_SERVICES=(
  authentication-service:authentication_service
  connection-gateway:connection_gateway
  contacts-service:contacts_service
  document-cognition-service:document_cognition_service
  document-storage-service:document_storage_service
  document-upload-finalizer:document_upload_finalizer
  email-service:email_service
  email-pubsub-workers:email_pubsub_workers
  notification-service:notification_service
  static-file-service:static_file_service
)

# --- Services that need their own Dockerfile --------------------------------
# search_processing_service needs pdfium; convert_service needs LibreOffice.
# These are excluded from the default build until their release images are
# proven.  Build them explicitly with --service if you have a tested image.
SPECIAL_SERVICES=(
  search-processing-service
  convert-service
)

# --- JS/Worker services (not covered by the Rust prototype) -----------------
JS_SERVICES=(
  sync_service
  lexical_service
  ai_editing_worker
  analytics_proxy
  websocket_service
)

usage() {
  cat <<'USAGE'
Usage: tooling/selfhost/build-release-images.sh [options]

Build per-service release images for the Macro self-host stack.

Options:
  --registry REG       Target registry (e.g. ghcr.io/my-org). Required.
  --tag TAG            Image tag (default: short git SHA).
  --push               Push images after building.
  --service NAME       Build only this service (repeatable). Default: all Rust services.
  --dockerfile PATH    Override Dockerfile path (default: docker/Dockerfile).
  --dry-run            Print commands without executing.
  -v, --verbose        Verbose output.
  -h, --help           Show this help.

Environment:
  MACRO_RELEASE_IMAGE_REGISTRY   Same as --registry.
  MACRO_RELEASE_IMAGE_TAG        Same as --tag.

Examples:
  # Build all Rust services locally
  ./tooling/selfhost/build-release-images.sh --registry ghcr.io/my-org

  # Build and push with a stable tag
  ./tooling/selfhost/build-release-images.sh --registry ghcr.io/my-org --tag v2026.4.28.0 --push

  # Build only authentication-service
  ./tooling/selfhost/build-release-images.sh --registry ghcr.io/my-org --service authentication-service
USAGE
}

log() {
  printf '[build-release-images] %s\n' "$*" >&2
}

die() {
  printf '[build-release-images] ERROR: %s\n' "$*" >&2
  exit 1
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
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

# --- Parse args ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)
      REGISTRY="${2:?missing value for --registry}"
      shift 2
      ;;
    --tag)
      TAG="${2:?missing value for --tag}"
      shift 2
      ;;
    --push)
      PUSH=true
      shift
      ;;
    --service)
      SERVICES+=("${2:?missing value for --service}")
      shift 2
      ;;
    --dockerfile)
      DOCKERFILE="${2:?missing value for --dockerfile}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -z "$REGISTRY" ]] && die "--registry is required (or set MACRO_RELEASE_IMAGE_REGISTRY)"

require_tool docker

# If no --service given, default to all Rust services.
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  for pair in "${RUST_SERVICES[@]}"; do
    SERVICES+=("${pair%%:*}")
  done
fi

# --- Build -------------------------------------------------------------------
log "Building release images with registry=$REGISTRY tag=$TAG"

for svc in "${SERVICES[@]}"; do
  # Find the Cargo binary name for this service
  bin=""
  for pair in "${RUST_SERVICES[@]}"; do
    if [[ "${pair%%:*}" == "$svc" ]]; then
      bin="${pair##*:}"
      break
    fi
  done

  # Handle special services that need their own Dockerfile
  if [[ -z "$bin" ]]; then
    case "$svc" in
      search-processing-service)
        log "WARNING: $svc is a special-case service (pdfium). Using docker/Dockerfile.search_processing_service."
        DOCKERFILE_SVC="docker/Dockerfile.search_processing_service"
        bin="search_processing_service"
        ;;
      convert-service)
        log "WARNING: $svc is a special-case service (LibreOffice). Using docker/Dockerfile.convert_service."
        DOCKERFILE_SVC="docker/Dockerfile.convert_service"
        bin="convert_service"
        ;;
      *)
        die "unknown service: $svc (not in RUST_SERVICES or special-case list)"
        ;;
    esac
  else
    DOCKERFILE_SVC="$DOCKERFILE"
  fi

  image="$REGISTRY/$svc:$TAG"
  log "Building $image (SERVICE_NAME=$bin)"

  run docker build \
    -f "$DOCKERFILE_SVC" \
    --build-arg "SERVICE_NAME=$bin" \
    -t "$image" \
    .

  if [[ "$PUSH" == "true" ]]; then
    log "Pushing $image"
    run docker push "$image"
  fi
done

log "Done. Built ${#SERVICES[@]} image(s) with tag $TAG"
if [[ "$PUSH" == "true" ]]; then
  log "Images pushed to $REGISTRY"
  log "Set MACRO_RELEASE_IMAGE_REGISTRY=$REGISTRY and MACRO_RELEASE_IMAGE_TAG=$TAG in your .env"
fi
