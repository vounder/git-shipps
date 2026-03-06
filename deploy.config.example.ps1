# git-shipps — Deploy Configuration
# ─────────────────────────────────────────────────────────────────────────────
# Copy this file to deploy.config.ps1 and fill in your values.
# deploy.config.ps1 is in .gitignore — never commit it (contains server details).
# ─────────────────────────────────────────────────────────────────────────────

# ── Server ────────────────────────────────────────────────────────────────────
$SERVER_USER = "root"                  # SSH user on your VPS
$SERVER_IP   = "1.2.3.4"              # IP address or hostname of your VPS

# ── App path on VPS ───────────────────────────────────────────────────────────
$REMOTE_APP  = "/root/myapp"           # Absolute path where your repo is cloned on the VPS

# ── Docker Compose ────────────────────────────────────────────────────────────
$COMPOSE_FILE = "docker-compose.prod.yml"  # Compose file to use for production

# ── SSH Key ───────────────────────────────────────────────────────────────────
# Path to the private SSH key used to connect to the VPS.
# Created by setup-deploy-key.ps1, or set to "" to use your default SSH key.
$DEPLOY_KEY = "$HOME\.ssh\deploy_key"

# ── Health Check (optional) ───────────────────────────────────────────────────
# URL that should return HTTP 200 after a successful deploy.
# Set to "" or remove this line to skip the health check.
$HEALTH_URL = "http://127.0.0.1:3000/health"

# ── App URL (optional) ────────────────────────────────────────────────────────
# Shown at the end of a successful deploy for quick access.
$APP_URL = "https://example.com"

# ── Git Branch ────────────────────────────────────────────────────────────────
# Branch to push and pull. Defaults to "main" if not set.
$DEFAULT_BRANCH = "main"

# ── Webhook Notification (optional) ──────────────────────────────────────────
# Discord or Slack incoming webhook URL. Set to "" to disable.
# Discord:  https://discord.com/api/webhooks/<id>/<token>
# Slack:    https://hooks.slack.com/services/<id>/<token>
$WEBHOOK_URL = ""
