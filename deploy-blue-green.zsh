#!/usr/bin/env zsh
set -euo pipefail

# Load optional env file to centralize config tweaks.
ENV_FILE="${ENV_FILE:-.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

# Config (can be overridden through environment/.env)
APP_NAME="${APP_NAME:-myapp}"
LIVE_LABEL_KEY="${LIVE_LABEL_KEY:-traefik.enable}"
LIVE_LABEL_VALUE="${LIVE_LABEL_VALUE:-true}"
HEALTHCHECK_ENDPOINT="${HEALTHCHECK_ENDPOINT:-http://localhost:3000/color}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-60}"        # seconds
HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL:-3}"       # seconds
SKIP_HEALTHCHECK="${SKIP_HEALTHCHECK:-false}"
STACK_SERVICE_NAME="${STACK_SERVICE_NAME:-webapp}"

usage() {
  cat >&2 <<'USAGE'
Usage: ./deploy-blue-green.zsh [action] [options]
Actions:
  deploy        Build/update the idle color, validate it, then switch traffic
  shutdown      Stop both color stacks
  rollback      Re-enable the previously idle color and disable the live one

Options (also configurable via env/.env):
  --skip-health-check    Skip pre-promotion health validation
USAGE
}

ACTION="deploy"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-health-check)
      SKIP_HEALTHCHECK="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    deploy|shutdown|rollback)
      ACTION="$1"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  local level="$1"; shift
  printf '[%s] [%s] %s\n' "$(timestamp)" "$level" "$*"
}

log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }

stack_exists() {
  local color="$1"
  docker ps --filter "name=${APP_NAME}_${color}" --format '{{.ID}}' | head -n1 | grep -q .
}

service_container_id() {
  local color="$1"
  COMPOSE_PROJECT_NAME="${APP_NAME}_${color}" docker compose ps -q "$STACK_SERVICE_NAME" 2>/dev/null || true
}

# Always deploy the latest image tag
VERSION_TAG="latest"
log_info "Using VERSION_TAG='${VERSION_TAG}'"

# Determine which color is currently live by inspecting Traefik labels
get_live_color() {
  local blue_live green_live

  blue_live=$(docker ps --filter "name=${APP_NAME}_blue" --format '{{.ID}}' | head -n1)
  green_live=$(docker ps --filter "name=${APP_NAME}_green" --format '{{.ID}}' | head -n1)

  local blue_label="false"
  local green_label="false"

  if [[ -n "$blue_live" ]]; then
    blue_label=$(docker inspect -f "{{index .Config.Labels \"${LIVE_LABEL_KEY}\"}}" "$blue_live" 2>/dev/null || echo "false")
  fi

  if [[ -n "$green_live" ]]; then
    green_label=$(docker inspect -f "{{index .Config.Labels \"${LIVE_LABEL_KEY}\"}}" "$green_live" 2>/dev/null || echo "false")
  fi

  if [[ "$blue_label" == "$LIVE_LABEL_VALUE" ]]; then
    echo "blue"
  elif [[ "$green_label" == "$LIVE_LABEL_VALUE" ]]; then
    echo "green"
  else
    echo "none"
  fi
}

start_stack() {
  local color="$1"
  local traefik_enabled="$2"
  local traefik_priority="${3:-0}"
  log_info "Starting stack '${color}' (Traefik=${traefik_enabled}, Priority=${traefik_priority})..."
  COMPOSE_PROJECT_NAME="${APP_NAME}_${color}" \
  VERSION_TAG="${VERSION_TAG}" \
  DEPLOY_COLOR="${color}" \
  TRAEFIK_ENABLE="${traefik_enabled}" \
  TRAEFIK_PRIORITY="${traefik_priority}" \
  docker compose up -d --build --pull always
}

shutdown_all_stacks() {
  local color
  log_info "Shutting down all ${APP_NAME} stacks..."
  for color in blue green; do
    log_info "Stopping stack '${color}'..."
    COMPOSE_PROJECT_NAME="${APP_NAME}_${color}" \
    VERSION_TAG="${VERSION_TAG}" \
    DEPLOY_COLOR="${color}" \
    TRAEFIK_ENABLE="false" \
    docker compose down --remove-orphans
  done
  log_info "All stacks have been stopped."
}

health_check_stack() {
  local color="$1"
  if [[ "$SKIP_HEALTHCHECK" == "true" ]]; then
    log_warn "Skipping health check for stack '${color}' (SKIP_HEALTHCHECK=true)."
    return 0
  fi

  local elapsed=0
  printf -v health_cmd 'if command -v wget >/dev/null 2>&1; then wget -qO- %q >/dev/null; elif command -v curl >/dev/null 2>&1; then curl -sf %q >/dev/null; else echo "wget/curl missing in container" >&2; exit 1; fi' \
    "$HEALTHCHECK_ENDPOINT" "$HEALTHCHECK_ENDPOINT"

  while (( elapsed < HEALTHCHECK_TIMEOUT )); do
    if [[ -n "$(service_container_id "$color")" ]]; then
      if COMPOSE_PROJECT_NAME="${APP_NAME}_${color}" docker compose exec -T "$STACK_SERVICE_NAME" sh -c "$health_cmd"; then
        log_info "Health check passed for stack '${color}'."
        return 0
      fi
    else
      log_info "Service '${STACK_SERVICE_NAME}' in stack '${color}' not ready yet."
    fi
    sleep "$HEALTHCHECK_INTERVAL"
    elapsed=$((elapsed + HEALTHCHECK_INTERVAL))
    log_info "Waiting for stack '${color}' to become healthy (${elapsed}s/${HEALTHCHECK_TIMEOUT}s)..."
  done

  log_error "Health check failed for stack '${color}' after ${HEALTHCHECK_TIMEOUT}s."
  return 1
}

generate_priority() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
  else
    date +%s
  fi
}

case "$ACTION" in
  deploy)
    ;;
  shutdown)
    shutdown_all_stacks
    exit 0
    ;;
  rollback)
    LIVE_COLOR=$(get_live_color)
    if [[ "$LIVE_COLOR" == "none" ]]; then
      log_error "Cannot rollback because no live stack is currently enabled."
      exit 1
    fi
    if [[ "$LIVE_COLOR" == "blue" ]]; then
      TARGET_COLOR="green"
    else
      TARGET_COLOR="blue"
    fi
    if ! stack_exists "$TARGET_COLOR"; then
      log_error "Cannot rollback: stack '${TARGET_COLOR}' is not running."
      exit 1
    fi
    log_info "Rolling back: enabling '${TARGET_COLOR}' and disabling '${LIVE_COLOR}'."
    start_stack "$TARGET_COLOR" "true" "$(generate_priority)"
    start_stack "$LIVE_COLOR" "false" "0"
    log_info "Rollback complete. '${TARGET_COLOR}' is now live."
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac

LIVE_COLOR=$(get_live_color)

if [[ "$LIVE_COLOR" == "none" ]]; then
  BOOTSTRAP_COLOR="blue"
  log_info "No live stack detected. Bootstrapping '${BOOTSTRAP_COLOR}' as the initial deployment..."
  start_stack "$BOOTSTRAP_COLOR" "true" "$(generate_priority)"
  log_info "'${BOOTSTRAP_COLOR}' is now serving traffic."
  exit 0
fi

if [[ "$LIVE_COLOR" == "blue" ]]; then
  OLD_COLOR="blue"
  NEW_COLOR="green"
else
  OLD_COLOR="green"
  NEW_COLOR="blue"
fi

log_info "Current live color: $LIVE_COLOR"
log_info "Preparing new deployment on: $NEW_COLOR"

# 1) Bring up NEW_COLOR with Traefik disabled so it can be validated without traffic.
start_stack "$NEW_COLOR" "false" "0"

log_info "Waiting for stack '$NEW_COLOR' to pass health checks at ${HEALTHCHECK_ENDPOINT}."
if ! health_check_stack "$NEW_COLOR"; then
  log_error "Deployment aborted: '${NEW_COLOR}' failed health validation. '${OLD_COLOR}' remains live."
  exit 1
fi

# 2) Enable NEW_COLOR in Traefik with a higher priority so Traefik switches immediately.
NEW_PRIORITY="$(generate_priority)"
start_stack "$NEW_COLOR" "true" "$NEW_PRIORITY"

# 3) Disable OLD_COLOR in Traefik (containers remain running for fast rollback).
start_stack "$OLD_COLOR" "false" "0"

log_info "Traffic switched to ${NEW_COLOR}."
log_info "If everything is stable, the previous stack can be removed later with:"
log_info "  COMPOSE_PROJECT_NAME=${APP_NAME}_${OLD_COLOR} docker compose down"
