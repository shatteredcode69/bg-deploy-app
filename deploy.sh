#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  deploy.sh  –  Blue-Green Zero-Downtime Deployment Script
#  Runs on the EC2 instance via SSH from the GitHub Actions pipeline.
#
#  Usage (called by CI):
#    bash deploy.sh <ECR_REGISTRY> <ECR_REPO> <IMAGE_TAG> <APP_VERSION>
#
#  What it does:
#    1. Determines which slot (blue|green) is currently IDLE
#    2. Pulls the new image from ECR
#    3. Starts the idle container with the new image
#    4. Waits for Docker HEALTHCHECK to pass (max 60s)
#    5. Validates with a curl-based /health probe
#    6. Atomically switches the Nginx symlink to the new slot
#    7. Reloads Nginx (zero downtime)
#    8. Prunes old Docker images (housekeeping)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colour output helpers ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()    { echo -e "${CYAN}[DEPLOY]${RESET} $*"; }
ok()     { echo -e "${GREEN}[  OK  ]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[ WARN ]${RESET} $*"; }
fail()   { echo -e "${RED}[ FAIL ]${RESET} $*"; exit 1; }
banner() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}\n"; }

# ── Argument validation ───────────────────────────────────────────────────────
if [[ $# -lt 4 ]]; then
  fail "Usage: $0 <ECR_REGISTRY> <ECR_REPO> <IMAGE_TAG> <APP_VERSION>"
fi

ECR_REGISTRY="$1"
ECR_REPO="$2"
IMAGE_TAG="$3"
APP_VERSION="$4"
FULL_IMAGE="${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"

NGINX_CONF_DIR="/etc/nginx/conf.d"
ACTIVE_SYMLINK="${NGINX_CONF_DIR}/active.conf"
COMPOSE_FILE="/home/ec2-user/blue-green-deployment/docker-compose.yml"

BLUE_PORT=3001
GREEN_PORT=3002
HEALTH_RETRIES=12      # × 5s = 60s max
HEALTH_INTERVAL=5

# ── Step 1 – Determine active/idle slots ─────────────────────────────────────
banner "Step 1 – Slot Detection"

# Read current symlink target to determine active slot
if [[ -L "${ACTIVE_SYMLINK}" ]]; then
  ACTIVE_TARGET=$(readlink -f "${ACTIVE_SYMLINK}")
  if echo "${ACTIVE_TARGET}" | grep -q "blue"; then
    ACTIVE_SLOT="blue"
    IDLE_SLOT="green"
    IDLE_PORT="${GREEN_PORT}"
  else
    ACTIVE_SLOT="green"
    IDLE_SLOT="blue"
    IDLE_PORT="${BLUE_PORT}"
  fi
else
  # First deployment – no symlink yet; default to blue as active, deploy to green
  warn "No active symlink found – assuming first deployment."
  ACTIVE_SLOT="none"
  IDLE_SLOT="blue"
  IDLE_PORT="${BLUE_PORT}"
fi

log "Active slot : ${BOLD}${ACTIVE_SLOT}${RESET}"
log "Idle slot   : ${BOLD}${IDLE_SLOT}${RESET} (port ${IDLE_PORT})"
log "New image   : ${FULL_IMAGE}"

# ── Step 2 – Pull the new image from ECR ──────────────────────────────────────
banner "Step 2 – Pull Image"

log "Pulling ${FULL_IMAGE} …"
docker pull "${FULL_IMAGE}" || fail "Docker pull failed."
ok "Image pulled successfully."

# Export env vars for docker compose
export ECR_REGISTRY ECR_REPO IMAGE_TAG APP_VERSION

# ── Step 3 – Start idle container with new image ─────────────────────────────
banner "Step 3 – Deploy Idle Container (${IDLE_SLOT})"

log "Stopping and removing old ${IDLE_SLOT} container (if any) …"
docker compose -f "${COMPOSE_FILE}" rm -sf "${IDLE_SLOT}" 2>/dev/null || true

log "Starting ${IDLE_SLOT} container …"
docker compose -f "${COMPOSE_FILE}" up -d "${IDLE_SLOT}"
ok "${IDLE_SLOT} container started."

# ── Step 4 – Wait for Docker healthcheck to report healthy ───────────────────
banner "Step 4 – Docker Health Gate"

log "Waiting for Docker HEALTHCHECK to pass (max ${HEALTH_RETRIES}×${HEALTH_INTERVAL}s) …"
CONTAINER_NAME="bg-${IDLE_SLOT}"
attempt=0
while [[ $attempt -lt ${HEALTH_RETRIES} ]]; do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
  if [[ "${STATUS}" == "healthy" ]]; then
    ok "Docker healthcheck: ${STATUS}"
    break
  fi
  attempt=$((attempt + 1))
  log "Attempt ${attempt}/${HEALTH_RETRIES} – status: ${STATUS} – waiting ${HEALTH_INTERVAL}s …"
  sleep "${HEALTH_INTERVAL}"
done

if [[ "${STATUS}" != "healthy" ]]; then
  fail "Container did not become healthy after $((HEALTH_RETRIES * HEALTH_INTERVAL))s. Aborting."
fi

# ── Step 5 – Curl-based /health probe ────────────────────────────────────────
banner "Step 5 – HTTP Health Check"

HEALTH_URL="http://127.0.0.1:${IDLE_PORT}/health"
log "Probing ${HEALTH_URL} …"

HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "${HEALTH_URL}" || echo "000")

if [[ "${HTTP_CODE}" != "200" ]]; then
  fail "/health returned HTTP ${HTTP_CODE}. Aborting traffic switch."
fi

# Parse environment from response to verify correct slot is running
HEALTH_BODY=$(curl -sf --max-time 5 "${HEALTH_URL}" || echo '{}')
HEALTH_ENV=$(echo "${HEALTH_BODY}" | grep -o '"environment":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
ok "HTTP 200 – running environment: ${HEALTH_ENV}"

if [[ "${HEALTH_ENV}" != "${IDLE_SLOT}" ]]; then
  fail "Health check returned env '${HEALTH_ENV}', expected '${IDLE_SLOT}'. Aborting."
fi

# ── Step 6 – Atomic Nginx symlink switch ─────────────────────────────────────
banner "Step 6 – Nginx Traffic Switch"

NEW_CONF="${NGINX_CONF_DIR}/${IDLE_SLOT}.conf"
TEMP_LINK="${NGINX_CONF_DIR}/active.conf.tmp"

log "Switching Nginx → ${IDLE_SLOT} …"

# Atomic symlink replacement (ln -sfn + mv is POSIX-atomic)
ln -sfn "${NEW_CONF}" "${TEMP_LINK}"
mv -f "${TEMP_LINK}" "${ACTIVE_SYMLINK}"

ok "Symlink updated: active.conf → ${NEW_CONF}"

# Test config before reload
log "Testing Nginx configuration …"
nginx -t || fail "nginx -t failed. Symlink NOT reloaded."

log "Reloading Nginx (graceful) …"
systemctl reload nginx || fail "nginx reload failed."

ok "Nginx reloaded. Traffic now routed to ${BOLD}${IDLE_SLOT}${RESET}."

# ── Step 7 – Teardown old active container (optional grace period) ────────────
banner "Step 7 – Graceful Old Container Stop"

if [[ "${ACTIVE_SLOT}" != "none" ]]; then
  log "Giving ${ACTIVE_SLOT} a 15s grace period to drain connections …"
  sleep 15
  log "Stopping ${ACTIVE_SLOT} container …"
  docker compose -f "${COMPOSE_FILE}" stop "${ACTIVE_SLOT}" || warn "Could not stop ${ACTIVE_SLOT} – continuing."
  ok "${ACTIVE_SLOT} container stopped."
fi

# ── Step 8 – Prune old Docker images ─────────────────────────────────────────
banner "Step 8 – Image Cleanup"

log "Pruning dangling and unused Docker images …"
docker image prune -af --filter "until=24h" 2>/dev/null || warn "Image prune returned non-zero – continuing."
ok "Disk cleanup complete."

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Deployment Complete"
echo -e "  ${GREEN}●${RESET} New active slot  : ${BOLD}${IDLE_SLOT}${RESET}"
echo -e "  ${GREEN}●${RESET} Image deployed   : ${FULL_IMAGE}"
echo -e "  ${GREEN}●${RESET} App version      : ${APP_VERSION}"
echo -e "  ${GREEN}●${RESET} Previous slot    : ${ACTIVE_SLOT} (stopped)"
echo -e ""
ok "Zero-downtime deployment finished successfully. 🚀"
