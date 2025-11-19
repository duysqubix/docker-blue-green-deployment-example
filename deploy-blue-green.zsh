#!/usr/bin/env zsh
set -euo pipefail

# Config
APP_NAME="myapp"
LIVE_LABEL_KEY="traefik.enable"
LIVE_LABEL_VALUE="true"

# Always deploy the latest image tag
VERSION_TAG="latest"
echo "Using VERSION_TAG='${VERSION_TAG}'"

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
  echo "Starting stack '${color}' (Traefik=${traefik_enabled})..."
  COMPOSE_PROJECT_NAME="${APP_NAME}_${color}" \
  VERSION_TAG="${VERSION_TAG}" \
  DEPLOY_COLOR="${color}" \
  TRAEFIK_ENABLE="${traefik_enabled}" \
  TRAEFIK_PRIORITY="${traefik_priority}" \
  docker compose up -d --build  --pull always
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

LIVE_COLOR=$(get_live_color)

if [[ "$LIVE_COLOR" == "none" ]]; then
  BOOTSTRAP_COLOR="blue"
  echo "No live stack detected. Bootstrapping '${BOOTSTRAP_COLOR}' as the initial deployment..."
  start_stack "$BOOTSTRAP_COLOR" "true" "$(generate_priority)"
  echo "'${BOOTSTRAP_COLOR}' is now serving traffic."
  exit 0
fi

if [[ "$LIVE_COLOR" == "blue" ]]; then
  OLD_COLOR="blue"
  NEW_COLOR="green"
else
  OLD_COLOR="green"
  NEW_COLOR="blue"
fi

echo "Current live color: $LIVE_COLOR"
echo "Preparing new deployment on: $NEW_COLOR"

# 1) Bring up NEW_COLOR with Traefik disabled so it can be validated without traffic.
start_stack "$NEW_COLOR" "false" "0"

echo "New stack '$NEW_COLOR' is up. Run validation/tests against it."
read "?Press ENTER to continue and switch traffic to ${NEW_COLOR}, or Ctrl+C to abort."

# 2) Enable NEW_COLOR in Traefik with a higher priority so Traefik switches immediately.
NEW_PRIORITY="$(generate_priority)"
start_stack "$NEW_COLOR" "true" "$NEW_PRIORITY"

# 3) Disable OLD_COLOR in Traefik (containers remain running for fast rollback).
start_stack "$OLD_COLOR" "false" "0"

echo "Traffic switched to ${NEW_COLOR}."
echo
echo "If everything is stable, the previous stack can be removed later with:"
echo "  COMPOSE_PROJECT_NAME=${APP_NAME}_${OLD_COLOR} docker compose down"
