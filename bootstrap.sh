#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  bootstrap.sh  –  One-time EC2 Instance Setup (Amazon Linux 2023)
#
#  Run this ONCE on a fresh EC2 instance to install all dependencies and
#  prepare the server for blue-green deployments.
#
#  Usage:
#    chmod +x bootstrap.sh && sudo bash bootstrap.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()  { echo -e "${CYAN}[SETUP]${RESET} $*"; }
ok()   { echo -e "${GREEN}[  OK ]${RESET} $*"; }
fail() { echo -e "${RED}[ ERR ]${RESET} $*"; exit 1; }

banner() {
  echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}${CYAN}  $*${RESET}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

[[ $EUID -ne 0 ]] && fail "Run as root: sudo bash bootstrap.sh"

AWS_REGION="${AWS_REGION:-us-east-1}"
APP_DIR="/home/ec2-user/blue-green-deployment"
NGINX_CONF_DIR="/etc/nginx/conf.d"

# ── 1. System update ──────────────────────────────────────────────────────────
banner "1 – System Update"
dnf update -y
ok "System updated."

# ── 2. Docker installation ────────────────────────────────────────────────────
banner "2 – Docker"
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user
ok "Docker installed and running."

# ── 3. Docker Compose v2 ──────────────────────────────────────────────────────
banner "3 – Docker Compose v2"
COMPOSE_VERSION="v2.27.0"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL \
  "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
ok "Docker Compose $(docker compose version) installed."

# ── 4. Nginx ─────────────────────────────────────────────────────────────────
banner "4 – Nginx"
dnf install -y nginx
systemctl enable nginx
ok "Nginx installed."

# ── 5. AWS CLI v2 ─────────────────────────────────────────────────────────────
banner "5 – AWS CLI v2"
if ! command -v aws &>/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi
ok "AWS CLI $(aws --version) ready."

# ── 6. ECR credential helper ──────────────────────────────────────────────────
banner "6 – ECR Credential Helper"
dnf install -y amazon-ecr-credential-helper
mkdir -p /root/.docker /home/ec2-user/.docker
cat > /root/.docker/config.json <<'EOF'
{ "credsStore": "ecr-login" }
EOF
cp /root/.docker/config.json /home/ec2-user/.docker/config.json
chown ec2-user:ec2-user /home/ec2-user/.docker/config.json
ok "ECR credential helper configured."

# ── 7. Create application directory ──────────────────────────────────────────
banner "7 – App Directory"
mkdir -p "${APP_DIR}"
chown ec2-user:ec2-user "${APP_DIR}"
ok "App directory created at ${APP_DIR}."

# ── 8. Copy Nginx config files ────────────────────────────────────────────────
banner "8 – Nginx Config"

# Remove default config if present
rm -f /etc/nginx/conf.d/default.conf

# Copy slot configs (assumes files are in ./nginx/ relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "${SCRIPT_DIR}/nginx" ]]; then
  cp "${SCRIPT_DIR}/nginx/blue.conf"   "${NGINX_CONF_DIR}/blue.conf"
  cp "${SCRIPT_DIR}/nginx/green.conf"  "${NGINX_CONF_DIR}/green.conf"
  cp "${SCRIPT_DIR}/nginx/nginx.conf"  /etc/nginx/nginx.conf
  ok "Nginx slot configs installed."
else
  log "nginx/ directory not found. Copy blue.conf/green.conf manually."
fi

# ── 9. Create initial symlink (blue is default active) ────────────────────────
banner "9 – Initial Symlink (→ blue)"
if [[ ! -L "${NGINX_CONF_DIR}/active.conf" ]]; then
  ln -sfn "${NGINX_CONF_DIR}/blue.conf" "${NGINX_CONF_DIR}/active.conf"
  ok "Initial symlink created: active.conf → blue.conf"
else
  ok "Symlink already exists: $(readlink -f ${NGINX_CONF_DIR}/active.conf)"
fi

# ── 10. Validate and start Nginx ──────────────────────────────────────────────
banner "10 – Nginx Validation & Start"
nginx -t && systemctl start nginx
ok "Nginx is running."

# ── 11. Copy docker-compose.yml ───────────────────────────────────────────────
banner "11 – Docker Compose Setup"
if [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
  cp "${SCRIPT_DIR}/docker-compose.yml" "${APP_DIR}/docker-compose.yml"
  chown ec2-user:ec2-user "${APP_DIR}/docker-compose.yml"
  ok "docker-compose.yml installed at ${APP_DIR}/"
fi

# ── 12. Configure ECR region for credential helper ────────────────────────────
banner "12 – ECR Region"
echo "AWS_DEFAULT_REGION=${AWS_REGION}" >> /etc/environment
ok "Region set to ${AWS_REGION}."

# ── Summary ───────────────────────────────────────────────────────────────────
banner "Bootstrap Complete! 🎉"
echo -e "  ${GREEN}●${RESET} Docker   : $(docker --version)"
echo -e "  ${GREEN}●${RESET} Compose  : $(docker compose version)"
echo -e "  ${GREEN}●${RESET} Nginx    : $(nginx -v 2>&1)"
echo -e "  ${GREEN}●${RESET} AWS CLI  : $(aws --version)"
echo -e ""
echo -e "  ${BOLD}Next steps:${RESET}"
echo -e "  1. Configure GitHub Secrets (see README.md)"
echo -e "  2. Push to main to trigger the CI/CD pipeline"
echo -e "  3. Visit http://<EC2-PUBLIC-IP> to see the dashboard"
echo -e ""
log "Log out and back in (or run 'newgrp docker') for Docker group changes."
